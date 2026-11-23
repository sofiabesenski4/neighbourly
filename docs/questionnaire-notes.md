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

## Known limits

- **Options match categories by name.** Renaming a category in the database takes its
  services out of an option, and an option with none left is hidden. A warning is logged:
  `[Questionnaire] missing categories`.
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
