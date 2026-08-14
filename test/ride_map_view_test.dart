import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:iraq_cycling/models/ride_point.dart';
import 'package:iraq_cycling/screens/ride_map_view.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';
import 'package:iraq_cycling/services/route_finder.dart';

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

  late Directory tempDir;
  late MapTileService mapTileService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ride_map_view_test');
    // Tile requests always fail (no network in the test VM); RideMapView
    // renders fine regardless, it just eventually shows the offline banner.
    mapTileService = MapTileService(
      cacheDir: tempDir,
      httpClient: MockClient((request) async => http.Response('', 404)),
    );
  });

  tearDown(() => tempDir.deleteSync(recursive: true));

  // [routeFinder] defaults to one pointed at nothing in particular - none of
  // the existing camera/gesture tests below ever trigger a route search, so
  // its lazily-opened db connection is simply never touched.
  Widget harness(
    List<RidePoint> points,
    bool isLive, {
    RouteFinder? routeFinder,
  }) => MaterialApp(
    home: MultiProvider(
      providers: [
        ChangeNotifierProvider<MapTileService>.value(value: mapTileService),
        Provider<RouteFinder>.value(value: routeFinder ?? RouteFinder()),
      ],
      child: Scaffold(body: RideMapView(points: points, isLive: isLive)),
    ),
  );

  MapCamera cameraOf(WidgetTester tester) =>
      MapController.of(tester.element(find.byType(TileLayer))).camera;

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

  double tiltMatrixEntry11(WidgetTester tester) => tester
      .widget<AnimatedContainer>(find.byType(AnimatedContainer))
      .transform!
      .entry(1, 1);

  testWidgets(
    'live+following camera turns to heading, zooms with speed, and tilts',
    (tester) async {
      // Due-east movement (~56m, well past the jitter floor) at a stop.
      final stopped = [_point(33.3000, 44.3000, 0, 0), _point(33.3000, 44.3006, 0, 5)];
      await tester.pumpWidget(harness([stopped.first], true));
      await pumpSettled(tester);

      await tester.pumpWidget(harness(stopped, true));
      await pumpSettled(tester);

      final camera = cameraOf(tester);
      // Heading ~90 (east) -> map rotation is -heading so east points up.
      expect(camera.rotation, closeTo(-90, 2));
      // Near-stopped -> zoomed all the way in.
      expect(camera.zoom, closeTo(17.0, 0.25));
      // Tilted: rotateX + scale changes this diagonal entry away from 1.0.
      expect(tiltMatrixEntry11(tester), isNot(closeTo(1.0, 0.01)));

      // Same heading, now at 54 km/h -> zoom pulls back out toward the far end.
      final riding = [
        ...stopped,
        _point(33.3000, 44.3012, 15, 10),
      ];
      await tester.pumpWidget(harness(riding, true));
      await pumpSettled(tester);
      expect(cameraOf(tester).zoom, closeTo(14.0, 0.25));

      // Route drawing is untouched: every point still lands in the polyline.
      final polyline = tester
          .widget<PolylineLayer>(find.byType(PolylineLayer))
          .polylines
          .single;
      expect(polyline.points, hasLength(riding.length));

      // Ride stops -> camera drops back to flat, north-up.
      await tester.pumpWidget(harness(riding, false));
      await tester.pumpAndSettle();
      expect(cameraOf(tester).rotation, closeTo(0, 0.5));
      expect(tiltMatrixEntry11(tester), closeTo(1.0, 0.01));
    },
  );

  testWidgets('manual pan stops following instead of fighting the gesture', (
    tester,
  ) async {
    final points = [_point(33.3000, 44.3000, 0, 0), _point(33.3000, 44.3006, 0, 5)];
    await tester.pumpWidget(harness(points, true));
    await pumpSettled(tester);

    expect(find.byIcon(Icons.my_location), findsNothing);

    await tester.drag(find.byType(FlutterMap), const Offset(-120, -80));
    await pumpSettled(tester);

    // A recenter button appears once the user has taken over the camera.
    expect(find.byIcon(Icons.my_location), findsOneWidget);

    await tester.tap(find.byIcon(Icons.my_location));
    await pumpSettled(tester);

    expect(find.byIcon(Icons.my_location), findsNothing);
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

      // Armed: the button flips to a cancel affordance and a hint banner
      // appears.
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('اضغط على الخريطة لتحديد الوجهة'), findsOneWidget);

      // Grab the live onTap callback straight off the built FlutterMap
      // instead of driving a real touch gesture - screen-pixel -> geo-point
      // conversion isn't what this test is checking; the wiring is.
      final options = tester.widget<FlutterMap>(find.byType(FlutterMap)).options;
      await tester.runAsync(() async {
        options.onTap!(
          const TapPosition(Offset.zero, Offset.zero),
          const LatLng(33.3010, 44.3010),
        );
        // Give the detached _planRouteTo() Future real time to run its
        // sqlite queries to completion before handing back to fake-async
        // pumping below.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await pumpSettled(tester);

      expect(find.byIcon(Icons.location_on), findsOneWidget);
      expect(find.textContaining('1.30 كم'), findsOneWidget);
      // Only the planned route renders as a polyline - the ride's own
      // recorded route needs >= 2 points, and this ride has only one.
      final plannedPolyline = tester
          .widget<PolylineLayer>(find.byType(PolylineLayer))
          .polylines
          .single;
      expect(plannedPolyline.points, [
        const LatLng(33.3000, 44.3000),
        const LatLng(33.3010, 44.3010),
      ]);

      await tester.tap(find.byIcon(Icons.close));
      await pumpSettled(tester);

      expect(find.byIcon(Icons.location_on), findsNothing);
      expect(find.byType(PolylineLayer), findsNothing);
      // The plan-route button is back, ready to start over.
      expect(find.byIcon(Icons.alt_route), findsOneWidget);
    },
  );
}
