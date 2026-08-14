import 'package:sqflite/sqflite.dart';

import '../models/ride.dart';
import '../models/ride_point.dart';
import 'app_database.dart';

/// Fully offline local storage for rides — no network calls in this file.
class RideRepository {
  Database? _database;

  Future<Database> get _db async {
    _database ??= await openAppDatabase();
    return _database!;
  }

  /// Saves a ride and all its points in a single transaction.
  /// Returns the saved ride with its assigned id.
  Future<Ride> saveRide(Ride ride) async {
    final db = await _db;

    final rideId = await db.transaction<int>((txn) async {
      final id = await txn.insert('rides', ride.toMap());

      final batch = txn.batch();
      for (final point in ride.points) {
        final pointMap = point.toMap();
        pointMap['ride_id'] = id;
        batch.insert('ride_points', pointMap);
      }
      await batch.commit(noResult: true);

      return id;
    });

    return ride.copyWith(id: rideId);
  }

  /// Rides only, without points, for fast list display.
  Future<List<Ride>> getAllRidesSummary() async {
    final db = await _db;
    final rows = await db.query('rides', orderBy: 'start_time DESC');
    return rows.map((row) => Ride.fromMap(row)).toList();
  }

  /// Full ride with all points ordered by timestamp.
  Future<Ride?> getRideWithPoints(int rideId) async {
    final db = await _db;

    final rideRows = await db.query(
      'rides',
      where: 'id = ?',
      whereArgs: [rideId],
      limit: 1,
    );
    if (rideRows.isEmpty) return null;

    final pointRows = await db.query(
      'ride_points',
      where: 'ride_id = ?',
      whereArgs: [rideId],
      orderBy: 'timestamp ASC',
    );

    final points = pointRows.map((row) => RidePoint.fromMap(row)).toList();
    return Ride.fromMap(rideRows.first, points: points);
  }

  Future<void> deleteRide(int rideId) async {
    final db = await _db;
    await db.delete('rides', where: 'id = ?', whereArgs: [rideId]);
  }
}
