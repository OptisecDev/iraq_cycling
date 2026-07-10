import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/utils/distance_calculator.dart';

void main() {
  group('DistanceCalculator.haversineDistance', () {
    test('Baghdad to Basra is approximately 448km within 5% margin', () {
      // Baghdad
      const lat1 = 33.3152;
      const lon1 = 44.3661;
      // Basra
      const lat2 = 30.5085;
      const lon2 = 47.7804;

      final distanceMeters = DistanceCalculator.haversineDistance(
        lat1,
        lon1,
        lat2,
        lon2,
      );
      final distanceKm = distanceMeters / 1000;

      // Great-circle distance for these coordinates is ~448km per
      // independent geo-distance references (not the ~420km road distance).
      const expectedKm = 448;
      const marginKm = expectedKm * 0.05;

      expect(distanceKm, closeTo(expectedKm, marginKm));
    });
  });

  group('DistanceCalculator.isValidGpsJump', () {
    test('accepts a realistic case: 10 meters over 1 second (10 m/s)', () {
      final isValid = DistanceCalculator.isValidGpsJump(
        10,
        const Duration(seconds: 1),
      );
      expect(isValid, isTrue);
    });

    test('rejects an unrealistic case: same distance implying 300 m/s', () {
      final isValid = DistanceCalculator.isValidGpsJump(
        10,
        const Duration(microseconds: 33333), // 10m / 0.0333s ~= 300 m/s
      );
      expect(isValid, isFalse);
    });

    test('rejects a zero Duration to avoid division-by-zero', () {
      final isValid = DistanceCalculator.isValidGpsJump(10, Duration.zero);
      expect(isValid, isFalse);
    });
  });
}
