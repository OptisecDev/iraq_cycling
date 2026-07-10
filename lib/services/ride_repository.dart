import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/ride.dart';
import '../models/ride_point.dart';

/// Fully offline local storage for rides — no network calls in this file.
class RideRepository {
  static const String _dbName = 'iraq_cycling.db';
  static const int _dbVersion = 1;

  Database? _database;

  Future<Database> get _db async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE rides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            start_time INTEGER NOT NULL,
            end_time INTEGER,
            total_distance_meters REAL NOT NULL,
            max_speed_mps REAL NOT NULL,
            total_elevation_gain_meters REAL NOT NULL,
            avg_heart_rate REAL,
            calories_burned REAL
          )
        ''');

        await db.execute('''
          CREATE TABLE ride_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ride_id INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            altitude REAL NOT NULL,
            speed REAL NOT NULL,
            timestamp INTEGER NOT NULL,
            accuracy REAL,
            FOREIGN KEY (ride_id) REFERENCES rides (id) ON DELETE CASCADE
          )
        ''');

        await db.execute(
          'CREATE INDEX idx_ride_points_ride_id ON ride_points (ride_id)',
        );
      },
    );
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
