# Resource printout format

**Draft for team review.** This example shows the data the print template needs. Riley can decide how to store it in the database.

[Open the JSON example](resource-printout.example.json)

## How it works

```text
Chatbot answer       Category search
       \                /
        Selected resource IDs
                 |
     Published database records
                 |
              JSON data
                 |
     Shared resource-card template
                 |
           Print preview
                 |
         Print / Save as PDF
```

Each item in `resources` uses the same fields. The frontend reads those fields and fills the card template Hugh will build. Both search methods use the same template.

## From data to card

```text
JSON field                  Card label
-------------------------   ---------------------
name                        Service name
location                    Where
hours                       When
contact                     Contact
access_instructions         How to get help
language_services           Languages and support
sources                     Source
last_checked_at             Last checked
```

- `null` means the information is unknown. Do not guess it.
- `language_services` is one text field, e.g. "English and French; interpretation by appointment."
- `image_url` is optional. The team still needs to decide where images appear.
- Generate `printed_at` when preparing the preview.
- Keep the user's question, chat history, and personal client details off the handout.

## Questions for the team

**A resource belongs to Food and Housing. Both categories are selected.**

```text
Option A                         Option B
Food                             Food
  Resource card                    Resource card [Food + Housing]
Housing                          Housing
  Same resource card               See the card on page ...
```

Which approach should we use? Neither is agreed yet.

Also: should separate Food and Housing print requests produce two guides, while selecting both together produces one combined guide?