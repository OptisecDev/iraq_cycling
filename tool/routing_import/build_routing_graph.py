#!/usr/bin/env python3
"""Build-time tool: OSM (Overpass) -> routing_nodes/routing_edges/place_names db.

Not on-device logic. Run this during development to produce a prebuilt
sqlite database matching the routing_nodes/routing_edges schema created in
lib/services/app_database.dart (_createRoutingGraphTables) and the
place_names schema (_createPlaceNamesTable), appDbVersion 6.
Ship the output as a build-time asset copied into place on first app run,
the same way it's documented under "خط أنابيب بيانات التوجيه" in
PROJECT_STATE.md.

place_names is a name-search index over the *same* already-fetched named
ways (streets/squares) - no separate Overpass query for POIs/amenities.
One row per unique name: when a street is split into many OSM way
segments (common for long streets), the longest segment (by node count
inside BBOX) is picked as that name's representative point, so search
results stay one-per-name instead of dozens of near-duplicates.

Usage:
    python3 build_routing_graph.py --fetch -o baghdad_routing.db
    python3 build_routing_graph.py -i baghdad_osm_raw.json -o baghdad_routing.db
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import sys
import urllib.parse
import urllib.request
from pathlib import Path

# Must match BaghdadRegion in lib/services/map_tile_service.dart.
BBOX = (33.0, 44.1, 33.6, 44.6)  # min_lat, min_lon, max_lat, max_lon

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

OVERPASS_QUERY = f"""
[out:json][timeout:300][bbox:{BBOX[0]},{BBOX[1]},{BBOX[2]},{BBOX[3]}];
(
  way["highway"];
  way["cycleway"];
);
out body geom;
>;
out skel qt;
""".strip()

# Same formula/constant as lib/utils/distance_calculator.dart
# (DistanceCalculator.haversineDistance) - kept identical deliberately so
# there is only one great-circle distance formula in the whole app.
EARTH_RADIUS_METERS = 6371000


def haversine_distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    d_lat = math.radians(lat2 - lat1)
    d_lon = math.radians(lon2 - lon1)
    a = (
        math.sin(d_lat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(d_lon / 2) ** 2
    )
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return EARTH_RADIUS_METERS * c


def fetch_overpass_data(url: str = OVERPASS_URL) -> dict:
    req = urllib.request.Request(
        url,
        data=f"data={urllib.parse.quote(OVERPASS_QUERY)}".encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=580) as resp:
        return json.loads(resp.read())


def cycleway_value(tags: dict) -> str | None:
    """cycleway / cycleway:both, else combine cycleway:left / :right.

    OSM sometimes splits cycle-lane tagging by side of the road instead of
    a single `cycleway=*` tag.
    """
    direct = tags.get("cycleway") or tags.get("cycleway:both")
    if direct:
        return direct
    left = tags.get("cycleway:left")
    right = tags.get("cycleway:right")
    parts = []
    if left:
        parts.append(f"left:{left}")
    if right:
        parts.append(f"right:{right}")
    return ",".join(parts) if parts else None


def way_direction(tags: dict) -> str:
    """'forward' | 'reverse' | 'both'.

    oneway:bicycle takes priority over the general oneway tag: a street
    that's one-way for cars can still be legally contraflow for bicycles
    (this app is bicycle-only, so that distinction matters here).
    """
    bicycle = tags.get("oneway:bicycle")
    if bicycle == "yes":
        return "forward"
    if bicycle == "-1":
        return "reverse"
    if bicycle == "no":
        return "both"

    general = tags.get("oneway")
    if general == "yes":
        return "forward"
    if general == "-1":
        return "reverse"
    return "both"


def build_edges(way: dict, node_coords: dict[int, tuple[float, float]]):
    """Yield (from_id, to_id, distance_meters) directed edge tuples for one way."""
    tags = way.get("tags", {})
    direction = way_direction(tags)
    node_ids = way.get("nodes", [])

    for a, b in zip(node_ids, node_ids[1:]):
        if a not in node_coords or b not in node_coords:
            continue  # node outside the fetched set; skip this segment only
        lat1, lon1 = node_coords[a]
        lat2, lon2 = node_coords[b]
        dist = haversine_distance(lat1, lon1, lat2, lon2)

        if direction == "forward":
            yield (a, b, dist)
        elif direction == "reverse":
            yield (b, a, dist)
        else:
            yield (a, b, dist)
            yield (b, a, dist)


ROUTING_NODES_DDL = """
CREATE TABLE IF NOT EXISTS routing_nodes (
  id INTEGER PRIMARY KEY,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL
)
"""

ROUTING_EDGES_DDL = """
CREATE TABLE IF NOT EXISTS routing_edges (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  from_node_id INTEGER NOT NULL,
  to_node_id INTEGER NOT NULL,
  osm_way_id INTEGER NOT NULL,
  highway_type TEXT NOT NULL,
  cycleway TEXT,
  surface TEXT,
  oneway INTEGER NOT NULL DEFAULT 0,
  distance_meters REAL NOT NULL,
  weight REAL NOT NULL,
  FOREIGN KEY (from_node_id) REFERENCES routing_nodes (id) ON DELETE CASCADE,
  FOREIGN KEY (to_node_id) REFERENCES routing_nodes (id) ON DELETE CASCADE
)
"""

ROUTING_EDGES_INDEXES = [
    "CREATE INDEX IF NOT EXISTS idx_routing_edges_from_node ON routing_edges (from_node_id)",
    "CREATE INDEX IF NOT EXISTS idx_routing_edges_to_node ON routing_edges (to_node_id)",
    "CREATE INDEX IF NOT EXISTS idx_routing_edges_osm_way ON routing_edges (osm_way_id)",
]

PLACE_NAMES_DDL = """
CREATE TABLE IF NOT EXISTS place_names (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  name_normalized TEXT NOT NULL,
  latitude REAL NOT NULL,
  longitude REAL NOT NULL,
  osm_way_id INTEGER NOT NULL
)
"""

PLACE_NAMES_INDEX = (
    "CREATE INDEX IF NOT EXISTS idx_place_names_normalized "
    "ON place_names (name_normalized)"
)

# Tashkeel/diacritics + tatweel (kashida) - stripped entirely rather than
# mapped, since they carry no distinguishing meaning for search matching.
_ARABIC_DIACRITICS_RE = re.compile(r"[\u064B-\u065F\u0670\u0640]")

# Alef variants -> bare alef, alef maksura -> yeh, taa marbuta -> haa: the
# standard normalization for loose Arabic text search, since Baghdad street
# names are inconsistently tagged across these forms in OSM.
_ARABIC_CHAR_MAP = str.maketrans(
    {"أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه"}
)


def normalize_arabic_name(name: str) -> str:
    """Normalizes a place name for loose search matching.

    Mirrors lib/utils/arabic_text.dart's normalizeArabic() exactly - this is
    what gets indexed here, and that's what a search query gets normalized
    with at query time, so the two must stay in sync.
    """
    text = _ARABIC_DIACRITICS_RE.sub("", name)
    text = text.translate(_ARABIC_CHAR_MAP)
    return " ".join(text.split()).strip().lower()


def extract_place_names(ways: list[dict]) -> list[tuple[str, str, float, float, int]]:
    """One (name, name_normalized, latitude, longitude, osm_way_id) row per
    unique named way, using the longest-inside-BBOX segment as each name's
    representative point (see module docstring)."""
    min_lat, min_lon, max_lat, max_lon = BBOX
    candidates: dict[str, tuple[int, list[dict]]] = {}

    for way in ways:
        name = way.get("tags", {}).get("name")
        if not name:
            continue
        filtered = [
            pt
            for pt in way.get("geometry") or []
            if pt and min_lat <= pt["lat"] <= max_lat and min_lon <= pt["lon"] <= max_lon
        ]
        if not filtered:
            continue  # way only clips through the edge of BBOX; not a local street
        existing = candidates.get(name)
        if existing is None or len(filtered) > len(existing[1]):
            candidates[name] = (way["id"], filtered)

    rows = []
    for name, (way_id, filtered) in candidates.items():
        midpoint = filtered[len(filtered) // 2]
        rows.append(
            (name, normalize_arabic_name(name), midpoint["lat"], midpoint["lon"], way_id)
        )
    return rows


def build_database(osm_data: dict, out_path: Path) -> tuple[int, int, int]:
    elements = osm_data["elements"]
    ways = [e for e in elements if e["type"] == "way"]
    nodes = [e for e in elements if e["type"] == "node"]

    # Overpass's [bbox:...] filter selects any way that *intersects* the
    # box, then returns that way's full, unclipped node list - so a way
    # crossing the boundary drags in nodes well outside BBOX. Filter those
    # back out here so the shipped graph stays scoped to BaghdadRegion as
    # intended; edges with an endpoint outside the box are dropped below
    # (via the "not in node_coords" check in build_edges).
    min_lat, min_lon, max_lat, max_lon = BBOX
    node_coords = {
        n["id"]: (n["lat"], n["lon"])
        for n in nodes
        if min_lat <= n["lat"] <= max_lat and min_lon <= n["lon"] <= max_lon
    }

    if out_path.exists():
        out_path.unlink()

    conn = sqlite3.connect(out_path)
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute(ROUTING_NODES_DDL)
    conn.execute(ROUTING_EDGES_DDL)
    for stmt in ROUTING_EDGES_INDEXES:
        conn.execute(stmt)
    conn.execute(PLACE_NAMES_DDL)
    conn.execute(PLACE_NAMES_INDEX)

    used_node_ids: set[int] = set()
    edge_rows = []

    for way in ways:
        tags = way.get("tags", {})
        highway_type = tags.get("highway") or "cycleway"
        cycleway = cycleway_value(tags)
        surface = tags.get("surface")
        direction = way_direction(tags)
        oneway_flag = 0 if direction == "both" else 1

        for from_id, to_id, dist in build_edges(way, node_coords):
            used_node_ids.add(from_id)
            used_node_ids.add(to_id)
            weight = dist  # neutral initial value; coefficient table is a
            # separate decision deferred per PROJECT_STATE.md (needs a real
            # cyclist's input on road-type/surface preference, not made-up
            # numbers).
            edge_rows.append(
                (
                    from_id,
                    to_id,
                    way["id"],
                    highway_type,
                    cycleway,
                    surface,
                    oneway_flag,
                    dist,
                    weight,
                )
            )

    node_rows = [
        (nid, node_coords[nid][0], node_coords[nid][1])
        for nid in used_node_ids
        if nid in node_coords
    ]
    place_rows = extract_place_names(ways)

    with conn:
        conn.executemany(
            "INSERT OR IGNORE INTO routing_nodes (id, latitude, longitude) VALUES (?, ?, ?)",
            node_rows,
        )
        conn.executemany(
            """
            INSERT INTO routing_edges
              (from_node_id, to_node_id, osm_way_id, highway_type, cycleway,
               surface, oneway, distance_meters, weight)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            edge_rows,
        )
        conn.executemany(
            """
            INSERT INTO place_names
              (name, name_normalized, latitude, longitude, osm_way_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            place_rows,
        )

    node_count = conn.execute("SELECT COUNT(*) FROM routing_nodes").fetchone()[0]
    edge_count = conn.execute("SELECT COUNT(*) FROM routing_edges").fetchone()[0]
    place_count = conn.execute("SELECT COUNT(*) FROM place_names").fetchone()[0]
    conn.close()
    return node_count, edge_count, place_count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-i", "--input", type=Path, help="Pre-fetched Overpass JSON response"
    )
    parser.add_argument(
        "--fetch", action="store_true", help="Fetch fresh data from Overpass API"
    )
    parser.add_argument(
        "-o", "--output", type=Path, required=True, help="Output sqlite db path"
    )
    args = parser.parse_args()

    if args.fetch:
        print(f"Fetching OSM data from {OVERPASS_URL} for bbox {BBOX} ...", file=sys.stderr)
        osm_data = fetch_overpass_data()
    elif args.input:
        with args.input.open() as f:
            osm_data = json.load(f)
    else:
        parser.error("must pass either --fetch or -i/--input")
        return 2

    node_count, edge_count, place_count = build_database(osm_data, args.output)
    size_bytes = args.output.stat().st_size

    print(f"routing_nodes: {node_count}")
    print(f"routing_edges: {edge_count}")
    print(f"place_names: {place_count}")
    print(f"output: {args.output} ({size_bytes:,} bytes / {size_bytes / 1024 / 1024:.2f} MiB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
