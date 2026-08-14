import '../models/traffic_hazard.dart';
import 'distance_calculator.dart';

/// Which hazards a position at ([latitude], [longitude]) has just entered
/// the radius of, excluding any id already in [alreadyTriggered] — so each
/// hazard is reported only once per call to this "newly entered" check
/// (callers are expected to accumulate returned ids into their own
/// [alreadyTriggered] set across a ride, so a hazard isn't re-announced
/// every GPS update while the rider lingers nearby).
///
/// Pure and synchronous by design: no GPS, database, or TTS access here, so
/// it can be unit tested directly with plain coordinates.
Set<int> newlyTriggeredHazardIds({
  required double latitude,
  required double longitude,
  required List<TrafficHazard> hazards,
  required Set<int> alreadyTriggered,
}) {
  final result = <int>{};
  for (final hazard in hazards) {
    final id = hazard.id;
    if (id == null || alreadyTriggered.contains(id)) continue;

    final distance = DistanceCalculator.haversineDistance(
      latitude,
      longitude,
      hazard.latitude,
      hazard.longitude,
    );
    if (distance <= hazard.radiusMeters) {
      result.add(id);
    }
  }
  return result;
}
