# Resource map: notes and technical debt

Running notes for the printout feature on `feat/resource-map`. This records
anything we may need to revisit: guesses, known limits, untested assumptions and
decisions we put off. Add to it as work goes on, and remove entries once resolved.

**Goal:** on the printout, show resources on a map with distance and estimated
travel time from the user's location.

## Decisions to revisit

| Decision | Current choice | Why it may change |
|---|---|---|
| Minimum geocoder score | 90 (`Geocoder::MINIMUM_SCORE`) | Based on about 30 test addresses. My first guess of 80 would have accepted `123 Fake Street, Victoria, BC`, which scored 88 and matched a house on Salt Spring Island. Revisit if real resources are rejected or pinned in the wrong place. |
| Assuming Victoria for typed places | `FlyerOrigin` adds `, Victoria, BC` unless the text has a comma | The score drops without a city (`919 Pandora Ave` alone gets 89). Adding Victoria still found Saanich and Esquimalt addresses in testing, but a place elsewhere in BC typed without a city could match the wrong one. |
| Printing during a geocoder outage | Print the guide without distances, with a note saying why | Chosen so an outside service can't block someone getting a guide. The alternative is an error asking them to try again. |
| Accepted match types | `SITE`, `UNIT`, `CIVIC_NUMBER`, `BLOCK`, `INTERSECTION` | `BLOCK` is needed for 2916 Douglas St, but places a pin on the block rather than the building. |
| Travel time | Walking only, straight-line, at 5 km/h (1 km ≈ 12 min) | Real routes are longer, especially around the Inner Harbour and the Gorge. Accurate times would need a routing engine or paid service. The pace may also be too fast for many of the people using these guides. |
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
- **Git LFS for tiles:** not decided. Tiles could reach 60–150 MB (an estimate, not
  measured). LFS needs GitHub storage quota, and all developers, CI and Docker
  builds would need it set up. Decide before the tile commit, because large files
  are hard to remove from git history.
- **Real data coverage:** we've only tested the 20-resource sample. We don't know
  how many production resources have usable street addresses.

## Known limitations

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
- Rainbow Kitchen is listed under Victoria, but the geocoder places it in Esquimalt.
  The match looks right, but the printed city would be wrong.

### Map (not built yet)

- Downtown pins will crowd together. Many resources are within a few blocks of each
  other, and several in the sample share an address (713 Johnson St). A downtown
  inset may be needed.
- A long legend could push the map section past one page.
- Tiles and PDF size: the size of each PDF and the time to generate it are unmeasured.
- Prawn has no public clipping method, so cropping tiles needs a small low-level PDF
  operator.
- Every map page must credit "© OpenStreetMap contributors".

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
- **Not installed yet:** Docker (via `colima`), `osmium`, `tilemaker` and Git LFS.
  All are only needed for building tiles.
- **`trufflehog`:** the pre-commit hook needs it. It's 3.99.8 locally and 3.99.7 in CI.
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
