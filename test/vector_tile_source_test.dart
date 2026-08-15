import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:iraq_cycling/services/vector_tile_source.dart';
import 'package:path/path.dart' as p;
import 'package:pmtiles/pmtiles.dart';

const _fixturePath = 'test/fixtures/baghdad_test.pmtiles';

// A tile confirmed present in the fixture archive (from the Planetiler
// build log's own tile listing - see tool/vector_tiles/README.md) and one
// confirmed absent: same zoom level, but centered on lon=0/lat=0 - nowhere
// near Baghdad, and the fixture is clipped to BaghdadRegion's bbox, so nothing
// is emitted there at any zoom.
const _presentZ = 11;
const _presentX = 1276;
const _presentY = 822;
const _absentZ = 10;
const _absentX = 512;
const _absentY = 512;

const _fakeTileJson = '''
{"tiles": ["https://example.invalid/tiles/{z}/{x}/{y}.pbf"]}
''';

void main() {
  late Directory tempDir;
  late PmTilesArchive bundledArchive;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('vector_tile_source_test');
    bundledArchive = await PmTilesArchive.fromFile(File(_fixturePath));
  });

  tearDown(() async {
    await bundledArchive.close();
    tempDir.deleteSync(recursive: true);
  });

  test('serves from cache without touching the network', () async {
    var networkCalls = 0;
    final cacheFile = File(p.join(tempDir.path, '5', '6', '7.pbf'));
    await cacheFile.parent.create(recursive: true);
    await cacheFile.writeAsBytes([1, 2, 3]);

    final resolver = VectorTileSourceResolver(
      cacheDir: tempDir,
      bundledArchive: bundledArchive,
      httpClient: MockClient((request) async {
        networkCalls++;
        return http.Response('', 404);
      }),
    );

    final result = await resolver.resolveTile(5, 6, 7);

    expect(result, isNotNull);
    expect(result!.source, TileSource.cache);
    expect(result.bytes, [1, 2, 3]);
    expect(networkCalls, 0);
  });

  test(
    'cache miss + network success serves the network response and writes '
    'it to the cache',
    () async {
      final resolver = VectorTileSourceResolver(
        cacheDir: tempDir,
        bundledArchive: bundledArchive,
        httpClient: MockClient((request) async {
          if (request.url.toString().contains('/planet')) {
            return http.Response(_fakeTileJson, 200);
          }
          if (request.url.toString() ==
              'https://example.invalid/tiles/5/6/7.pbf') {
            return http.Response.bytes([9, 9, 9], 200);
          }
          return http.Response('', 404);
        }),
      );

      final result = await resolver.resolveTile(5, 6, 7);

      expect(result, isNotNull);
      expect(result!.source, TileSource.network);
      expect(result.bytes, [9, 9, 9]);

      // Written through to the cache for next time.
      final cacheFile = File(p.join(tempDir.path, '5', '6', '7.pbf'));
      // Cache write is fire-and-forget (unawaited) - give it a moment.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await cacheFile.exists(), isTrue);
      expect(await cacheFile.readAsBytes(), [9, 9, 9]);
    },
  );

  test(
    'cache miss + network failure falls back to the bundled archive',
    () async {
      final resolver = VectorTileSourceResolver(
        cacheDir: tempDir,
        bundledArchive: bundledArchive,
        httpClient: MockClient((request) async => http.Response('', 500)),
      );

      final result = await resolver.resolveTile(
        _presentZ,
        _presentX,
        _presentY,
      );

      expect(result, isNotNull);
      expect(result!.source, TileSource.bundled);
      expect(result.bytes, isNotEmpty);
    },
  );

  test(
    'cache miss + network failure + bundled archive miss returns null',
    () async {
      final resolver = VectorTileSourceResolver(
        cacheDir: tempDir,
        bundledArchive: bundledArchive,
        httpClient: MockClient((request) async {
          throw const SocketException('no network in test VM');
        }),
      );

      final result = await resolver.resolveTile(
        _absentZ,
        _absentX,
        _absentY,
      );

      expect(result, isNull);
    },
  );

  test(
    'network TileJSON discovery only happens once per resolver instance',
    () async {
      var tileJsonCalls = 0;
      final resolver = VectorTileSourceResolver(
        cacheDir: tempDir,
        bundledArchive: bundledArchive,
        httpClient: MockClient((request) async {
          if (request.url.toString().contains('/planet')) {
            tileJsonCalls++;
            return http.Response(_fakeTileJson, 200);
          }
          return http.Response.bytes([1], 200);
        }),
      );

      await resolver.resolveTile(1, 1, 1);
      await resolver.resolveTile(2, 2, 2);

      expect(tileJsonCalls, 1);
    },
  );
}
