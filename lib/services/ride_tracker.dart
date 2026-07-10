import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/ride.dart';
import '../models/ride_point.dart';
import '../utils/calorie_calculator.dart';
import '../utils/distance_calculator.dart';
import 'heart_rate_service.dart';
import 'location_service.dart';

enum TrackingState { idle, tracking, paused, finished }

class RideTracker extends ChangeNotifier {
  RideTracker({LocationService? locationService, HeartRateService? heartRateService})
    : _locationService = locationService ?? LocationService(),
      _heartRateService = heartRateService;

  final LocationService _locationService;
  // Optional: a ride tracks and saves fine with no heart rate sensor
  // connected at all — this stays null in that case and avgHeartRate is
  // simply never computed.
  final HeartRateService? _heartRateService;
  StreamSubscription<int>? _bpmSubscription;
  int _bpmSum = 0;
  int _bpmSampleCount = 0;

  StreamSubscription<Position>? _positionSubscription;

  TrackingState _state = TrackingState.idle;
  TrackingState get state => _state;

  Ride? _currentRide;
  Ride? get currentRide => _currentRide;

  double _instantSpeedMps = 0;
  double get instantSpeedKmh => _instantSpeedMps * 3.6;

  final List<RidePoint> _points = [];
  RidePoint? _lastValidPoint;

  double _totalDistanceMeters = 0;
  double _maxSpeedMps = 0;
  double _totalElevationGainMeters = 0;

  Future<String?> startRide() async {
    final granted = await _locationService.ensurePermissionsGranted();
    if (!granted) {
      return 'يجب تفعيل خدمة الموقع ومنح إذن الوصول إليه لبدء الرحلة';
    }

    _points.clear();
    _lastValidPoint = null;
    _totalDistanceMeters = 0;
    _maxSpeedMps = 0;
    _totalElevationGainMeters = 0;
    _instantSpeedMps = 0;
    _bpmSum = 0;
    _bpmSampleCount = 0;

    _currentRide = Ride(startTime: DateTime.now());
    _state = TrackingState.tracking;

    _positionSubscription = _locationService.positionStream.listen(
      _onPosition,
      onError: (Object error, StackTrace stackTrace) {
        // GPS stream errors must not stop tracking — log and keep listening.
        developer.log(
          'Position stream error',
          name: 'RideTracker',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );

    // Heart rate is entirely optional: if no sensor is connected, this
    // subscription simply never receives data and avgHeartRate stays null.
    _bpmSubscription = _heartRateService?.bpmStream.listen(
      _onBpm,
      onError: (Object error, StackTrace stackTrace) {
        developer.log(
          'Heart rate stream error',
          name: 'RideTracker',
          error: error,
          stackTrace: stackTrace,
        );
      },
    );

    notifyListeners();
    return null;
  }

  void _onBpm(int bpm) {
    if (_state != TrackingState.tracking) return;
    _bpmSum += bpm;
    _bpmSampleCount += 1;
  }

  void _onPosition(Position position) {
    if (_state != TrackingState.tracking) return;

    final point = RidePoint(
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      speed: position.speed,
      timestamp: position.timestamp,
      accuracy: position.accuracy,
    );

    _instantSpeedMps = point.speed;
    if (point.speed > _maxSpeedMps) {
      _maxSpeedMps = point.speed;
    }

    final lastPoint = _lastValidPoint;
    if (lastPoint == null) {
      _points.add(point);
      _lastValidPoint = point;
    } else {
      final distance = DistanceCalculator.haversineDistance(
        lastPoint.latitude,
        lastPoint.longitude,
        point.latitude,
        point.longitude,
      );
      final timeDelta = point.timestamp.difference(lastPoint.timestamp);

      if (DistanceCalculator.isValidGpsJump(distance, timeDelta)) {
        _totalDistanceMeters += distance;

        final altitudeDelta = point.altitude - lastPoint.altitude;
        if (altitudeDelta > 0) {
          _totalElevationGainMeters += altitudeDelta;
        }

        _points.add(point);
        _lastValidPoint = point;
      }
      // Noisy/unrealistic jump: discard the point and keep the previous
      // last-valid-point as the reference for the next reading.
    }

    _currentRide = _currentRide?.copyWith(
      points: List.unmodifiable(_points),
      totalDistanceMeters: _totalDistanceMeters,
      maxSpeedMps: _maxSpeedMps,
      totalElevationGainMeters: _totalElevationGainMeters,
    );

    notifyListeners();
  }

  void pauseRide() {
    if (_state != TrackingState.tracking) return;
    _state = TrackingState.paused;
    notifyListeners();
  }

  void resumeRide() {
    if (_state != TrackingState.paused) return;
    _state = TrackingState.tracking;
    notifyListeners();
  }

  Ride? finishRide() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _bpmSubscription?.cancel();
    _bpmSubscription = null;

    final ride = _currentRide;
    if (ride == null) {
      _state = TrackingState.idle;
      notifyListeners();
      return null;
    }

    // Null when no heart rate sensor was connected for this ride — the
    // ride is saved exactly as it was in Phase 1 in that case.
    final avgHeartRate =
        _bpmSampleCount > 0 ? _bpmSum / _bpmSampleCount : null;
    final finishedRide = ride.copyWith(
      endTime: DateTime.now(),
      avgHeartRate: avgHeartRate,
    );
    final caloriesBurned = estimateCaloriesBurned(
      duration: finishedRide.duration,
      avgHeartRate: avgHeartRate,
      avgSpeedKmh: finishedRide.avgSpeedKmh,
    );

    _currentRide = finishedRide.copyWith(caloriesBurned: caloriesBurned);
    _state = TrackingState.finished;
    notifyListeners();
    return _currentRide;
  }

  void reset() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _bpmSubscription?.cancel();
    _bpmSubscription = null;
    _currentRide = null;
    _points.clear();
    _lastValidPoint = null;
    _totalDistanceMeters = 0;
    _maxSpeedMps = 0;
    _totalElevationGainMeters = 0;
    _instantSpeedMps = 0;
    _bpmSum = 0;
    _bpmSampleCount = 0;
    _state = TrackingState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _bpmSubscription?.cancel();
    super.dispose();
  }
}
