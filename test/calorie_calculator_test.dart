import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/utils/calorie_calculator.dart';

void main() {
  group('estimateCaloriesBurned with heart rate data', () {
    test(
      'a realistic 1-hour ride at 140bpm produces a positive, plausible '
      'calorie value (not negative, not absurd for a short-ish ride)',
      () {
        final calories = estimateCaloriesBurned(
          duration: const Duration(hours: 1),
          avgHeartRate: 140,
        );

        expect(calories, greaterThan(0));
        // A moderately intense hour of cycling should plausibly be in the
        // low hundreds to under a thousand kcal for a 70kg/30yo rider, not
        // e.g. tens of thousands.
        expect(calories, lessThan(1500));
      },
    );

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
    test(
      'a ride with no heart rate data still produces a plausible positive '
      'value using the MET/speed fallback',
      () {
        final calories = estimateCaloriesBurned(
          duration: const Duration(hours: 1),
          avgHeartRate: null,
          avgSpeedKmh: 20,
        );

        expect(calories, greaterThan(0));
        expect(calories, lessThan(1500));
      },
    );

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
}
