// Covers the questionnaire's "Use my location" button. Real Chrome covers the normal paths in
// spec/system/questionnaire_spec.rb. These are mostly the cases a browser can't easily be
// made to produce, like late answers and timeouts. What the server does with the hidden
// fields is in spec/models/questionnaire/location_answer_spec.rb.
import test from "node:test";
import assert from "node:assert/strict";

import DeviceLocationController from "../../app/javascript/controllers/device_location_controller.js";
import { withFakeGeolocation } from "./support/fake_geolocation.js";

const position = {
  coords: { latitude: 48.427113, longitude: -123.357764, accuracy: 40 },
};

// A controller with stand-ins for the parts of the page it uses.
function locationController() {
  const controller = Object.create(DeviceLocationController.prototype);
  controller.offerTarget = { hidden: true };
  controller.statusTarget = { textContent: "", hidden: true };
  for (const name of ["near", "device", "checked", "lat", "lng"]) {
    controller[`${name}Target`] = { value: "" };
  }
  controller.connect();
  return controller;
}

function assertNoLocation(controller) {
  for (const name of ["device", "checked", "lat", "lng"]) {
    assert.equal(controller[`${name}Target`].value, "", name);
  }
}

test("offers the button only when the browser can find the device", () => {
  withFakeGeolocation(() =>
    assert.equal(locationController().offerTarget.hidden, false),
  );
  withFakeGeolocation(
    () => assert.equal(locationController().offerTarget.hidden, true),
    { supported: false },
  );
});

test("asks nothing until the button is pressed", () => {
  withFakeGeolocation((pending) => {
    locationController();

    assert.equal(pending.length, 0);
  });
});

test("fills in a rounded position, replacing a typed place, and says how accurate it is", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.nearTarget.value = "919 Pandora Ave";
    controller.checkedTarget.value = "919 Pandora Ave";

    controller.use();
    assert.equal(controller.statusTarget.textContent, "Finding your location…");
    assert.equal(controller.statusTarget.hidden, false);
    pending[0].success(position);

    assert.equal(controller.deviceTarget.value, "1");
    assert.equal(controller.latTarget.value, "48.427");
    assert.equal(controller.lngTarget.value, "-123.358");
    assert.equal(controller.nearTarget.value, "");
    assert.equal(controller.checkedTarget.value, "");
    assert.equal(
      controller.statusTarget.textContent,
      "Using your location (accurate to about 40 m). Press Next to continue.",
    );
  });
});

test("warns when the position is rough", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.use();
    pending[0].success({ coords: { ...position.coords, accuracy: 3000 } });

    assert.match(
      controller.statusTarget.textContent,
      /may be off by about 3 km.*type a nearby place/,
    );
  });
});

test("says what happened when access is denied, or the location isn't found in time", () => {
  for (const [code, message] of [
    [1, /turned off for this site/],
    [2, /couldn't find your location/],
    [3, /couldn't find your location/],
  ]) {
    withFakeGeolocation((pending) => {
      const controller = locationController();
      controller.nearTarget.value = "919 Pandora Ave";
      controller.use();
      assert.equal(pending[0].options.timeout, 10000);
      pending[0].failure({ code });

      assert.match(controller.statusTarget.textContent, message);
      assert.equal(controller.nearTarget.value, "919 Pandora Ave");
      assertNoLocation(controller);
    });
  }
});

test("typing a place drops the device's location and its message", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.use();
    pending[0].success(position);

    controller.nearTarget.value = "9";
    controller.forget();

    assertNoLocation(controller);
    assert.equal(controller.statusTarget.hidden, true);
    assert.equal(controller.nearTarget.value, "9");
  });
});

// The browser can take a long time to answer, especially while its permission prompt is
// open. A late answer must not replace what the person has done since.
test("ignores an answer that comes after typing a place", () => {
  for (const answer of ["success", "failure"]) {
    withFakeGeolocation((pending) => {
      const controller = locationController();
      controller.use();
      controller.nearTarget.value = "919 Pandora Ave";
      controller.forget();
      pending[0][answer](answer === "success" ? position : { code: 1 });

      assertNoLocation(controller);
      assert.equal(controller.nearTarget.value, "919 Pandora Ave");
      assert.equal(controller.statusTarget.hidden, true);
    });
  }
});

test("ignores an answer that comes after the page has gone", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.use();
    controller.disconnect();
    pending[0].success(position);

    assertNoLocation(controller);
  });
});

test("only the latest of several requests is used", () => {
  withFakeGeolocation((pending) => {
    const controller = locationController();
    controller.use();
    controller.use();

    pending[0].success(position);
    assertNoLocation(controller);
    pending[1].success(position);
    assert.equal(controller.latTarget.value, "48.427");
  });
});
