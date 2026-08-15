import 'dart:io';

import 'vector_tile_source.dart';

/// Loopback HTTP server that fronts [VectorTileSourceResolver] with plain
/// tile URLs maplibre_gl's native map engine can fetch directly - it takes a
/// style/tile URL template, not a Flutter-side `TileProvider` the way
/// flutter_map did.
///
/// Routes:
///   GET /style.json             - the shared MapLibre style (see
///                                  `assets/map_style/baghdad_style.json`),
///                                  with its vector source's `{{TILE_BASE_URL}}`
///                                  placeholder rewritten to this server's
///                                  own address (only known once bound).
///   GET /tiles/{z}/{x}/{y}.pbf  - a single vector tile, resolved via
///                                  [VectorTileSourceResolver].
class VectorTileHttpServer {
  /// [styleTemplate] is the raw contents of `baghdad_style.json`, containing
  /// the `{{TILE_BASE_URL}}` placeholder. [onTileResolved] is called after
  /// every tile request with whether a tile was found from any source - the
  /// caller (`MapTileService`) uses this to drive the existing
  /// consecutive-failure/offline-banner tracking.
  VectorTileHttpServer({
    required VectorTileSourceResolver resolver,
    required String styleTemplate,
    required void Function(bool success) onTileResolved,
  }) : _resolver = resolver,
       _styleTemplate = styleTemplate,
       _onTileResolved = onTileResolved;

  final VectorTileSourceResolver _resolver;
  final String _styleTemplate;
  final void Function(bool success) _onTileResolved;

  HttpServer? _server;

  /// This server's own base URL (e.g. `http://127.0.0.1:54321`). Only valid
  /// after [start] has completed.
  String get baseUrl {
    final server = _server;
    if (server == null) {
      throw StateError('VectorTileHttpServer.start() must complete first.');
    }
    return 'http://127.0.0.1:${server.port}';
  }

  /// The style URL to hand to `MapLibreMap(styleString: ...)`.
  String get styleUrl => '$baseUrl/style.json';

  /// Binds to an ephemeral loopback port. Safe to call more than once;
  /// subsequent calls are no-ops.
  Future<void> start() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_handleRequest);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;

      if (segments.length == 1 && segments[0] == 'style.json') {
        await _serveStyle(request);
        return;
      }

      if (segments.length == 4 &&
          segments[0] == 'tiles' &&
          segments[3].endsWith('.pbf')) {
        final z = int.tryParse(segments[1]);
        final x = int.tryParse(segments[2]);
        final y = int.tryParse(
          segments[3].substring(0, segments[3].length - '.pbf'.length),
        );
        if (z != null && x != null && y != null) {
          await _serveTile(request, z, x, y);
          return;
        }
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      // A single malformed/failed request must never take the loopback
      // server down for the rest of the map.
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // Response was already closed/broken; nothing more to do.
      }
    }
  }

  Future<void> _serveStyle(HttpRequest request) async {
    final body = _styleTemplate.replaceAll('{{TILE_BASE_URL}}', baseUrl);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(body);
    await request.response.close();
  }

  Future<void> _serveTile(HttpRequest request, int z, int x, int y) async {
    final result = await _resolver.resolveTile(z, x, y);
    _onTileResolved(result != null);

    if (result == null) {
      request.response.statusCode = HttpStatus.noContent;
      await request.response.close();
      return;
    }

    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'x-protobuf')
      ..add(result.bytes);
    await request.response.close();
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}
