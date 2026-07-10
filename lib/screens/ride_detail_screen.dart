import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/ride.dart';
import '../services/map_tile_service.dart';
import '../services/ride_repository.dart';
import '../utils/format_utils.dart';
import '../widgets/stat_column.dart';

const _defaultZoom = 13.0;

/// Shows a single past ride: its full recorded route as a static polyline
/// fitted to the route's bounds, plus final ride statistics below.
class RideDetailScreen extends StatelessWidget {
  const RideDetailScreen({super.key, required this.rideId});

  final int rideId;

  @override
  Widget build(BuildContext context) {
    final repository = context.read<RideRepository>();
    final tileService = context.watch<MapTileService>();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('تفاصيل الرحلة'),
      ),
      body: FutureBuilder<Ride?>(
        future: repository.getRideWithPoints(rideId),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          final ride = snapshot.data;
          if (ride == null) {
            return const Center(
              child: Text(
                'تعذر العثور على هذه الرحلة',
                style: TextStyle(color: Colors.white54, fontSize: 16),
              ),
            );
          }

          final latLngPoints = ride.points
              .map((point) => LatLng(point.latitude, point.longitude))
              .toList(growable: false);

          return Column(
            children: [
              Expanded(
                flex: 5,
                child: latLngPoints.isEmpty
                    ? const Center(
                        child: Text(
                          'لا توجد نقاط GPS مسجلة لهذه الرحلة',
                          style: TextStyle(color: Colors.white54),
                        ),
                      )
                    : FlutterMap(
                        options: MapOptions(
                          initialCenter: latLngPoints.first,
                          initialZoom: _defaultZoom,
                          initialCameraFit: latLngPoints.length >= 2
                              ? CameraFit.coordinates(
                                  coordinates: latLngPoints,
                                  padding: const EdgeInsets.all(30),
                                )
                              : null,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: MapTileService.tileUrlTemplate,
                            tileProvider: tileService.tileProvider,
                            userAgentPackageName: 'com.optisec.iraq_cycling',
                          ),
                          if (latLngPoints.length >= 2)
                            PolylineLayer(
                              polylines: [
                                Polyline(
                                  points: latLngPoints,
                                  color: Colors.greenAccent,
                                  strokeWidth: 4,
                                ),
                              ],
                            ),
                        ],
                      ),
              ),
              Expanded(
                flex: 4,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: Wrap(
                      alignment: WrapAlignment.spaceEvenly,
                      runSpacing: 24,
                      spacing: 24,
                      children: [
                        StatColumn(
                          label: 'المسافة (كم)',
                          value: ride.totalDistanceKm.toStringAsFixed(2),
                        ),
                        StatColumn(
                          label: 'الوقت',
                          value: formatDuration(ride.duration),
                        ),
                        StatColumn(
                          label: 'المعدل (كم/س)',
                          value: ride.avgSpeedKmh.toStringAsFixed(1),
                        ),
                        StatColumn(
                          label: 'أقصى سرعة (كم/س)',
                          value: ride.maxSpeedKmh.toStringAsFixed(1),
                        ),
                        StatColumn(
                          label: 'ارتفاع التسلق (م)',
                          value: ride.totalElevationGainMeters.toStringAsFixed(
                            0,
                          ),
                        ),
                        if (ride.avgHeartRate != null)
                          StatColumn(
                            label: 'معدل نبض القلب',
                            value: ride.avgHeartRate!.toStringAsFixed(0),
                          ),
                        if (ride.caloriesBurned != null)
                          StatColumn(
                            label: 'السعرات الحرارية',
                            value: ride.caloriesBurned!.toStringAsFixed(0),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
