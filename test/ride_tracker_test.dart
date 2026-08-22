import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:iraq_cycling/services/location_service.dart';
import 'package:iraq_cycling/services/ride_tracker.dart';

/// A [LocationService] whose permission check always succeeds and whose
/// [positionStream] is driven manually by the test via [emit] - no real GPS
/// hardware/platform channel involved.
class FakeLocationService extends LocationService {
  final _controller = StreamController<Position>.broadcast();

  @override
  Future<bool> ensurePermissionsGranted() async => true;

  @override
  Stream<Position> get positionStream => _controller.stream;

  void emit(Position position) => _controller.add(position);

  Future<void> close() => _controller.close();
}

Position _position(
  double latitude,
  double longitude, {
  double speed = 0,
  required DateTime timestamp,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: timestamp,
  accuracy: 5,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: speed,
  speedAccuracy: 0,
);

void main() {
  late FakeLocationService locationService;
  late DateTime fakeNow;
  late RideTracker tracker;

  setUp(() {
    locationService = FakeLocationService();
    fakeNow = DateTime(2026, 1, 1, 8, 0, 0);
    tracker = RideTracker(locationService: locationService, now: () => fakeNow);
  });

  tearDown(() => locationService.close());

  /// Lets pending stream events (from [FakeLocationService.emit]) reach
  /// [RideTracker]'s subscription before assertions - the broadcast stream
  /// controller delivers on a microtask, not synchronously.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  group('pauseRide/resumeRide', () {
    test('pausing stops new GPS fixes from being recorded', () async {
      await tracker.startRide();
      locationService.emit(
        _position(33.3000, 44.3000, timestamp: fakeNow),
      );
      await flush();
      final distanceBeforePause = tracker.currentRide!.totalDistanceMeters;
      final pointsBeforePause = tracker.currentRide!.points.length;

      tracker.pauseRide();
      expect(tracker.state, TrackingState.paused);

      // A GPS fix that arrives while paused (e.g. the phone still has a
      // lock while stopped at a light) must not move distance/points.
      locationService.emit(
        _position(
          33.3010,
          44.3010,
          timestamp: fakeNow.add(const Duration(seconds: 30)),
        ),
      );
      await flush();

      expect(tracker.currentRide!.totalDistanceMeters, distanceBeforePause);
      expect(tracker.currentRide!.points.length, pointsBeforePause);
    });

    test(
      'saved ride duration excludes time spent paused at a traffic light',
      () async {
        await tracker.startRide();

        // Ride for 10 minutes.
        fakeNow = fakeNow.add(const Duration(minutes: 10));
        tracker.pauseRide();
        expect(tracker.state, TrackingState.paused);

        // Stopped at the light for 2 minutes.
        fakeNow = fakeNow.add(const Duration(minutes: 2));
        tracker.resumeRide();
        expect(tracker.state, TrackingState.tracking);

        // pausedDurationMs must be folded into the ride immediately on
        // resume (not deferred to finishRide), so a widget reading
        // Ride.duration right after resuming sees the 2 paused minutes
        // already excluded rather than a jump forward - see
        // resumeRide()'s copyWith in ride_tracker.dart.
        expect(tracker.currentRide!.pausedDurationMs, const Duration(minutes: 2).inMilliseconds);

        // Ride another 5 minutes, then finish.
        fakeNow = fakeNow.add(const Duration(minutes: 5));
        final finished = tracker.finishRide();

        expect(finished, isNotNull);
        // Wall-clock elapsed was 17 minutes; 2 of those were paused.
        expect(finished!.duration, const Duration(minutes: 15));
      },
    );

    test(
      'resuming does not lose distance/points recorded before the pause',
      () async {
        await tracker.startRide();
        locationService.emit(
          _position(33.3000, 44.3000, timestamp: fakeNow),
        );
        await flush();

        tracker.pauseRide();
        fakeNow = fakeNow.add(const Duration(minutes: 1));
        tracker.resumeRide();

        // A real GPS jump (~1.1km over 20s => ~57 km/h is too fast for a
        // bike and would be rejected as noise, so keep the post-resume fix
        // realistic: ~150m over 20s => 27 km/h).
        locationService.emit(
          _position(
            33.3013,
            44.3000,
            timestamp: fakeNow.add(const Duration(seconds: 20)),
          ),
        );
        await flush();

        expect(tracker.currentRide!.points.length, 2);
        expect(tracker.currentRide!.totalDistanceMeters, greaterThan(0));
      },
    );

    test(
      'finishing directly from paused (without resuming) still excludes '
      'the open pause span',
      () async {
        await tracker.startRide();
        fakeNow = fakeNow.add(const Duration(minutes: 10));
        tracker.pauseRide();

        fakeNow = fakeNow.add(const Duration(minutes: 3));
        final finished = tracker.finishRide();

        expect(finished!.duration, const Duration(minutes: 10));
      },
    );

    test('pauseRide is a no-op when not tracking', () {
      expect(tracker.state, TrackingState.idle);
      tracker.pauseRide();
      expect(tracker.state, TrackingState.idle);
    });

    test('resumeRide is a no-op when not paused', () async {
      await tracker.startRide();
      expect(tracker.state, TrackingState.tracking);
      tracker.resumeRide();
      expect(tracker.state, TrackingState.tracking);
    });
  });
}
