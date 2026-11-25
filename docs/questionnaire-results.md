# Building the questionnaire's results page

The questionnaire gathers answers and runs the search. The results page shows what it found.
They meet at `@results`, a `QuestionnaireResults`.

`app/views/questionnaires/results.html.erb` shows the guided printout preview directly in
the response to the last question's form. The PDF form submits checked service IDs, their
category filter, default print settings, and any rounded coordinates needed for the map.

## What's in `@results`

| | |
|---|---|
| `services` | The matching services, already filtered and in order, each once. An empty list when nothing matched |
| `origin` | Where distances are measured from, or nil if location was skipped |
| `answers` | What was answered, each with `key`, `title` and `labels`. Skipped questions are left out |
| `missing_distances?` | True when someone gave a place but it couldn't be looked up |
| `hidden_fields` | Only for the change button. Don't show these |

A location's label is the place that was typed, or "your location".

## What the page must do

- **Keep the order of `services` within each category.** Sections use the manual builder's category order.
- **Build cards with `ResourceCard.new(service, origin: @results.origin)`,** so that distances
  agree with the order. Use `card.title`, because a service's name may be blank once PR #96
  merges. `card.distance_km` can be nil, and so can `service.description`.
- **Say so when `missing_distances?` is true.** The address service is down, or this
  connection has used up its lookups, so the services are in name order instead.
- **Keep answers out of URLs, the session, cookies and browser storage.** People may be on
  shared computers, and these answers can be sensitive.
- **Turn off Turbo's page cache,** as `show.html.erb` does:

  ```erb
  <% content_for :head do %>
    <meta name="turbo-cache-control" content="no-cache">
  <% end %>
  ```

  `Cache-Control: no-store` is already sent.

## Changing an answer

Show this beside each answer:

```erb
<%= render "questionnaires/change_answer", results: @results, answer: answer %>
```

It's a form with one button. It opens that question with every answer kept, and Next then goes
through the later questions again, with their answers filled in.

Skipped questions aren't in `answers`, so they can't be reopened this way. Someone would have to
start over, with a link to `find_help_for_myself_path`. Adding them is a small change if the
page needs it.
