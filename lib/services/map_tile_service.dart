import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pmtiles/pmtiles.dart';

import 'vector_tile_http_server.dart';
import 'vector_tile_source.dart';

/// Bounding box covering Baghdad and its immediate surroundings, and the
/// zoom range (10-17) that gives street-level navigation detail without
/// downloading the entire country. Also the bbox `tool/vector_tiles/`
/// clips the bundled offline PMTiles archive to - keep the two in sync.
class BaghdadRegion {
  const BaghdadRegion._();

  static const double minLatitude = 33.0;
  static const double maxLatitude = 33.6;
  static const double minLongitude = 44.1;
  static const double maxLongitude = 44.6;
  static const int minZoom = 10;
  static const int maxZoom = 17;
}

/// Hybrid offline/online vector-tile source for the app's maps.
///
/// Three tile sources, tried in order for every tile request (see
/// [VectorTileSourceResolver]): the on-disk cache of tiles already fetched
/// once before -> a live fetch from OpenFreeMap (free, open, no API key -
/// see the resolver's doc comment) written through to that cache -> the
/// bundled offline PMTiles archive for Baghdad, produced entirely outside
/// the app by `tool/vector_tiles/` (documented there; not run by the app or
/// CI). maplibre_gl (the map rendering engine, replacing flutter_map) talks
/// HTTP, not a Flutter-side tile-provider abstraction, so these three
/// sources are fronted by a tiny loopback [VectorTileHttpServer] rather than
/// wired in directly.
///
/// This is a strict improvement on the old raster pipeline's offline
/// fallback (a blank gray tile): offline users without any cached tiles now
/// still see the real bundled Baghdad basemap instead of nothing.
class MapTileService extends ChangeNotifier {
  /// [cacheDir], [assetBundle] and [supportDir], if provided, are used
  /// instead of resolving real ones via `path_provider`/`rootBundle` in
  /// [init] - mainly so tests can inject a temp directory and an in-memory
  /// asset bundle without needing a platform channel, the same pattern
  /// `RoutingGraphSeeder` already uses for the routing-graph asset.
  MapTileService({
    http.Client? httpClient,
    Directory? cacheDir,
    AssetBundle? assetBundle,
    Directory? supportDir,
  }) : _httpClient = httpClient ?? http.Client(),
       _cacheDir = cacheDir,
       _assetBundle = assetBundle ?? rootBundle,
       _supportDir = supportDir,
       _testStyleUrl = null;

  /// Skips [init] (no real asset bundle, PMTiles archive, or HTTP server)
  /// and returns [styleUrl] as given - for widget tests that only need
  /// *some* valid-looking style URL. `MapLibreMap`'s platform view never
  /// actually initializes under `flutter_test` (see
  /// `test/ride_map_view_test.dart`), so nothing ever fetches this URL for
  /// real; [hasTileFetchFailures] simply stays false.
  @visibleForTesting
  MapTileService.readyForTesting({required String styleUrl})
    : _httpClient = http.Client(),
      _cacheDir = null,
      _assetBundle = rootBundle,
      _supportDir = null,
      _testStyleUrl = styleUrl;

  static const String storeName = 'iraq_cycling_tiles';
  static const String _bundledArchiveAssetPath =
      'assets/vector_tiles/baghdad.pmtiles';
  static const String _styleAssetPath = 'assets/map_style/baghdad_style.json';

  final http.Client _httpClient;
  Directory? _cacheDir;
  final AssetBundle _assetBundle;
  final Directory? _supportDir;
  final String? _testStyleUrl;

  VectorTileSourceResolver? _resolver;
  VectorTileHttpServer? _server;
  PmTilesArchive? _bundledArchive;

  bool get isInitialized => _testStyleUrl != null || _server != null;

  /// The style URL to hand to `MapLibreMap(styleString: ...)`. Only valid
  /// once [init] has completed (or, in tests, when constructed via
  /// [MapTileService.readyForTesting]).
  String get styleUrl {
    final testStyleUrl = _testStyleUrl;
    if (testStyleUrl != null) return testStyleUrl;

    final server = _server;
    if (server == null) {
      throw StateError(
        'MapTileService.init() must complete before styleUrl is used.',
      );
    }
    return server.styleUrl;
  }

  // Number of consecutive tile requests that must fail (nothing from cache,
  // network, or the bundled archive) before treating the map as "unusable"
  // and surfacing that to the user. A handful rather than a single failure
  // avoids flashing the banner for one flaky tile while most of the visible
  // area loads fine.
  static const int _consecutiveFailureThreshold = 6;
  int _consecutiveTileFailures = 0;

  /// True once [_consecutiveFailureThreshold] tile requests in a row have
  /// come back empty from every source. In practice this means the bundled
  /// archive doesn't cover the visible area either (well outside Baghdad).
  /// [RideMapView] watches this (via [ChangeNotifier]) to show a banner.
  bool get hasTileFetchFailures =>
      _consecutiveTileFailures >= _consecutiveFailureThreshold;

  void _onTileResolved(bool success) {
    if (success) {
      final wasFailing = hasTileFetchFailures;
      _consecutiveTileFailures = 0;
      if (wasFailing) notifyListeners();
      return;
    }

    _consecutiveTileFailures++;
    if (_consecutiveTileFailures == _consecutiveFailureThreshold) {
      notifyListeners();
    }
  }

  /// Copies the bundled PMTiles asset out to a real file (needed since
  /// [PmTilesArchive] reads from the filesystem, not the in-APK asset
  /// bundle), opens it, starts the loopback tile/style server, and prepares
  /// the on-disk tile cache. Safe to call more than once; subsequent calls
  /// are no-ops.
  Future<void> init() async {
    if (_server != null) return;

    final support = _supportDir ?? await getApplicationSupportDirectory();

    final cacheDir = _cacheDir ?? Directory(p.join(support.path, storeName));
    await cacheDir.create(recursive: true);
    _cacheDir = cacheDir;

    final bundledFile = File(p.join(support.path, 'baghdad_bundled.pmtiles'));
    if (!await bundledFile.exists()) {
      final data = await _assetBundle.load(_bundledArchiveAssetPath);
      await bundledFile.parent.create(recursive: true);
      await bundledFile.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    final bundledArchive = await PmTilesArchive.fromFile(bundledFile);
    _bundledArchive = bundledArchive;

    final resolver = VectorTileSourceResolver(
      cacheDir: cacheDir,
      bundledArchive: bundledArchive,
      httpClient: _httpClient,
    );
    _resolver = resolver;

    final styleTemplate = await _assetBundle.loadString(_styleAssetPath);
    final server = VectorTileHttpServer(
      resolver: resolver,
      styleTemplate: styleTemplate,
      onTileResolved: _onTileResolved,
    );
    await server.start();
    _server = server;
  }

  /// Number of tiles that [downloadBaghdadRegion] would need to fetch, for
  /// displaying an estimate to the user before they start the download.
  int get estimatedTileCount {
    var total = 0;
    for (var z = BaghdadRegion.minZoom; z <= BaghdadRegion.maxZoom; z++) {
      final range = _tileRangeForZoom(
        BaghdadRegion.minLatitude,
        BaghdadRegion.maxLatitude,
        BaghdadRegion.minLongitude,
        BaghdadRegion.maxLongitude,
        z,
      );
      total += (range.maxX - range.minX + 1) * (range.maxY - range.minY + 1);
    }
    return total;
  }

  /// Pre-warms the on-disk cache with higher-resolution online vector tiles
  /// for the whole of [BaghdadRegion], so they're available offline before
  /// ever being viewed live. The bundled archive already covers this area
  /// by default (see [init]), so this is "fetch the better tiles now, while
  /// on wifi" rather than "make offline possible at all". Tiles already
  /// cached are skipped (delegated to [VectorTileSourceResolver.resolveTile]
  /// itself, which checks the cache first). [onProgress] is called with a
  /// value from 0.0 to 1.0 as tiles complete.
  Future<void> downloadBaghdadRegion({
    required void Function(double progress) onProgress,
  }) async {
    if (!isInitialized) await init();
    final resolver = _resolver!;

    final tiles = <_TileXYZ>[];
    for (var z = BaghdadRegion.minZoom; z <= BaghdadRegion.maxZoom; z++) {
      final range = _tileRangeForZoom(
        BaghdadRegion.minLatitude,
        BaghdadRegion.maxLatitude,
        BaghdadRegion.minLongitude,
        BaghdadRegion.maxLongitude,
        z,
      );
      for (var x = range.minX; x <= range.maxX; x++) {
        for (var y = range.minY; y <= range.maxY; y++) {
          tiles.add(_TileXYZ(z, x, y));
        }
      }
    }

    if (tiles.isEmpty) {
      onProgress(1);
      return;
    }

    // Deliberately slow and low-concurrency: this is a courtesy rate limit
    // against OpenFreeMap's shared tile server, not a performance target.
    const concurrency = 2;
    const interBatchDelay = Duration(milliseconds: 250);

    var completed = 0;
    for (var i = 0; i < tiles.length; i += concurrency) {
      final batch = tiles.skip(i).take(concurrency).toList();
      await Future.wait(
        batch.map((t) => resolver.resolveTile(t.z, t.x, t.y)),
      );
      completed += batch.length;
      onProgress(completed / tiles.length);
      if (i + concurrency < tiles.length) {
        await Future.delayed(interBatchDelay);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_server?.close());
    unawaited(_bundledArchive?.close());
    _httpClient.close();
    super.dispose();
  }
}

class _TileXYZ {
  const _TileXYZ(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;

  @override
  String toString() => '($z/$x/$y)';
}

typedef _TileRange = ({int minX, int maxX, int minY, int maxY});

_TileRange _tileRangeForZoom(
  double minLat,
  double maxLat,
  double minLon,
  double maxLon,
  int z,
) {
  return (
    minX: _lonToTileX(minLon, z),
    maxX: _lonToTileX(maxLon, z),
    minY: _latToTileY(maxLat, z), // higher latitude -> smaller tile y
    maxY: _latToTileY(minLat, z),
  );
}

int _lonToTileX(double lonDeg, int z) {
  final n = 1 << z;
  return (((lonDeg + 180.0) / 360.0) * n).floor().clamp(0, n - 1);
}

int _latToTileY(double latDeg, int z) {
  final n = 1 << z;
  final latRad = latDeg * (math.pi / 180.0);
  final y =
      ((1 - (math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi)) /
          2) *
      n;
  return y.floor().clamp(0, n - 1);
}
