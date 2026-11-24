# Questionnaire: notes and open questions

Running notes for the guided questionnaire at `/find-help/myself`. This records decisions
and anything we may need to revisit. Remove entries once they're resolved.

## Decisions

- **The wording and groups in `config/questionnaire.yml` are a draft.** They'll be updated
  later. "Youth services" and "Indigenous services" describe people more than needs, so they
  may belong in a later question.
- **"Health" will include mental health once categories have parents.** PR #85 puts Mental
  Health Support under Health Care, and a search for a parent includes its children. "Mental
  health" stays available as its own narrower option. The team accepted this.
- **The questionnaire is built against `main`.** PR #85 adds its own printout handoff,
  `POST /printout/from-questionnaire`. That work will fit itself to this one later.
- **The route isn't named `new_questionnaire`.** PR #85 turns on a link as soon as a route
  with that name exists, before the questionnaire is ready to be linked to.
- **An answer with no option we know is refused, not ignored.** Ignoring it would mean
  searching for everything.
- **Answers travel with the question's key, not a step number.** Hiding a question would
  renumber the rest. A key that's no longer a question leads to the first one.
- **Going back with an answer that can't be read drops it.** The person comes to that
  question again on the way forward, so nothing is skipped without them seeing it.
- **Unknown details never hide a service.** Most services don't say what ages or genders they
  serve, so hiding the unknown ones would hide nearly everything. Categories are the exception.
- **Ranks add up** when several answers rank a service, so one that suits two answers comes
  before one that suits one. Ties keep their order: nearest first, then by name.
- **Ages are read now, though no question asks for them yet.** They're saved in clear formats,
  `"15-25"`, `"19+"` and `{"min": 19}`. Gender isn't read, because it's saved only as free text.
- **A question with `requires` appears once one visible service has the data.** Until then its
  answer couldn't change anything. One is enough because nothing appears until someone adds
  the question to the YAML, so the team already chooses when.
- **Two questions can't set the same part of the search.** Their options are merged, so the
  second would replace the first. The config is refused when it loads.
- **"Start over" is a link, not a button.** It's a plain GET, which holds no answers. A button
  inside the form could put the answers in the URL.
- **Location sorts and never filters.** Services with no known location come last.
- **When the address service is down, people carry on.** Services are in name order, and a
  message says they aren't sorted by distance. The same goes for a connection that has used
  up its 60 lookups an hour. The results page needs to keep that message:
  `@results.missing_distances?` says when it applies.
- **The results page gets `@results` and nothing else.** `docs/questionnaire-results.md` is the
  agreement. Tell whoever builds the page before changing it.
- **After changing an answer, Next goes through the later questions again.** Going straight back
  to the results would need a flag on every screen, to save one press.
- **A skipped question can't be reopened from the results,** because skipped ones aren't in
  `answers`. It's a small change if the page needs it.
- **A place is looked up once.** Its text and rounded coordinates travel in hidden fields.
  Changing the text looks it up again, and so does pressing Next after a failed lookup.
- **The device's location waits for Next.** The printout moves on by itself. Here people see
  how accurate it is first, since a laptop's can be off by kilometres.
- **A typed place wins over the device's location,** and each replaces the other on the page.
- **Asking the browser is shared with the printout** in `app/javascript/lib/device_location.js`.
  PR #85 changes lines beside the ones that moved, so expect a small conflict there. Its
  `flyer_builder_controller.js` should keep calling the shared code.
- **The page says the browser may use Google's or Apple's location service,** as the printout
  does, because outside companies are involved.
- **The page doesn't say who does the lookup.** It's the BC government's address service, as
  for printouts, which don't say so either.
- **The "not found" wording isn't shared with the printout.** The printout's is private to
  its controller, and PR #85 changes that file.

## Open questions

- **The format for demographics isn't agreed with Sofia.** `ResourceAttributes#age_range`
  reads today's formats and may need to change. PR #96 writes ages as text like `"19+"`.
- **Whether "Do any of these apply to you?" sorts or filters.** The plan is to sort, with
  `rank`, unless the team decides otherwise.

## Known limits

- **`requires` reads services one at a time,** on each screen, until it finds one with the
  data. No question uses it yet. With thousands of services and no data, it would be slow.
- **Of the 20 seeded services, 3 have ages and none has gender.** An age question would hide
  few services until there's more data. Importing a changed row again replaces these details.
- **Landmarks like "Central Library" usually aren't found.** The address service needs a
  street address or intersection.
- **The browser's own Back and Reload buttons lose the answers.** Tried in headless Chrome:
  both ask for the URL with a plain GET, because Turbo rewrites the history entry. So people
  see a fresh first question, and never a "resubmit" or expired page. The Back button in the
  page keeps answers. Not tried: Safari, Firefox, or with JavaScript off, where Turbo isn't
  running and the browser may ask to resubmit.
- **Options match categories by name.** Renaming a category in the database takes its
  services out of an option, and an option with none left is hidden. A warning is logged:
  `[Questionnaire] missing categories`.
- **A detail saved under a name we don't look for is unknown,** with no error, so its question
  may stay hidden and filter nothing. Imports must use the names in `docs/service-details.md`.
- **A service with no category isn't shown once someone chooses one.**
- **If PR #85 merges first**, its "Food and meals" category needs adding to
  `db/category_names.yml` and to an option.

## Privacy checks

- **Queries keep people's choices out of Sentry and the logs,** but only with production's
  current settings. Sentry records query text, which holds `$1` in place of the choice. Turning
  on `query_log_tags_enabled`, or turning off `prepared_statements`, puts the choice itself in
  that text. `RAILS_LOG_LEVEL=debug` puts it in the logs. Development's log shows choices.
- **Sentry collects no parameters** because `config/initializers/sentry.rb` sets
  `send_default_pii = false`. Sentry 7.2 deprecates that setting in favour of
  `data_collection`, whose own defaults do collect parameters and request bodies. So don't
  remove the line without turning those off. Sentry isn't loaded in tests, so no spec guards
  this.
- **Sentry doesn't record the place being looked up,** for the same reason. The lookup's URL
  holds the place, and Sentry notes outgoing requests, but leaves the query off. Checked by
  hand with Sentry 7.2: turning `send_default_pii` on does record it.
