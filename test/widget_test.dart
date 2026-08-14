import 'dart:io';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:iraq_cycling/main.dart';
import 'package:iraq_cycling/services/hazard_repository.dart';
import 'package:iraq_cycling/services/heart_rate_service.dart';
import 'package:iraq_cycling/services/map_tile_service.dart';
import 'package:iraq_cycling/services/user_profile_repository.dart';
import 'package:iraq_cycling/services/voice_alert_service.dart';

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

/// A [TtsClient] that does nothing, since the real one talks to a platform
/// channel that isn't available in the test VM.
class _NoOpTtsClient implements TtsClient {
  @override
  Future<void> setLanguage(String language) async {}

  @override
  Future<void> speak(String text) async {}
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

    // Not loaded from disk here — the test never triggers a query that
    // would need it, so this stays at its in-memory defaults, avoiding any
    // real sqflite/platform-channel access in the test VM.
    final userProfileRepository = UserProfileRepository();

    // Neither is exercised by this test (no ride is started, so
    // RideTracker never calls hazardRepository.getAll()), so a real
    // sqflite/platform-channel connection is never actually opened.
    final hazardRepository = HazardRepository();
    final voiceAlertService = VoiceAlertService(ttsClient: _NoOpTtsClient());

    await tester.pumpWidget(
      MyApp(
        mapTileService: mapTileService,
        heartRateService: heartRateService,
        userProfileRepository: userProfileRepository,
        hazardRepository: hazardRepository,
        voiceAlertService: voiceAlertService,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ابدأ الرحلة'), findsOneWidget);
  });
}
