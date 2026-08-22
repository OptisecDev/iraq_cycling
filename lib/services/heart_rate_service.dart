import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils/heart_rate_parser.dart';

/// Standard Bluetooth SIG-defined Heart Rate Service, exposed by chest
/// straps (Polar, Wahoo, Garmin) and by watches in "HR broadcast to
/// equipment" mode (e.g. Fitbit Charge 6). Not proprietary.
final heartRateServiceUuid = Uuid.parse('0000180d-0000-1000-8000-00805f9b34fb');

/// Heart Rate Measurement characteristic, standard sub-characteristic of
/// [heartRateServiceUuid].
final heartRateMeasurementCharacteristicUuid = Uuid.parse(
  '00002a37-0000-1000-8000-00805f9b34fb',
);

enum HeartRateConnectionState { disconnected, scanning, connecting, connected }

/// The subset of FlutterReactiveBle's API used by [HeartRateService],
/// extracted as an interface so tests can inject a no-op fake instead of
/// constructing a real `FlutterReactiveBle()` — the real class eagerly
/// starts async platform-channel initialization as soon as it's
/// constructed, which throws in a test VM with no BLE platform channel.
abstract class BleClient {
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices});
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Duration? connectionTimeout,
  });
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  );
}

class ReactiveBleClient implements BleClient {
  final _ble = FlutterReactiveBle();

  @override
  Stream<DiscoveredDevice> scanForDevices({required List<Uuid> withServices}) =>
      _ble.scanForDevices(withServices: withServices);

  @override
  Stream<ConnectionStateUpdate> connectToDevice({
    required String id,
    Duration? connectionTimeout,
  }) => _ble.connectToDevice(id: id, connectionTimeout: connectionTimeout);

  @override
  Stream<List<int>> subscribeToCharacteristic(
    QualifiedCharacteristic characteristic,
  ) => _ble.subscribeToCharacteristic(characteristic);
}

/// Wraps flutter_reactive_ble to find and stream BPM readings from a
/// standard BLE Heart Rate Service device. Entirely optional to the rest of
/// the app: nothing here is required for GPS ride tracking to work.
class HeartRateService extends ChangeNotifier {
  HeartRateService({BleClient? bleClient, DateTime Function()? now})
    : _ble = bleClient ?? ReactiveBleClient(),
      _now = now ?? DateTime.now;

  final BleClient _ble;
  // Overridable clock so tests can control elapsed time deterministically
  // (the stable-connection check below depends on it) instead of racing a
  // real 5-second wait - see test/heart_rate_service_test.dart.
  final DateTime Function() _now;

  /// Minimum time a connection must have been held for its later drop to
  /// count as a genuine mid-ride loss of signal (worth retrying
  /// indefinitely - see [_handleDisconnect]) rather than the initial
  /// handshake churn a device already held by another app can produce
  /// (bounded to one retry, same as before).
  static const _stableConnectionThreshold = Duration(seconds: 5);

  DateTime? _connectedSince;
  bool _hadStableConnection = false;
  bool _userInitiatedDisconnect = false;

  HeartRateConnectionState _connectionState =
      HeartRateConnectionState.disconnected;
  HeartRateConnectionState get connectionState => _connectionState;

  String? _connectedDeviceId;
  String? get connectedDeviceId => _connectedDeviceId;

  /// Most recent BPM reading, for simple UI display. Null until the first
  /// reading arrives, and reset on disconnect.
  int? _latestBpm;
  int? get latestBpm => _latestBpm;

  final Map<String, DiscoveredDevice> _devicesById = {};
  final _discoveredDevicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();
  Stream<List<DiscoveredDevice>> get discoveredDevices =>
      _discoveredDevicesController.stream;

  /// Devices found so far, e.g. from a previous scan. A broadcast stream
  /// (unlike [discoveredDevices]) does not replay past events to a new
  /// listener, so a screen reopened after scanning already found a device
  /// (in particular the one it's currently connected to) needs this to
  /// avoid showing an empty "no device found" list.
  List<DiscoveredDevice> get discoveredDevicesSnapshot =>
      List.unmodifiable(_devicesById.values);

  final _bpmController = StreamController<int>.broadcast();
  Stream<int> get bpmStream => _bpmController.stream;

  StreamSubscription<DiscoveredDevice>? _scanSubscription;
  StreamSubscription<ConnectionStateUpdate>? _connectionSubscription;
  StreamSubscription<List<int>>? _measurementSubscription;

  // Auto-retry once on an unexpected drop before surfacing "disconnected".
  int _retriesLeft = 0;

  /// Starts scanning after ensuring BLUETOOTH_SCAN/BLUETOOTH_CONNECT are
  /// granted. These are Android 12+ runtime permissions that neither the
  /// manifest declaration nor flutter_reactive_ble request on their own —
  /// without this, scanForDevices silently finds nothing and no system
  /// permission dialog ever appears.
  Future<void> startScan() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();
    final granted = statuses.values.every((status) => status.isGranted);
    if (!granted) {
      developer.log(
        'Bluetooth scan/connect permission not granted',
        name: 'HeartRateService',
      );
      _connectionState = HeartRateConnectionState.disconnected;
      notifyListeners();
      return;
    }

    _scanSubscription?.cancel();
    _devicesById.clear();
    _connectionState = HeartRateConnectionState.scanning;
    notifyListeners();

    _scanSubscription = _ble
        .scanForDevices(withServices: [heartRateServiceUuid])
        .listen(
          (device) {
            _devicesById[device.id] = device;
            _discoveredDevicesController.add(
              List.unmodifiable(_devicesById.values),
            );
          },
          onError: (Object error, StackTrace stackTrace) {
            developer.log(
              'Heart rate scan error',
              name: 'HeartRateService',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
  }

  void stopScan() {
    _scanSubscription?.cancel();
    _scanSubscription = null;
    if (_connectionState == HeartRateConnectionState.scanning) {
      _connectionState = HeartRateConnectionState.disconnected;
      notifyListeners();
    }
  }

  Future<void> connect(String deviceId) async {
    stopScan();
    _userInitiatedDisconnect = false;
    _hadStableConnection = false;
    _retriesLeft = 1;
    _connect(deviceId);
  }

  void _connect(String deviceId) {
    _connectionState = HeartRateConnectionState.connecting;
    notifyListeners();

    _connectionSubscription?.cancel();
    _connectionSubscription = _ble
        .connectToDevice(
          id: deviceId,
          // A connectionTimeout is required to get a fast, direct connect
          // (Android autoConnect=false). Without it, flutter_reactive_ble
          // sets autoConnect=true, which is meant for slow opportunistic
          // background reconnection, not connecting to a device that's
          // actively advertising right now — on-device testing showed this
          // left the connection stuck retrying indefinitely.
          connectionTimeout: const Duration(seconds: 10),
        )
        .listen(
          _onConnectionUpdate,
          onError: (Object error, StackTrace stackTrace) {
            developer.log(
              'Heart rate connection error',
              name: 'HeartRateService',
              error: error,
              stackTrace: stackTrace,
            );
            _handleDisconnect(deviceId);
          },
        );
  }

  void _onConnectionUpdate(ConnectionStateUpdate update) {
    switch (update.connectionState) {
      case DeviceConnectionState.connected:
        _connectedDeviceId = update.deviceId;
        _connectionState = HeartRateConnectionState.connected;
        _connectedSince = _now();
        // Deliberately not resetting _retriesLeft here. A device that's
        // already held by another app (e.g. its own vendor app) can flap
        // connecting -> briefly "connected" -> disconnected repeatedly
        // during the handshake; refilling the retry budget on every such
        // flicker made the auto-retry-once policy retry indefinitely
        // in that case (confirmed via on-device logcat: native connect()
        // calls continuing well after the UI already reported
        // "disconnected"). The budget is only set by the user-initiated
        // connect() entry point now - a *stable* connection instead gets an
        // unbounded retry policy on drop, via _hadStableConnection below.
        notifyListeners();
        _subscribeToMeasurement(update.deviceId);
      case DeviceConnectionState.disconnected:
        _handleDisconnect(update.deviceId);
      case DeviceConnectionState.connecting:
      case DeviceConnectionState.disconnecting:
        break;
    }
  }

  void _subscribeToMeasurement(String deviceId) {
    final characteristic = QualifiedCharacteristic(
      characteristicId: heartRateMeasurementCharacteristicUuid,
      serviceId: heartRateServiceUuid,
      deviceId: deviceId,
    );

    _measurementSubscription?.cancel();
    _measurementSubscription = _ble
        .subscribeToCharacteristic(characteristic)
        .listen(
          (bytes) {
            final bpm = parseHeartRateBpm(bytes);
            if (bpm != null) {
              _latestBpm = bpm;
              _bpmController.add(bpm);
              notifyListeners();
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            developer.log(
              'Heart rate measurement stream error',
              name: 'HeartRateService',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
  }

  void _handleDisconnect(String deviceId) {
    _measurementSubscription?.cancel();
    _measurementSubscription = null;

    final connectedSince = _connectedSince;
    _connectedSince = null;
    if (connectedSince != null &&
        _now().difference(connectedSince) >= _stableConnectionThreshold) {
      _hadStableConnection = true;
    }

    if (_userInitiatedDisconnect) {
      _finalizeDisconnect();
      return;
    }

    if (_hadStableConnection) {
      // A real mid-ride signal loss (out of range, interference, the phone
      // screen locking) after a connection that actually held for a while
      // - keep retrying indefinitely instead of silently going dark for
      // the rest of the ride, since the rider has no safe way to reopen
      // the pairing screen and press "connect" again while cycling. This
      // was the real cause of heart-rate/calories going blank mid-ride on
      // a real device: the bounded single-retry policy below was giving
      // up permanently after one failed reconnect attempt.
      _connectionState = HeartRateConnectionState.connecting;
      notifyListeners();
      _connect(deviceId);
      return;
    }

    if (_retriesLeft > 0) {
      _retriesLeft -= 1;
      _connect(deviceId);
      return;
    }

    // Giving up: a connection that never proved itself stable (the
    // handshake-churn case a device held by another app can produce) is
    // still bounded to one retry, same as before.
    _finalizeDisconnect();
  }

  /// Cancels the connection stream (rather than leaving it listening -
  /// connectToDevice() keeps retrying at the native BLE layer for as long
  /// as its subscription is alive, regardless of what state it last
  /// reported) and resets to disconnected.
  void _finalizeDisconnect() {
    _connectionSubscription?.cancel();
    _connectionSubscription = null;

    _connectedDeviceId = null;
    _latestBpm = null;
    _connectionState = HeartRateConnectionState.disconnected;
    notifyListeners();
  }

  /// Disconnects the current device (if any) and resets to idle. Does not
  /// stop an in-progress scan; call [stopScan] separately if needed.
  void disconnect() {
    _userInitiatedDisconnect = true;
    _connectedSince = null;
    _hadStableConnection = false;
    _retriesLeft = 0;
    _finalizeDisconnect();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _measurementSubscription?.cancel();
    _discoveredDevicesController.close();
    _bpmController.close();
    super.dispose();
  }
}
