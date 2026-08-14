import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Schema-only coverage for the routing_nodes/routing_edges tables (added in
/// appDbVersion 5) and the place_names search index (appDbVersion 6) - "the
/// shape openAppDatabase creates matches what the OSM-import pipeline
/// documented in PROJECT_STATE.md expects to write".
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('app_database_test');
    dbPath = p.join(tempDir.path, 'test.db');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('fresh install creates routing_nodes with the expected columns', () async {
    final db = await openAppDatabase(overridePath: dbPath);

    final columns = await db.rawQuery('PRAGMA table_info(routing_nodes)');
    final columnNames = columns.map((c) => c['name']).toSet();

    expect(columnNames, {'id', 'latitude', 'longitude'});
  });

  test('fresh install creates routing_edges with the expected columns', () async {
    final db = await openAppDatabase(overridePath: dbPath);

    final columns = await db.rawQuery('PRAGMA table_info(routing_edges)');
    final columnNames = columns.map((c) => c['name']).toSet();

    expect(columnNames, {
      'id',
      'from_node_id',
      'to_node_id',
      'osm_way_id',
      'highway_type',
      'cycleway',
      'surface',
      'oneway',
      'distance_meters',
      'weight',
    });
  });

  test('routing_edges has indexes on from_node_id, to_node_id and osm_way_id', () async {
    final db = await openAppDatabase(overridePath: dbPath);

    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'routing_edges'",
    );
    final indexNames = indexes.map((i) => i['name']).toSet();

    expect(indexNames, {
      'idx_routing_edges_from_node',
      'idx_routing_edges_to_node',
      'idx_routing_edges_osm_way',
    });
  });

  test(
    'routing_nodes accepts an explicit id (OSM node id reuse, not autoincrement)',
    () async {
      final db = await openAppDatabase(overridePath: dbPath);

      await db.insert('routing_nodes', {
        'id': 123456789,
        'latitude': 33.3,
        'longitude': 44.4,
      });

      final rows = await db.query('routing_nodes');
      expect(rows, hasLength(1));
      expect(rows.first['id'], 123456789);
    },
  );

  test('deleting a routing_node cascades to its routing_edges', () async {
    final db = await openAppDatabase(overridePath: dbPath);
    await db.insert('routing_nodes', {
      'id': 1,
      'latitude': 33.3,
      'longitude': 44.4,
    });
    await db.insert('routing_nodes', {
      'id': 2,
      'latitude': 33.31,
      'longitude': 44.41,
    });
    await db.insert('routing_edges', {
      'from_node_id': 1,
      'to_node_id': 2,
      'osm_way_id': 999,
      'highway_type': 'residential',
      'oneway': 0,
      'distance_meters': 42.0,
      'weight': 42.0,
    });

    await db.delete('routing_nodes', where: 'id = ?', whereArgs: [1]);

    final remainingEdges = await db.query('routing_edges');
    expect(remainingEdges, isEmpty);
  });

  test('fresh install creates place_names with the expected columns', () async {
    final db = await openAppDatabase(overridePath: dbPath);

    final columns = await db.rawQuery('PRAGMA table_info(place_names)');
    final columnNames = columns.map((c) => c['name']).toSet();

    expect(columnNames, {
      'id',
      'name',
      'name_normalized',
      'latitude',
      'longitude',
      'osm_way_id',
    });
  });

  test('place_names has an index on name_normalized', () async {
    final db = await openAppDatabase(overridePath: dbPath);

    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'place_names'",
    );
    final indexNames = indexes.map((i) => i['name']).toSet();

    expect(indexNames, {'idx_place_names_normalized'});
  });
}
