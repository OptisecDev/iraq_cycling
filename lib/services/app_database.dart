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
const int appDbVersion = 8;

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
      await _createRoutingGraphTables(db);
      await _createPlaceNamesTable(db);
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
      if (oldVersion < 5) {
        await _createRoutingGraphTables(db);
      }
      if (oldVersion < 6) {
        await _createPlaceNamesTable(db);
      }
      if (oldVersion < 7) {
        await db.execute('ALTER TABLE rides ADD COLUMN max_heart_rate REAL');
      }
      if (oldVersion < 8) {
        await db.execute(
          'ALTER TABLE rides ADD COLUMN paused_duration_ms INTEGER NOT NULL DEFAULT 0',
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
      max_heart_rate REAL,
      calories_burned REAL,
      paused_duration_ms INTEGER NOT NULL DEFAULT 0
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

/// Offline bike-routing graph for the Baghdad region (see [BaghdadRegion]
/// in map_tile_service.dart for the exact lat/lon bounds this is scoped to).
///
/// Populated by [RoutingGraphSeeder] from an OSM extract clipped to the
/// Baghdad bounds, converted into this nodes/edges shape by an offline
/// pipeline; see the "خط أنابيب بيانات التوجيه (OSM -> nodes/edges)"
/// section in PROJECT_STATE.md for the full extraction/conversion steps and
/// the reasoning behind each column below. Read by [RouteFinder]'s A*
/// search.
///
/// [routing_nodes.id] is deliberately the source OSM node id itself (not an
/// autoincrement surrogate) — `INTEGER PRIMARY KEY` in SQLite accepts an
/// explicit value on insert, and reusing the OSM id lets a re-import
/// upsert/replace rows directly without first rebuilding an id mapping.
///
/// [routing_edges] rows are directed: an OSM way with `oneway=yes` becomes
/// one row (way's node order); a way with `oneway=-1` becomes one row
/// (reversed node order); any other way (untagged or `oneway=no`) becomes
/// two rows, one per direction. This keeps the schema itself pathfinding-
/// agnostic — a future A*/Dijkstra implementation just walks rows matching
/// `from_node_id`, with no oneway branching at query time.
Future<void> _createRoutingGraphTables(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS routing_nodes (
      id INTEGER PRIMARY KEY,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL
    )
  ''');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS routing_edges (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      from_node_id INTEGER NOT NULL,
      to_node_id INTEGER NOT NULL,
      osm_way_id INTEGER NOT NULL,
      highway_type TEXT NOT NULL,
      cycleway TEXT,
      surface TEXT,
      oneway INTEGER NOT NULL DEFAULT 0,
      distance_meters REAL NOT NULL,
      weight REAL NOT NULL,
      FOREIGN KEY (from_node_id) REFERENCES routing_nodes (id) ON DELETE CASCADE,
      FOREIGN KEY (to_node_id) REFERENCES routing_nodes (id) ON DELETE CASCADE
    )
  ''');

  await db.execute(
    'CREATE INDEX idx_routing_edges_from_node ON routing_edges (from_node_id)',
  );
  await db.execute(
    'CREATE INDEX idx_routing_edges_to_node ON routing_edges (to_node_id)',
  );
  await db.execute(
    'CREATE INDEX idx_routing_edges_osm_way ON routing_edges (osm_way_id)',
  );
}

/// Name-search index for [PlaceSearchService]: one row per uniquely-named
/// street/square from the same OSM extract [_createRoutingGraphTables]
/// pulls its nodes/edges from - see
/// `tool/routing_import/build_routing_graph.py`'s `extract_place_names()`
/// for how rows are produced (dedup by name, longest segment wins as the
/// representative point) and populated by [RoutingGraphSeeder] alongside
/// routing_nodes/routing_edges.
///
/// [name_normalized] is precomputed at build time via the same
/// `normalize_arabic_name()` (Python) / `normalizeArabic()` (Dart,
/// lib/utils/arabic_text.dart) logic, so a search query only needs to be
/// normalized once at query time and compared directly - no per-row
/// normalization work at query time.
Future<void> _createPlaceNamesTable(Database db) async {
  await db.execute('''
    CREATE TABLE IF NOT EXISTS place_names (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      name_normalized TEXT NOT NULL,
      latitude REAL NOT NULL,
      longitude REAL NOT NULL,
      osm_way_id INTEGER NOT NULL
    )
  ''');

  await db.execute(
    'CREATE INDEX IF NOT EXISTS idx_place_names_normalized '
    'ON place_names (name_normalized)',
  );
}
