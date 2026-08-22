import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../models/ride.dart';
import '../models/ride_point.dart';
import '../models/traffic_hazard.dart';
import '../utils/calorie_calculator.dart';
import '../utils/distance_calculator.dart';
import '../utils/hazard_proximity.dart';
import 'hazard_repository.dart';
import 'heart_rate_service.dart';
import 'location_service.dart';
import 'user_profile_repository.dart';
import 'voice_alert_service.dart';

enum TrackingState { idle, tracking, paused, finished }

class RideTracker extends ChangeNotifier {
  RideTracker({
    LocationService? locationService,
    HeartRateService? heartRateService,
    UserProfileRepository? userProfileRepository,
    HazardRepository? hazardRepository,
    VoiceAlertService? voiceAlertService,
    DateTime Function()? now,
  }) : _locationService = locationService ?? LocationService(),
       _heartRateService = heartRateService,
       _userProfileRepository = userProfileRepository,
       _hazardRepository = hazardRepository,
       _voiceAlertService = voiceAlertService,
       _now = now ?? DateTime.now;

  final LocationService _locationService;
  // Overridable clock so tests can control elapsed wall-clock time
  // deterministically (pause/resume duration math below depends on it)
  // instead of racing real Future.delayed calls - see test/ride_tracker_test.dart.
  final DateTime Function() _now;
  // Optional: a ride tracks and saves fine with no heart rate sensor
  // connected at all — this stays null in that case and avgHeartRate is
  // simply never computed.
  final HeartRateService? _heartRateService;
  // Optional: without a profile, calorie estimates fall back to the same
  // placeholders calorie_calculator.dart always used (see resolveWeightKg/
  // resolveAgeYears below).
  final UserProfileRepository? _userProfileRepository;
  // Optional: with no hazards defined (or no repository/voice service
  // supplied at all), a ride tracks and saves exactly as before — nothing
  // is ever checked or spoken.
  final HazardRepository? _hazardRepository;
  final VoiceAlertService? _voiceAlertService;
  List<TrafficHazard> _hazards = const [];
  final Set<int> _triggeredHazardIds = {};
  StreamSubscription<int>? _bpmSubscription;
  int _bpmSum = 0;
  int _bpmSampleCount = 0;
  int _maxBpm = 0;
  LiveCalorieAccumulator? _liveCalorieAccumulator;

  StreamSubscription<Position>? _positionSubscription;

  // Total time spent paused so far, plus the start of the currently-open
  // pause span (if any) - see pauseRide/resumeRide. [Ride.duration]
  // subtracts the total from wall-clock elapsed time, so a stop at a
  // traffic light doesn't inflate the saved ride's duration and deflate
  // its average speed.
  int _pausedDurationMs = 0;
  DateTime? _pausedAt;

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

  /// Running calorie total for the in-progress ride, updated live as BPM
  /// samples arrive. Separate from `Ride.caloriesBurned`, which is only
  /// computed once at [finishRide] from the ride's average heart rate.
  double get liveCalories => _liveCalorieAccumulator?.totalCalories ?? 0;

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
    _maxBpm = 0;
    _pausedDurationMs = 0;
    _pausedAt = null;
    final profile = _userProfileRepository?.current;
    _liveCalorieAccumulator = LiveCalorieAccumulator(
      weightKg: resolveWeightKg(profile?.weightKg),
      ageYears: resolveAgeYears(profile?.age),
      gender: resolveGender(profile?.gender),
    );
    _triggeredHazardIds.clear();
    _hazards = await _hazardRepository?.getAll() ?? const [];

    _currentRide = Ride(startTime: _now());
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
    if (bpm > _maxBpm) {
      _maxBpm = bpm;
    }
    _liveCalorieAccumulator?.addSample(bpm);
    notifyListeners();
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

    _checkHazards(point);

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

  /// Speaks a warning (fire-and-forget) for each hazard whose radius the
  /// rider has just entered, at most once per hazard per ride.
  void _checkHazards(RidePoint point) {
    final voiceAlertService = _voiceAlertService;
    if (_hazards.isEmpty || voiceAlertService == null) return;

    final newlyTriggered = newlyTriggeredHazardIds(
      latitude: point.latitude,
      longitude: point.longitude,
      hazards: _hazards,
      alreadyTriggered: _triggeredHazardIds,
    );
    for (final id in newlyTriggered) {
      _triggeredHazardIds.add(id);
      final hazard = _hazards.firstWhere((h) => h.id == id);
      voiceAlertService.announce(hazard.message);
    }
  }

  void pauseRide() {
    if (_state != TrackingState.tracking) return;
    _pausedAt = _now();
    _state = TrackingState.paused;
    notifyListeners();
  }

  void resumeRide() {
    if (_state != TrackingState.paused) return;
    _closeOpenPauseSpan();
    _state = TrackingState.tracking;
    // Reflects the now-larger pausedDurationMs immediately, so the elapsed
    // time shown resumes right where it was at the moment of pausing
    // instead of jumping forward by however long the pause lasted.
    _currentRide = _currentRide?.copyWith(pausedDurationMs: _pausedDurationMs);
    notifyListeners();
  }

  /// Folds the currently-open pause span (if any) into [_pausedDurationMs]
  /// and clears it. Called on resume, and also on [finishRide] in case the
  /// rider ends the ride while still paused instead of resuming first.
  void _closeOpenPauseSpan() {
    final pausedAt = _pausedAt;
    if (pausedAt == null) return;
    _pausedDurationMs += _now().difference(pausedAt).inMilliseconds;
    _pausedAt = null;
  }

  Ride? finishRide() {
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _bpmSubscription?.cancel();
    _bpmSubscription = null;
    // Finishing directly from paused (without resuming first) must still
    // exclude that open pause span from the saved duration.
    _closeOpenPauseSpan();

    final ride = _currentRide;
    if (ride == null) {
      _state = TrackingState.idle;
      notifyListeners();
      return null;
    }

    // Null when no heart rate sensor was connected for this ride — the
    // ride is saved exactly as it was in Phase 1 in that case.
    final avgHeartRate = _bpmSampleCount > 0 ? _bpmSum / _bpmSampleCount : null;
    final maxHeartRate = _bpmSampleCount > 0 ? _maxBpm.toDouble() : null;
    final finishedRide = ride.copyWith(
      endTime: _now(),
      avgHeartRate: avgHeartRate,
      maxHeartRate: maxHeartRate,
      pausedDurationMs: _pausedDurationMs,
    );
    final profile = _userProfileRepository?.current;
    final caloriesBurned = estimateCaloriesBurned(
      duration: finishedRide.duration,
      avgHeartRate: avgHeartRate,
      avgSpeedKmh: finishedRide.avgSpeedKmh,
      weightKg: resolveWeightKg(profile?.weightKg),
      ageYears: resolveAgeYears(profile?.age),
      gender: resolveGender(profile?.gender),
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
    _maxBpm = 0;
    _pausedDurationMs = 0;
    _pausedAt = null;
    _liveCalorieAccumulator = null;
    _triggeredHazardIds.clear();
    _hazards = const [];
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
