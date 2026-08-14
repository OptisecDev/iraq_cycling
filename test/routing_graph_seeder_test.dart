import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/routing_graph_seeder.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Serves a single fixed-content asset from an in-memory byte buffer, and
/// counts how many times [load] was called - so tests can assert the
/// (large) asset copy is skipped once the graph is already seeded.
class _FakeAssetBundle extends CachingAssetBundle {
  _FakeAssetBundle(this._bytes);

  final Uint8List _bytes;
  int loadCount = 0;

  @override
  Future<ByteData> load(String key) async {
    loadCount++;
    return ByteData.sublistView(_bytes);
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String appDbPath;
  late Uint8List seedDbBytes;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('routing_graph_seeder_test');
    appDbPath = p.join(tempDir.path, 'app.db');

    // Build a tiny standalone seed db with the same routing_nodes/edges
    // shape build_routing_graph.py produces, to stand in for the real
    // (89 MiB) bundled asset.
    final seedDbPath = p.join(tempDir.path, 'seed_source.db');
    final seedDb = await databaseFactory.openDatabase(seedDbPath);
    await seedDb.execute(
      'CREATE TABLE routing_nodes (id INTEGER PRIMARY KEY, latitude REAL NOT NULL, longitude REAL NOT NULL)',
    );
    await seedDb.execute('''
      CREATE TABLE routing_edges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        from_node_id INTEGER NOT NULL,
        to_node_id INTEGER NOT NULL,
        osm_way_id INTEGER NOT NULL,
        highway_type TEXT NOT NULL,
        cycleway TEXT,
        surface TEXT,
        oneway INTEGER NOT NULL DEFAULT 0,
        distance_meters REAL NOT NULL,
        weight REAL NOT NULL
      )
    ''');
    await seedDb.insert('routing_nodes', {
      'id': 1,
      'latitude': 33.3,
      'longitude': 44.4,
    });
    await seedDb.insert('routing_nodes', {
      'id': 2,
      'latitude': 33.31,
      'longitude': 44.41,
    });
    await seedDb.insert('routing_edges', {
      'from_node_id': 1,
      'to_node_id': 2,
      'osm_way_id': 999,
      'highway_type': 'residential',
      'oneway': 0,
      'distance_meters': 42.0,
      'weight': 42.0,
    });
    await seedDb.close();

    seedDbBytes = await File(seedDbPath).readAsBytes();
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('seedIfNeeded copies nodes and edges from the asset into an empty db', () async {
    final appDb = await openAppDatabase(overridePath: appDbPath);
    final bundle = _FakeAssetBundle(seedDbBytes);

    await RoutingGraphSeeder(
      assetBundle: bundle,
      tempDir: tempDir,
    ).seedIfNeeded(appDb);

    final nodes = await appDb.query('routing_nodes', orderBy: 'id');
    final edges = await appDb.query('routing_edges');

    expect(nodes, hasLength(2));
    expect(nodes.first['id'], 1);
    expect(edges, hasLength(1));
    expect(edges.first['osm_way_id'], 999);
    expect(bundle.loadCount, 1);
  });

  test('seedIfNeeded is a no-op once both tables are already populated', () async {
    final appDb = await openAppDatabase(overridePath: appDbPath);
    final bundle = _FakeAssetBundle(seedDbBytes);
    final seeder = RoutingGraphSeeder(assetBundle: bundle, tempDir: tempDir);

    await seeder.seedIfNeeded(appDb);
    await seeder.seedIfNeeded(appDb);

    expect(bundle.loadCount, 1);
  });

  test('seedIfNeeded self-heals a partial previous seed', () async {
    final appDb = await openAppDatabase(overridePath: appDbPath);
    // Simulate a run that was interrupted after routing_nodes but before
    // routing_edges.
    await appDb.insert('routing_nodes', {
      'id': 999999,
      'latitude': 0,
      'longitude': 0,
    });

    final bundle = _FakeAssetBundle(seedDbBytes);
    await RoutingGraphSeeder(
      assetBundle: bundle,
      tempDir: tempDir,
    ).seedIfNeeded(appDb);

    final nodes = await appDb.query('routing_nodes', orderBy: 'id');
    expect(nodes.map((n) => n['id']), [1, 2]);
    expect(await appDb.query('routing_edges'), hasLength(1));
  });
}
