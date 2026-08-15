# Baghdad offline vector-tile build

Build-time tool: OSM -> `assets/vector_tiles/baghdad.pmtiles`, the bundled
zero-connectivity basemap `MapTileService`/`VectorTileSourceResolver` fall
back to when there's no cached or live tile available (see those classes'
doc comments for the full online/offline precedence).

Not run by the app or CI. Run it manually whenever the bundled basemap needs
refreshing, the same way `tool/routing_import/build_routing_graph.py`
documents its own OSM pipeline.

## Why these tools

- [Planetiler](https://github.com/onthegomap/planetiler), run against
  `baghdad_offline_schema.yml` in this directory - a **custom** schema
  (Planetiler's `generate-custom` mode), not its bundled default OpenMapTiles
  profile. The default profile also pulls in ~1.5GB of global auxiliary
  datasets (ocean water polygons, natural-earth low-zoom shading, lake
  centerlines) that a landlocked, zoom-10-17-only city basemap has no use
  for - `baghdad_offline_schema.yml` sources everything from the OSM extract
  alone (roads, water, buildings, landuse, place labels), which is why this
  build finishes in well under a minute instead of the better part of an
  hour, and produces a ~9MB archive.
- The schema deliberately reuses OpenMapTiles' layer/attribute naming
  (`transportation`/`class`, `water`, `building`, `place`/`class`, etc.,
  though not its full per-feature classification detail) so the same
  `assets/map_style/baghdad_style.json` renders both this bundled archive
  and the online OpenFreeMap (real OpenMapTiles-schema) source without a
  visual mismatch - see that file's `sources.openmaptiles` for the shared
  contract. Layers/attributes this schema doesn't populate (POI icons,
  landcover shading, admin boundaries, 3D building extrusion height, etc.)
  simply don't render; the important layers for a cycling nav basemap -
  roads (including cycleways/paths), water, buildings, place labels - do.
- Planetiler requires **Java 21+**. If the system default `java` is older
  (this repo was built against a system defaulting to Java 17), point at a
  newer JDK explicitly, e.g. `/usr/lib/jvm/java-25-openjdk/bin/java`.

## Steps

1. Download an OSM extract covering Baghdad. Iraq's whole-country extract
   from Geofabrik is small (~90MB) and simplest - no need to hunt for a
   city-level extract:

   ```
   curl -L -o iraq-latest.osm.pbf \
     https://download.geofabrik.de/asia/iraq-latest.osm.pbf
   ```

2. Download Planetiler:

   ```
   curl -L -o planetiler.jar \
     https://github.com/onthegomap/planetiler/releases/latest/download/planetiler.jar
   ```

3. Edit `baghdad_offline_schema.yml`'s `sources.osm.local_path` to point at
   wherever you downloaded the extract in step 1, then run Planetiler in
   `generate-custom` mode, clipping output to `BaghdadRegion`'s bbox (must
   match `BaghdadRegion` in `lib/services/map_tile_service.dart` -
   `min_lon,min_lat,max_lon,max_lat`) and the same max zoom (14 - vector
   tiles overzoom cleanly client-side, so 14 covers the app's 10-17 display
   range same as the old raster pipeline did explicitly per-zoom):

   ```
   java -jar planetiler.jar generate-custom \
     --schema=baghdad_offline_schema.yml \
     --bounds=44.1,33.0,44.6,33.6 \
     --output=baghdad.pmtiles \
     --minzoom=0 --maxzoom=14 \
     --force
   ```

4. Copy the result into the app:

   ```
   cp baghdad.pmtiles ../../assets/vector_tiles/baghdad.pmtiles
   ```

## Keeping the bbox in sync

`BaghdadRegion` (`lib/services/map_tile_service.dart`) is the single
source of truth for the bbox - `tool/routing_import/build_routing_graph.py`
already depends on it matching for the routing graph, and this pipeline's
`--bounds` must match it too. If `BaghdadRegion` ever changes, rerun step 3
(step 1/2's downloads don't need repeating).

## If richer detail is ever needed later

Switching back to Planetiler's bundled OpenMapTiles profile (drop
`generate-custom --schema=...`, pass `--osm_path=` directly, add
`--download` to fetch the three auxiliary datasets) would add POI icons,
landcover shading, admin boundaries, and full building-height 3D extrusion,
at the cost of the slow one-time global-dataset download described above.
Not needed for the current bundled-fallback use case, which prioritizes a
small asset size and a fast, self-contained rebuild.
