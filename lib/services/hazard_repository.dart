import 'package:sqflite/sqflite.dart';

import '../models/traffic_hazard.dart';
import 'app_database.dart';

/// Local persistence for rider-marked hazard locations, via the same shared
/// sqflite database used by [RideRepository]/[UserProfileRepository].
class HazardRepository {
  /// [databasePath], if provided, is passed through to [openAppDatabase] —
  /// only tests need this, to point at an isolated temp database.
  HazardRepository({String? databasePath}) : _databasePath = databasePath;

  final String? _databasePath;
  Database? _database;

  Future<Database> get _db async {
    _database ??= await openAppDatabase(overridePath: _databasePath);
    return _database!;
  }

  Future<List<TrafficHazard>> getAll() async {
    final db = await _db;
    final rows = await db.query('traffic_hazards', orderBy: 'id DESC');
    return rows.map(TrafficHazard.fromMap).toList();
  }

  /// Adds a hazard and returns it with its assigned id.
  Future<TrafficHazard> add(TrafficHazard hazard) async {
    final db = await _db;
    final id = await db.insert('traffic_hazards', hazard.toMap());
    return TrafficHazard(
      id: id,
      latitude: hazard.latitude,
      longitude: hazard.longitude,
      radiusMeters: hazard.radiusMeters,
      message: hazard.message,
    );
  }

  Future<void> delete(int id) async {
    final db = await _db;
    await db.delete('traffic_hazards', where: 'id = ?', whereArgs: [id]);
  }
}
