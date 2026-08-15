import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pmtiles/pmtiles.dart';

/// Which of the three tile sources actually served a given tile - exposed
/// mainly so tests can assert on precedence without inspecting bytes.
enum TileSource { cache, network, bundled }

class TileFetchResult {
  const TileFetchResult(this.bytes, this.source);

  final List<int> bytes;
  final TileSource source;
}

/// Resolves a single {z}/{x}/{y} vector tile request against three sources,
/// in priority order:
///
///   1. the on-disk cache of tiles already fetched from the network before
///      (fastest, and avoids re-fetching the same tile every ride);
///   2. a live fetch from OpenFreeMap (higher-resolution than the bundled
///      offline set - see [_resolveOnlineTemplate] for why the URL isn't a
///      fixed constant), written through to the cache on success;
///   3. the bundled offline PMTiles archive for Baghdad, produced by
///      `tool/vector_tiles/` - the zero-connectivity fallback.
///
/// This is the "online/offline tile-source switching logic" - deliberately
/// kept free of any Flutter/widget/HTTP-server dependency so it can be unit
/// tested directly (see `test/vector_tile_source_test.dart`), the same way
/// [MapTileService]'s raster tile provider was previously only exercised
/// indirectly through widget tests.
class VectorTileSourceResolver {
  /// [httpClient] is injectable so tests can supply a `MockClient` instead
  /// of hitting the network, matching the pattern already used by
  /// `MapTileService`.
  VectorTileSourceResolver({
    required Directory cacheDir,
    required PmTilesArchive bundledArchive,
    http.Client? httpClient,
  }) : _cacheDir = cacheDir,
       _bundledArchive = bundledArchive,
       _httpClient = httpClient ?? http.Client();

  // OpenFreeMap's TileJSON. The actual tile URL template it returns
  // includes a versioned path segment (e.g. `.../planet/20260802.../{z}/{x}/{y}.pbf`)
  // that changes as they rebuild their planet extract, so it can't be a
  // fixed constant - it's discovered once per process lifetime instead.
  static const String _tileJsonUrl = 'https://tiles.openfreemap.org/planet';
  static const Duration _tileJsonTimeout = Duration(seconds: 8);
  static const Duration _tileTimeout = Duration(seconds: 8);

  final Directory _cacheDir;
  final PmTilesArchive _bundledArchive;
  final http.Client _httpClient;

  String? _onlineTileTemplate;

  /// Resolves the tile at [z]/[x]/[y], trying each source in turn. Returns
  /// null if nothing was available anywhere (offline, nothing cached yet,
  /// and the bundled archive doesn't cover this coordinate).
  Future<TileFetchResult?> resolveTile(int z, int x, int y) async {
    final cacheFile = _cacheFileFor(z, x, y);
    if (await cacheFile.exists()) {
      return TileFetchResult(await cacheFile.readAsBytes(), TileSource.cache);
    }

    final networkBytes = await _tryNetwork(z, x, y);
    if (networkBytes != null) {
      unawaited(_writeCache(cacheFile, networkBytes));
      return TileFetchResult(networkBytes, TileSource.network);
    }

    final bundledBytes = await _tryBundled(z, x, y);
    if (bundledBytes != null) {
      return TileFetchResult(bundledBytes, TileSource.bundled);
    }

    return null;
  }

  Future<List<int>?> _tryNetwork(int z, int x, int y) async {
    final template = await _resolveOnlineTemplate();
    if (template == null) return null;

    final url = template
        .replaceAll('{z}', '$z')
        .replaceAll('{x}', '$x')
        .replaceAll('{y}', '$y');

    try {
      final response = await _httpClient
          .get(Uri.parse(url))
          .timeout(_tileTimeout);
      if (response.statusCode == 200) return response.bodyBytes;
      return null;
    } catch (_) {
      // No internet, DNS failure, timeout, etc. - fall through to the
      // bundled archive.
      return null;
    }
  }

  Future<String?> _resolveOnlineTemplate() async {
    if (_onlineTileTemplate != null) return _onlineTileTemplate;

    try {
      final response = await _httpClient
          .get(Uri.parse(_tileJsonUrl))
          .timeout(_tileJsonTimeout);
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) return null;
      final tiles = decoded['tiles'];
      if (tiles is! List || tiles.isEmpty) return null;
      final template = tiles.first;
      if (template is! String) return null;

      _onlineTileTemplate = template;
      return template;
    } catch (_) {
      // Retried on the next call (e.g. once connectivity returns) rather
      // than cached as a permanent failure.
      return null;
    }
  }

  Future<List<int>?> _tryBundled(int z, int x, int y) async {
    final tileId = ZXY(z, x, y).toTileId();
    try {
      final tile = await _bundledArchive.tile(tileId);
      return tile.bytes();
    } on TileNotFoundException {
      return null;
    } catch (error, stackTrace) {
      developer.log(
        'Failed to read bundled tile ($z/$x/$y)',
        name: 'VectorTileSourceResolver',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _writeCache(File file, List<int> bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    } catch (_) {
      // Best-effort only; failing to persist the cache must not affect the
      // tile that is already being served.
    }
  }

  File _cacheFileFor(int z, int x, int y) =>
      File(p.join(_cacheDir.path, '$z', '$x', '$y.pbf'));
}
