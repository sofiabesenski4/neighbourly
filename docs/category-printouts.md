# Live resource guide and printable cards

Implements the data and PDF generation part of existence issue #256. The
live guide is available at `/flyers/new`; other screens can use the endpoints below.
Category results come directly from saved resource data. No Qwen, embedding,
scraping, or other network call runs while filtering or making the PDF.

Run `bundle install` and restart the app after switching to this branch. There
are no new database migrations. Prawn handles PDF generation; `pdf-reader` is
used only in tests. Prawn's font dependency requires the compatible
`bigdecimal` 3.3.1 version now recorded in the lockfile.

## Entry points

```ruby
# Returns ResourceCategorySearch::Section objects, each with a category and
# its matching Document records. Valid categories with no matches stay empty.
sections = ResourceCategorySearch.call(categories: ["food", "shelter"])

# Returns PDF bytes, or nil when no resources match.
pdf = FlyerGenerator.call(categories: ["food", "shelter"])
```

- `GET /flyers/preview?flyer[categories][]=food` displays matching cards.
- `GET /flyers/preview.json?flyer[categories][]=food&flyer[categories][]=shelter`
  returns the same grouped resources for Scott's front end.
- `POST /flyers`, with `flyer[categories][]=food` and any other selected keys,
  returns the PDF inline. Use the normal Rails CSRF token for browser POSTs.
- `GET /flyers/new` shows sidebar filters, live HTML cards and Generate printout.
  Food and shelter are selected initially; an explicit `flyer[categories][]`
  query overrides those defaults.

## Live interface

The Stimulus `flyer-builder` controller waits 300 ms after a filter change,
then requests the JSON preview. It keeps the old cards visible while loading,
aborts obsolete requests, and ignores late responses. Empty selections clear
the preview locally. Empty results and failed requests disable printing;
lookup failures offer a retry. Resource strings are inserted with
`textContent`, not interpreted as HTML. Embedding vectors are excluded from
the selected columns when loading cards.

The layout uses a sidebar and two card columns on desktop. At smaller widths
the cards use one column, and on phones the filters move above the guide.
Filters stay in view while scrolling on taller desktop screens.

Generate printout posts the latest selection with CSRF protection. No PDF is
made during filtering. After generation, a local PDF blob is loaded in an
offscreen frame and the browser's print dialog is requested. The browser owns
printer selection, paper settings, print preview and Save as PDF. An Open PDF
link remains available if automatic PDF printing is blocked or unsupported.
The interface does not claim that a print job was completed. Blob URLs and
requests are cleaned up when the filters change or the page is left.

Only the flyer controller permits `blob:` frames and objects for this purpose;
the global security policy, self-hosted script rule and anti-framing policy
remain unchanged. With JavaScript disabled, the form still submits directly
to the PDF endpoint.

PDF requests with `Accept: application/pdf` receive JSON errors with 422
(invalid selection), 404 (no matches) or 503 (generation failed), instead of
an HTML redirect. Standard form submissions retain their normal redirects.

The JSON response has this shape:

```json
{
  "categories": [
    {
      "key": "food",
      "name": "Food",
      "resources": [
        {
          "id": 1,
          "title": "Resource title",
          "fields": [{"label": "Notes", "value": "Saved resource information"}]
        }
      ]
    }
  ]
}
```

Category keys and ordering come from `ResourceCategory`. Selections use OR:
food plus shelter returns resources in either category. A resource in both
appears once in each selected category. Duplicate selections are removed.
Empty and unknown selections are rejected.

## Existing data

Category matching uses `metadata.resource_categories`, as introduced by the
base `feat/resource-categories` branch. After updating an existing database,
run its backfill once:

```sh
bin/rails resources:categorize
```

This updates metadata without generating new embeddings. New imports and
form entries already set these category keys on the base branch.

`ResourceCard` exposes a fixed allowlist of public card fields. Missing
values remove the whole field, including its label. `Notes` precedes
`Intake`. Values of zero and false are retained. Last updated is printed
only when the source actually supplies it; the database import/edit timestamp
is not substituted for a source update date. No Last checked field is added.
The description is labelled `Services`; saved service/category labels provide
a fallback when a description is absent.

Older imported records stored Notes and Intake only in labelled searchable
text. The presenter reads those saved labels as a fallback, including
multiline values. Future imports also retain these fields in metadata.

## Prototype visibility and the issue 65 dependency

The selected prototype rule uses records with embeddings and excludes closed
resources and resources whose removal reports were accepted. A pending report
does not change visibility. Accepted removals stay excluded even if a later
edit regenerates an embedding.

This branch does not introduce or claim a published/pending/archived review
workflow. Issue #65 must establish the shared publication rule before this
can meet the final published-only acceptance criterion. Its integration point
is the eligible-resource query in `ResourceCategorySearch`.

## Print layout

- Letter portrait with two independently stacked columns.
- Card title 13.5 pt, body 11.5 pt, secondary fields 10.5 pt.
- Font sizes never shrink to fit a page. Redistributable DejaVu fonts and
  their license are bundled for consistent rendering.
- Text is measured at both widths and cached for that PDF generation.
- A greedy fit compares at most eight full-width alternatives per pass.
  It does not enumerate every possible arrangement or promise a globally
  minimum page count.
- Full-width cards can fill shorter remaining space. Categories can share a
  page, with each heading spanning both columns.
- A complete card stays on one page whenever it can fit on an empty page.
  A card exceeding even a full page continues at full width, with repeated
  resource and category headings. Extremely long titles are retained in the
  body as well as a shortened repeating header.
- The printed timestamp is generated when the PDF is requested.

The preview exposes the same data and field ordering. The PDF renderer owns
paper pagination; the responsive browser preview does not promise matching
page breaks at arbitrary window sizes.

## Focused checks

```sh
bundle exec rspec spec/models/resource_category_search_spec.rb \
  spec/models/resource_card_spec.rb spec/models/flyer_pdf_spec.rb \
  spec/models/flyer_generator_spec.rb spec/requests/flyers_spec.rb
```

The PDF tests read the actual generated bytes, including a long-field
continuation case. HTTP tests cover anonymous preview, JSON integration,
invalid input, empty results, PDF delivery, and logged generation failures.
`spec/system/flyers_spec.rb` checks the form's no-JavaScript fallback;
`spec/requests/content_security_policy_spec.rb` checks the unchanged global
policy. Browser checks also exercised live filtering, cleared selection,
lookup failure and retry, delayed stale responses, real PDF generation,
automatic print invocation, cleanup after a filter change, and phone layout.
