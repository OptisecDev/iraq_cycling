import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

/// Single shared sqflite bootstrap for the whole app (rides + user profile).
///
/// Both [RideRepository] and [UserProfileRepository] open this same
/// database file/version through this one function, instead of each owning
/// its own `onCreate`/`onUpgrade` — two independent schema definitions for
/// the same file would drift out of sync as soon as one changed without the
/// other. sqflite's default `singleInstance: true` means repeated calls to
/// [openAppDatabase] from the same isolate return the same live connection,
/// so this is safe to call from multiple repositories.
const String appDbName = 'iraq_cycling.db';
const int appDbVersion = 4;

/// [overridePath], if provided, is opened directly instead of resolving a
/// path via `getDatabasesPath()` — only tests need this, to point at an
/// isolated temp file rather than the real app database location.
Future<Database> openAppDatabase({String? overridePath}) async {
  final path = overridePath ?? await _dbPath();
  return openDatabase(
    path,
    version: appDbVersion,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
    onCreate: (db, version) async {
      await _createRideTables(db);
      await _createUserProfileTable(db);
      await _createTrafficHazardsTable(db);
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) {
        await _createUserProfileTable(db);
      }
      if (oldVersion < 3) {
        await _createTrafficHazardsTable(db);
      }
      // Only alter an already-existing table that predates the gender
      // column: an oldVersion < 2 upgrade just created the table above via
      // _createUserProfileTable, which already includes gender, so running
      // ALTER TABLE again here would fail with "duplicate column".
      if (oldVersion >= 2 && oldVersion < 4) {
        await db.execute(
          "ALTER TABLE user_profile ADD COLUMN gender TEXT NOT NULL DEFAULT 'male'",
        );
      }
    },
  );
}

Future<String> _dbPath() async => join(await getDatabasesPath(), appDbName);

Future<void> _createRideTables(Database db) async {
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
}

Future<void> _createUserProfileTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS user_profile (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      name TEXT NOT NULL,
      weight_kg REAL NOT NULL,
      age_years INTEGER NOT NULL,
      gender TEXT NOT NULL DEFAULT 'male',
      preferred_unit TEXT NOT NULL
    )
  ''');
}

Future<void> _createTrafficHazardsTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS traffic_hazards (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      radius_meters REAL NOT NULL,
      message TEXT NOT NULL
    )
  ''');
}
