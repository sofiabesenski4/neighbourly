# The printed map

Every printed guide ends with a map page. It shows the area around the chosen location, or
downtown Victoria if there isn't one, with a numbered pin for each resource. The numbers match
the card headers, so a reader finds a pin's name by looking up its card.

The page is drawn when the guide is printed, from image tiles stored in the app. Drawing it makes
no network calls. Looking up a typed location can call the geocoder, but that happens before the
map is drawn.

This page explains how the map works. For rebuilding the tiles, see
[map-tiles.md](map-tiles.md). For known limits and open decisions, see
[resource-map-notes.md](resource-map-notes.md).

## What's fixed and what changes

The map isn't fitted to the resources in the guide.

| Part of the map | Where it comes from | Changes per guide? |
|---|---|---|
| Streets and water | PNG tiles in `lib/map_tiles/`, rendered once by hand | No |
| Area shown | A 1.3 km radius around the centre | Only with the centre |
| Pins and "Not shown on map" list | The resources in this guide | Yes |

A guide whose resources are all far from downtown therefore prints a map with no pins. This is
deliberate: a map zoomed in enough to read is preferred over one that fits everything.

## Where the map is centred

| Situation | Centre |
|---|---|
| A location was typed or came from "Use my location" | That location |
| No location was given | Downtown (48.4265, -123.3656) |
| The location couldn't be looked up | Downtown |
| The location is so far away that it has no tiles | Downtown |

A location partly on the tiles keeps its own map, with a blank part where the tiles end. In the
last row of the table, the page doesn't tell the reader that the map shows somewhere else.

The location isn't marked on the map yet, so a reader has to assume it's the middle.

## How a page gets drawn

```
FlyersController
  └─ FlyerGenerator
       └─ FlyerPdf                numbers the resources and prints the cards
            └─ FlyerMapPage       draws the map page
                 ├─ MapTileSet    reads the manifest and finds tile files
                 ├─ MapView       picks the zoom, scale, tiles and page positions
                 │    └─ MapProjection   converts degrees to world pixels
                 └─ MapPinLayout  decides what's a pin and what's not shown
```

1. `FlyerPdf` numbers each resource in the order the cards print. A resource in two categories
   prints two cards with the same number.
2. After the last card, `FlyerPdf` starts a new page and hands `FlyerMapPage` the numbered
   resources and the centre.
3. `FlyerMapPage` works out how tall the map can be, after leaving room for the text below it.
4. `MapView` chooses a zoom and scale for that frame, and which tiles it needs.
5. `MapPinLayout` sorts the resources into pins, edge markers and "not shown".
6. `FlyerMapPage` draws the tiles, the border, the pins, the scale bar, the credit and the list.

`MapView`, `MapPinLayout` and `MapProjection` know nothing about Prawn or the database, so they
can be tested with plain numbers. All the Prawn drawing for the map is in `FlyerMapPage`.

## How pins stay lined up with the streets

Tiles and pins go through one calculation, `MapView#page_position_for_world`, so they can't drift
apart. A position passes through three kinds of coordinates:

1. **Degrees:** a `GeoPoint`, with a latitude and longitude.
2. **World pixels:** the position on a Web Mercator map of the whole world at the chosen zoom.
   `y` grows downward. See `MapProjection`.
3. **Page points:** PDF units of 1/72 inch, measured from the map frame's bottom-left corner.
   `y` grows upward, as in Prawn. `MapView#scale` converts world pixels to page points.

`FlyerMapPage` draws inside a Prawn bounding box the same size as the frame, so `MapView`'s
numbers can be passed straight to Prawn.

## Choosing the zoom

Tiles come in fixed zoom levels, where each level doubles the map's size. `MapView` picks the most
detailed zoom where the whole radius fits the frame at a readable size, meaning a scale of at
least 0.6. Below that, map text would be too small. Scale is capped at 1.2, because tiles start to
look soft above that.

Two sizes depend on this:

- **The radius, 1.3 km.** Zoom 15 is where most street names appear. At 1.5 km the map drops to
  zoom 14, which has few of them.
- **The frame's height.** A map about 640 pt tall fits at zoom 15, and one about 470 pt tall
  drops to zoom 14. So anything added under the map can cost the street names. That's why there's
  no number-to-name list.

A long "Not shown on map" list shrinks the map, but never below 400 pt. Beyond that, the list
continues on another page. At that height the map will be at zoom 14.

## What gets a pin

| Resource | What the page shows |
|---|---|
| Inside the frame | A pin with its number |
| Within 10 pt of another pin | One shared pin, such as "4, 19" |
| Has coordinates, but outside the frame | **Nothing yet** (see below) |
| No coordinates, or impossible ones | Its number and name under "Not shown on map" |

Pins are black with white numbers, because guides may be photocopied and the map is grey. They
show only numbers, to keep the map readable.

Pins merge at 10 pt because of how they're drawn. A pin reaches 7 pt from its middle and a digit
reaches about 3 pt from the other pin's middle, so anything closer can hide a number. A merged
pin sits in the middle of its group, so it's slightly away from each real location.

**Off-map resources:** `MapPinLayout` already works out edge markers for these, but nothing draws
them yet. Until the border arrows are added, these resources have a card but no sign on the map.

## Clipping the tiles

Tiles hang over the frame's edge, so they have to be cropped. Prawn has no public clipping method,
so `FlyerMapPage#draw_tiles` writes the PDF operators itself:

```
x y width height re W n
```

`re` describes a rectangle, `W` makes it the clipping area, and `n` ends the path without drawing
it. This sits inside `save_graphics_state`, so the clipping stops once the tiles are drawn. Raw
operators ignore Prawn's bounds, so it uses absolute page positions.

## The scale bar

The bar is one km long at the centre of the map, from `MapView#points_per_km`. Its label, "1 km ≈
16 min walk", is calculated from the same constants as the cards' walking times, in `ResourceCard`.
Changing the pace or the street factor there updates both.

## Credits

The page prints the credit and style licence from `lib/map_tiles/manifest.json`, under the map. The
data's licence requires this, so keep it if you redesign the page. See the credits section of
[map-tiles.md](map-tiles.md).

## Changing things

| To change | Edit | Then check |
|---|---|---|
| The area shown | `FlyerMapPage::RADIUS_KM` | The zoom on a printout, and street names |
| The default centre | `FlyerMapPage::DOWNTOWN` | |
| Pin size | `FlyerMapPage::PIN_DIAMETER` | `MapPinLayout::PIN_MERGE_DISTANCE`, which assumes it |
| When pins merge | `MapPinLayout::PIN_MERGE_DISTANCE` | Downtown on a printout |
| Readable size limits | `MapView::MIN_SCALE`, `MapView::MAX_SCALE` | Map text and sharpness on paper |
| Walking pace | `ResourceCard` constants | The cards and the scale bar change together |

## Trying it

Look at the page itself, because specs can't tell whether a map reads well. With the development
database's sample loaded:

```sh
bin/rails runner '
  origin = FlyerOrigin.new(label: "919 Pandora Ave", point: GeoPoint.new(lat: 48.4265, lng: -123.36))
  File.binwrite("tmp/guide.pdf", FlyerPdf.new(sections: CategorySearch.call(categories: []), origin: origin).render)
'
open tmp/guide.pdf
```

Leave out `origin:` to see the downtown map. Cards then have no Distance row, because there's
nothing to measure from.

The specs are `spec/models/flyer_map_page_spec.rb`, which read back real PDFs, and
`spec/models/map_tile_set_spec.rb`, which runs against the real stored tiles.
