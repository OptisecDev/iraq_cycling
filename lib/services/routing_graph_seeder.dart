import 'dart:io';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// One-time data seed for the offline bike-routing graph (`routing_nodes`/
/// `routing_edges`, see `_createRoutingGraphTables` in `app_database.dart`)
/// from a prebuilt sqlite db shipped as a Flutter asset.
///
/// The asset itself is produced entirely outside the app by
/// `tool/routing_import/build_routing_graph.py` (an offline, build-time
/// OSM -> nodes/edges pipeline, documented in PROJECT_STATE.md). Nothing in
/// this class talks to Overpass/OSM or computes any routing-graph data - it
/// only copies already-computed rows into the app's live database.
class RoutingGraphSeeder {
  /// [assetBundle] and [tempDir], if provided, are used instead of the real
  /// `rootBundle`/`path_provider` - so tests can inject a fake bundle and a
  /// throwaway directory without needing a platform channel.
  RoutingGraphSeeder({AssetBundle? assetBundle, Directory? tempDir})
    : _assetBundle = assetBundle ?? rootBundle,
      _tempDir = tempDir;

  static const String assetPath = 'assets/routing/baghdad_routing.db';

  final AssetBundle _assetBundle;
  final Directory? _tempDir;

  /// Copies `routing_nodes`/`routing_edges` from the bundled asset into
  /// [db] unless both tables are already populated. Safe to call on every
  /// app start - a cheap no-op after the first successful run, and also
  /// self-heals a previous run that was interrupted mid-seed (one table
  /// populated, the other not).
  Future<void> seedIfNeeded(Database db) async {
    final nodeCount = await _rowCount(db, 'routing_nodes');
    final edgeCount = await _rowCount(db, 'routing_edges');
    if (nodeCount > 0 && edgeCount > 0) return;

    final assetData = await _assetBundle.load(assetPath);
    final tempDir = _tempDir ?? await getTemporaryDirectory();
    final seedFile = File(
      p.join(
        tempDir.path,
        'baghdad_routing_seed_${DateTime.now().microsecondsSinceEpoch}.db',
      ),
    );
    await seedFile.writeAsBytes(
      assetData.buffer.asUint8List(
        assetData.offsetInBytes,
        assetData.lengthInBytes,
      ),
      flush: true,
    );

    try {
      // ATTACH must run outside any transaction - SQLite rejects it once a
      // transaction is already open.
      await db.execute('ATTACH DATABASE ? AS seed', [seedFile.path]);
      try {
        await db.transaction((txn) async {
          // Matches the re-import policy documented in PROJECT_STATE.md:
          // full delete then reinsert from scratch - routing_edges first
          // (FK to routing_nodes), routing_nodes first on the way back in.
          await txn.execute('DELETE FROM routing_edges');
          await txn.execute('DELETE FROM routing_nodes');
          await txn.execute(
            'INSERT INTO routing_nodes SELECT id, latitude, longitude '
            'FROM seed.routing_nodes',
          );
          await txn.execute('''
            INSERT INTO routing_edges
              (from_node_id, to_node_id, osm_way_id, highway_type, cycleway,
               surface, oneway, distance_meters, weight)
            SELECT from_node_id, to_node_id, osm_way_id, highway_type,
                   cycleway, surface, oneway, distance_meters, weight
            FROM seed.routing_edges
          ''');
        });
      } finally {
        await db.execute('DETACH DATABASE seed');
      }
    } finally {
      if (await seedFile.exists()) {
        await seedFile.delete();
      }
    }
  }

  Future<int> _rowCount(Database db, String table) async {
    final result = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}
