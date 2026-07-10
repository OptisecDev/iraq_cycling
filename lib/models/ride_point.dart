class RidePoint {
  final double latitude;
  final double longitude;
  final double altitude;
  final double speed;
  final DateTime timestamp;
  final double? accuracy;

  RidePoint({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.speed,
    required this.timestamp,
    this.accuracy,
  });

  Map<String, dynamic> toMap() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      'altitude': altitude,
      'speed': speed,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'accuracy': accuracy,
    };
  }

  factory RidePoint.fromMap(Map<String, dynamic> map) {
    return RidePoint(
      latitude: map['latitude'] as double,
      longitude: map['longitude'] as double,
      altitude: map['altitude'] as double,
      speed: map['speed'] as double,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      accuracy: map['accuracy'] as double?,
    );
  }
}
