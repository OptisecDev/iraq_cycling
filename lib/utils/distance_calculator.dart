import 'dart:math';

class DistanceCalculator {
  static const double _earthRadiusMeters = 6371000;

  /// Great-circle distance between two GPS coordinates in meters,
  /// using the same Haversine formula used by Garmin/Strava.
  static double haversineDistance(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    final dLat = _degreesToRadians(lat2 - lat1);
    final dLon = _degreesToRadians(lon2 - lon1);

    final a =
        sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) *
            cos(_degreesToRadians(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));

    return _earthRadiusMeters * c;
  }

  /// Rejects GPS noise: a jump is invalid if it implies unrealistic speed
  /// for a bicycle, or if the time delta is zero (division-by-zero guard).
  static bool isValidGpsJump(
    double distanceMeters,
    Duration timeDelta, {
    double maxRealisticSpeedMps = 25,
  }) {
    if (timeDelta.inMicroseconds <= 0) return false;
    final impliedSpeedMps =
        distanceMeters / (timeDelta.inMicroseconds / 1000000);
    return impliedSpeedMps <= maxRealisticSpeedMps;
  }

  static double _degreesToRadians(double degrees) => degrees * pi / 180;
}
