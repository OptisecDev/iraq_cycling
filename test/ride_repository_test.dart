import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/models/ride.dart';
import 'package:iraq_cycling/models/ride_point.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/ride_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('ride_repository_test');
    dbPath = p.join(tempDir.path, 'test.db');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Ride buildRide({
    required DateTime startTime,
    required DateTime endTime,
    List<RidePoint> points = const [],
    double? maxHeartRate,
    int pausedDurationMs = 0,
  }) {
    return Ride(
      startTime: startTime,
      endTime: endTime,
      points: points,
      totalDistanceMeters: 1000,
      maxSpeedMps: 10,
      totalElevationGainMeters: 5,
      avgHeartRate: 120,
      maxHeartRate: maxHeartRate,
      caloriesBurned: 200,
      pausedDurationMs: pausedDurationMs,
    );
  }

  test(
    'saveRide then getRideWithPoints round-trips route points and max heart rate',
    () async {
      final repository = RideRepository(databasePath: dbPath);
      final ride = buildRide(
        startTime: DateTime(2026, 1, 1, 8),
        endTime: DateTime(2026, 1, 1, 9),
        points: [
          RidePoint(
            latitude: 33.3,
            longitude: 44.4,
            altitude: 10,
            speed: 5,
            timestamp: DateTime(2026, 1, 1, 8, 30),
          ),
          RidePoint(
            latitude: 33.31,
            longitude: 44.41,
            altitude: 12,
            speed: 6,
            timestamp: DateTime(2026, 1, 1, 8, 45),
          ),
        ],
        maxHeartRate: 165,
      );

      final saved = await repository.saveRide(ride);
      final reloaded = await repository.getRideWithPoints(saved.id!);

      expect(reloaded, isNotNull);
      expect(reloaded!.maxHeartRate, 165);
      expect(reloaded.avgHeartRate, 120);
      expect(reloaded.points, hasLength(2));
      expect(reloaded.points.first.latitude, 33.3);
      expect(reloaded.totalDistanceMeters, 1000);
      expect(reloaded.startTime, DateTime(2026, 1, 1, 8));
      expect(reloaded.endTime, DateTime(2026, 1, 1, 9));
    },
  );

  test(
    'saveRide then getRideWithPoints round-trips pausedDurationMs, and the '
    'reloaded duration still excludes it',
    () async {
      final repository = RideRepository(databasePath: dbPath);
      final ride = buildRide(
        startTime: DateTime(2026, 1, 1, 8, 0),
        endTime: DateTime(2026, 1, 1, 9, 0),
        pausedDurationMs: const Duration(minutes: 10).inMilliseconds,
      );

      final saved = await repository.saveRide(ride);
      final reloaded = await repository.getRideWithPoints(saved.id!);

      expect(reloaded, isNotNull);
      expect(
        reloaded!.pausedDurationMs,
        const Duration(minutes: 10).inMilliseconds,
      );
      // 1 hour wall-clock minus the 10 paused minutes.
      expect(reloaded.duration, const Duration(minutes: 50));
    },
  );

  test(
    'a row written without an explicit paused_duration_ms (e.g. via the '
    'appDbVersion 7->8 ALTER TABLE backfill) reloads as an unpaused ride',
    () async {
      final db = await openAppDatabase(overridePath: dbPath);
      final id = await db.insert('rides', {
        'start_time': DateTime(2026, 1, 1, 8, 0).millisecondsSinceEpoch,
        'end_time': DateTime(2026, 1, 1, 9, 0).millisecondsSinceEpoch,
        'total_distance_meters': 1000.0,
        'max_speed_mps': 10.0,
        'total_elevation_gain_meters': 5.0,
      });

      final repository = RideRepository(databasePath: dbPath);
      final reloaded = await repository.getRideWithPoints(id);

      expect(reloaded, isNotNull);
      expect(reloaded!.pausedDurationMs, 0);
      expect(reloaded.duration, const Duration(hours: 1));
    },
  );

  test(
    'getAllRidesSummary sorts newest-first by end_time, not start_time',
    () async {
      final repository = RideRepository(databasePath: dbPath);

      // Deliberately out of chronological order, and with a start_time
      // order that would sort *differently* than end_time (an
      // earlier-starting ride that ends later than one that started after
      // it) — this only passes if sorting is by end_time.
      final rideA = await repository.saveRide(
        buildRide(
          startTime: DateTime(2026, 1, 1, 8),
          endTime: DateTime(2026, 1, 3, 9),
        ),
      );
      final rideB = await repository.saveRide(
        buildRide(
          startTime: DateTime(2026, 1, 2, 8),
          endTime: DateTime(2026, 1, 2, 9),
        ),
      );
      final rideC = await repository.saveRide(
        buildRide(
          startTime: DateTime(2026, 1, 3, 8),
          endTime: DateTime(2026, 1, 1, 9),
        ),
      );

      final summary = await repository.getAllRidesSummary();

      expect(summary.map((r) => r.id).toList(), [
        rideA.id,
        rideB.id,
        rideC.id,
      ]);
      // Sanity check this isn't just coincidentally matching insertion
      // order: rideC started last but ended first.
      expect(rideC.startTime.isAfter(rideB.startTime), isTrue);
    },
  );

  test('deleteRide removes only the targeted ride and its points', () async {
    final repository = RideRepository(databasePath: dbPath);

    final keep = await repository.saveRide(
      buildRide(
        startTime: DateTime(2026, 1, 1),
        endTime: DateTime(2026, 1, 1, 1),
      ),
    );
    final remove = await repository.saveRide(
      buildRide(
        startTime: DateTime(2026, 1, 2),
        endTime: DateTime(2026, 1, 2, 1),
        points: [
          RidePoint(
            latitude: 1,
            longitude: 1,
            altitude: 0,
            speed: 0,
            timestamp: DateTime(2026, 1, 2),
          ),
        ],
      ),
    );

    await repository.deleteRide(remove.id!);

    final remaining = await repository.getAllRidesSummary();
    expect(remaining.map((r) => r.id), [keep.id]);
    expect(await repository.getRideWithPoints(remove.id!), isNull);
  });

  test('clearAllHistory removes every ride and cascades to their points', () async {
    final repository = RideRepository(databasePath: dbPath);

    await repository.saveRide(
      buildRide(
        startTime: DateTime(2026, 1, 1),
        endTime: DateTime(2026, 1, 1, 1),
        points: [
          RidePoint(
            latitude: 1,
            longitude: 1,
            altitude: 0,
            speed: 0,
            timestamp: DateTime(2026, 1, 1),
          ),
        ],
      ),
    );
    await repository.saveRide(
      buildRide(
        startTime: DateTime(2026, 1, 2),
        endTime: DateTime(2026, 1, 2, 1),
      ),
    );

    await repository.clearAllHistory();

    expect(await repository.getAllRidesSummary(), isEmpty);
  });
}
