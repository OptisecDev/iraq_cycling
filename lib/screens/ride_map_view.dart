import 'dart:async';
import 'dart:math' show Point;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' hide DistanceCalculator;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:provider/provider.dart';

import '../models/ride_point.dart';
import '../services/location_service.dart';
import '../services/map_tile_service.dart';
import '../services/place_search_service.dart';
import '../services/route_finder.dart';
import '../utils/distance_calculator.dart';
import '../utils/format_utils.dart';
import 'download_map_screen.dart';

/// Debounce delay between the user typing in the destination search box and
/// actually querying [PlaceSearchService] - avoids a query per keystroke.
const _searchDebounceDelay = Duration(milliseconds: 250);

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
/// approximate Waze's tilted 3D navigation view - a real camera tilt (in
/// degrees from nadir, maplibre_gl's [ml.CameraPosition.tilt] unit) rather
/// than the perspective-transform-on-a-flat-widget hack the previous
/// flutter_map-based renderer needed, since maplibre_gl's native camera
/// actually supports pitch.
const _navigationTiltDegrees = 45.0;

/// A GPS jump smaller than this is treated as noise for heading purposes:
/// near-stationary jitter between fixes would otherwise make the heading -
/// and so the whole map - spin erratically.
const _minHeadingDistanceMeters = 3.0;

/// Recomputes the great-circle bearing between two recorded points, or null
/// if the rider has barely moved (GPS jitter would otherwise spin the map
/// while stopped at a light). Pure and top-level so it's directly
/// unit-testable without touching the map widget - see
/// `test/ride_map_view_test.dart`.
double? headingBetween(RidePoint previous, RidePoint last) {
  final movedMeters = DistanceCalculator.haversineDistance(
    previous.latitude,
    previous.longitude,
    last.latitude,
    last.longitude,
  );
  if (movedMeters < _minHeadingDistanceMeters) return null;

  return normalizeBearing(
    const Distance().bearing(
      LatLng(previous.latitude, previous.longitude),
      LatLng(last.latitude, last.longitude),
    ),
  );
}

/// Zoom level for the navigation camera at [speedMps]: closest in
/// ([_navigationZoomClose]) when stopped, pulled back to
/// [_navigationZoomFar] by [_navigationZoomFullSpeedKmh]. Pure and
/// top-level for the same reason as [headingBetween].
double dynamicZoomFor(double speedMps) {
  final speedKmh = speedMps * 3.6;
  final t = (speedKmh / _navigationZoomFullSpeedKmh).clamp(0.0, 1.0);
  return _navigationZoomClose - t * (_navigationZoomClose - _navigationZoomFar);
}

ml.LatLng _toMl(LatLng point) => ml.LatLng(point.latitude, point.longitude);

/// Live map for the tracking screen: draws the current ride's route as it is
/// recorded and follows the current position, unless the user has manually
/// panned/zoomed - in which case a "recenter" button reappears instead of
/// fighting their gesture. While live and following, the camera also turns
/// to match the rider's heading, tilts into a 3D perspective, and zooms
/// dynamically with speed, the same way Waze's active-navigation view does.
///
/// A visible "plan route" button arms destination-picking mode, which shows
/// a search box (backed by [PlaceSearchService], an offline name index over
/// Baghdad's streets/squares) alongside the option to just tap the map
/// directly. Either way of picking a destination plans a [RouteFinder]
/// route from the current position (the live ride position if one is being
/// recorded, otherwise a one-shot GPS fix), drawn as a distinctly-colored
/// polyline separate from the ride's own recorded-route polyline above. This
/// is route *planning* only - it never affects ride recording.
class RideMapView extends StatefulWidget {
  const RideMapView({
    super.key,
    required this.points,
    required this.isLive,
    this.heartRateBpm,
    this.heartRateConnected = false,
    this.liveCalories = 0,
    this.instantSpeedKmh = 0,
    this.distanceKm = 0,
    this.avgSpeedKmh = 0,
    this.elevationGainMeters = 0,
    this.duration = Duration.zero,
  });

  final List<RidePoint> points;
  final bool isLive;

  /// Most recent BPM reading from [HeartRateService.latestBpm], or null if
  /// none has arrived yet. Purely a passthrough for the floating HUD below —
  /// this widget doesn't touch the BLE stream itself.
  final int? heartRateBpm;
  final bool heartRateConnected;

  /// Running calorie total for the in-progress ride, from
  /// [RideTracker.liveCalories].
  final double liveCalories;

  /// Instantaneous speed, running distance, average speed, elevation gain,
  /// and elapsed time for the in-progress (or not-yet-started) ride - all
  /// passthroughs for the floating stat HUD below, same as the heart-rate/
  /// calorie fields above.
  final double instantSpeedKmh;
  final double distanceKm;
  final double avgSpeedKmh;
  final double elevationGainMeters;
  final Duration duration;

  @override
  State<RideMapView> createState() => _RideMapViewState();
}

class _RideMapViewState extends State<RideMapView> {
  ml.MapLibreMapController? _controller;
  bool _styleLoaded = false;

  // Guards against onCameraIdle misreading our own animateCamera calls (or
  // the very first idle event after map creation) as a user gesture - see
  // _onCameraIdle.
  bool _isProgrammaticCameraMove = false;
  bool _receivedInitialIdle = false;

  bool _syncingAnnotations = false;
  ml.Line? _rideLine;
  ml.Line? _plannedRouteLine;
  ml.Circle? _currentPositionCircle;
  ml.Circle? _destinationCircle;

  final LocationService _locationService = LocationService();
  bool _followEnabled = true;
  double _heading = 0;

  // Route-planning state, independent of the ride's own recorded route
  // above. Triggered by the "plan route" button, not a hidden gesture: the
  // button arms [_pickingDestination], and the *next* tap on the map (while
  // armed) supplies the destination.
  bool _pickingDestination = false;
  LatLng? _destination;
  RouteResult? _plannedRoute;
  bool _isRouting = false;
  String? _routeError;

  // Destination search, shown alongside the map-tap option while
  // [_pickingDestination] is armed.
  final TextEditingController _searchController = TextEditingController();
  List<PlaceSearchResult> _searchResults = const [];
  Timer? _searchDebounce;

  /// Starts (or restarts) a route search to [destination] from the best
  /// available current position - the ride's live position if one is being
  /// recorded, otherwise a one-shot GPS fix.
  Future<void> _planRouteTo(LatLng destination) async {
    setState(() {
      _pickingDestination = false;
      _destination = destination;
      _plannedRoute = null;
      _routeError = null;
      _isRouting = true;
    });

    final start = await _resolveStartPoint();
    if (!mounted) return;
    if (start == null) {
      setState(() {
        _isRouting = false;
        _routeError = 'تعذر تحديد موقعك الحالي';
      });
      return;
    }

    final routeFinder = context.read<RouteFinder>();
    RouteResult? result;
    String? error;
    try {
      result = await routeFinder.findRoute(
        startLatitude: start.latitude,
        startLongitude: start.longitude,
        endLatitude: destination.latitude,
        endLongitude: destination.longitude,
      );
      if (result == null) error = 'لا يوجد مسار متاح لهذه الوجهة';
    } catch (_) {
      error = 'تعذر حساب المسار';
    }

    if (!mounted) return;
    setState(() {
      _isRouting = false;
      _plannedRoute = result;
      _routeError = error;
    });
  }

  Future<LatLng?> _resolveStartPoint() async {
    if (widget.points.isNotEmpty) {
      final last = widget.points.last;
      return LatLng(last.latitude, last.longitude);
    }
    try {
      if (!await _locationService.ensurePermissionsGranted()) return null;
      final position = await _locationService.getCurrentPosition();
      return LatLng(position.latitude, position.longitude);
    } catch (_) {
      return null;
    }
  }

  void _clearRoute() {
    setState(() {
      _destination = null;
      _plannedRoute = null;
      _routeError = null;
      _isRouting = false;
    });
  }

  void _togglePickingDestination() {
    setState(() {
      _pickingDestination = !_pickingDestination;
      _searchController.clear();
      _searchResults = const [];
    });
  }

  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = const []);
      return;
    }
    _searchDebounce = Timer(_searchDebounceDelay, () async {
      final results = await context.read<PlaceSearchService>().search(query);
      if (!mounted) return;
      setState(() => _searchResults = results);
    });
  }

  void _selectSearchResult(PlaceSearchResult result) {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() => _searchResults = const []);
    _planRouteTo(result.point);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RideMapView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.isLive && !widget.isLive) {
      // Tracking just stopped: drop back to a flat, north-up view instead of
      // leaving it stuck at whatever heading/tilt it last had.
      _heading = 0;
      _driveCameraOrientation(bearing: 0, tilt: 0);
      _syncAnnotations();
      return;
    }

    if (widget.isLive && _followEnabled && widget.points.isNotEmpty) {
      _updateHeading();
      final last = widget.points.last;
      _driveCamera(
        target: LatLng(last.latitude, last.longitude),
        zoom: dynamicZoomFor(last.speed),
        bearing: _heading,
        tilt: _navigationTiltDegrees,
      );
    }
    _syncAnnotations();
  }

  void _updateHeading() {
    final points = widget.points;
    if (points.length < 2) return;
    final heading = headingBetween(points[points.length - 2], points.last);
    if (heading != null) _heading = heading;
  }

  /// Issues an atomic camera move: maplibre_gl's `bearing` is the camera's
  /// own compass direction (clockwise from north), so setting it directly to
  /// the rider's heading already produces "heading-up" navigation - unlike
  /// flutter_map's raw map-rotation angle, which needed negating
  /// (`-heading`) to get the same visual effect.
  void _driveCamera({
    required LatLng target,
    required double zoom,
    required double bearing,
    required double tilt,
  }) {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    _isProgrammaticCameraMove = true;
    controller.animateCamera(
      ml.CameraUpdate.newCameraPosition(
        ml.CameraPosition(
          target: _toMl(target),
          zoom: zoom,
          bearing: bearing,
          tilt: tilt,
        ),
      ),
    );
  }

  /// Adjusts only bearing/tilt (e.g. the flat/north-up reset when tracking
  /// stops), leaving the current target/zoom alone.
  void _driveCameraOrientation({required double bearing, required double tilt}) {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    _isProgrammaticCameraMove = true;
    unawaited(controller.animateCamera(ml.CameraUpdate.bearingTo(bearing)));
    unawaited(controller.animateCamera(ml.CameraUpdate.tiltTo(tilt)));
  }

  void _onCameraIdle() {
    if (_isProgrammaticCameraMove) {
      _isProgrammaticCameraMove = false;
      return;
    }
    if (!_receivedInitialIdle) {
      // The map's own initial-placement settle, not a user gesture.
      _receivedInitialIdle = true;
      return;
    }
    if (widget.isLive && _followEnabled) {
      setState(() => _followEnabled = false);
    }
  }

  void _recenter() {
    setState(() => _followEnabled = true);
    if (widget.points.isNotEmpty) {
      _updateHeading();
      final last = widget.points.last;
      _driveCamera(
        target: LatLng(last.latitude, last.longitude),
        zoom: dynamicZoomFor(last.speed),
        bearing: _heading,
        tilt: _navigationTiltDegrees,
      );
    }
  }

  void _onMapCreated(ml.MapLibreMapController controller) {
    _controller = controller;
  }

  void _onStyleLoaded() {
    _styleLoaded = true;
    _syncAnnotations();
  }

  void _onMapClick(Point<double> point, ml.LatLng coordinates) {
    if (_pickingDestination) {
      _planRouteTo(LatLng(coordinates.latitude, coordinates.longitude));
    }
  }

  /// Keeps the map's line/circle annotations (the ride's own recorded
  /// route, the planned-route preview, the current-position dot, and the
  /// destination pin) in sync with State - maplibre_gl manages these
  /// imperatively via the controller rather than as declarative widgets, so
  /// this replaces what used to be `PolylineLayer`/`MarkerLayer` children of
  /// `FlutterMap`. Safe to call repeatedly (guarded against overlapping
  /// concurrent runs); a stale call is simply superseded by the next one,
  /// which live tracking triggers frequently anyway.
  Future<void> _syncAnnotations() async {
    if (_syncingAnnotations) return;
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    _syncingAnnotations = true;
    try {
      final latLngPoints = widget.points
          .map((point) => LatLng(point.latitude, point.longitude))
          .toList(growable: false);

      await _syncLine(
        controller,
        current: _rideLine,
        set: (line) => _rideLine = line,
        points: latLngPoints.length >= 2 ? latLngPoints : null,
        color: Colors.greenAccent,
      );

      await _syncLine(
        controller,
        current: _plannedRouteLine,
        set: (line) => _plannedRouteLine = line,
        points: (_plannedRoute != null && _plannedRoute!.points.length >= 2)
            ? _plannedRoute!.points
            : null,
        color: Colors.lightBlueAccent,
      );
      if (!mounted) return;

      final current = latLngPoints.isNotEmpty ? latLngPoints.last : null;
      await _syncCircle(
        controller,
        current: _currentPositionCircle,
        set: (circle) => _currentPositionCircle = circle,
        point: current,
        radius: 7,
        color: Colors.blueAccent,
      );
      if (!mounted) return;

      await _syncCircle(
        controller,
        current: _destinationCircle,
        set: (circle) => _destinationCircle = circle,
        point: _destination,
        radius: 9,
        color: Colors.redAccent,
      );
    } finally {
      _syncingAnnotations = false;
    }
  }

  Future<void> _syncLine(
    ml.MapLibreMapController controller, {
    required ml.Line? current,
    required void Function(ml.Line?) set,
    required List<LatLng>? points,
    required Color color,
  }) async {
    if (points == null) {
      if (current != null) {
        await controller.removeLine(current);
        set(null);
      }
      return;
    }
    if (current == null) {
      final line = await controller.addLine(
        ml.LineOptions(
          geometry: points.map(_toMl).toList(),
          lineColor: color.toHexStringRGB(),
          lineWidth: 4,
        ),
      );
      set(line);
    } else {
      await controller.updateLine(
        current,
        ml.LineOptions(geometry: points.map(_toMl).toList()),
      );
    }
  }

  Future<void> _syncCircle(
    ml.MapLibreMapController controller, {
    required ml.Circle? current,
    required void Function(ml.Circle?) set,
    required LatLng? point,
    required double radius,
    required Color color,
  }) async {
    if (point == null) {
      if (current != null) {
        await controller.removeCircle(current);
        set(null);
      }
      return;
    }
    if (current == null) {
      final circle = await controller.addCircle(
        ml.CircleOptions(
          geometry: _toMl(point),
          circleRadius: radius,
          circleColor: color.toHexStringRGB(),
          circleStrokeColor: '#ffffff',
          circleStrokeWidth: 2,
        ),
      );
      set(circle);
    } else {
      await controller.updateCircle(
        current,
        ml.CircleOptions(geometry: _toMl(point)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tileService = context.watch<MapTileService>();
    final current = widget.points.isNotEmpty
        ? LatLng(widget.points.last.latitude, widget.points.last.longitude)
        : null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncAnnotations();
    });

    final map = ml.MapLibreMap(
      styleString: tileService.styleUrl,
      initialCameraPosition: ml.CameraPosition(
        target: _toMl(current ?? _defaultCenter),
        zoom: _defaultZoom,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedCallback: _onStyleLoaded,
      onCameraIdle: _onCameraIdle,
      onMapClick: _onMapClick,
    );

    return Stack(
      children: [
        map,
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
        if (_pickingDestination)
          Positioned(
            top: tileService.hasTileFetchFailures ? 56 : 8,
            left: 12,
            right: 12,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.search,
                          color: Colors.amberAccent,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: _searchController,
                            onChanged: _onSearchChanged,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText:
                                  'ابحث عن شارع أو ساحة، أو اضغط على الخريطة',
                              hintStyle: TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_searchResults.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: _searchResults.length,
                        itemBuilder: (context, index) {
                          final result = _searchResults[index];
                          return ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.place,
                              color: Colors.white54,
                              size: 18,
                            ),
                            title: Text(
                              result.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                            onTap: () => _selectSearchResult(result),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_destination != null)
          Positioned(
            top: tileService.hasTileFetchFailures ? 56 : 8,
            left: 12,
            right: 12,
            child: Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.alt_route,
                      color: Colors.lightBlueAccent,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _isRouting
                            ? 'جارٍ حساب المسار...'
                            : _routeError ??
                                  'المسافة: ${(_plannedRoute!.distanceMeters / 1000).toStringAsFixed(2)} كم',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white70,
                        size: 18,
                      ),
                      tooltip: 'إلغاء المسار',
                      onPressed: _clearRoute,
                    ),
                  ],
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
        // Stacked above the recenter FAB (when both are visible) rather
        // than sharing its slot.
        if (_destination == null)
          Positioned(
            right: 12,
            bottom: (widget.isLive && !_followEnabled) ? 68 : 12,
            child: FloatingActionButton.small(
              heroTag: 'planRoute',
              backgroundColor: _pickingDestination
                  ? Colors.redAccent
                  : null,
              tooltip: _pickingDestination
                  ? 'إلغاء تحديد الوجهة'
                  : 'خطط مساراً',
              onPressed: _togglePickingDestination,
              child: Icon(
                _pickingDestination ? Icons.close : Icons.alt_route,
              ),
            ),
          ),
        // Bottom-left: clear of the top tile-failure banner and the
        // bottom-right recenter FAB above.
        if (widget.isLive)
          Positioned(
            left: 12,
            bottom: 12,
            child: _LiveVitalsHud(
              heartRateBpm: widget.heartRateBpm,
              heartRateConnected: widget.heartRateConnected,
              liveCalories: widget.liveCalories,
            ),
          ),
        // Stacked above the vitals HUD (when both are visible) rather than
        // sharing its slot - anchored bottom-left like the HUD below it, so
        // neither ever competes for space with the bottom-right FABs.
        Positioned(
          left: 12,
          bottom: widget.isLive ? 76 : 12,
          child: _SpeedDistanceCard(
            instantSpeedKmh: widget.instantSpeedKmh,
            distanceKm: widget.distanceKm,
            avgSpeedKmh: widget.avgSpeedKmh,
            elevationGainMeters: widget.elevationGainMeters,
            duration: widget.duration,
          ),
        ),
      ],
    );
  }
}

/// Frosted-glass backdrop shared by the floating map HUDs below - a blurred,
/// translucent, hairline-bordered panel instead of a flat solid fill, so the
/// overlays read as slim premium chips floating over the map rather than
/// opaque cards sitting on top of it.
class _GlassPanel extends StatelessWidget {
  const _GlassPanel({required this.borderRadius, required this.child});

  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: borderRadius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A hairline vertical separator between adjacent stats in the floating map
/// HUDs, standing in for the wider [SizedBox] gaps [StatColumn] normally
/// relies on to read as a group elsewhere in the app.
class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 18,
      color: Colors.white.withValues(alpha: 0.16),
    );
  }
}

/// Compact labelled stat value for the floating map HUDs only - visually
/// like [StatColumn] (value over label), but at the much smaller scale a
/// slim glass overlay calls for. [StatColumn] itself stays untouched since
/// it's also shared by the past-ride detail and profile screens, where the
/// larger, non-overlay presentation is still correct.
class _CompactStat extends StatelessWidget {
  const _CompactStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          label,
          style: TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.62),
            letterSpacing: 0.2,
            height: 1.1,
          ),
        ),
      ],
    );
  }
}

/// Floating speed/distance HUD over the map, collapsed by default to just
/// instantaneous speed and running distance - tap it to expand and reveal
/// elapsed time, average speed, and elevation gain, mirroring the
/// collapsible live-tracking stat overlays in Strava/Garmin. Shown
/// regardless of [RideMapView.isLive] (unlike [_LiveVitalsHud] below) since
/// these values are meaningful in the idle state too - the stats panel this
/// replaces always displayed them, zeroed out before a ride starts.
class _SpeedDistanceCard extends StatefulWidget {
  const _SpeedDistanceCard({
    required this.instantSpeedKmh,
    required this.distanceKm,
    required this.avgSpeedKmh,
    required this.elevationGainMeters,
    required this.duration,
  });

  final double instantSpeedKmh;
  final double distanceKm;
  final double avgSpeedKmh;
  final double elevationGainMeters;
  final Duration duration;

  @override
  State<_SpeedDistanceCard> createState() => _SpeedDistanceCardState();
}

class _SpeedDistanceCardState extends State<_SpeedDistanceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(11);
    return _GlassPanel(
      borderRadius: borderRadius,
      child: InkWell(
        borderRadius: borderRadius,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CompactStat(
                    label: 'كم/س',
                    value: widget.instantSpeedKmh.toStringAsFixed(1),
                  ),
                  const SizedBox(width: 8),
                  const _StatDivider(),
                  const SizedBox(width: 8),
                  _CompactStat(
                    label: 'المسافة (كم)',
                    value: widget.distanceKm.toStringAsFixed(2),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white54,
                    size: 14,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 5),
                Container(
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
                const SizedBox(height: 5),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _CompactStat(
                      label: 'الوقت',
                      value: formatDuration(widget.duration),
                    ),
                    const SizedBox(width: 8),
                    const _StatDivider(),
                    const SizedBox(width: 8),
                    _CompactStat(
                      label: 'المعدل (كم/س)',
                      value: widget.avgSpeedKmh.toStringAsFixed(1),
                    ),
                    const SizedBox(width: 8),
                    const _StatDivider(),
                    const SizedBox(width: 8),
                    _CompactStat(
                      label: 'الارتفاع (م)',
                      value: widget.elevationGainMeters.toStringAsFixed(0),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Floating HUD over the live map showing the current BPM (with a heart icon
/// that pulses in time with it) and the accumulated calorie total for the
/// in-progress ride. Uses [_CompactStat], the same compact value/label
/// widget the speed readout below the map uses, so the two floating HUDs
/// match each other's styling.
class _LiveVitalsHud extends StatelessWidget {
  const _LiveVitalsHud({
    required this.heartRateBpm,
    required this.heartRateConnected,
    required this.liveCalories,
  });

  final int? heartRateBpm;
  final bool heartRateConnected;
  final double liveCalories;

  @override
  Widget build(BuildContext context) {
    final bpmText = heartRateConnected
        ? (heartRateBpm?.toString() ?? '--')
        : '--';

    return _GlassPanel(
      borderRadius: BorderRadius.circular(11),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulsingHeart(bpm: heartRateConnected ? heartRateBpm : null),
            const SizedBox(width: 4),
            _CompactStat(label: 'نبض القلب', value: bpmText),
            const SizedBox(width: 8),
            const _StatDivider(),
            const SizedBox(width: 8),
            const Icon(
              Icons.local_fire_department,
              color: Colors.orangeAccent,
              size: 14,
            ),
            const SizedBox(width: 3),
            _CompactStat(
              label: 'سعرات حرارية',
              value: liveCalories.toStringAsFixed(0),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small heart icon that beats in time with the live BPM reading (or a
/// slow idle pulse when no heart rate sensor is connected yet), so the
/// floating HUD visibly reflects that the reading is live rather than a
/// static snapshot.
class _PulsingHeart extends StatefulWidget {
  const _PulsingHeart({required this.bpm});

  final int? bpm;

  @override
  State<_PulsingHeart> createState() => _PulsingHeartState();
}

class _PulsingHeartState extends State<_PulsingHeart>
    with SingleTickerProviderStateMixin {
  static const _idleBeatDuration = Duration(milliseconds: 1200);
  // Clamps against implausible BPM readings (sensor glitches) turning into
  // an unusably fast or slow animation.
  static const _minBeatDuration = Duration(milliseconds: 300);
  static const _maxBeatDuration = Duration(milliseconds: 1500);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _beatDurationFor(widget.bpm),
  )..repeat(reverse: true);

  Duration _beatDurationFor(int? bpm) {
    if (bpm == null || bpm <= 0) return _idleBeatDuration;
    final beatMs = (60000 / bpm).round();
    return Duration(
      milliseconds: beatMs.clamp(
        _minBeatDuration.inMilliseconds,
        _maxBeatDuration.inMilliseconds,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _PulsingHeart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bpm != widget.bpm) {
      _controller.duration = _beatDurationFor(widget.bpm);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(
        begin: 0.85,
        end: 1.15,
      ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
      child: Icon(
        Icons.favorite,
        color: widget.bpm != null ? Colors.redAccent : Colors.white38,
        size: 15,
      ),
    );
  }
}
