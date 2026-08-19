import 'ride_point.dart';

class Ride {
  final int? id;
  final DateTime startTime;
  final DateTime? endTime;
  final List<RidePoint> points;
  final double totalDistanceMeters;
  final double maxSpeedMps;
  final double totalElevationGainMeters;
  final double? avgHeartRate;
  final double? maxHeartRate;
  final double? caloriesBurned;

  Ride({
    this.id,
    required this.startTime,
    this.endTime,
    this.points = const [],
    this.totalDistanceMeters = 0,
    this.maxSpeedMps = 0,
    this.totalElevationGainMeters = 0,
    this.avgHeartRate,
    this.maxHeartRate,
    this.caloriesBurned,
  });

  Duration get duration {
    final end = endTime ?? DateTime.now();
    return end.difference(startTime);
  }

  double get avgSpeedKmh {
    final seconds = duration.inSeconds;
    if (seconds == 0) return 0;
    return (totalDistanceMeters / seconds) * 3.6;
  }

  double get maxSpeedKmh => maxSpeedMps * 3.6;

  double get totalDistanceKm => totalDistanceMeters / 1000;

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'start_time': startTime.millisecondsSinceEpoch,
      'end_time': endTime?.millisecondsSinceEpoch,
      'total_distance_meters': totalDistanceMeters,
      'max_speed_mps': maxSpeedMps,
      'total_elevation_gain_meters': totalElevationGainMeters,
      'avg_heart_rate': avgHeartRate,
      'max_heart_rate': maxHeartRate,
      'calories_burned': caloriesBurned,
    };
  }

  factory Ride.fromMap(
    Map<String, dynamic> map, {
    List<RidePoint> points = const [],
  }) {
    return Ride(
      id: map['id'] as int?,
      startTime: DateTime.fromMillisecondsSinceEpoch(map['start_time'] as int),
      endTime: map['end_time'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['end_time'] as int)
          : null,
      points: points,
      totalDistanceMeters: map['total_distance_meters'] as double,
      maxSpeedMps: map['max_speed_mps'] as double,
      totalElevationGainMeters: map['total_elevation_gain_meters'] as double,
      avgHeartRate: map['avg_heart_rate'] as double?,
      maxHeartRate: map['max_heart_rate'] as double?,
      caloriesBurned: map['calories_burned'] as double?,
    );
  }

  Ride copyWith({
    int? id,
    DateTime? startTime,
    DateTime? endTime,
    List<RidePoint>? points,
    double? totalDistanceMeters,
    double? maxSpeedMps,
    double? totalElevationGainMeters,
    double? avgHeartRate,
    double? maxHeartRate,
    double? caloriesBurned,
  }) {
    return Ride(
      id: id ?? this.id,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      points: points ?? this.points,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      maxSpeedMps: maxSpeedMps ?? this.maxSpeedMps,
      totalElevationGainMeters:
          totalElevationGainMeters ?? this.totalElevationGainMeters,
      avgHeartRate: avgHeartRate ?? this.avgHeartRate,
      maxHeartRate: maxHeartRate ?? this.maxHeartRate,
      caloriesBurned: caloriesBurned ?? this.caloriesBurned,
    );
  }
}
