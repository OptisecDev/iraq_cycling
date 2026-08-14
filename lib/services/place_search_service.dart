import 'package:latlong2/latlong.dart';
import 'package:sqflite/sqflite.dart';

import '../utils/arabic_text.dart';
import 'app_database.dart';

/// One name-search match: a street/square name plus the representative
/// point [RouteFinder.findRoute] can be given directly as a destination.
class PlaceSearchResult {
  const PlaceSearchResult({required this.name, required this.point});

  final String name;
  final LatLng point;
}

/// Search-by-name over the offline `place_names` index (populated by
/// [RoutingGraphSeeder] from the same OSM extract `routing_nodes`/
/// `routing_edges` come from - see `_createPlaceNamesTable` in
/// `app_database.dart`).
///
/// This is a plain substring/prefix match over `name_normalized`, not a
/// fuzzy or ranked full-text search - deliberately minimal for a first cut
/// (see PROJECT_STATE.md: route safety weighting and richer search are
/// separate, later decisions).
class PlaceSearchService {
  /// [databasePath], if provided, is passed through to [openAppDatabase] -
  /// only tests need this, to point at an isolated temp database.
  PlaceSearchService({String? databasePath}) : _databasePath = databasePath;

  static const int defaultLimit = 20;

  final String? _databasePath;
  Database? _database;

  Future<Database> get _db async {
    _database ??= await openAppDatabase(overridePath: _databasePath);
    return _database!;
  }

  /// Matches [query] against `place_names.name_normalized` (both sides run
  /// through the same [normalizeArabic] used to build that column, so
  /// diacritics/alef-variant differences between the two don't matter).
  /// Prefix matches rank above mid-string matches; ties break toward
  /// shorter names, since a short exact-ish name is usually what a
  /// substring query was aiming for over a long compound one that happens
  /// to contain it. Returns an empty list for a blank query rather than
  /// the whole table.
  Future<List<PlaceSearchResult>> search(
    String query, {
    int limit = defaultLimit,
  }) async {
    final normalized = normalizeArabic(query);
    if (normalized.isEmpty) return const [];

    final db = await _db;
    final escaped = _escapeLike(normalized);
    final rows = await db.rawQuery(
      '''
      SELECT name, latitude, longitude
      FROM place_names
      WHERE name_normalized LIKE ? ESCAPE '\\'
      ORDER BY
        CASE WHEN name_normalized LIKE ? ESCAPE '\\' THEN 0 ELSE 1 END,
        LENGTH(name_normalized) ASC
      LIMIT ?
      ''',
      ['%$escaped%', '$escaped%', limit],
    );

    return rows
        .map(
          (row) => PlaceSearchResult(
            name: row['name'] as String,
            point: LatLng(
              row['latitude'] as double,
              row['longitude'] as double,
            ),
          ),
        )
        .toList(growable: false);
  }

  String _escapeLike(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}
