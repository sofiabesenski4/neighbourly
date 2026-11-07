# Resource map: notes and technical debt

Running notes for the printout feature on `feat/resource-map`. This records
anything we may need to revisit: guesses, known limits, untested assumptions and
decisions we put off. Add to it as work goes on, and remove entries once resolved.

**Goal:** on the printout, show resources on a map with distance and estimated
travel time from the user's location.

## Plan

### Where things stand

Branch `feat/resource-map`, built on `main`, pushed with no PR opened yet.

| Done and committed | Commit |
|---|---|
| Geocode resources on save, and a backfill task (`bin/rails resources:geocode`) | `561118d`, `79c6304` |
| Distance and walking time on printed cards | `6544911` |
| Location screen before the builder, with distances in the live preview | `3d84855`, `5e7be6c` |
| Walking times allow for streets (× 1.3) | `d01589e` |
| Scanner fix in the pre-commit hook | `7bfda9f` |
| Stored tiles in `lib/map_tiles/`, the build script, and `docs/map-tiles.md` | `6e5a63b` |
| `MapProjection`, `MapView` and `MapPinLayout` | `d9c3439` |
| Final map page with numbered pins (`FlyerMapPage`, `MapTileSet`, `docs/printed-map.md`) | "Print a map with pins numbered to match the cards" |
| Border arrows for off-map resources | "Point to off-map resources from the map's border" |
| "You are here" marker | "Mark the chosen location on the printed map" |

**The planned map is finished.** Only the decisions and checks below remain.

### How to work (the user's rules)

- **Never commit until the user has reviewed and approved that commit.** "Go" means start the
  work, not commit it. Stage it, open the changed files in VS Code, explain them, and wait.
  `code` isn't on PATH: use `"/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" -r <files>`.
- Commits are atomic in the team lead's sense: one complete change in behaviour, with its
  frontend and specs, so one revert removes it. If describing it needs "and", split it.
- Write detailed comments. Explain new files by purpose and how they fit the architecture, and
  existing files by what the whole file does and then what changed.
- Ask before installing anything, and never push unless asked. Keep this file updated as things
  come up. Use agents where work is independent. Keep replies short: the user is watching tokens.
- Before browser specs, run `yarn build`. They use real Chrome and need current JavaScript.

### Next

**Later (the user wants this, approach not chosen):** change the map's area for guides where the
fixed view doesn't work. Either zoom out when the location isn't in range, or zoom to where the
pins are. Today it's always 1.3 km around the location or downtown, and a location with no tiles
gets downtown. See `docs/printed-map.md`, and note that zooming out loses street names below zoom 15.

**Map direction (the user's preference):** a map zoomed in enough to read, showing downtown or
the area around the chosen location, not one that fits everything. Everything else gets an
arrow at the border. Keep all the zoom levels: dropping 11–13 saves only 3.4 MB.

**Check on real printouts:** how merged arrows read, and pin and arrow sizes on actual paper. So far the
map has only been viewed on screen.

### Testing locally

- Start the app with `bin/rails server -p 3000`, and open `/flyers/new` in Chrome.
- The development database has the 20-resource sample loaded, under the source "Sample: street
  survival guide". Delete that source when it's no longer needed.
- Saving or importing resources needs the UVic VPN, for embeddings. "Use my location" may fail on
  the VPN, and failed in Brave. Printing and the geocoder need neither.

### Not done yet

The team still needs to decide on confidential addresses before the map ships, which the user
set aside for now. Coastline data should be rebuilt once the official host is back. The branch
hasn't had a PR opened.

The design mockup and proposal are older than this plan. Where they differ, this plan wins.

## Decisions to revisit

| Decision | Current choice | Why it may change |
|---|---|---|
| Minimum geocoder score | 90 (`Geocoder::MINIMUM_SCORE`) | Based on about 30 test addresses. My first guess of 80 would have accepted `123 Fake Street, Victoria, BC`, which scored 88 and matched a house on Salt Spring Island. Revisit if real resources are rejected or pinned in the wrong place. |
| Assuming Victoria for typed places | `FlyerOrigin` adds `, Victoria, BC` unless the text has a comma | The score drops without a city (`919 Pandora Ave` alone gets 89). Adding Victoria still found Saanich and Esquimalt addresses in testing, but a place elsewhere in BC typed without a city could match the wrong one. |
| Printing during a geocoder outage | Print the guide without distances, with a note saying why | Chosen so an outside service can't block someone getting a guide. The alternative is an error asking them to try again. |
| Accepted match types | `SITE`, `UNIT`, `CIVIC_NUMBER`, `BLOCK`, `INTERSECTION` | `BLOCK` is needed for 2916 Douglas St, but places a pin on the block rather than the building. |
| Travel time | Walking only: straight-line distance × 1.3 for following streets, at 5 km/h (1 km ≈ 16 min) | 1.3 (`ResourceCard::STREET_ROUTE_FACTOR`) comes from grid geometry and hasn't been measured against Victoria's streets. Accurate times would need a routing engine or paid service. The pace may also be too fast for many of the people using these guides. |
| Map tile source | Render our own from OpenStreetMap data | Not tried yet. OpenStreetMap's own tile servers forbid bulk downloads. If rendering is too much work, the fallback is drawing a plain map ourselves. |
| Google Maps | Not used | Its terms forbid storing tiles and restrict caching geocodes. It also needs billing, and it keeps search terms, IP addresses and coordinates. |

## Open questions

- **Confidential addresses:** set aside for now at the project's request. Some
  shelters, such as transition houses, keep their locations private, and a pin on
  a public flyer could put people in danger. The Cridge Transition House in the
  sample data has no street address, so it wouldn't get a pin, but nothing stops a
  private address being entered. The team should decide on a rule before the map
  ships.
- **Geocoder privacy:** we couldn't find whether the BC geocoder logs requests or
  how long it keeps them. To find out, email DataBC at data@gov.bc.ca. This matters
  most for a location typed by the person printing, which should never be stored
  or logged on our side.
- **Geocoder limits:** the public limit is 1,000 requests a minute with no key. A
  free key gives higher limits if we ever need them. The code doesn't send a key.
- **Git LFS for tiles:** the tiles were committed in plain git, about 55 MB. LFS would need GitHub
  storage quota, and all developers, CI and Docker builds would need it set up. Check the team is
  OK with this before pushing, because large files are hard to remove from git history.
- **Real data coverage:** we've only tested the 20-resource sample. We don't know
  how many production resources have usable street addresses.

## Known limitations

### Walking times

- **Accepted debt: water.** Walking times don't allow for going around water. A resource
  just across the Inner Harbour or the Gorge can be a much longer walk than its printed
  time, because the route has to reach a bridge. We've chosen to accept this, and fixing
  it would need a routing engine.

### Geocoding

- A high score doesn't prove a match is right. We don't check that the match's
  city agrees with the resource's city, so a wrong match scoring 90 or above would
  still be accepted.
- Failed lookups aren't recorded. A resource with no trustworthy match is looked up
  again on every save that changes its metadata, and there's no way to list these
  resources for someone to fix.
- The retry window is short. During a simulated outage, a job made 5 attempts over about
  6 minutes (waits of roughly 3, 20, 90 and 260 seconds), then failed for good. An
  outage longer than that leaves resources without coordinates until a later save or
  a rerun of `bin/rails resources:geocode`, and nothing tells anyone to rerun it. The
  only trace is a row in `solid_queue_failed_executions`, which stays after the rerun
  succeeds. Consider a longer retry window, or an alert, if outages turn out to be common.
- `bin/rails resources:geocode` only queues jobs and doesn't report how many lookups
  succeed. In development it needs `SOLID_QUEUE_IN_PUMA=1` and a running server,
  because in-process jobs are lost when the task exits.
- Imported coordinates are only checked for being numbers, not for being a real
  location. A latitude of 999 would be accepted, and later distance calculations
  would be wrong.
- Resources saved with no city score lower, because `Document#geocoding_query` sends
  `address, BC`. In testing, `919 Pandora Ave, BC` scored exactly 90 and `919 Pandora, BC`
  scored 84, so a resource with no city and a shortened address gets no coordinates.
- Typed locations don't support landmarks or shorthand. `Central Library`, `UVic` and
  neighbourhoods like `Fernwood` don't match, and `Douglas & Yates` scores 88 even
  though it finds the right intersection. People get an error with examples of what
  works. A slightly lower minimum for intersections might fix the shorthand.
- The printout's note repeats what was typed, not the address the geocoder matched, so
  a reader can't see if a typed place matched somewhere unexpected.
- The typed location appears in the generated PDF. It's the person's own document, but
  a printout left behind would show it.
- Each printout with a location makes one geocoder call. A slow reply can add up to about
  10 seconds (5 to connect and 5 to read) before it prints without distances.
- `limits_concurrency` only works with Solid Queue. Development uses Solid Queue
  only when `SOLID_QUEUE_IN_PUMA=1`. Otherwise jobs run on Rails' default in-process
  adapter, with no one-at-a-time limit, and queued jobs are lost on restart.
- `geocoder_spec.rb` uses fake replies modelled on real ones, so it can't detect the
  real service changing its format. The live checks so far were one-offs, not part
  of the suite: the 20-resource sample was imported with real embeddings and Solid
  Queue workers, then backfilled. Both paths gave coordinates to 19 with no failed
  jobs, and ran one job at a time. The other, The Cridge Transition House, has no
  street address. Retries were also checked with Solid Queue workers by making the
  connection fail: the job gave up after 5 attempts with the resource intact, a queued
  retry succeeded once the connection returned, and the backfill recovered the job that
  had given up. Only refused connections were tried this way. Timeouts and error replies
  are covered by specs only, and no automated test covers the worker path.

### Sample data

- The sample's notes come from a 2022 guide, so hours and intake details may be out
  of date.
- Some addresses contain notes, such as "(around back)" and "(location may change)".
  The geocoder ignored these in testing, but they stay in the printed address as is.
- Most sample resources don't land in a category. When imported into development, 13 of
  the 20 printed under "Other resources", because their labels (such as "Emergency shelter")
  aren't exact names in the categories table. Real imports may need a mapping.
- Rainbow Kitchen is listed under Victoria, but the geocoder places it in Esquimalt.
  The match looks right, but the printed city would be wrong.

### Map tiles

- **Replace the coastline data.** The official host (`osmdata.openstreetmap.de`) was down for
  the whole build, so the water comes from an unofficial January 2022 copy at Ifremer, and
  its `.dbf` was regenerated locally, holding no geography. Streets are from 5 Nov 2026.
  Nothing looked wrong downtown, but it wasn't compared against current data. Rebuild when
  the official host is back. The copy was deleted, so a rerun needs that host, and the
  script's official-download path has never run for real.
- 4,470 tiles, about 55 MB, kept in plain git at `lib/map_tiles/`. Not `vendor/`, because the
  Dockerfile's `COPY vendor/* ./vendor/` flattens folders and invalidates its gem cache, and
  not `tmp/`, which deploys exclude. Rebuilding adds another copy to git history forever, so
  rebuild rarely. Zooms 11–13 total only 3.4 MB, so dropping them saves little.
- Credit must read `© OpenMapTiles © OpenStreetMap contributors`, near the printed map. The
  manifest also has a `style_credit` for the Positron style, which should be somewhere readers
  can find it. The water polygons' own license wasn't checked.
- Seams line up, in the data and in a close-up of a rendered PDF. A scan flagged 104 of 8,671,
  of which the 3 worst viewed were just labels ending on a seam.
- Map content quirks: no US roads, so San Juan Island is a bare coastline at the edge; "Sidney"
  is missing at zoom 11; a ferry label reads "PORT ANGELES VICTORIA" over the water; and marina
  dock letters appear at zoom 15. Most street names only appear by zoom 15.
- The tile build needs about 6 GB free, and Homebrew's `colima` leaves about 1.3 GB in
  `~/.colima` after stopping. `colima delete` removes it.

### Map

- **An arrow's label can cover a pin near the border.** Labels only avoid each other. It didn't
  happen with the sample, but a covered pin hides its number, as pin 4 once was. Pins could be
  checked against labels too, if real data shows this.
- **One label collision merges arrows across the whole map.** The merge distance applies everywhere,
  so a crowded guide can merge arrows that weren't touching. A made-up guide of 24 resources in a
  ring went almost entirely to pairs.
- **A merged arrow's direction is an average.** Its resources can be in somewhat different
  directions, more so once labels have forced extra merging.
- **Arrow distances are from the map's centre.** That matches the cards, except for a location with
  no tiles: the map falls back to downtown, so arrows measure from downtown and cards from the
  location. A map centred somewhere with few resources nearby, such as UVic with the sample, shows
  only arrows.
- **The map's area doesn't depend on the guide's resources.** It's always the same radius around
  the chosen location or downtown, on stored tiles. Only the pins change with the resources, so a
  guide whose resources are all far from downtown prints a map with only arrows. This follows the
  "zoomed in, not fit everything" preference, and the user may revisit it.
- **Numbers belong to resources, not cards.** A resource in two categories keeps the number from
  its first card, so it has one pin. That means later categories can read out of order, such as
  "7, then 1". The user tried numbering every card 1 to n and chose this, to avoid repeated numbers
  on pins.
- **A pin at the chosen location can cover most of the "You are here" ring.** Pins are drawn on top
  so their numbers stay readable, and the label above still shows. With 919 Pandora Ave as the
  location, "4, 19" covers the ring and "15" touches the label. "You are here" could also be wrong
  for someone printing for another person, such as an outreach worker.
- **No number-to-name list.** The user compared both and removed it. It made the map short enough
  to drop to zoom 14, and readers can match a pin's number to a card.
- The user printed a guide from Chrome through the real screens, and the map centred on their
  location. That was on screen, not on paper.
- **A location with no tiles shows downtown instead.** The chosen fallback, rather than an empty
  box, but the page doesn't say so. A location partly on the tiles keeps its own map, with a blank
  part. The "You are here" marker shows on the partial map, but not on the downtown one.
- The radius is 1.3 km, not the 1.5–2 km first suggested. At 1.5 km the map drops to zoom 14,
  which has few street names. The frame must also stay tall enough: at about 470 pt it dropped to
  zoom 14, so anything printed under the map that takes much space costs the street names.
- Pins merge within 10 pt, up from 6. At 6, pin 4 printed almost entirely under pin 19. A merged
  pin can sit up to about 25 m from a real location at this zoom.
- The map adds real size: the 20-resource guide came to 1.4–1.7 MB and about 0.4 s to generate,
  at zoom 15. Printing it hasn't been tried.
- The live preview's cards have no numbers. The numbers only mean something next to the printed
  map, so they're printed only.
- `MapProjection`, `MapView` and `MapPinLayout` have now been checked against real tiles on screen,
  but not on paper. Still assumptions: 14 pt pins, 10 pt arrows, and a scale range of 0.6–1.2
  chosen to keep map text readable and tiles at 120 dpi or better.
- Near the edge of zoom 16's coverage, a small radius can leave a blank strip in the frame.
  A 30 m radius left 68 pt blank on the right of a 525 pt frame. A lower-zoom underlay or
  requiring coverage of the whole frame would fix it.
- A short frame makes the area-wide map too small to read: 525 × 400 pt gives about 4.5 pt
  map text, while 525 × 650 pt gives a usable scale. Plan the page around a tall map.
- `MapView` assumes the manifest has `min_zoom`, `max_zoom` and `zooms: {z => {south, west,
  north, east}}`, and that a tile exists if it overlaps those bounds. The tile build must
  match this. `FlyerMapPage` leaves a blank square for a missing file.
- Coverage of a centred map is checked using the rectangle around its circle, so a corner
  can trigger a less detailed zoom even when the circle itself fits.
- There's no wrapping across the 180° meridian. That's fine for Victoria, but an arrow for
  a resource very far away could point the long way round.
- Pins whose group would be too spread out stay separate, so downtown pins just over the
  merge distance will partly overlap.
- Downtown pins crowd but stay readable with the sample's 19. A guide with many more resources
  may need a downtown inset. Merged pins like "8, 9, 10" can cover a street name.
- A long "Not shown on map" list shrinks the map to 400 pt, then continues on another page.

### Choosing a location

- Coordinates are rounded to about 100 m and kept in the page, so the preview and printout
  share one lookup and show the same distances. If the geocoder is down on the first
  screen, the preview shows no distances but printing tries the lookup again, so in that
  one case a printout could have distances that the preview didn't.
- The preview's location goes in a POST body so it stays out of URLs and web server logs.
- Both screens share one URL and switch in the browser, which keeps addresses out of the
  URL and history. The browser's Back button leaves the page rather than going back a
  screen, so people need the Change button.
- The builder shows briefly before JavaScript hides it on a slow load, because without
  JavaScript both screens need to show.

### Device location

- A Mac can fail after permission is granted. Chrome on the development Mac got permission,
  then logged `CoreLocationProvider: kCLErrorLocationUnknown`, meaning macOS couldn't work
  out a position at that moment. Google Maps couldn't find the Mac either. The page shows
  "We couldn't find your location". It appeared to start working after the UVic VPN was
  turned off, so people on a VPN may hit this. Chrome's own Sensors panel can supply a
  fake position to test the flow.
- Brave couldn't get a location when tried on desktop. It's known for not using Google's
  location service the way Chrome does, though the exact reason wasn't confirmed. People
  there see the "couldn't find your location" message and can type a place.
- Accuracy varies. Laptops estimate from Wi-Fi and can be off by a neighbourhood or
  more. The page shows the browser's reported accuracy and warns from 1 km up, but
  that figure is itself an estimate.
- It's the device's location, not necessarily the reader's. An outreach worker or
  library computer printing for someone else should type a place instead.
- The location isn't limited to this region. Someone outside Greater Victoria gets very
  long distances, and a map of downtown (see Map above).
- A browser may remember the permission for the next person on a shared computer. We
  don't keep the location, but the next person can use the button without a prompt.
- Chrome may send nearby Wi-Fi networks to Google to work out the position. That's
  between the person and their browser, and the page mentions it.
- The real permission prompt is not tested. The browser specs set the permission
  directly, because a test can't click the browser's own prompt. It needs a manual try.

## Left out of scope

Not part of the current goal, but easy to add later:

- Address suggestions while typing. Skip them on the user's location field if added,
  so partial home addresses aren't sent to the geocoder as someone types.
- Walking-time rings on the map.
- Real walking routes, driving or transit times.

## Environment and tooling

- **Browser specs:** `spec/system/flyer_builder_live_spec.rb` needs Chrome and current
  JavaScript. Run `yarn build` first: `app/assets/builds` is git-ignored, and a stale
  build fails every example in that file with "expected to find css". Don't install
  Homebrew's `chromedriver` unless needed. Selenium downloaded a matching driver by
  itself, and Homebrew's was five major versions behind its Chrome when checked.
- **Tile build tools:** `colima`, `docker` and `osmium-tool` from Homebrew, used only to run
  `script/build_map_tiles`. The app never needs them. `tilemaker` and `tileserver-gl` run in
  containers pinned by digest in the script. Git LFS isn't used.
- **`trufflehog`:** the pre-commit hook needs it. It's 3.99.8 locally and 3.99.7 in CI. Its binary
  disappeared repeatedly around scans, blocking commits. Adding `--no-update` to the hook's
  command stopped that so far, but the cause wasn't proven. If it recurs, `brew reinstall trufflehog`.
- **Local data:** the development database has no documents.
- **Local embeddings need the UVic VPN:** the configured embedding service,
  `api-ailearninglab-prod.uvic.ca`, works on the VPN. Off the VPN, the call took over
  a minute to fail with `Faraday::ConnectionFailed`. Saving a resource needs an
  embedding, so saves and imports fail locally without the VPN.
  `Document#generate_embedding` only rescues `RubyLLM::Error`, so this error may surface
  as an unhandled exception rather than a form error. That code predates this work.

## Documentation to update

- **Proposal doc:** the shared proposal is out of date. It puts the map before
  distance and walking time, and says we'd store `geocoded_at` and `geocode_score`,
  which the code doesn't. Its tile estimate (zoom 13–15, about 30 MB) is superseded
  by zoom 11–16, and its plan to pin only with a confidential-address rule in place
  has been set aside for now.
- **Missing printout docs:** `docs/category-printouts.md` existed on the old printout
  branch but isn't on `main`. It held the promise that making a PDF needs no network
  calls. A typed location would be the first exception, so that rule should be written
  down somewhere.
