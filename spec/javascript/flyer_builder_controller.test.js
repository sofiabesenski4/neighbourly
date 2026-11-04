import test from "node:test";
import assert from "node:assert/strict";

import FlyerBuilderController from "../../app/javascript/controllers/flyer_builder_controller.js";

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
