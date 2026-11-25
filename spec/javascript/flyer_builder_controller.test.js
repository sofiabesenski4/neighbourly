import test from "node:test";
import assert from "node:assert/strict";

import FlyerBuilderController from "../../app/javascript/controllers/flyer_builder_controller.js";

// Builds a controller with stand-ins for the distance dialog and location fields.
function locationController() {
  const controller = Object.create(FlyerBuilderController.prototype);
  const stub = (extra = {}) => ({ hidden: false, focus: () => {}, ...extra });
  controller.locationRequest = 0;
  controller.locateUrlValue = "/printout/locate.json";
  controller.nearTarget = { value: "" };
  controller.latTarget = { value: "" };
  controller.lngTarget = { value: "" };
  controller.locationStatusTarget = stub({ textContent: "", hidden: true });
  controller.placeErrorTarget = stub({ textContent: "", hidden: true });
  controller.confirmPlaceButtonTarget = stub({ textContent: "Continue" });
  controller.locationStepTarget = {
    open: true,
    showModal() {
      this.open = true;
    },
    close() {
      this.open = false;
    },
  };
  controller.locationHeadingTarget = stub();
  controller.locationSummaryTarget = stub({ textContent: "" });
  controller.distanceButtonTarget = stub();
  controller.distanceLabelTarget = stub();
  controller.distanceWarningTarget = stub();
  controller.printErrorTarget = stub({ hidden: true });
  controller.clearPrintout = () => {};
  controller.updateFilterControls = () => {};
  controller.refresh = () => {};
  return controller;
}

function assertOnBuilderStep(controller) {
  assert.equal(controller.locationStepTarget.open, false);
}

function assertOnLocationStep(controller) {
  assert.equal(controller.locationStepTarget.open, true);
}

// Runs a test with a fake navigator.geolocation that holds the browser's answer until
// the test gives it. Real Chrome covers the normal paths in flyer_builder_live_spec.rb.
// These are the cases a browser can't easily be made to produce, like timeouts.
function withFakeGeolocation(run) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const pending = [];
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: {
      geolocation: {
        getCurrentPosition: (success, failure, options) =>
          pending.push({ success, failure, options }),
      },
    },
  });
  try {
    run(pending);
  } finally {
    if (previous) Object.defineProperty(globalThis, "navigator", previous);
    else delete globalThis.navigator;
  }
}

// Captures requests without a browser.
async function withFakePreviewRequest(respond, run) {
  const previousFetch = globalThis.fetch;
  const previousDocument = globalThis.document;
  const requests = [];
  globalThis.document = { querySelector: () => ({ content: "token" }) };
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    return respond();
  };
  try {
    await run(requests);
  } finally {
    globalThis.fetch = previousFetch;
    globalThis.document = previousDocument;
  }
}

const position = {
  coords: { latitude: 48.427113, longitude: -123.357764, accuracy: 40 },
};

test("rounds the device's position before it can leave the browser, then moves on", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.nearTarget.value = "919 Pandora Ave";

    controller.useMyLocation();
    assert.equal(
      controller.locationStatusTarget.textContent,
      "Finding your location…",
    );
    assertOnLocationStep(controller);
    pending[0].success(position);

    assert.equal(controller.latTarget.value, "48.427");
    assert.equal(controller.lngTarget.value, "-123.358");
    assert.equal(controller.nearTarget.value, "");
    assert.equal(
      controller.distanceLabelTarget.textContent,
      "Current location",
    );
    assertOnBuilderStep(controller);
    assert.match(
      controller.locationSummaryTarget.textContent,
      /accurate to about 40 m/,
    );
  });
});

test("warns in the builder when the device's position is rough", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();

    controller.useMyLocation();
    pending[0].success({ coords: { ...position.coords, accuracy: 3000 } });

    assert.match(
      controller.locationSummaryTarget.textContent,
      /may be off by about 3 km/,
    );
  });
});

test("gives up on the location lookup after a limited time", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();

    controller.useMyLocation();

    assert.equal(pending[0].options.timeout, 10000);
  });
});

test("keeps the dialog open when the location can't be found or times out", () => {
  for (const code of [2, 3]) {
    withFakeGeolocation((pending) => {
      const controller = locationController();

      controller.useMyLocation();
      pending[0].failure({ code });

      assert.match(
        controller.locationStatusTarget.textContent,
        /couldn't find your location/,
      );
      assert.equal(controller.latTarget.value, "");
      assertOnLocationStep(controller);
    });
  }
});

// The browser can take a long time to answer, especially while its permission prompt
// is open. A late answer must not bring back a location the person moved on from.
test("ignores a late answer after a place is typed", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.useMyLocation();

    controller.nearTarget.value = "919 Pandora Ave";
    controller.locationChanged();
    pending[0].success(position);

    assert.equal(controller.latTarget.value, "");
    assert.equal(controller.nearTarget.value, "919 Pandora Ave");
    assertOnLocationStep(controller);
  });
});

test("ignores a late answer after skipping", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.useMyLocation();

    controller.skipLocation();
    pending[0].failure({ code: 1 });

    assert.equal(controller.locationStatusTarget.hidden, true);
    assertOnBuilderStep(controller);
  });
});

test("only the latest of several requests is used", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.useMyLocation();
    controller.useMyLocation();

    pending[0].success(position);
    assert.equal(controller.latTarget.value, "");

    pending[1].success(position);
    assert.equal(controller.latTarget.value, "48.427");
  });
});

test("skipping clears any location and moves on", () => {
  const controller = locationController();
  controller.nearTarget.value = "919 Pandora Ave";
  controller.latTarget.value = "48.427";

  controller.skipLocation();

  assert.equal(controller.nearTarget.value, "");
  assert.equal(controller.latTarget.value, "");
  assertOnBuilderStep(controller);
});

// A finished or in-progress printout has distances from the old location, so it
// must not stay available once the person goes back to change it.
test("editing distances opens the dialog and discards a printout", () => {
  const events = [];
  const controller = locationController();
  controller.printRequest = { abort: () => events.push("aborted") };
  controller.clearPrintout = () => events.push("cleared");
  controller.applyLocation("Distances from: here.");
  controller.refresh = () => events.push("refreshed");

  controller.changeLocation();

  assert.deepEqual(events, ["aborted", "cleared"]);
  assert.equal(controller.locationStepTarget.open, true);
});

test("checks a typed place with the server, then moves on", async () => {
  const controller = locationController();
  controller.nearTarget.value = " 919 Pandora Ave ";

  await withFakePreviewRequest(
    () => ({
      ok: true,
      json: async () => ({ located: true, lat: 48.427, lng: -123.358 }),
    }),
    async (requests) => {
      await controller.confirmPlace();

      assert.equal(requests[0].url, "/printout/locate.json");
      assert.equal(
        requests[0].options.body.get("flyer[near]"),
        "919 Pandora Ave",
      );
    },
  );

  assertOnBuilderStep(controller);
  assert.equal(
    controller.locationSummaryTarget.textContent,
    "Distances from: 919 Pandora Ave.",
  );
  assert.equal(controller.distanceLabelTarget.textContent, "919 Pandora Ave");
  assert.equal(controller.confirmPlaceButtonTarget.disabled, false);
  // Kept so the preview and printout don't need to look the place up again.
  assert.equal(controller.latTarget.value, 48.427);
  assert.equal(controller.lngTarget.value, -123.358);
});

// The preview must show the same distances as the printout. The location goes in the
// request body, because web server logs record URLs and this may be someone's home.
test("sends the questionnaire location to the preview in the request body", async () => {
  const previousWindow = globalThis.window;
  globalThis.window = { location: { origin: "https://neighbourly.example" } };
  const controller = Object.create(FlyerBuilderController.prototype);
  controller.fromQuestionnaireValue = true;
  controller.revision = 0;
  controller.previewUrlValue = "/printout/preview.json";
  controller.previewErrorTarget = { hidden: true };
  controller.setLoading = () => {};
  controller.selectedCategories = () => ["17"];
  controller.selectedOrganizations = () => ["5"];
  controller.searchTarget = { value: "meal" };
  controller.sortTarget = { value: "desc" };
  controller.render = () => {};
  controller.hasLatTarget = true;
  controller.latTarget = { value: "48.427" };
  controller.lngTarget = { value: "-123.358" };

  try {
    await withFakePreviewRequest(
      () => ({ ok: true, json: async () => ({ categories: [] }) }),
      async (requests) => {
        await controller.refresh();

        const { url, options } = requests[0];
        assert.equal(options.method, "POST");
        assert.equal(options.body.get("flyer[lat]"), "48.427");
        assert.equal(options.body.get("flyer[lng]"), "-123.358");
        // Nothing in the URL: Rails would let a `flyer` there replace the body's.
        assert.equal(url.search, "");
        assert.deepEqual(options.body.getAll("flyer[categories][]"), ["17"]);
        assert.deepEqual(options.body.getAll("flyer[organizations][]"), ["5"]);
        assert.equal(options.body.get("flyer[query]"), "meal");
        assert.equal(options.body.get("flyer[sort]"), "desc");
      },
    );
  } finally {
    globalThis.window = previousWindow;
  }
});

test("keeps questionnaire filters in the preview request body without a location", () => {
  const previousDocument = globalThis.document;
  const controller = Object.create(FlyerBuilderController.prototype);
  controller.organizationTargets = [];
  controller.fromQuestionnaireValue = true;
  controller.searchTarget = { value: "meals" };
  controller.sortTarget = { value: "default" };
  const url = new URL("https://neighbourly.example/printout/preview.json");

  try {
    globalThis.document = { querySelector: () => null };
    const options = controller.previewRequestOptions(["17"], url);

    assert.equal(options.method, "POST");
    assert.equal(url.search, "");
    assert.deepEqual(options.body.getAll("flyer[categories][]"), ["17"]);
    assert.equal(options.body.get("flyer[query]"), "meals");
    assert.equal(options.body.has("flyer[lat]"), false);
  } finally {
    globalThis.document = previousDocument;
  }
});

test("clearing every category requests and renders the complete guide", async () => {
  const previousWindow = globalThis.window;
  const previousFetch = globalThis.fetch;

  try {
    globalThis.window = { location: { origin: "https://neighbourly.example" } };

    const requests = [];
    const rendered = [];
    let selected = ["17"];
    let organizations = [];

    globalThis.fetch = async (url) => {
      requests.push(new URL(url));
      return {
        ok: true,
        json: async () => ({ categories: [{ key: "17", resources: [] }] }),
      };
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.revision = 0;
    controller.previewUrlValue = "/printout/preview.json";
    controller.searchTarget = { value: "" };
    controller.sortTarget = { value: "default" };
    controller.previewErrorTarget = { hidden: true };
    controller.setLoading = () => {};
    controller.selectedCategories = () => selected;
    controller.render = (categories) => rendered.push(categories);
    controller.selectedOrganizations = () => organizations;

    await controller.refresh();
    selected = [];
    await controller.refresh();

    assert.equal(requests.length, 2);
    assert.deepEqual(requests[0].searchParams.getAll("flyer[categories][]"), [
      "17",
    ]);
    assert.deepEqual(
      requests[1].searchParams.getAll("flyer[categories][]"),
      [],
    );
    assert.deepEqual(rendered.at(-1), [{ key: "17", resources: [] }]);

    controller.searchTarget.value = " free meals ";
    controller.sortTarget.value = "desc";
    await controller.refresh();
    assert.equal(requests[2].searchParams.get("flyer[query]"), "free meals");
    assert.equal(requests[2].searchParams.get("flyer[sort]"), "desc");

    organizations = ["5", "9"];
    await controller.refresh();
    assert.deepEqual(
      requests[3].searchParams.getAll("flyer[organizations][]"),
      ["5", "9"],
    );
  } finally {
    globalThis.window = previousWindow;
    globalThis.fetch = previousFetch;
  }
});

test("resource cards show contact information and other details in one list", () => {
  const previousDocument = globalThis.document;

  try {
    globalThis.document = {
      createElement: (tagName) => ({
        tagName,
        dataset: {},
        children: [],
        setAttribute() {},
        append(...children) {
          this.children.push(...children);
        },
        addEventListener() {},
      }),
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.excludedServiceIds = new Set();
    const article = controller.card({
      id: 1,
      title: "Food bank",
      fields: [
        { label: "Phone", value: "250-555-0100" },
        { label: "Hours", value: "Monday" },
      ],
    });

    assert.match(article.className, /\bborder\b/);
    assert.match(article.className, /\bbg-white\b/);
    assert.match(article.children[0].className, /\bbg-stone-100\b/);
    assert.equal(article.children.length, 2);
    const list = article.children[1];
    assert.equal(list.tagName, "dl");
    const values = list.children.map((row) => row.children[1]);
    assert.match(values[0].className, /\bwhitespace-pre-line\b/);
    assert.deepEqual(
      values.map((value) => value.textContent),
      ["250-555-0100", "Monday"],
    );
    assert.doesNotMatch(article.className, /\bflyer-card\b/);
  } finally {
    globalThis.document = previousDocument;
  }
});

test("resource cards stay in row-major order in one responsive grid", () => {
  const previousDocument = globalThis.document;

  try {
    const createElement = (tagName) => ({
      tagName,
      dataset: {},
      style: {
        setProperty(name, value) {
          this[name] = value;
        },
      },
      children: [],
      append(...children) {
        this.children.push(...children);
      },
      replaceChildren(...children) {
        this.children = children.flatMap((child) =>
          child.tagName === "#document-fragment" ? child.children : [child],
        );
      },
      setAttribute() {},
      addEventListener() {},
    });

    globalThis.document = {
      createElement,
      createDocumentFragment: () =>
        Object.assign(createElement("#document-fragment"), {
          replaceChildren(...children) {
            this.children = children;
          },
        }),
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.cardsTarget = createElement("div");
    controller.countTarget = {};
    controller.statusTarget = {};
    controller.generateTarget = {};
    controller.previewErrorTarget = { hidden: true };
    controller.excludedServiceIds = new Set();
    controller.searchTarget = { value: "" };
    controller.selectedCategories = () => [];
    controller.selectedOrganizations = () => [];
    controller.generating = false;
    controller.resourceSelectionTargets = [];
    controller.selectAllTarget = {};
    controller.deselectAllTarget = {};

    controller.render([
      { name: "Empty category", resources: [] },
      {
        name: "Food",
        colour: "896109",
        resources: ["Alpha", "Bravo", "Charlie", "Delta"].map(
          (title, index) => ({ id: index + 1, title, fields: [] }),
        ),
      },
    ]);

    assert.equal(controller.cardsTarget.children.length, 1);
    const [category] = controller.cardsTarget.children;
    const [heading, grid] = category.children;
    assert.equal(heading.textContent, "Food");
    assert.match(category.className, /flyer-category-group/);
    assert.equal(category.style["--flyer-category-colour"], "#896109");
    assert.equal(heading.style.color, "#896109");
    assert.equal(controller.countTarget.textContent, "4 resources included");
    assert.match(grid.className, /grid-cols-1/);
    assert.match(grid.className, /lg:grid-cols-2/);
    assert.equal(grid.children.length, 4);
    assert.deepEqual(
      grid.children.map((card) => card.children[0].children[0].textContent),
      ["Alpha", "Bravo", "Charlie", "Delta"],
    );
    controller.render([
      { name: "Food", resources: [{ id: 1, title: "Alpha", fields: [] }] },
      { name: "Health", resources: [{ id: 1, title: "Alpha", fields: [] }] },
    ]);
    assert.equal(controller.countTarget.textContent, "1 resource included");
    controller.render([{ name: "Empty category", resources: [] }]);
    assert.equal(controller.countTarget.textContent, "0 resources included");
    assert.equal(controller.cardsTarget.children.length, 1);
    assert.equal(
      controller.cardsTarget.children[0].textContent,
      "No resources are available to display.",
    );
    assert.equal(controller.generateTarget.disabled, true);
  } finally {
    globalThis.document = previousDocument;
  }
});

test("a delayed preview response cannot replace a newer selection", async () => {
  const previousWindow = globalThis.window;
  const previousFetch = globalThis.fetch;

  try {
    globalThis.window = { location: { origin: "https://neighbourly.example" } };

    let releaseOldResponse;
    const rendered = [];
    let selected = ["17"];
    globalThis.fetch = (url) => {
      const categories = new URL(url).searchParams.getAll(
        "flyer[categories][]",
      );
      if (categories.includes("17")) {
        return new Promise((resolve) => {
          releaseOldResponse = () =>
            resolve({
              ok: true,
              json: async () => ({ categories: ["old"] }),
            });
        });
      }
      return Promise.resolve({
        ok: true,
        json: async () => ({ categories: ["latest"] }),
      });
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.revision = 0;
    controller.previewUrlValue = "/printout/preview.json";
    controller.searchTarget = { value: "" };
    controller.sortTarget = { value: "default" };
    controller.previewErrorTarget = { hidden: true };
    controller.setLoading = () => {};
    controller.selectedCategories = () => selected;
    controller.render = (categories) => rendered.push(categories);
    controller.selectedOrganizations = () => [];

    const oldRequest = controller.refresh();
    selected = ["23"];
    await controller.refresh();
    releaseOldResponse();
    await oldRequest;

    assert.deepEqual(rendered, [["latest"]]);
  } finally {
    globalThis.window = previousWindow;
    globalThis.fetch = previousFetch;
  }
});

function resourceSelectionController() {
  const controller = Object.create(FlyerBuilderController.prototype);
  controller.previewReady = true;
  controller.previewCategories = [
    {
      resources: [
        { id: 1, title: "Alpha" },
        { id: 2, title: "Beta" },
      ],
    },
    { resources: [{ id: 1, title: "Alpha" }] },
  ];
  controller.excludedServiceIds = new Set(["99"]);
  controller.resourceSelectionTargets = [1, 2, 1].map((id) => ({
    value: String(id),
  }));
  controller.countTarget = {};
  controller.selectAllTarget = {};
  controller.deselectAllTarget = {};
  controller.generateTarget = {};
  controller.generateLabelTarget = {};
  controller.generating = false;
  controller.revision = 4;
  controller.discardPrintout = () => {
    controller.discarded = true;
  };
  return controller;
}

test("bulk selection changes only matching resources and counts category duplicates once", () => {
  const controller = resourceSelectionController();
  controller.selectResources({ params: { selected: false } });
  assert.deepEqual([...controller.excludedServiceIds], ["99", "1", "2"]);
  assert.equal(controller.countTarget.textContent, "0 resources included");
  assert.equal(controller.generateTarget.disabled, true);
  assert.ok(
    controller.resourceSelectionTargets.every((input) => !input.checked),
  );

  controller.toggleResource({ target: { value: "1", checked: true } });
  assert.deepEqual(
    controller.resourceSelectionTargets.map((input) => input.checked),
    [true, false, true],
  );
  assert.equal(controller.countTarget.textContent, "1 resource included");
  assert.equal(controller.generateTarget.disabled, false);

  controller.selectResources({ params: { selected: true } });
  assert.deepEqual([...controller.excludedServiceIds], ["99"]);
  assert.equal(controller.countTarget.textContent, "2 resources included");
});

test("selection changes invalidate an in-flight printout without replacing checkbox focus", () => {
  const controller = resourceSelectionController();
  controller.generating = true;
  controller.renderCards = () =>
    assert.fail("selection must preserve the existing checkbox elements");
  controller.toggleResource({ target: { value: "1", checked: false } });
  assert.equal(controller.discarded, true);
  assert.equal(controller.revision, 5);
  assert.equal(controller.generating, false);
  assert.equal(controller.generateLabelTarget.textContent, "Generate printout");
  assert.equal(controller.countTarget.textContent, "1 resource included");
});

test("bulk selection ignores stale results while a filter refresh is pending", () => {
  const controller = resourceSelectionController();
  controller.previewReady = false;
  controller.selectResources({ params: { selected: false } });
  assert.deepEqual([...controller.excludedServiceIds], ["99"]);
});
