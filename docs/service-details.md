# Service details that questions can use

A questionnaire answer can filter services by details that have no column of their own, such
as the ages a service accepts. Those live in `services.additional_details`. The app can only
find one if it's saved under a name below, in a format below. **Anything else is kept and may
still show on cards, but questions treat it as unknown, with no error or warning.**

Anyone adding a CSV, an import or a form that saves services should use these names.
`ResourceAttributes` (`app/models/resource_attributes.rb`) reads them. Change this file when
you change that one.

## Ages: `age_range`

Save it as a detail named **`Ages`** (the simplest choice for a CSV column).

| Name | Found? |
|---|---|
| `Ages`, `Age`, `Age Range` | Yes |
| `ages`, `AGE_RANGE`, `age-range` | Yes. Capitals and punctuation don't matter |
| `Age Group`, `Ages Served`, `Age Limit` | No |
| `Min Age` and `Max Age` as separate columns | No |
| An age in `Notes`, `Eligibility` or `Description` | No |

If a service has several, the first filled in of `age range`, `ages`, `age` is used, whichever
order they were saved in. If that one is unclear, the ages are unknown.

| Value | Read as |
|---|---|
| `15-25`, `15 to 25`, `15 – 25` | 15 to 25 |
| `19+` | 19 and older |
| `{"min": 13, "max": 18}` | 13 to 18 |
| `{"min": 19}` | 19 and older |
| `{"max": 18}` | 18 and younger |
| `19`, `adults 19+`, `19 and over`, `under 19` | Unknown |
| `13-18, 25+` | Unknown |
| `All ages`, `youth`, `varies`, blank | Unknown |

"All ages" being unknown is harmless: an unknown age never hides a service.

### Where each source saves it

| Source | How | Read? |
|---|---|---|
| CSV import | Each column under its own header | Only if the header and value are in the tables above |
| Resource form | Minimum and maximum age, saved as `age_range` with numbers | Yes |
| Services form | It has no age field | No |
| AI enrichment (PR #96, not merged) | Plans to add `ages`, like `19+` or `12-18` | Yes, in those formats |

Importing a changed row again replaces all of that service's details.

## Not read yet

**Gender and eligibility** are saved as free text under `gender` or `eligibility`, with no
agreed format, so nothing reads them. The format for all of these isn't agreed with Sofia yet.

## Adding another detail

1. Add a method to `ResourceAttributes`, and its name to `NAMES`.
2. Add a section here with the names and formats it reads.
3. Check that what each source saves really is found, as `spec/models/resource_attributes_spec.rb`
   and `spec/requests/documents_spec.rb` do for ages.
