import 'package:sqflite/sqflite.dart';

import '../models/user_profile.dart';
import 'app_database.dart';

/// Local persistence for the single-row rider profile, via the same shared
/// sqflite database used by [RideRepository] (see app_database.dart) — no
/// new storage dependency introduced for this.
class UserProfileRepository {
  /// [databasePath], if provided, is passed through to [openAppDatabase] —
  /// only tests need this, to point at an isolated temp database.
  UserProfileRepository({String? databasePath}) : _databasePath = databasePath;

  final String? _databasePath;
  Database? _database;

  Future<Database> get _db async {
    _database ??= await openAppDatabase(overridePath: _databasePath);
    return _database!;
  }

  /// The most recently loaded or saved profile, available synchronously.
  ///
  /// [RideTracker] needs a profile at the moment a ride finishes without
  /// making that call async, so this cache — populated by [load] at app
  /// startup and kept current by [save] — is the source of truth it reads.
  /// Defaults to the same placeholders `calorie_calculator.dart` already
  /// used before any profile existed, so behavior is unchanged until a
  /// profile is actually saved.
  UserProfile current = const UserProfile();

  Future<UserProfile> load() async {
    final db = await _db;
    final rows = await db.query(
      'user_profile',
      where: 'id = ?',
      whereArgs: [1],
      limit: 1,
    );
    current = rows.isEmpty
        ? const UserProfile()
        : UserProfile.fromMap(rows.first);
    return current;
  }

  Future<void> save(UserProfile profile) async {
    final db = await _db;
    await db.insert(
      'user_profile',
      profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    current = profile;
  }
}
