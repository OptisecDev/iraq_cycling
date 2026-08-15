# Baghdad offline-region capture

Build-time procedure: a one-time, real-device MapLibre Native offline-region
download -> `assets/offline_regions/baghdad_offline.db`, the bundled
zero-connectivity basemap `MapTileService.init` installs into MapLibre's own
offline cache on first launch (see that class's doc comment).

Not run by the app or CI. Run it manually whenever the bundled basemap needs
refreshing or `BaghdadRegion`'s bbox changes, the same way
`tool/routing_import/build_routing_graph.py` documents its own OSM pipeline.

## Why this replaced the old PMTiles/loopback-server pipeline

The previous design (`VectorTileSourceResolver` + a loopback
`VectorTileHttpServer` fronting a bundled PMTiles archive) turned out to be
unreachable with zero connectivity: MapLibre Native's `ConnectivityReceiver`
tells the native mbgl core to refuse **any** HTTP request - including to
`127.0.0.1` - whenever Android reports no active network, verified on a real
device in airplane mode (see `PROJECT_STATE.md`, sessions "الخامسة"/
"السادسة", 2026-08-15). MapLibre's own native offline-region cache, by
contrast, is read *before* that connectivity gate - confirmed working fully
offline the same session. This procedure produces the asset that mechanism
needs: a real offline-region database, captured once via MapLibre's own
`downloadOfflineRegion` API against a real style over a real connection, then
pulled off the device and shipped as a bundled asset.

## Steps

This needs a real Android device or emulator (native SDK code, not something
`flutter test` can drive) and takes maybe a minute or two of actual download
time - but requires the app stay foregrounded the whole time (MapLibre's
offline downloads don't survive a process kill; there's no cross-restart
resumption).

1. **Build and install a *debug* APK** - not the app's normal release build.
   Pulling the result in step 4 needs `adb shell run-as`, which only works
   against a debuggable install:

   ```
   flutter build apk --debug --target-platform android-arm64
   adb install -r build/app/outputs/flutter-apk/app-debug.apk
   ```

2. Add a throwaway screen/button (temporary - delete it again once you're
   done, same as any other scratch verification code in this repo) that
   calls, while the device has real connectivity:

   ```dart
   import 'package:maplibre_gl/maplibre_gl.dart' as ml;

   await ml.setOfflineMaxConcurrentRequests(maxRequests: 2, maxRequestsPerHost: 2);
   await ml.setOfflineTileCountLimit(2000); // headroom above the ~1,075-tile estimate below
   await ml.downloadOfflineRegion(
     ml.OfflineRegionDefinition(
       bounds: ml.LatLngBounds(
         southwest: const ml.LatLng(33.0, 44.1), // BaghdadRegion.minLatitude/minLongitude
         northeast: const ml.LatLng(33.6, 44.6), // BaghdadRegion.maxLatitude/maxLongitude
       ),
       mapStyleUrl: 'https://tiles.openfreemap.org/styles/liberty',
       minZoom: 10,
       maxZoom: 14,
     ),
     onEvent: (event) { /* log progress so you can see it's moving */ },
   );
   ```

   - `mapStyleUrl` must be the **exact literal string**
     `MapTileService._realStyleUrl` uses in the app - MapLibre's offline
     cache is keyed by exact request URL, so any mismatch (trailing slash,
     different casing) here means real cache misses at runtime despite the
     region existing.
   - `maxZoom: 14`, not `BaghdadRegion.maxZoom` (17): the real tile-pyramid
     count for this bbox is **~1,075 tiles at z10-14** vs. **~64,000 at
     z10-17** (60x more), and OpenFreeMap's `/planet` source almost
     certainly has the same z14 native-data ceiling the old PMTiles archive
     did (same OpenMapTiles-schema convention) - camera zooms 15-17 keep
     working exactly as before via ordinary client-side vector-tile
     overzoom of the z14 data, unrelated to what's captured here. Asking
     for z17 directly would mean ~64k real HTTP requests against a shared
     public tile server, most past the source's real data ceiling - a
     courtesy concern, not just wasted time.
   - `setOfflineMaxConcurrentRequests(2, 2)` is the courtesy throttle here -
     the same spirit as the old pipeline's explicit "concurrency=2 ...
     courtesy rate limit against OpenFreeMap's shared tile server" comment,
     just via the native SDK's own knob instead of a manual delay loop.

3. Tap the button, watch the progress logs, and **keep the app in the
   foreground** until you see the terminal success event. Don't lock the
   screen or switch apps.

4. Pull the resulting database off the device:

   ```
   adb shell run-as com.optisec.iraq_cycling cat files/mbgl-offline.db > baghdad_offline.db
   ```

5. Copy it into the app:

   ```
   cp baghdad_offline.db ../../assets/offline_regions/baghdad_offline.db
   ```

6. Delete the throwaway capture screen/button and any temporary routing
   change you made to reach it, and confirm `git status`/`git diff` are
   clean for Dart source before committing just the new asset.

7. **Re-verify on-device with the app's normal release build**: fresh
   `adb install -r`, launch once with real connectivity so
   `MapTileService.init` installs the region, force-stop, then real
   airplane mode + WiFi off (double-check via `adb shell settings get
   global airplane_mode_on`, `dumpsys wifi`, and `ping 8.8.8.8` returning
   "Network is unreachable" - don't trust the quick-settings icon alone),
   relaunch, and confirm the map renders fully - roads, buildings, water,
   parks, and place-name labels - on both the live tracking screen and the
   past-ride detail screen.

## Keeping the bbox in sync

`BaghdadRegion` (`lib/services/map_tile_service.dart`) is the single source
of truth for the bbox - `tool/routing_import/build_routing_graph.py` already
depends on it matching for the routing graph, and this capture's `bounds`
must match it too. If `BaghdadRegion` ever changes, rerun this procedure.
