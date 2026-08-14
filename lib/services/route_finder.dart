import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:latlong2/latlong.dart' hide DistanceCalculator;
import 'package:sqflite/sqflite.dart';

import '../utils/distance_calculator.dart';
import 'app_database.dart';

/// The result of a successful [RouteFinder.findRoute] call: an ordered
/// polyline from the snapped start node to the snapped end node, plus the
/// route's total physical length.
///
/// [distanceMeters] is the sum of `routing_edges.distance_meters` along the
/// chosen path - the real-world distance a rider would cover - which is
/// deliberately tracked separately from the `weight` column used to choose
/// that path (see [RouteFinder] doc comment).
class RouteResult {
  const RouteResult({required this.points, required this.distanceMeters});

  final List<LatLng> points;
  final double distanceMeters;
}

/// Computes the best bike route between two arbitrary lat/lon points over
/// the offline routing graph (`routing_nodes`/`routing_edges`, populated by
/// [RoutingGraphSeeder]) using A*, with a haversine straight-line-distance
/// heuristic.
///
/// Cost model: the search optimizes on `routing_edges.weight` (the column
/// intended to eventually carry cycling-friendliness coefficients on top of
/// raw distance - see PROJECT_STATE.md, "جدول معاملات weight الفعلي"),
/// while [RouteResult.distanceMeters] is accumulated separately from
/// `distance_meters` so the reported trip length stays the true physical
/// distance regardless of how `weight` is tuned later. The haversine
/// heuristic is only admissible if `weight >= distance_meters` for every
/// edge, which holds today (the import pipeline seeds `weight == dist` as a
/// neutral placeholder) and is expected to keep holding once real
/// coefficients only add cycling-unfriendliness penalties on top of
/// distance, never subtract from it.
///
/// This class does no routing-graph population itself - it only reads an
/// already-seeded database, via the same lazy shared-connection pattern as
/// [RideRepository]/[HazardRepository]/[UserProfileRepository].
class RouteFinder {
  /// [databasePath], if provided, is passed through to [openAppDatabase] —
  /// only tests need this, to point at an isolated temp database.
  RouteFinder({String? databasePath}) : _databasePath = databasePath;

  final String? _databasePath;
  Database? _database;

  Future<Database> get _db async {
    _database ??= await openAppDatabase(overridePath: _databasePath);
    return _database!;
  }

  /// Finds the best route from ([startLatitude], [startLongitude]) to
  /// ([endLatitude], [endLongitude]).
  ///
  /// Both endpoints are first snapped to their nearest `routing_nodes` row.
  /// Returns `null` if the graph has no path connecting the two snapped
  /// nodes (e.g. disconnected components). Throws a [StateError] if no
  /// routing node at all exists within [_maxSnapRadiusMeters] of either
  /// input point - this means the graph has no coverage there, not that a
  /// route search failed.
  Future<RouteResult?> findRoute({
    required double startLatitude,
    required double startLongitude,
    required double endLatitude,
    required double endLongitude,
  }) async {
    final startNode = await _nearestNode(startLatitude, startLongitude);
    final endNode = await _nearestNode(endLatitude, endLongitude);

    if (startNode.id == endNode.id) {
      return RouteResult(
        points: [LatLng(startNode.latitude, startNode.longitude)],
        distanceMeters: 0,
      );
    }

    return _aStar(startNode, endNode);
  }

  Future<RouteResult?> _aStar(_Node start, _Node end) async {
    final db = await _db;

    // Cost so far, in `weight` units - the quantity A* optimizes on.
    final costSoFar = <int, double>{start.id: 0};
    // Physical distance so far, in meters - accumulated in parallel purely
    // for the final [RouteResult.distanceMeters], never used to rank nodes.
    final distanceSoFar = <int, double>{start.id: 0};
    final cameFrom = <int, int>{};
    final coordsById = <int, (double, double)>{
      start.id: (start.latitude, start.longitude),
      end.id: (end.latitude, end.longitude),
    };
    final closed = <int>{};

    final openSet = HeapPriorityQueue<_OpenEntry>(
      (a, b) => a.fScore.compareTo(b.fScore),
    );
    openSet.add(
      _OpenEntry(
        nodeId: start.id,
        fScore: _heuristicMeters(start, end),
      ),
    );

    while (openSet.isNotEmpty) {
      final current = openSet.removeFirst();
      if (!closed.add(current.nodeId)) {
        // Already finalized via a cheaper queue entry added earlier.
        continue;
      }
      if (current.nodeId == end.id) {
        return _reconstructRoute(
          cameFrom: cameFrom,
          distanceSoFar: distanceSoFar,
          coordsById: coordsById,
          startId: start.id,
          endId: end.id,
        );
      }

      final currentCost = costSoFar[current.nodeId]!;
      final currentDistance = distanceSoFar[current.nodeId]!;

      final neighbors = await db.rawQuery(
        '''
        SELECT e.to_node_id AS id, e.weight AS weight,
               e.distance_meters AS distance_meters,
               n.latitude AS latitude, n.longitude AS longitude
        FROM routing_edges e
        JOIN routing_nodes n ON n.id = e.to_node_id
        WHERE e.from_node_id = ?
        ''',
        [current.nodeId],
      );

      for (final row in neighbors) {
        final neighborId = row['id'] as int;
        if (closed.contains(neighborId)) continue;

        final edgeWeight = (row['weight'] as num).toDouble();
        final edgeDistance = (row['distance_meters'] as num).toDouble();
        final tentativeCost = currentCost + edgeWeight;

        if (tentativeCost < (costSoFar[neighborId] ?? double.infinity)) {
          costSoFar[neighborId] = tentativeCost;
          distanceSoFar[neighborId] = currentDistance + edgeDistance;
          cameFrom[neighborId] = current.nodeId;
          final neighborLat = row['latitude'] as double;
          final neighborLon = row['longitude'] as double;
          coordsById[neighborId] = (neighborLat, neighborLon);
          final h = DistanceCalculator.haversineDistance(
            neighborLat,
            neighborLon,
            end.latitude,
            end.longitude,
          );
          openSet.add(
            _OpenEntry(nodeId: neighborId, fScore: tentativeCost + h),
          );
        }
      }
    }

    return null;
  }

  RouteResult _reconstructRoute({
    required Map<int, int> cameFrom,
    required Map<int, double> distanceSoFar,
    required Map<int, (double, double)> coordsById,
    required int startId,
    required int endId,
  }) {
    final orderedIds = <int>[endId];
    var node = endId;
    while (node != startId) {
      node = cameFrom[node]!;
      orderedIds.add(node);
    }
    final points = orderedIds.reversed
        .map((id) => coordsById[id]!)
        .map((c) => LatLng(c.$1, c.$2))
        .toList(growable: false);

    return RouteResult(points: points, distanceMeters: distanceSoFar[endId]!);
  }

  double _heuristicMeters(_Node from, _Node to) =>
      DistanceCalculator.haversineDistance(
        from.latitude,
        from.longitude,
        to.latitude,
        to.longitude,
      );

  static const double _initialSnapRadiusMeters = 300;
  static const double _maxSnapRadiusMeters = 20000;

  /// Finds the `routing_nodes` row nearest to ([lat], [lon]) by expanding a
  /// lat/lon bounding box search until at least one node falls inside it,
  /// then picking the closest candidate by exact haversine distance.
  ///
  /// There is no spatial index (R-tree) on `routing_nodes`, so this trades a
  /// little precision at the box's edges (a square window, not a true
  /// circle) for avoiding a full-table scan on every call - acceptable for
  /// snapping a rider's start/end point, not for a precision GIS lookup.
  Future<_Node> _nearestNode(double lat, double lon) async {
    final db = await _db;
    var radiusMeters = _initialSnapRadiusMeters;
    while (true) {
      final latDelta = radiusMeters / _metersPerLatDegree;
      final lonDelta =
          radiusMeters /
          (_metersPerLatDegree * math.cos(lat * math.pi / 180).abs().clamp(
            1e-6,
            1,
          ));

      final rows = await db.query(
        'routing_nodes',
        where:
            'latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?',
        whereArgs: [
          lat - latDelta,
          lat + latDelta,
          lon - lonDelta,
          lon + lonDelta,
        ],
      );

      if (rows.isNotEmpty) {
        _Node? best;
        var bestDistance = double.infinity;
        for (final row in rows) {
          final nodeLat = row['latitude'] as double;
          final nodeLon = row['longitude'] as double;
          final distance = DistanceCalculator.haversineDistance(
            lat,
            lon,
            nodeLat,
            nodeLon,
          );
          if (distance < bestDistance) {
            bestDistance = distance;
            best = _Node(id: row['id'] as int, latitude: nodeLat, longitude: nodeLon);
          }
        }
        return best!;
      }

      if (radiusMeters >= _maxSnapRadiusMeters) {
        throw StateError(
          'No routing_nodes found within ${_maxSnapRadiusMeters}m of '
          '($lat, $lon).',
        );
      }
      radiusMeters = math.min(radiusMeters * 4, _maxSnapRadiusMeters);
    }
  }

  // Approximate and only used to size the bounding-box search window above
  // - the actual distance comparisons all use the exact haversine formula.
  static const double _metersPerLatDegree = 111320;
}

class _Node {
  const _Node({required this.id, required this.latitude, required this.longitude});

  final int id;
  final double latitude;
  final double longitude;
}

class _OpenEntry {
  const _OpenEntry({required this.nodeId, required this.fScore});

  final int nodeId;
  final double fScore;
}
