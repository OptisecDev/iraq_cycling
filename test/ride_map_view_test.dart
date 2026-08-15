import 'dart:io';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iraq_cycling/models/ride_point.dart';
import 'package:iraq_cycling/screens/ride_map_view.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';
import 'package:iraq_cycling/services/place_search_service.dart';
import 'package:iraq_cycling/services/route_finder.dart';
import 'package:iraq_cycling/utils/arabic_text.dart';

RidePoint _point(
  double latitude,
  double longitude,
  double speedMps,
  int secondsFromEpoch,
) => RidePoint(
  latitude: latitude,
  longitude: longitude,
  altitude: 0,
  speed: speedMps,
  timestamp: DateTime.fromMillisecondsSinceEpoch(secondsFromEpoch * 1000),
  accuracy: 5,
);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // maplibre_gl's MapLibreMap renders via a real AndroidView platform view,
  // which talks to the engine over two channels flutter_test has no
  // backing implementation for: the shared 'flutter/platform_views'
  // channel (create/dispose), and a per-instance
  // 'plugins.flutter.io/maplibre_gl_<id>' channel the plugin opens itself
  // once the view is "created" (see MapLibreMethodChannel.initPlatform).
  // Faking both is enough for the widget tree to build and lay out without
  // throwing - it still never reaches an actual native map, so
  // onStyleLoadedCallback (and so a real MapLibreMapController) never
  // fires, same as without this mocking.
  const platformViewsChannel = MethodChannel('flutter/platform_views');
  final mockedMapChannels = <MethodChannel>[];
  setUp(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformViewsChannel, (call) async {
      switch (call.method) {
        case 'create':
          final id = call.arguments['id'] as int;
          final mapChannel = MethodChannel(
            'plugins.flutter.io/maplibre_gl_$id',
          );
          mockedMapChannels.add(mapChannel);
          TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(mapChannel, (call) async => null);
          return 0;
        default:
          return null;
      }
    });
  });
  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformViewsChannel, null);
    for (final channel in mockedMapChannels) {
      TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
    mockedMapChannels.clear();
  });

  // maplibre_gl renders the map itself via a native AndroidView/UiKitView
  // platform view, which flutter_test cannot actually create -
  // onMapCreated/onStyleLoadedCallback never fire in a widget test, so a
  // real MapLibreMapController (and so real camera state or drawn
  // lines/circles) is never available to assert on here. Two kinds of
  // coverage replace what the old flutter_map-based tests checked directly
  // against the map widget:
  //   - the camera math (headingBetween/dynamicZoomFor, both top-level pure
  //     functions in ride_map_view.dart) is unit-tested directly below,
  //     with no widget tree involved at all - arguably better coverage than
  //     the old approach of pumping a widget and reading MapCamera.of(...).
  //   - the route-planning/search wiring is still tested end-to-end here,
  //     grabbing MapLibreMap.onMapClick straight off the built widget the
  //     same way the old tests grabbed FlutterMap.options.onTap - that part
  //     is a plain constructor callback, not a platform-view behavior, so
  //     it works identically to before.
  //
  // Two behaviors from the old flutter_map-based test file have no
  // replacement here, as a direct consequence of the platform-view swap:
  // a tester.drag()-triggered "manual pan stops following" gesture (there
  // is no Flutter-side gesture arena for a platform view to test against),
  // and reading back drawn polylines/circles as widgets (maplibre_gl adds
  // them imperatively via the controller, which is never created in these
  // tests). Both need manual on-device verification instead.

  group('headingBetween', () {
    test('returns the great-circle bearing between two points', () {
      // Due-east movement (~56m, well past the jitter floor).
      final previous = _point(33.3000, 44.3000, 0, 0);
      final last = _point(33.3000, 44.3006, 0, 5);
      expect(headingBetween(previous, last), closeTo(90, 2));
    });

    test('returns null when the points are within the jitter floor', () {
      final previous = _point(33.3000, 44.3000, 0, 0);
      final last = _point(33.30001, 44.30001, 0, 1);
      expect(headingBetween(previous, last), isNull);
    });
  });

  group('dynamicZoomFor', () {
    test('zooms all the way in when stopped', () {
      expect(dynamicZoomFor(0), closeTo(17.0, 0.001));
    });

    test('pulls back to the far zoom at/above full navigation speed', () {
      expect(dynamicZoomFor(30 / 3.6), closeTo(14.0, 0.001));
      expect(dynamicZoomFor(100 / 3.6), closeTo(14.0, 0.001));
    });

    test('interpolates between the two at partial speed', () {
      final zoom = dynamicZoomFor(15 / 3.6);
      expect(zoom, greaterThan(14.0));
      expect(zoom, lessThan(17.0));
    });
  });

  late Directory tempDir;
  late MapTileService mapTileService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ride_map_view_test');
    mapTileService = MapTileService.readyForTesting(
      styleUrl: 'http://127.0.0.1:1/style.json',
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  // [routeFinder]/[placeSearchService] default to ones pointed at nothing in
  // particular - none of the existing camera/gesture tests below ever
  // trigger a route search or a name search, so their lazily-opened db
  // connections are simply never touched.
  Widget harness(
    List<RidePoint> points,
    bool isLive, {
    RouteFinder? routeFinder,
    PlaceSearchService? placeSearchService,
  }) => MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<MapTileService>.value(value: mapTileService),
        Provider<RouteFinder>.value(value: routeFinder ?? RouteFinder()),
        Provider<PlaceSearchService>.value(
          value: placeSearchService ?? PlaceSearchService(),
        ),
      ],
      child: Scaffold(body: RideMapView(points: points, isLive: isLive)),
    ),
  );

  // The live map's HUD includes a heart icon that pulses on an infinitely
  // repeating AnimationController (see _PulsingHeart in ride_map_view.dart)
  // while isLive is true - pumpAndSettle() never terminates against that
  // (it always has a pending frame scheduled), so tests that render the
  // live map pump a bounded number of frames instead.
  Future<void> pumpSettled(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('live map renders the HUD and no recenter button initially', (
    tester,
  ) async {
    final points = [_point(33.3000, 44.3000, 0, 0)];
    await tester.pumpWidget(harness(points, true));
    await pumpSettled(tester);

    expect(find.byType(ml.MapLibreMap), findsOneWidget);
    expect(find.text('نبض القلب'), findsOneWidget);
    expect(find.byIcon(Icons.my_location), findsNothing);
  });

  testWidgets('non-live map hides the live HUD', (tester) async {
    final points = [_point(33.3000, 44.3000, 0, 0)];
    await tester.pumpWidget(harness(points, false));
    await pumpSettled(tester);

    expect(find.text('نبض القلب'), findsNothing);
  });

  testWidgets(
    'plan-route button arms destination-picking, then a map tap plans and '
    'draws the route',
    (tester) async {
      // A tiny two-node graph: node 1 sits at the rider's current position
      // (so route planning uses the live point, no GPS fix needed), node 2
      // is the tapped destination.
      // sqflite_common_ffi's async db work is real platform/isolate I/O,
      // which never completes against flutter_test's fake clock - it has to
      // run inside tester.runAsync() to actually resolve.
      final dbPath = p.join(tempDir.path, 'routing.db');
      await tester.runAsync(() async {
        final seedDb = await openAppDatabase(overridePath: dbPath);
        await seedDb.insert('routing_nodes', {
          'id': 1,
          'latitude': 33.3000,
          'longitude': 44.3000,
        });
        await seedDb.insert('routing_nodes', {
          'id': 2,
          'latitude': 33.3010,
          'longitude': 44.3010,
        });
        await seedDb.insert('routing_edges', {
          'from_node_id': 1,
          'to_node_id': 2,
          'osm_way_id': 1,
          'highway_type': 'residential',
          'oneway': 1,
          'distance_meters': 1300.0,
          'weight': 1300.0,
        });
      });

      final points = [_point(33.3000, 44.3000, 0, 0)];
      await tester.pumpWidget(
        harness(
          points,
          false,
          routeFinder: RouteFinder(databasePath: dbPath),
        ),
      );
      await pumpSettled(tester);

      // No destination yet, so the plan-route button is showing (and the
      // map ignores taps until it's pressed).
      expect(find.byIcon(Icons.alt_route), findsOneWidget);

      await tester.tap(find.byIcon(Icons.alt_route));
      await pumpSettled(tester);

      // Armed: the button flips to a cancel affordance and the search box
      // appears.
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Grab the live onMapClick callback straight off the built
      // MapLibreMap instead of driving a real touch gesture - screen-pixel
      // -> geo-point conversion isn't what this test is checking; the
      // wiring is. (Same trick the old flutter_map-based test used for
      // FlutterMap.options.onTap.)
      final onMapClick = tester
          .widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap))
          .onMapClick!;
      await tester.runAsync(() async {
        onMapClick(
          const Point(0, 0),
          const ml.LatLng(33.3010, 44.3010),
        );
        // Give the detached _planRouteTo() Future real time to run its
        // sqlite queries to completion before handing back to fake-async
        // pumping below.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await pumpSettled(tester);

      expect(find.textContaining('1.30 كم'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await pumpSettled(tester);

      expect(find.textContaining('1.30 كم'), findsNothing);
      // The plan-route button is back, ready to start over.
      expect(find.byIcon(Icons.alt_route), findsOneWidget);
    },
  );

  testWidgets(
    'destination search finds a place by name and plans a route to it',
    (tester) async {
      final dbPath = p.join(tempDir.path, 'search_routing.db');
      await tester.runAsync(() async {
        final seedDb = await openAppDatabase(overridePath: dbPath);
        await seedDb.insert('routing_nodes', {
          'id': 1,
          'latitude': 33.3000,
          'longitude': 44.3000,
        });
        await seedDb.insert('routing_nodes', {
          'id': 2,
          'latitude': 33.3010,
          'longitude': 44.3010,
        });
        await seedDb.insert('routing_edges', {
          'from_node_id': 1,
          'to_node_id': 2,
          'osm_way_id': 1,
          'highway_type': 'residential',
          'oneway': 1,
          'distance_meters': 1300.0,
          'weight': 1300.0,
        });
        await seedDb.insert('place_names', {
          'name': 'شارع الرشيد',
          'name_normalized': normalizeArabic('شارع الرشيد'),
          'latitude': 33.3010,
          'longitude': 44.3010,
          'osm_way_id': 1,
        });
      });

      final points = [_point(33.3000, 44.3000, 0, 0)];
      await tester.pumpWidget(
        harness(
          points,
          false,
          routeFinder: RouteFinder(databasePath: dbPath),
          placeSearchService: PlaceSearchService(databasePath: dbPath),
        ),
      );
      await pumpSettled(tester);

      await tester.tap(find.byIcon(Icons.alt_route));
      await pumpSettled(tester);

      // Drive the search box's own onChanged callback directly (same
      // reasoning as grabbing onMapClick above) inside runAsync, so both
      // the debounce Timer and the real sqlite FFI query behind it
      // actually get to complete.
      final onChanged = tester
          .widget<TextField>(find.byType(TextField))
          .onChanged!;
      await tester.runAsync(() async {
        onChanged('رشيد');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await pumpSettled(tester);

      expect(find.text('شارع الرشيد'), findsOneWidget);

      final resultTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, 'شارع الرشيد'),
      );
      await tester.runAsync(() async {
        resultTile.onTap!();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await pumpSettled(tester);

      expect(find.textContaining('1.30 كم'), findsOneWidget);
    },
  );
}
