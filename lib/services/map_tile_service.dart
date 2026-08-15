import 'package:flutter/foundation.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

/// Bounding box covering Baghdad and its immediate surroundings, and the
/// camera zoom range (10 city-wide overview - 17 street-level) the app's
/// navigation UI dynamically zooms between (see `RideMapView`). Also the
/// bbox the one-time offline-region capture documented in
/// `tool/vector_tiles/README.md` clips to - keep the two in sync.
class BaghdadRegion {
  const BaghdadRegion._();

  static const double minLatitude = 33.0;
  static const double maxLatitude = 33.6;
  static const double minLongitude = 44.1;
  static const double maxLongitude = 44.6;
  static const int minZoom = 10;
  static const int maxZoom = 17;
}

/// Installs the app's bundled offline map data into MapLibre Native's own
/// offline-region SQLite cache on first launch, and hands out the real,
/// published OpenFreeMap style URL every `MapLibreMap` in the app renders
/// against.
///
/// Offline availability goes through MapLibre Native's offline/ambient
/// cache directly ([ml.installOfflineMapTiles]) rather than a custom
/// cache/network/bundled-archive resolver fronted by a loopback HTTP
/// server (the old design, removed - see git history for
/// `VectorTileSourceResolver`/`VectorTileHttpServer`). That native cache is
/// read *before* MapLibre's connectivity gate - confirmed on a real device
/// with airplane mode + WiFi both off (see `PROJECT_STATE.md`, sessions
/// "الخامسة"/"السادسة") - whereas even a 127.0.0.1 loopback HTTP request
/// was blocked outright by that gate.
class MapTileService {
  MapTileService() : _testStyleUrl = null;

  /// Skips [init] and returns [styleUrl] as given - for widget tests that
  /// only need *some* valid-looking style URL. `MapLibreMap`'s platform
  /// view never actually initializes under `flutter_test`, so nothing ever
  /// fetches this URL for real.
  @visibleForTesting
  MapTileService.readyForTesting({required String styleUrl})
    : _testStyleUrl = styleUrl;

  /// The real, published OpenFreeMap "Liberty" style: stable, free, no API
  /// key. See `tool/vector_tiles/README.md` for the one-time offline-region
  /// capture that makes this render fully offline too.
  static const String _realStyleUrl =
      'https://tiles.openfreemap.org/styles/liberty';

  static const String _bundledOfflineDbAssetPath =
      'assets/offline_regions/baghdad_offline.db';

  final String? _testStyleUrl;
  bool _initialized = false;

  /// The style URL to hand to `MapLibreMap(styleString: ...)`.
  String get styleUrl => _testStyleUrl ?? _realStyleUrl;

  /// Installs the bundled offline region into MapLibre's native offline
  /// cache the first time the app ever runs. Safe to call more than once;
  /// if any offline region already exists (the normal case after the first
  /// launch), this is a no-op. Self-healing: if the offline database is
  /// ever cleared (e.g. Android's "Clear storage"), the next launch's
  /// [init] detects the empty region list and reinstalls the bundled
  /// fallback automatically.
  Future<void> init() async {
    if (_testStyleUrl != null || _initialized) return;

    final regions = await ml.getListOfRegions();
    if (regions.isEmpty) {
      await ml.installOfflineMapTiles(_bundledOfflineDbAssetPath);
    }
    _initialized = true;
  }
}
