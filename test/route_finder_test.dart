import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/route_finder.dart';
import 'package:iraq_cycling/utils/distance_calculator.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Coverage for [RouteFinder]: the A* pathfinding engine that reads the
/// `routing_nodes`/`routing_edges` tables populated by [RoutingGraphSeeder].
/// Every test builds its own tiny hand-crafted graph directly via
/// `db.insert` (no real OSM data, no [RoutingGraphSeeder] involved) so the
/// search logic itself - snapping, hop-by-hop expansion, weight-vs-distance
/// bookkeeping, path reconstruction - is exercised in isolation.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;
  late Database db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('route_finder_test');
    dbPath = p.join(tempDir.path, 'test.db');
    // Seeded directly via this raw handle below; RouteFinder(databasePath:)
    // opens the *same* underlying connection (sqflite's default
    // singleInstance:true keys on path), so no separate hand-off is needed.
    db = await openAppDatabase(overridePath: dbPath);
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> insertNode(int id, double lat, double lon) => db.insert(
    'routing_nodes',
    {'id': id, 'latitude': lat, 'longitude': lon},
  );

  Future<void> insertEdge(
    int fromId,
    int toId, {
    required double distanceMeters,
    double? weight,
  }) => db.insert('routing_edges', {
    'from_node_id': fromId,
    'to_node_id': toId,
    'osm_way_id': 1,
    'highway_type': 'residential',
    'oneway': 1,
    'distance_meters': distanceMeters,
    'weight': weight ?? distanceMeters,
  });

  test('finds a direct one-hop route between two adjacent nodes', () async {
    const lat1 = 33.300, lon1 = 44.400;
    const lat2 = 33.301, lon2 = 44.401;
    final dist = DistanceCalculator.haversineDistance(lat1, lon1, lat2, lon2);

    await insertNode(1, lat1, lon1);
    await insertNode(2, lat2, lon2);
    await insertEdge(1, 2, distanceMeters: dist);

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      startLatitude: lat1,
      startLongitude: lon1,
      endLatitude: lat2,
      endLongitude: lon2,
    );

    expect(result, isNotNull);
    expect(result!.points, hasLength(2));
    expect(result.points.first.latitude, closeTo(lat1, 1e-9));
    expect(result.points.first.longitude, closeTo(lon1, 1e-9));
    expect(result.points.last.latitude, closeTo(lat2, 1e-9));
    expect(result.points.last.longitude, closeTo(lon2, 1e-9));
    expect(result.distanceMeters, closeTo(dist, 0.01));
  });

  test('finds a multi-hop route through intermediate nodes, in order', () async {
    const coords = [
      (33.300, 44.400),
      (33.301, 44.401),
      (33.302, 44.402),
      (33.303, 44.403),
    ];
    for (var i = 0; i < coords.length; i++) {
      await insertNode(i + 1, coords[i].$1, coords[i].$2);
    }

    var totalDistance = 0.0;
    for (var i = 0; i < coords.length - 1; i++) {
      final dist = DistanceCalculator.haversineDistance(
        coords[i].$1,
        coords[i].$2,
        coords[i + 1].$1,
        coords[i + 1].$2,
      );
      totalDistance += dist;
      await insertEdge(i + 1, i + 2, distanceMeters: dist);
    }

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      startLatitude: coords.first.$1,
      startLongitude: coords.first.$2,
      endLatitude: coords.last.$1,
      endLongitude: coords.last.$2,
    );

    expect(result, isNotNull);
    expect(result!.points, hasLength(4));
    for (var i = 0; i < coords.length; i++) {
      expect(result.points[i].latitude, closeTo(coords[i].$1, 1e-9));
      expect(result.points[i].longitude, closeTo(coords[i].$2, 1e-9));
    }
    expect(result.distanceMeters, closeTo(totalDistance, 0.01));
  });

  test('start and end snapping to the same node returns a zero-distance route', () async {
    const lat = 33.300, lon = 44.400;
    await insertNode(1, lat, lon);
    // A second, farther node so the graph isn't trivially single-node.
    await insertNode(2, 33.320, 44.420);
    await insertEdge(1, 2, distanceMeters: 2000);

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      // Two nearby points that both snap to node 1, not node 2.
      startLatitude: lat + 0.00001,
      startLongitude: lon,
      endLatitude: lat - 0.00001,
      endLongitude: lon,
    );

    expect(result, isNotNull);
    expect(result!.points, hasLength(1));
    expect(result.points.single.latitude, closeTo(lat, 1e-9));
    expect(result.points.single.longitude, closeTo(lon, 1e-9));
    expect(result.distanceMeters, 0);
  });

  test('prefers the lower-weight route even when it is physically longer', () async {
    const startCoord = (33.300, 44.400);
    const midCoord = (33.301, 44.401);
    const endCoord = (33.302, 44.402);

    await insertNode(1, startCoord.$1, startCoord.$2);
    await insertNode(2, midCoord.$1, midCoord.$2);
    await insertNode(3, endCoord.$1, endCoord.$2);

    // Direct edge: physically shortest, but heavily weight-penalized (e.g.
    // a busy arterial road a cyclist should avoid).
    final directDistance = DistanceCalculator.haversineDistance(
      startCoord.$1,
      startCoord.$2,
      endCoord.$1,
      endCoord.$2,
    );
    await insertEdge(1, 3, distanceMeters: directDistance, weight: 100000);

    // Two-hop detour: physically longer, but much lower total weight (e.g.
    // a dedicated cycleway).
    final hop1Distance = DistanceCalculator.haversineDistance(
      startCoord.$1,
      startCoord.$2,
      midCoord.$1,
      midCoord.$2,
    );
    final hop2Distance = DistanceCalculator.haversineDistance(
      midCoord.$1,
      midCoord.$2,
      endCoord.$1,
      endCoord.$2,
    );
    await insertEdge(1, 2, distanceMeters: hop1Distance);
    await insertEdge(2, 3, distanceMeters: hop2Distance);

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      startLatitude: startCoord.$1,
      startLongitude: startCoord.$2,
      endLatitude: endCoord.$1,
      endLongitude: endCoord.$2,
    );

    expect(result, isNotNull);
    // Took the detour through node 2, not the direct (but heavily
    // weighted) edge straight to node 3.
    expect(result!.points, hasLength(3));
    expect(result.points[1].latitude, closeTo(midCoord.$1, 1e-9));
    expect(result.distanceMeters, closeTo(hop1Distance + hop2Distance, 0.01));
    expect(result.distanceMeters, greaterThan(directDistance));
  });

  test('returns null when the snapped nodes have no connecting path', () async {
    await insertNode(1, 33.300, 44.400);
    await insertNode(2, 33.500, 44.500); // Far away, no edges at all.

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      startLatitude: 33.300,
      startLongitude: 44.400,
      endLatitude: 33.500,
      endLongitude: 44.500,
    );

    expect(result, isNull);
  });

  test('snaps to the nearest of several nearby candidate nodes', () async {
    const queryLat = 33.300, queryLon = 44.400;
    // Node A: ~80m from the query point.
    const nodeA = (33.3007, 44.400);
    // Node C: farther away, ~200m from the query point.
    const nodeC = (33.3018, 44.400);
    const destination = (33.310, 44.410);

    await insertNode(1, nodeA.$1, nodeA.$2);
    await insertNode(2, nodeC.$1, nodeC.$2);
    await insertNode(3, destination.$1, destination.$2);

    // Only the nearer node (A) is connected onward - if snapping picked the
    // farther node (C) instead, this route would be unreachable.
    final distA = DistanceCalculator.haversineDistance(
      nodeA.$1,
      nodeA.$2,
      destination.$1,
      destination.$2,
    );
    await insertEdge(1, 3, distanceMeters: distA);

    final result = await RouteFinder(databasePath: dbPath).findRoute(
      startLatitude: queryLat,
      startLongitude: queryLon,
      endLatitude: destination.$1,
      endLongitude: destination.$2,
    );

    expect(result, isNotNull);
    expect(result!.points.first.latitude, closeTo(nodeA.$1, 1e-9));
    expect(result.points.first.longitude, closeTo(nodeA.$2, 1e-9));
  });
}
