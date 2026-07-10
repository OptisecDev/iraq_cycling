import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iraq_cycling/main.dart';
import 'package:iraq_cycling/services/heart_rate_service.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';

/// A [BleClient] that never emits anything, real BLE platform channels
/// aren't available in the test VM (constructing a real `FlutterReactiveBle`
/// would throw as soon as it starts its async platform initialization).
class _NoOpBleClient implements BleClient {
  @override
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices}) =>
      const Stream.empty();

  @override
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Duration? connectionTimeout,
  }) => const Stream.empty();

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) => const Stream.empty();
}

void main() {
  testWidgets('TrackingScreen shows the idle start button', (
    WidgetTester tester,
  ) async {
    // A temp dir + a client that always fails avoids any real filesystem
    // setup via path_provider and any real network call to the tile server
    // during this widget test.
    final tempDir = Directory.systemTemp.createTempSync('tile_cache_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final mapTileService = MapTileService(
      cacheDir: tempDir,
      httpClient: MockClient((request) async => http.Response('', 404)),
    );

    final heartRateService = HeartRateService(bleClient: _NoOpBleClient());

    await tester.pumpWidget(
      MyApp(
        mapTileService: mapTileService,
        heartRateService: heartRateService,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ابدأ الرحلة'), findsOneWidget);
  });
}
