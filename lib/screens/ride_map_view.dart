import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../models/ride_point.dart';
import '../services/map_tile_service.dart';

/// Baghdad's approximate center, used before any GPS fix is available.
const _defaultCenter = LatLng(33.3128, 44.3615);
const _defaultZoom = 13.0;

/// Live map for the tracking screen: draws the current ride's route as it is
/// recorded and follows the current position, unless the user has manually
/// panned/zoomed - in which case a "recenter" button reappears instead of
/// fighting their gesture.
class RideMapView extends StatefulWidget {
  const RideMapView({super.key, required this.points, required this.isLive});

  final List<RidePoint> points;
  final bool isLive;

  @override
  State<RideMapView> createState() => _RideMapViewState();
}

class _RideMapViewState extends State<RideMapView> {
  final MapController _mapController = MapController();
  bool _followEnabled = true;

  @override
  void didUpdateWidget(covariant RideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLive && _followEnabled && widget.points.isNotEmpty) {
      final last = widget.points.last;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.move(
          LatLng(last.latitude, last.longitude),
          _mapController.camera.zoom,
        );
      });
    }
  }

  void _recenter() {
    setState(() => _followEnabled = true);
    if (widget.points.isNotEmpty) {
      final last = widget.points.last;
      _mapController.move(
        LatLng(last.latitude, last.longitude),
        _mapController.camera.zoom,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tileService = context.watch<MapTileService>();
    final latLngPoints = widget.points
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);
    final current = latLngPoints.isNotEmpty ? latLngPoints.last : null;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: current ?? _defaultCenter,
            initialZoom: _defaultZoom,
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && _followEnabled) {
                setState(() => _followEnabled = false);
              }
            },
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
            if (current != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: current,
                    width: 22,
                    height: 22,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blueAccent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (widget.isLive && !_followEnabled)
          Positioned(
            right: 12,
            bottom: 12,
            child: FloatingActionButton.small(
              heroTag: 'recenter',
              onPressed: _recenter,
              child: const Icon(Icons.my_location),
            ),
          ),
      ],
    );
  }
}
