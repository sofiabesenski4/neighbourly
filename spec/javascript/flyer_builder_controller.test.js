import test from "node:test";
import assert from "node:assert/strict";

import FlyerBuilderController from "../../app/javascript/controllers/flyer_builder_controller.js";

// Captures preview requests without a browser.
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

test("resource cards separate visible contacts from the details disclosure", () => {
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
      }),
    };

    const controller = Object.create(FlyerBuilderController.prototype);
    controller.excludedServiceIds = new Set();
    Object.defineProperty(controller, "summaryLabelsValue", {
      value: ["Phone"],
    });
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
    assert.match(
      article.children[1].children[0].children[1].className,
      /\bwhitespace-pre-line\b/,
    );
    assert.equal(
      article.children[1].children[0].children[1].textContent,
      "250-555-0100",
    );
    const disclosure = article.children[2];
    assert.equal(disclosure.tagName, "details");
    assert.equal(disclosure.children[0].textContent, "See details");
    assert.equal(
      disclosure.children[1].children[0].children[1].textContent,
      "Monday",
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
      getAttribute() {},
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
