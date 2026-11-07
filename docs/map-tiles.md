# Rebuilding the map tiles

The printable guide's map is drawn from image tiles stored in `lib/map_tiles/`.
`script/build_map_tiles` makes them from OpenStreetMap data. You only run it by hand, and
rarely. The app just reads the finished PNGs, so running or deploying it never needs Docker,
a map server or a network call for maps.

## When to rebuild

- The streets are out of date enough to matter. The tiles are a snapshot, and
  `lib/map_tiles/manifest.json` records its dates.
- You want a different area or different zoom levels.
- You want a different look.

**Current debt:** the coastline came from an unofficial January 2022 copy, because the
official host was down. Rebuild once it's back. See `docs/resource-map-notes.md`.

**Rebuilding has a lasting cost.** The tiles are about 55 MB in plain git, and each rebuild that
changes them adds up to that much to the repo's history permanently. Don't rebuild casually.

## What you need

- About 6 GB of free disk. BC's map data and the coastline data are each over 1 GB, and
  the container images are about 1.6 GB. All of it is deleted when the build ends.
- `colima`, `docker` and `osmium-tool`, from `brew install colima docker osmium-tool`. Also
  `curl`, `jq`, `awk` and `unzip`.
- Internet access to `download.geofabrik.de`, `osmdata.openstreetmap.de`,
  `raw.githubusercontent.com`, Docker Hub and `ghcr.io`.

The UVic VPN isn't needed. `tilemaker` and `tileserver-gl` run from container images that
the script pins by digest, so you don't install them yourself.

## Steps

1. Start Docker, with enough memory for BC's map data:

   ```sh
   colima start --memory 6 --cpu 4
   ```

2. Build into a temporary folder, so you can check the result first:

   ```sh
   script/build_map_tiles tmp/map_tiles
   ```

   This took about 10.5 minutes with a local copy of the coastline, on an 8-core Apple
   Silicon Mac. Downloading the coastline from the official host adds time that hasn't been
   measured yet.

3. Stop Docker. The second command is optional and frees about 1.3 GB:

   ```sh
   colima stop
   colima delete
   ```

4. Check the result, as described below.

5. Replace the stored tiles, then make sure the code still works with them:

   ```sh
   rm -rf lib/map_tiles && mv tmp/map_tiles lib/map_tiles
   bundle exec rspec
   ```

6. Print a real guide and check the map page. Specs can't judge how it looks on paper.

7. Commit the tiles and `manifest.json` together. The pre-commit hook scans every file, so
   it can take a moment. `trufflehog` must be on your path.

## What to check

The script stops with an error if a tile is missing or the sea didn't get drawn. It can't judge
how the map looks, so open a few tiles and check by eye. Downtown Victoria is:

| Zoom | Tile | What it should show |
|---|---|---|
| 12 | `12/644/1416.png` | The whole city, with water clearly darker than land |
| 15 | `15/5154/11332.png` | Downtown, with most street names |
| 16 | `16/10309/22664.png` | Pandora, Johnson and Yates, with clear labels |

Also check that:

- The coastline looks right around the Inner Harbour, the Gorge and Esquimalt.
- The tile count and size in the script's final summary are close to the last build:
  4,470 tiles, about 55 MB.
- `manifest.json` has the expected dates and sources.
- Credits still print on the map page exactly as `attribution` says in the manifest.

## How the build works

| Step | Tool | What it does |
|---|---|---|
| 1 | `curl` | Downloads British Columbia from Geofabrik and checks its checksum |
| 2 | `osmium` | Cuts out the Greater Victoria area |
| 3 | `curl` | Gets the world's sea polygons, because OpenStreetMap stores coastlines only as lines |
| 4 | `tilemaker` | Turns that data into vector tiles: shapes, not pictures yet |
| 5 | `curl`, `jq` | Downloads the Positron style and adapts it for offline, print-friendly rendering |
| 6 | `tileserver-gl` | Draws every tile as a 512 × 512 PNG, through a temporary local server |
| 7 | `sharp` | Compresses the tiles to greyscale palette PNGs |
| 8 | The script | Checks the sea really was drawn |
| 9 | The script | Checks nothing is missing, then writes `manifest.json` |

We make our own tiles because OpenStreetMap's tile servers forbid bulk downloads. The map data
itself is free to use.

## Changing what gets built

These settings are named variables near the top of `script/build_map_tiles`:

- **Area:** `WHOLE_AREA_BBOX`, as west,south,east,north.
- **Zoom levels:** `WHOLE_AREA_MIN_ZOOM` and `WHOLE_AREA_MAX_ZOOM`.
- **Most detailed zoom:** `URBAN_CORE_BBOX`, with its own min and max. Zoom 16 has four times
  the tiles of zoom 15, so it covers only the urban core.
- **Look:** the `patch_style` function and `GREY_LEVELS`.

Each extra zoom level has about four times as many tiles as the one before, so check the size.
If you change the area or zooms, also check that `MapView` still gets the coverage it expects.

## Options

These are environment variables, and all of them are optional:

| Variable | Use |
|---|---|
| `WATER_POLYGONS_DIR` | Use a local copy of the sea polygons instead of downloading. Needs `water_polygons.shp`, `.shx` and `.dbf`. Also set `WATER_POLYGONS_SOURCE` and `WATER_POLYGONS_DATE`, for the manifest |
| `MAP_TILES_WORK_DIR` | Keep the work folder and skip finished steps, for debugging. Delete a step's `.done.*` file to redo it |
| `RENDER_JOBS` | How many tiles to render at once. Defaults to 6 |
| `MINIMUM_FREE_GB` | Disk space required to start. Defaults to 6 |

## Problems we hit

- **`osmdata.openstreetmap.de` won't connect.** It was down for the whole first build, including
  from a separate network. A rerun stops with a clear error until it's back. To continue
  without it, you'd need your own copy of the sea polygons and `WATER_POLYGONS_DIR`. The script's
  official download path has never run against the real host, so watch it on the first run.
- **The sea is missing, but tools report success.** Without a `.dbf`, `tilemaker` silently skips
  the whole shapefile. The script now requires that file and checks open-water tiles.
- **Town labels get sliced at tile edges.** `tileMargin: 256` fixes this, at the cost of slower
  rendering. Keep it.
- **Docker can't pull images because of a credential helper.** Docker configs that name a helper
  that isn't installed break even anonymous pulls. The script uses its own empty config for
  this, and leaves yours alone.
- **`colima stop` changes your Docker context.** It can leave it on `default`. If you normally
  use another one, switch back with `docker context use <name>`.
- **"Only N GB free".** This is the script's own disk check. Free up space, or lower
  `MINIMUM_FREE_GB` if you're sure there's enough.
- **Don't put tiles in `vendor/`.** The app's Dockerfile has `COPY vendor/* ./vendor/`, which flattens
  folders and invalidates its gem cache. `tmp/` doesn't work either, because deploys exclude it.

## Credits and licences

Print this near the map, exactly as written. It's in the manifest as `attribution`:

```text
© OpenMapTiles © OpenStreetMap contributors
```

The Positron style is CC BY 4.0, and we changed it. Its credit is in the manifest as
`style_credit`, and should appear somewhere readers can find it. The sea polygons' own licence
section hasn't been checked. Check it when moving to the official download.
