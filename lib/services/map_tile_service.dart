import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Bounding box covering Baghdad and its immediate surroundings, and the
/// zoom range (10-17) that gives street-level navigation detail without
/// downloading the entire country.
class BaghdadRegion {
  const BaghdadRegion._();

  static const double minLatitude = 33.0;
  static const double maxLatitude = 33.6;
  static const double minLongitude = 44.1;
  static const double maxLongitude = 44.6;
  static const int minZoom = 10;
  static const int maxZoom = 17;
}

/// Offline-first tile source for OpenStreetMap raster tiles.
///
/// This deliberately does NOT use a third-party tile-caching package: the
/// obvious candidate, `flutter_map_tile_caching`, is GPLv3-licensed, which
/// would obligate this app (including its planned paid-subscription phase)
/// to also be released under GPLv3 or to purchase a commercial license.
/// Instead, this is a small, dependency-free file-based cache built directly
/// on top of `flutter_map`'s `TileProvider` API.
///
/// Tiles are fetched from OpenStreetMap's standard tile server
/// (`tile.openstreetmap.org`), which is intended for light, evaluation-scale
/// use and requires a valid identifying `User-Agent` header (see
/// https://operations.osmfoundation.org/policies/tiles/). Two things to keep
/// in mind as this app grows:
///   1. OSM's tile usage policy explicitly discourages *bulk* downloading of
///      tiles, which is exactly what [downloadBaghdadRegion] does (tens of
///      thousands of tiles for zoom 10-17 over Baghdad). This is kept to a
///      single one-time, low-concurrency, rate-limited download for one
///      developer's personal testing use, which is a reasonable reading of
///      "acceptable use" - but it does not scale to many users.
///   2. Before any wider release, replace [tileUrlTemplate] with a paid
///      provider (e.g. MapTiler, Thunderforest, Mapbox) or a self-hosted tile
///      server, and remove/replace the bulk pre-download entirely in favour
///      of normal on-demand caching. Hitting OSM's own servers at production
///      scale can get the app's traffic blocked.
class MapTileService {
  /// [cacheDir], if provided, is used immediately instead of resolving one
  /// via `path_provider` in [init] - mainly so tests can inject a temporary
  /// directory without needing a platform channel.
  MapTileService({http.Client? httpClient, Directory? cacheDir})
    : _httpClient = httpClient ?? http.Client(),
      _cacheDir = cacheDir;

  static const String storeName = 'iraq_cycling_tiles';
  static const String tileUrlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  // Identifies this app and gives OSM a way to contact the developer, as
  // required by their tile usage policy. Update the contact if it changes.
  static const String _userAgent =
      'iraq_cycling_app/1.0 (+ahssanali84.syber@gmail.com)';

  final http.Client _httpClient;
  Directory? _cacheDir;

  bool get isInitialized => _cacheDir != null;

  /// Prepares the on-disk cache directory (the "store"). Safe to call more
  /// than once; subsequent calls are no-ops.
  Future<void> init() async {
    if (_cacheDir != null) return;
    final supportDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(supportDir.path, storeName));
    await dir.create(recursive: true);
    _cacheDir = dir;
  }

  /// The tile provider to hand to a flutter_map [TileLayer]. Reads from the
  /// local cache first; falls back to network if missing; falls back to a
  /// neutral gray placeholder if neither is available.
  TileProvider get tileProvider {
    final dir = _cacheDir;
    if (dir == null) {
      throw StateError(
        'MapTileService.init() must complete before tileProvider is used.',
      );
    }
    return _OfflineFirstTileProvider(cacheDir: dir, httpClient: _httpClient);
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

  /// Triggers a one-time download of every tile covering [BaghdadRegion] at
  /// zoom levels [BaghdadRegion.minZoom] through [BaghdadRegion.maxZoom].
  /// Tiles already present in the cache are skipped. [onProgress] is called
  /// with a value from 0.0 to 1.0 as tiles complete.
  Future<void> downloadBaghdadRegion({
    required void Function(double progress) onProgress,
  }) async {
    if (!isInitialized) await init();
    final dir = _cacheDir!;

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
    // against OSM's shared tile server, not a performance target. See the
    // class-level doc comment about this download's policy implications.
    const concurrency = 2;
    const interBatchDelay = Duration(milliseconds: 250);

    var completed = 0;
    for (var i = 0; i < tiles.length; i += concurrency) {
      final batch = tiles.skip(i).take(concurrency).toList();
      await Future.wait(batch.map((t) => _downloadSingleTile(t, dir)));
      completed += batch.length;
      onProgress(completed / tiles.length);
      if (i + concurrency < tiles.length) {
        await Future.delayed(interBatchDelay);
      }
    }
  }

  Future<void> _downloadSingleTile(_TileXYZ t, Directory dir) async {
    final file = _fileFor(dir, t);
    if (await file.exists()) return;

    final url = tileUrlTemplate
        .replaceAll('{z}', '${t.z}')
        .replaceAll('{x}', '${t.x}')
        .replaceAll('{y}', '${t.y}');

    try {
      final response = await _httpClient
          .get(Uri.parse(url), headers: const {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(response.bodyBytes, flush: true);
      }
    } catch (error, stackTrace) {
      // No internet, or the server rejected/timed out the request. Skip this
      // tile rather than aborting the whole region download - it will just
      // fall back to network-on-demand or the gray placeholder when viewed.
      developer.log(
        'Failed to download tile $t',
        name: 'MapTileService',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void dispose() => _httpClient.close();
}

File _fileFor(Directory dir, _TileXYZ t) =>
    File(p.join(dir.path, '${t.z}', '${t.x}', '${t.y}.png'));

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

/// Reads tiles from the local file cache first, falling back to a network
/// fetch (which also populates the cache), falling back to a neutral gray
/// placeholder if there is no connectivity and nothing cached.
class _OfflineFirstTileProvider extends TileProvider {
  _OfflineFirstTileProvider({
    required this.cacheDir,
    required http.Client httpClient,
  }) : _httpClient = httpClient,
       // Must be a mutable (non-const) map: TileLayer's constructor calls
       // `headers.putIfAbsent(...)` on it, which throws on a const map.
       super(headers: {'User-Agent': MapTileService._userAgent});

  final Directory cacheDir;
  final http.Client _httpClient;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final file = _fileFor(
      cacheDir,
      _TileXYZ(coordinates.z, coordinates.x, coordinates.y),
    );
    if (file.existsSync()) return FileImage(file);

    return _CachingNetworkTileImage(
      url: getTileUrl(coordinates, options),
      cacheFile: file,
      httpClient: _httpClient,
      headers: headers,
    );
  }
}

class _CachingNetworkTileImage extends ImageProvider<_CachingNetworkTileImage> {
  const _CachingNetworkTileImage({
    required this.url,
    required this.cacheFile,
    required this.httpClient,
    required this.headers,
  });

  final String url;
  final File cacheFile;
  final http.Client httpClient;
  final Map<String, String> headers;

  @override
  Future<_CachingNetworkTileImage> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture<_CachingNetworkTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    _CachingNetworkTileImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    try {
      final response = await httpClient
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }

      final bytes = response.bodyBytes;
      unawaited(_writeToCache(bytes));
      return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } catch (_) {
      // Offline and not cached: show a neutral placeholder instead of an
      // error tile or a crash.
      return decode(
        await ui.ImmutableBuffer.fromUint8List(placeholderTileBytes),
      );
    }
  }

  Future<void> _writeToCache(Uint8List bytes) async {
    try {
      await cacheFile.parent.create(recursive: true);
      await cacheFile.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // Best-effort only; failing to persist the cache must not affect the
      // tile that is already being displayed.
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _CachingNetworkTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// A flat, neutral-gray 16x16 PNG shown when a tile is neither cached nor
/// reachable over the network. Generated once and embedded here so the
/// fallback never itself depends on disk or network access.
final Uint8List placeholderTileBytes = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  16,
  0,
  0,
  0,
  16,
  8,
  2,
  0,
  0,
  0,
  144,
  145,
  104,
  54,
  0,
  0,
  0,
  20,
  73,
  68,
  65,
  84,
  120,
  218,
  99,
  120,
  64,
  34,
  96,
  24,
  213,
  48,
  170,
  97,
  248,
  106,
  0,
  0,
  63,
  91,
  160,
  31,
  90,
  146,
  193,
  199,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);
