import 'package:flutter_test/flutter_test.dart';
import 'package:iraq_cycling/models/traffic_hazard.dart';
import 'package:iraq_cycling/utils/hazard_proximity.dart';

void main() {
  // A hazard right at the origin with a 50m radius, for all tests below.
  const hazard = TrafficHazard(
    id: 1,
    latitude: 33.3,
    longitude: 44.4,
    radiusMeters: 50,
    message: 'تقاطع خطر',
  );

  test('reports a hazard when the position is exactly on it', () {
    final triggered = newlyTriggeredHazardIds(
      latitude: hazard.latitude,
      longitude: hazard.longitude,
      hazards: [hazard],
      alreadyTriggered: {},
    );

    expect(triggered, {1});
  });

  test('does not report a hazard far outside its radius', () {
    final triggered = newlyTriggeredHazardIds(
      // Roughly 1km north - well outside a 50m radius.
      latitude: hazard.latitude + 0.01,
      longitude: hazard.longitude,
      hazards: [hazard],
      alreadyTriggered: {},
    );

    expect(triggered, isEmpty);
  });

  test('does not re-report a hazard already in alreadyTriggered', () {
    final triggered = newlyTriggeredHazardIds(
      latitude: hazard.latitude,
      longitude: hazard.longitude,
      hazards: [hazard],
      alreadyTriggered: {1},
    );

    expect(triggered, isEmpty);
  });

  test('skips hazards with no assigned id (never saved)', () {
    const unsavedHazard = TrafficHazard(
      latitude: 33.3,
      longitude: 44.4,
      message: 'not yet saved',
    );

    final triggered = newlyTriggeredHazardIds(
      latitude: 33.3,
      longitude: 44.4,
      hazards: [unsavedHazard],
      alreadyTriggered: {},
    );

    expect(triggered, isEmpty);
  });

  test('evaluates multiple hazards independently', () {
    const nearby = TrafficHazard(
      id: 2,
      latitude: 33.3,
      longitude: 44.4,
      radiusMeters: 50,
      message: 'قريب',
    );
    const faraway = TrafficHazard(
      id: 3,
      latitude: 34.0,
      longitude: 45.0,
      radiusMeters: 50,
      message: 'بعيد',
    );

    final triggered = newlyTriggeredHazardIds(
      latitude: 33.3,
      longitude: 44.4,
      hazards: [nearby, faraway],
      alreadyTriggered: {},
    );

    expect(triggered, {2});
  });
}
