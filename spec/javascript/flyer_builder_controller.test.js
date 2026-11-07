import test from "node:test";
import assert from "node:assert/strict";

import FlyerBuilderController from "../../app/javascript/controllers/flyer_builder_controller.js";

// Builds a controller with stand-ins for the page's two screens and location fields.
function locationController() {
  const controller = Object.create(FlyerBuilderController.prototype);
  const stub = (extra = {}) => ({ hidden: false, focus: () => {}, ...extra });
  controller.locationRequest = 0;
  controller.locateUrlValue = "/flyers/locate.json";
  controller.nearTarget = { value: "" };
  controller.latTarget = { value: "" };
  controller.lngTarget = { value: "" };
  controller.locationStatusTarget = stub({ textContent: "", hidden: true });
  controller.placeErrorTarget = stub({ textContent: "", hidden: true });
  controller.confirmPlaceButtonTarget = stub({ textContent: "Continue" });
  controller.locationStepTarget = stub();
  controller.locationHeadingTarget = stub();
  controller.subtitleTarget = stub();
  controller.builderStepTarget = stub({ hidden: true });
  controller.builderHeadingTarget = stub();
  controller.locationSummaryRowTarget = stub({ hidden: true });
  controller.locationSummaryTarget = stub({ textContent: "" });
  controller.printErrorTarget = stub({ hidden: true });
  controller.clearPrintout = () => {};
  controller.refresh = () => {};
  return controller;
}

function assertOnBuilderStep(controller) {
  assert.equal(controller.locationStepTarget.hidden, true);
  assert.equal(controller.builderStepTarget.hidden, false);
}

function assertOnLocationStep(controller) {
  assert.equal(controller.locationStepTarget.hidden, false);
  assert.equal(controller.builderStepTarget.hidden, true);
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

// Runs a test with a fake fetch for the place check. The page reads its security
// token from the document, which doesn't exist outside a browser.
async function withFakePlaceCheck(respond, run) {
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
    assertOnBuilderStep(controller);
    assert.match(
      controller.locationSummaryTarget.textContent,
      /accurate to about 40 m/,
    );
  });
});

test("warns on the second screen when the device's position is rough", () => {
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

test("stays on the first screen when the location can't be found or times out", () => {
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
test("changing the location discards a printout and returns to the first screen", () => {
  const events = [];
  const controller = locationController();
  controller.printRequest = { abort: () => events.push("aborted") };
  controller.clearPrintout = () => events.push("cleared");
  controller.showBuilderStep("Distances from: here.");
  controller.refresh = () => events.push("refreshed");

  controller.changeLocation();

  assert.deepEqual(events, ["aborted", "cleared"]);
  assertOnLocationStep(controller);
});

test("checks a typed place with the server, then moves on", async () => {
  const controller = locationController();
  controller.nearTarget.value = " 919 Pandora Ave ";

  await withFakePlaceCheck(
    () => ({
      ok: true,
      json: async () => ({ located: true, lat: 48.427, lng: -123.358 }),
    }),
    async (requests) => {
      await controller.confirmPlace();

      assert.equal(requests[0].url, "/flyers/locate.json");
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
  assert.equal(controller.confirmPlaceButtonTarget.disabled, false);
  // Kept so the preview and printout don't need to look the place up again.
  assert.equal(controller.latTarget.value, 48.427);
  assert.equal(controller.lngTarget.value, -123.358);
});

// The preview must show the same distances as the printout. The location goes in the
// request body, because web server logs record URLs and this may be someone's home.
test("sends a chosen location to the preview in the request body", async () => {
  const previousWindow = globalThis.window;
  globalThis.window = { location: { origin: "https://neighbourly.example" } };
  const controller = locationController();
  delete controller.refresh;
  controller.revision = 0;
  controller.previewUrlValue = "/flyers/preview.json";
  controller.previewErrorTarget = { hidden: true };
  controller.setLoading = () => {};
  controller.selectedCategories = () => ["17"];
  controller.render = () => {};
  controller.hasLatTarget = true;
  controller.latTarget.value = "48.427";
  controller.lngTarget.value = "-123.358";

  try {
    await withFakePlaceCheck(
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
      },
    );
  } finally {
    globalThis.window = previousWindow;
  }
});

test("reloads the preview after a choice, so its distances match", () => {
  const events = [];
  const controller = locationController();
  controller.refresh = () => events.push("refreshed");

  controller.skipLocation();

  assert.deepEqual(events, ["refreshed"]);
});

test("stays on the first screen with the server's message when a place isn't found", async () => {
  const controller = locationController();
  controller.nearTarget.value = "Central Library";

  await withFakePlaceCheck(
    () => ({
      ok: false,
      json: async () => ({ errors: ["We couldn't find that location."] }),
    }),
    () => controller.confirmPlace(),
  );

  assertOnLocationStep(controller);
  assert.equal(
    controller.placeErrorTarget.textContent,
    "We couldn't find that location.",
  );
  assert.equal(controller.confirmPlaceButtonTarget.textContent, "Continue");
});

test("moves on with a warning when the geocoder is down", async () => {
  const controller = locationController();
  controller.nearTarget.value = "919 Pandora Ave";

  await withFakePlaceCheck(
    () => ({ ok: true, json: async () => ({ located: false }) }),
    () => controller.confirmPlace(),
  );

  assertOnBuilderStep(controller);
  assert.match(
    controller.locationSummaryTarget.textContent,
    /can't check 919 Pandora Ave right now/,
  );
});

test("asks the person to retry when the connection fails", async () => {
  const controller = locationController();
  controller.nearTarget.value = "919 Pandora Ave";

  await withFakePlaceCheck(
    () => {
      throw new TypeError("Failed to fetch");
    },
    () => controller.confirmPlace(),
  );

  assertOnLocationStep(controller);
  assert.match(
    controller.placeErrorTarget.textContent,
    /Check your connection/,
  );
  assert.equal(controller.confirmPlaceButtonTarget.disabled, false);
});

test("asks for a place instead of checking a blank box", async () => {
  const controller = locationController();
  controller.nearTarget.value = "   ";

  await withFakePlaceCheck(
    () => assert.fail("should not call the server"),
    () => controller.confirmPlace(),
  );

  assertOnLocationStep(controller);
  assert.match(
    controller.placeErrorTarget.textContent,
    /Enter a street address/,
  );
});

// Typing during a slow check means its answer is for text that's no longer there.
test("ignores a place check's answer after the text changes", async () => {
  const controller = locationController();
  controller.nearTarget.value = "919 Pandora Ave";
  let release;
  const held = new Promise((resolve) => (release = resolve));

  await withFakePlaceCheck(
    async () => {
      await held;
      return { ok: true, json: async () => ({ located: true }) };
    },
    async () => {
      const check = controller.confirmPlace();
      assert.equal(
        controller.confirmPlaceButtonTarget.textContent,
        "Checking…",
      );

      controller.nearTarget.value = "919 Pandora";
      controller.locationChanged();
      assert.equal(controller.confirmPlaceButtonTarget.textContent, "Continue");

      release();
      await check;
    },
  );

  assertOnLocationStep(controller);
});

test("clearing every category requests and renders the complete guide", async () => {
  const previousWindow = globalThis.window;
  const previousFetch = globalThis.fetch;

  try {
    globalThis.window = { location: { origin: "https://neighbourly.example" } };

    const requests = [];
    const rendered = [];
    let selected = ["17"];

    globalThis.fetch = async (url) => {
      requests.push(new URL(url));
      return {
        ok: true,
        json: async () => ({ categories: [{ key: "17", resources: [] }] }),
      };
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.revision = 0;
    controller.previewUrlValue = "/flyers/preview.json";
    controller.previewErrorTarget = { hidden: true };
    controller.setLoading = () => {};
    controller.selectedCategories = () => selected;
    controller.render = (categories) => rendered.push(categories);

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
  } finally {
    globalThis.window = previousWindow;
    globalThis.fetch = previousFetch;
  }
});

test("rendered resource cards use Tailwind utility classes", () => {
  const previousDocument = globalThis.document;

  try {
    globalThis.document = {
      createElement: (tagName) => ({
        tagName,
        children: [],
        append(...children) {
          this.children.push(...children);
        },
      }),
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    const article = controller.card({
      title: "Food bank",
      fields: [{ label: "Hours", value: "Monday" }],
    });

    assert.match(article.className, /\bborder\b/);
    assert.match(article.className, /\bbg-white\b/);
    assert.match(article.children[0].className, /\bbg-stone-100\b/);
    assert.match(
      article.children[1].children[0].children[1].className,
      /\bwhitespace-pre-line\b/,
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
    controller.selectedCategories = () => [];
    controller.generating = false;

    controller.render([
      {
        name: "Food",
        resources: ["Alpha", "Bravo", "Charlie", "Delta"].map(
          (title, index) => ({ id: index + 1, title, fields: [] }),
        ),
      },
    ]);

    const grid = controller.cardsTarget.children[0].children[1];
    assert.match(grid.className, /grid-cols-1/);
    assert.match(grid.className, /lg:grid-cols-2/);
    assert.equal(grid.children.length, 4);
    assert.deepEqual(
      grid.children.map((card) => card.children[0].textContent),
      ["Alpha", "Bravo", "Charlie", "Delta"],
    );
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
    controller.previewUrlValue = "/flyers/preview.json";
    controller.previewErrorTarget = { hidden: true };
    controller.setLoading = () => {};
    controller.selectedCategories = () => selected;
    controller.render = (categories) => rendered.push(categories);

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
