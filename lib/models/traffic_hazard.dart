/// A rider-marked location that triggers a spoken warning when approached
/// during a ride (e.g. a known dangerous intersection).
///
/// There is no bundled/seeded hazard data — this app has no reliable source
/// of real, verified dangerous locations in Baghdad, and inventing plausible
/// -looking coordinates for a safety feature would be actively misleading.
/// The rider builds this list themselves via the hazard management screen,
/// from their own local knowledge.
class TrafficHazard {
  const TrafficHazard({
    this.id,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 50,
    required this.message,
  });

  final int? id;
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final String message;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'latitude': latitude,
      'longitude': longitude,
      'radius_meters': radiusMeters,
      'message': message,
    };
  }

  factory TrafficHazard.fromMap(Map<String, dynamic> map) {
    return TrafficHazard(
      id: map['id'] as int?,
      latitude: map['latitude'] as double,
      longitude: map['longitude'] as double,
      radiusMeters: map['radius_meters'] as double,
      message: map['message'] as String,
    );
  }
}
