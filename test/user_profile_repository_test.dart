import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/models/user_profile.dart';
import 'package:iraq_cycling/services/user_profile_repository.dart';
import 'package:iraq_cycling/utils/calorie_calculator.dart' show Gender;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    // sqflite normally talks to a real platform channel (Android/iOS); the
    // ffi backend lets it run against a real SQLite file from the plain
    // `flutter test` VM instead, which has no such channel.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('user_profile_test');
    dbPath = p.join(tempDir.path, 'test.db');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'load() with nothing saved yet returns the documented defaults',
    () async {
      final repository = UserProfileRepository(databasePath: dbPath);

      final profile = await repository.load();

      expect(profile.name, '');
      expect(profile.weightKg, 70);
      expect(profile.age, 30);
      expect(profile.gender, Gender.male);
      expect(profile.preferredUnit, PreferredUnit.km);
    },
  );

  test('current defaults before load() is ever called', () {
    final repository = UserProfileRepository(databasePath: dbPath);

    expect(repository.current.weightKg, 70);
    expect(repository.current.age, 30);
  });

  test(
    'save() then load() from a fresh instance round-trips the values',
    () async {
      await UserProfileRepository(databasePath: dbPath).save(
        const UserProfile(
          name: 'Ahmed',
          weightKg: 82.5,
          age: 27,
          gender: Gender.female,
          preferredUnit: PreferredUnit.miles,
        ),
      );

      // A brand new instance, forcing a real read from disk rather than
      // relying on the in-memory `current` cache of the instance that saved.
      final reloaded = await UserProfileRepository(databasePath: dbPath).load();

      expect(reloaded.name, 'Ahmed');
      expect(reloaded.weightKg, 82.5);
      expect(reloaded.age, 27);
      expect(reloaded.gender, Gender.female);
      expect(reloaded.preferredUnit, PreferredUnit.miles);
    },
  );

  test(
    'save() updates `current` synchronously, without needing a reload',
    () async {
      final repository = UserProfileRepository(databasePath: dbPath);

      await repository.save(
        const UserProfile(name: 'Sara', weightKg: 60, age: 22),
      );

      expect(repository.current.name, 'Sara');
      expect(repository.current.weightKg, 60);
    },
  );

  test(
    'saving twice overwrites the single row instead of adding a second one',
    () async {
      final repository = UserProfileRepository(databasePath: dbPath);

      await repository.save(const UserProfile(name: 'First'));
      await repository.save(const UserProfile(name: 'Second'));

      final reloaded = await UserProfileRepository(databasePath: dbPath).load();
      expect(reloaded.name, 'Second');
    },
  );
}
