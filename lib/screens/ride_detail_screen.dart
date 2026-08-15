import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:provider/provider.dart';

import '../models/ride.dart';
import '../services/map_tile_service.dart';
import '../services/ride_repository.dart';
import '../utils/format_utils.dart';
import '../widgets/stat_column.dart';

const _defaultZoom = 13.0;
const _boundsFitPadding = 30.0;

ml.LatLng _toMl(LatLng point) => ml.LatLng(point.latitude, point.longitude);

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
                    : _RideRouteMap(
                        tileService: tileService,
                        points: latLngPoints,
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

/// The static route map itself, split out so it can own the
/// [ml.MapLibreMapController] lifecycle (bounds-fit camera + the one-time
/// recorded-route line, added once the style has loaded).
class _RideRouteMap extends StatefulWidget {
  const _RideRouteMap({required this.tileService, required this.points});

  final MapTileService tileService;
  final List<LatLng> points;

  @override
  State<_RideRouteMap> createState() => _RideRouteMapState();
}

class _RideRouteMapState extends State<_RideRouteMap> {
  ml.MapLibreMapController? _controller;

  void _onMapCreated(ml.MapLibreMapController controller) {
    _controller = controller;
  }

  Future<void> _onStyleLoaded() async {
    final controller = _controller;
    if (controller == null) return;

    if (widget.points.length >= 2) {
      await controller.addLine(
        ml.LineOptions(
          geometry: widget.points.map(_toMl).toList(),
          lineColor: Colors.greenAccent.toHexStringRGB(),
          lineWidth: 4,
        ),
      );
      if (!mounted) return;

      var minLat = widget.points.first.latitude;
      var maxLat = widget.points.first.latitude;
      var minLon = widget.points.first.longitude;
      var maxLon = widget.points.first.longitude;
      for (final point in widget.points) {
        minLat = point.latitude < minLat ? point.latitude : minLat;
        maxLat = point.latitude > maxLat ? point.latitude : maxLat;
        minLon = point.longitude < minLon ? point.longitude : minLon;
        maxLon = point.longitude > maxLon ? point.longitude : maxLon;
      }
      await controller.animateCamera(
        ml.CameraUpdate.newLatLngBounds(
          ml.LatLngBounds(
            southwest: ml.LatLng(minLat, minLon),
            northeast: ml.LatLng(maxLat, maxLon),
          ),
          left: _boundsFitPadding,
          top: _boundsFitPadding,
          right: _boundsFitPadding,
          bottom: _boundsFitPadding,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ml.MapLibreMap(
      styleString: widget.tileService.styleUrl,
      initialCameraPosition: ml.CameraPosition(
        target: _toMl(widget.points.first),
        zoom: _defaultZoom,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
    );
  }
}
