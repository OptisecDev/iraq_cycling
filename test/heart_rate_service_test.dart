import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/heart_rate_service.dart';

/// A [BleClient] whose connection stream is driven manually by the test via
/// [emitConnected]/[emitDisconnected] - no real BLE platform channel
/// involved. Every [connectToDevice] call re-listens to the same underlying
/// broadcast stream, mirroring how [HeartRateService._connect] cancels its
/// previous subscription before re-subscribing on each (re)connect attempt.
class FakeBleClient implements BleClient {
  final _connectionController =
      StreamController<ConnectionStateUpdate>.broadcast();
  int connectCallCount = 0;

  @override
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices}) =>
      const Stream.empty();

  @override
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Duration? connectionTimeout,
  }) {
    connectCallCount += 1;
    return _connectionController.stream;
  }

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) => const Stream.empty();

  void emitConnected(String deviceId) {
    _connectionController.add(
      ConnectionStateUpdate(
        deviceId: deviceId,
        connectionState: DeviceConnectionState.connected,
        failure: null,
      ),
    );
  }

  void emitDisconnected(String deviceId) {
    _connectionController.add(
      ConnectionStateUpdate(
        deviceId: deviceId,
        connectionState: DeviceConnectionState.disconnected,
        failure: null,
      ),
    );
  }

  Future<void> close() => _connectionController.close();
}

void main() {
  late FakeBleClient bleClient;
  late DateTime fakeNow;
  late HeartRateService service;

  setUp(() {
    bleClient = FakeBleClient();
    fakeNow = DateTime(2026, 1, 1, 8, 0, 0);
    service = HeartRateService(bleClient: bleClient, now: () => fakeNow);
  });

  tearDown(() => bleClient.close());

  /// Lets the broadcast stream's queued event reach HeartRateService's
  /// subscription before assertions.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test(
    'a connection that never stabilizes (handshake churn) gets one retry, '
    'then gives up',
    () async {
      await service.connect('device-1');
      expect(bleClient.connectCallCount, 1);

      // Drops immediately - never held long enough to count as stable.
      bleClient.emitConnected('device-1');
      bleClient.emitDisconnected('device-1');
      await flush();
      expect(bleClient.connectCallCount, 2); // the one bounded retry

      // Retry attempt also churns immediately - budget is now exhausted.
      bleClient.emitConnected('device-1');
      bleClient.emitDisconnected('device-1');
      await flush();

      expect(bleClient.connectCallCount, 2); // no further attempt
      expect(service.connectionState, HeartRateConnectionState.disconnected);
    },
  );

  test(
    'a real mid-ride drop after a stable connection keeps retrying '
    'indefinitely instead of giving up after one attempt',
    () async {
      await service.connect('device-1');
      bleClient.emitConnected('device-1');
      await flush();
      expect(service.connectionState, HeartRateConnectionState.connected);

      // Held well past the stability threshold, then genuinely drops (out
      // of range / interference), mirroring a real mid-ride signal loss.
      fakeNow = fakeNow.add(const Duration(seconds: 30));
      bleClient.emitDisconnected('device-1');
      await flush();

      expect(service.connectionState, HeartRateConnectionState.connecting);
      expect(bleClient.connectCallCount, 2);

      // Several more quick failed reconnect attempts (each held for 0s)
      // must still keep retrying - a stable connection earlier in the
      // session means the bounded single-retry policy no longer applies.
      for (var i = 0; i < 3; i++) {
        bleClient.emitConnected('device-1');
        bleClient.emitDisconnected('device-1');
        await flush();
      }

      expect(bleClient.connectCallCount, 5);
      expect(service.connectionState, HeartRateConnectionState.connecting);
    },
  );

  test(
    'a user-initiated disconnect stops further automatic reconnect attempts',
    () async {
      await service.connect('device-1');
      bleClient.emitConnected('device-1');
      fakeNow = fakeNow.add(const Duration(seconds: 30));
      await flush();

      service.disconnect();
      expect(service.connectionState, HeartRateConnectionState.disconnected);

      final callCountAfterDisconnect = bleClient.connectCallCount;
      bleClient.emitDisconnected('device-1');
      await flush();

      expect(bleClient.connectCallCount, callCountAfterDisconnect);
      expect(service.connectionState, HeartRateConnectionState.disconnected);
    },
  );
}
