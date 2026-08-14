import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/models/traffic_hazard.dart';
import 'package:iraq_cycling/services/hazard_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('hazard_repository_test');
    dbPath = p.join(tempDir.path, 'test.db');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('getAll() with nothing saved yet returns an empty list', () async {
    final repository = HazardRepository(databasePath: dbPath);

    final hazards = await repository.getAll();

    expect(hazards, isEmpty);
  });

  test(
    'add() then getAll() from a fresh instance round-trips the values',
    () async {
      await HazardRepository(databasePath: dbPath).add(
        const TrafficHazard(
          latitude: 33.315,
          longitude: 44.366,
          radiusMeters: 75,
          message: 'تقاطع مزدحم أمامك',
        ),
      );

      final reloaded = await HazardRepository(databasePath: dbPath).getAll();

      expect(reloaded, hasLength(1));
      expect(reloaded.first.latitude, 33.315);
      expect(reloaded.first.longitude, 44.366);
      expect(reloaded.first.radiusMeters, 75);
      expect(reloaded.first.message, 'تقاطع مزدحم أمامك');
      expect(reloaded.first.id, isNotNull);
    },
  );

  test('add() assigns a usable id to the returned hazard', () async {
    final repository = HazardRepository(databasePath: dbPath);

    final saved = await repository.add(
      const TrafficHazard(latitude: 1, longitude: 2, message: 'test'),
    );

    expect(saved.id, isNotNull);
  });

  test('delete() removes only the targeted hazard', () async {
    final repository = HazardRepository(databasePath: dbPath);

    final first = await repository.add(
      const TrafficHazard(latitude: 1, longitude: 1, message: 'أول'),
    );
    await repository.add(
      const TrafficHazard(latitude: 2, longitude: 2, message: 'ثاني'),
    );

    await repository.delete(first.id!);
    final remaining = await repository.getAll();

    expect(remaining, hasLength(1));
    expect(remaining.first.message, 'ثاني');
  });
}
