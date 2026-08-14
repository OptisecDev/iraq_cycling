import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'package:iraq_cycling/models/ride_point.dart';
import 'package:iraq_cycling/screens/ride_map_view.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';

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

  Widget harness(List<RidePoint> points, bool isLive) => MaterialApp(
    home: ChangeNotifierProvider<MapTileService>.value(
      value: mapTileService,
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
}
