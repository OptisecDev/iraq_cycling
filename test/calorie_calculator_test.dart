import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/utils/calorie_calculator.dart';

void main() {
  group('estimateCaloriesBurned with heart rate data', () {
    test('a realistic 1-hour ride at 140bpm produces a positive, plausible '
        'calorie value (not negative, not absurd for a short-ish ride)', () {
      final calories = estimateCaloriesBurned(
        duration: const Duration(hours: 1),
        avgHeartRate: 140,
      );

      expect(calories, greaterThan(0));
      // A moderately intense hour of cycling should plausibly be in the
      // low hundreds to under a thousand kcal for a 70kg/30yo rider, not
      // e.g. tens of thousands.
      expect(calories, lessThan(1500));
    });

    test('female formula also produces a positive, plausible value', () {
      final calories = estimateCaloriesBurned(
        duration: const Duration(hours: 1),
        avgHeartRate: 140,
        gender: Gender.female,
      );

      expect(calories, greaterThan(0));
      expect(calories, lessThan(1500));
    });
  });

  group('estimateCaloriesBurned fallback (no heart rate)', () {
    test('a ride with no heart rate data still produces a plausible positive '
        'value using the MET/speed fallback', () {
      final calories = estimateCaloriesBurned(
        duration: const Duration(hours: 1),
        avgHeartRate: null,
        avgSpeedKmh: 20,
      );

      expect(calories, greaterThan(0));
      expect(calories, lessThan(1500));
    });

    test('fallback with unknown/zero average speed still produces a '
        'positive value (does not silently return 0)', () {
      final calories = estimateCaloriesBurned(
        duration: const Duration(minutes: 30),
        avgHeartRate: null,
      );

      expect(calories, greaterThan(0));
    });
  });

  group('estimateCaloriesBurned edge cases', () {
    test('zero-duration ride returns 0 without a divide-by-zero crash '
        '(heart-rate path)', () {
      final calories = estimateCaloriesBurned(
        duration: Duration.zero,
        avgHeartRate: 140,
      );

      expect(calories, 0);
    });

    test('zero-duration ride returns 0 without a divide-by-zero crash '
        '(fallback path)', () {
      final calories = estimateCaloriesBurned(
        duration: Duration.zero,
        avgHeartRate: null,
        avgSpeedKmh: 20,
      );

      expect(calories, 0);
    });
  });

  group('resolveWeightKg / resolveAgeYears (user profile fallback)', () {
    test('resolveWeightKg passes through a saved profile value', () {
      expect(resolveWeightKg(82.5), 82.5);
    });

    test('resolveWeightKg falls back to the placeholder when no profile '
        'has been saved yet (null)', () {
      expect(resolveWeightKg(null), placeholderWeightKg);
    });

    test('resolveAgeYears passes through a saved profile value', () {
      expect(resolveAgeYears(27), 27);
    });

    test('resolveAgeYears falls back to the placeholder when no profile '
        'has been saved yet (null)', () {
      expect(resolveAgeYears(null), placeholderAgeYears);
    });
  });

  group('resolveGender', () {
    test('passes through a saved profile value', () {
      expect(resolveGender(Gender.female), Gender.female);
    });

    test('falls back to male when no profile has been saved yet (null)', () {
      expect(resolveGender(null), Gender.male);
    });
  });

  group('caloriesPerMinuteFromHeartRate', () {
    test('matches the documented Keytel formula for a male rider', () {
      const hr = 140;
      const weight = 70.0;
      const age = 30;
      final expected =
          (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184;

      final actual = caloriesPerMinuteFromHeartRate(
        heartRateBpm: hr,
        weightKg: weight,
        ageYears: age,
        gender: Gender.male,
      );

      expect(actual, closeTo(expected, 1e-9));
    });

    test('matches the documented Keytel formula for a female rider', () {
      const hr = 140;
      const weight = 60.0;
      const age = 27;
      final expected =
          (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.074 * age) / 4.184;

      final actual = caloriesPerMinuteFromHeartRate(
        heartRateBpm: hr,
        weightKg: weight,
        ageYears: age,
        gender: Gender.female,
      );

      expect(actual, closeTo(expected, 1e-9));
    });

    test('clamps a negative regression result (very low HR) to zero', () {
      final actual = caloriesPerMinuteFromHeartRate(
        heartRateBpm: 40,
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );

      expect(actual, 0);
    });
  });

  group('LiveCalorieAccumulator', () {
    test('totalCalories is 0 before any sample is added', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );

      expect(accumulator.totalCalories, 0);
    });

    test('a single sample contributes nothing yet (no prior anchor to '
        'measure elapsed time from)', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );

      accumulator.addSample(140, timestamp: DateTime(2026, 1, 1, 10, 0, 0));

      expect(accumulator.totalCalories, 0);
    });

    test('accumulates calories over the elapsed time between two samples', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      final start = DateTime(2026, 1, 1, 10, 0, 0);

      accumulator.addSample(140, timestamp: start);
      accumulator.addSample(140, timestamp: start.add(const Duration(minutes: 1)));

      final expectedRate = caloriesPerMinuteFromHeartRate(
        heartRateBpm: 140,
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      expect(accumulator.totalCalories, closeTo(expectedRate, 1e-9));
    });

    test('rejects a reading above the 40-220bpm sensor range and does not '
        'charge that gap once a valid reading resumes', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      final start = DateTime(2026, 1, 1, 10, 0, 0);

      accumulator.addSample(140, timestamp: start);
      // Glitch reading, well above the valid range.
      accumulator.addSample(
        255,
        timestamp: start.add(const Duration(seconds: 30)),
      );
      // A valid reading 1 second after the glitch: only 1s should be
      // charged, not the 31s since the last valid sample.
      accumulator.addSample(
        140,
        timestamp: start.add(const Duration(seconds: 31)),
      );

      final ratePerSecond =
          caloriesPerMinuteFromHeartRate(
            heartRateBpm: 140,
            weightKg: 70,
            ageYears: 30,
            gender: Gender.male,
          ) /
          60;
      expect(accumulator.totalCalories, closeTo(ratePerSecond, 1e-6));
    });

    test('rejects a reading below the 40-220bpm sensor range', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      final start = DateTime(2026, 1, 1, 10, 0, 0);

      accumulator.addSample(140, timestamp: start);
      accumulator.addSample(
        10,
        timestamp: start.add(const Duration(seconds: 10)),
      );

      expect(accumulator.totalCalories, 0);
    });

    test('clamps an elapsed gap longer than 2 minutes (e.g. a BLE '
        'reconnection) instead of charging the full gap', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      final start = DateTime(2026, 1, 1, 10, 0, 0);

      accumulator.addSample(140, timestamp: start);
      // A 10-minute gap, as if the sensor reconnected after a status=147
      // GATT timeout.
      accumulator.addSample(
        140,
        timestamp: start.add(const Duration(minutes: 10)),
      );

      final expectedRate =
          caloriesPerMinuteFromHeartRate(
            heartRateBpm: 140,
            weightKg: 70,
            ageYears: 30,
            gender: Gender.male,
          ) *
          2; // capped at the 2-minute max gap, not the full 10 minutes.
      expect(accumulator.totalCalories, closeTo(expectedRate, 1e-9));
    });

    test('reset() clears the running total and the gap anchor', () {
      final accumulator = LiveCalorieAccumulator(
        weightKg: 70,
        ageYears: 30,
        gender: Gender.male,
      );
      final start = DateTime(2026, 1, 1, 10, 0, 0);
      accumulator.addSample(140, timestamp: start);
      accumulator.addSample(140, timestamp: start.add(const Duration(minutes: 1)));
      expect(accumulator.totalCalories, greaterThan(0));

      accumulator.reset();

      expect(accumulator.totalCalories, 0);
      // After reset, the next sample is treated as a fresh first sample
      // (no elapsed time charged against it).
      accumulator.addSample(140, timestamp: start.add(const Duration(minutes: 5)));
      expect(accumulator.totalCalories, 0);
    });
  });
}
