import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide DistanceCalculator;
import 'package:provider/provider.dart';

import '../models/ride_point.dart';
import '../services/map_tile_service.dart';
import '../utils/distance_calculator.dart';
import 'download_map_screen.dart';

/// Baghdad's approximate center, used before any GPS fix is available.
const _defaultCenter = LatLng(33.3128, 44.3615);
const _defaultZoom = 13.0;

/// Zoom range for the navigation camera: closest in when stopped/crawling,
/// pulled back out at riding speed so more of the road ahead is visible -
/// mirrors Waze's dynamic zoom. Both ends stay inside the 10-17 range
/// [BaghdadRegion] pre-caches, so dynamic zoom never asks for tiles that
/// aren't available offline.
const _navigationZoomClose = 17.0;
const _navigationZoomFar = 14.0;
const _navigationZoomFullSpeedKmh = 30.0;

/// Camera pitch applied while actively tracking and following the rider, to
/// approximate Waze's tilted 3D navigation view. flutter_map only renders
/// flat 2D tiles and has no native pitch, so this is faked with a
/// perspective transform around the map widget rather than a real camera
/// angle.
const _navigationPitchRadians = 0.55;
const _navigationPerspective = 0.0012;
const _navigationTiltScale = 1.35;

/// A GPS jump smaller than this is treated as noise for heading purposes:
/// near-stationary jitter between fixes would otherwise make the heading -
/// and so the whole map - spin erratically.
const _minHeadingDistanceMeters = 3.0;

/// Live map for the tracking screen: draws the current ride's route as it is
/// recorded and follows the current position, unless the user has manually
/// panned/zoomed - in which case a "recenter" button reappears instead of
/// fighting their gesture. While live and following, the camera also turns
/// to match the rider's heading, tilts into a 3D perspective, and zooms
/// dynamically with speed, the same way Waze's active-navigation view does.
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
  double _heading = 0;

  @override
  void didUpdateWidget(covariant RideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.isLive && !widget.isLive) {
      // Tracking just stopped: drop back to a flat, north-up view instead of
      // leaving it stuck at whatever heading it last had.
      _heading = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _mapController.rotate(0);
      });
      return;
    }

    if (widget.isLive && _followEnabled && widget.points.isNotEmpty) {
      _updateHeading();
      final last = widget.points.last;
      final zoom = _dynamicZoomFor(last.speed);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _mapController.moveAndRotate(
          LatLng(last.latitude, last.longitude),
          zoom,
          -_heading,
        );
      });
    }
  }

  /// Recomputes [_heading] as the great-circle bearing between the last two
  /// recorded points, skipping the update when the rider has barely moved so
  /// GPS jitter doesn't spin the map while stopped at a light.
  void _updateHeading() {
    final points = widget.points;
    if (points.length < 2) return;

    final previous = points[points.length - 2];
    final last = points.last;
    final movedMeters = DistanceCalculator.haversineDistance(
      previous.latitude,
      previous.longitude,
      last.latitude,
      last.longitude,
    );
    if (movedMeters < _minHeadingDistanceMeters) return;

    _heading = normalizeBearing(
      const Distance().bearing(
        LatLng(previous.latitude, previous.longitude),
        LatLng(last.latitude, last.longitude),
      ),
    );
  }

  double _dynamicZoomFor(double speedMps) {
    final speedKmh = speedMps * 3.6;
    final t = (speedKmh / _navigationZoomFullSpeedKmh).clamp(0.0, 1.0);
    return _navigationZoomClose -
        t * (_navigationZoomClose - _navigationZoomFar);
  }

  void _recenter() {
    setState(() => _followEnabled = true);
    if (widget.points.isNotEmpty) {
      _updateHeading();
      final last = widget.points.last;
      _mapController.moveAndRotate(
        LatLng(last.latitude, last.longitude),
        _dynamicZoomFor(last.speed),
        -_heading,
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
    final tilted = widget.isLive && _followEnabled;

    final map = FlutterMap(
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
    );

    return Stack(
      children: [
        ClipRect(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            transformAlignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, _navigationPerspective)
              ..rotateX(tilted ? _navigationPitchRadians : 0)
              ..scale(tilted ? _navigationTiltScale : 1.0),
            child: map,
          ),
        ),
        if (tileService.hasTileFetchFailures)
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DownloadMapScreen()),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off, color: Colors.white70, size: 20),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'لا يوجد اتصال بالإنترنت ولا خريطة محمّلة مسبقاً - اضغط للتحميل',
                          style: TextStyle(color: Colors.white, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
