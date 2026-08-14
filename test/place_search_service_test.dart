import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/services/app_database.dart';
import 'package:iraq_cycling/services/place_search_service.dart';
import 'package:iraq_cycling/utils/arabic_text.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Coverage for [PlaceSearchService]: the name-search index reader over the
/// `place_names` table populated by [RoutingGraphSeeder]. Every test seeds
/// its own tiny set of names directly via `db.insert` (no real OSM data),
/// mirroring the exact `(name, name_normalized, latitude, longitude,
/// osm_way_id)` shape `build_routing_graph.py`'s `extract_place_names()`
/// produces.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;
  late Database db;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('place_search_service_test');
    dbPath = p.join(tempDir.path, 'test.db');
    db = await openAppDatabase(overridePath: dbPath);
  });

  tearDown(() async {
    await db.close();
    tempDir.deleteSync(recursive: true);
  });

  Future<void> insertPlace(
    String name, {
    required double lat,
    required double lon,
    int wayId = 1,
  }) => db.insert('place_names', {
    'name': name,
    'name_normalized': normalizeArabic(name),
    'latitude': lat,
    'longitude': lon,
    'osm_way_id': wayId,
  });

  test('finds a place by an exact name match', () async {
    await insertPlace('شارع الرشيد', lat: 33.34, lon: 44.40);

    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('شارع الرشيد');

    expect(results, hasLength(1));
    expect(results.single.name, 'شارع الرشيد');
    expect(results.single.point.latitude, closeTo(33.34, 1e-9));
    expect(results.single.point.longitude, closeTo(44.40, 1e-9));
  });

  test('finds a place by a partial (substring) query', () async {
    await insertPlace('شارع الرشيد', lat: 33.34, lon: 44.40);

    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('رشيد');

    expect(results, hasLength(1));
    expect(results.single.name, 'شارع الرشيد');
  });

  test('matches regardless of diacritics or alef-variant differences', () async {
    // Indexed with tashkeel, as OSM sometimes tags it.
    await insertPlace('شارع الرَّشيد', lat: 33.34, lon: 44.40);

    // Queried with a plain alef instead of alef-with-hamza, no diacritics.
    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('الرشيد');

    expect(results, hasLength(1));
  });

  test('ranks a prefix match above a match in the middle of a longer name', () async {
    await insertPlace('شارع الرشيد الفرعي الأول', lat: 33.30, lon: 44.30);
    await insertPlace('الرشيد', lat: 33.34, lon: 44.40);

    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('الرشيد');

    expect(results, hasLength(2));
    expect(results.first.name, 'الرشيد');
  });

  test('an empty (or whitespace-only) query returns no results', () async {
    await insertPlace('شارع الرشيد', lat: 33.34, lon: 44.40);

    expect(await PlaceSearchService(databasePath: dbPath).search(''), isEmpty);
    expect(
      await PlaceSearchService(databasePath: dbPath).search('   '),
      isEmpty,
    );
  });

  test('a query with no matches returns an empty list', () async {
    await insertPlace('شارع الرشيد', lat: 33.34, lon: 44.40);

    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('لا يوجد شيء بهذا الاسم');

    expect(results, isEmpty);
  });

  test('respects the limit parameter', () async {
    for (var i = 0; i < 5; i++) {
      await insertPlace('شارع رقم $i', lat: 33.3 + i * 0.001, lon: 44.4);
    }

    final results = await PlaceSearchService(
      databasePath: dbPath,
    ).search('شارع', limit: 3);

    expect(results, hasLength(3));
  });
}
