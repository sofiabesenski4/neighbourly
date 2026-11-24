// Covers the shared code that asks the browser where the device is. How each page uses it
// is in flyer_builder_controller.test.js and device_location_controller.test.js.
import test from "node:test";
import assert from "node:assert/strict";

import {
  deviceLocationSupported,
  describeAccuracy,
  requestDeviceLocation,
} from "../../app/javascript/lib/device_location.js";
import { withFakeGeolocation } from "./support/fake_geolocation.js";

test("knows whether the browser can find the device", () => {
  withFakeGeolocation(() => assert.equal(deviceLocationSupported(), true));
  withFakeGeolocation(() => assert.equal(deviceLocationSupported(), false), {
    supported: false,
  });
});

test("gives only a rounded position, with its accuracy", () => {
  withFakeGeolocation((pending) => {
    const found = [];
    requestDeviceLocation((result) => found.push(result), assert.fail);
    pending[0].success({
      coords: { latitude: 48.427113, longitude: -123.357764, accuracy: 40 },
    });

    assert.deepEqual(found, [{ lat: "48.427", lng: "-123.358", accuracy: 40 }]);
  });
});

test("settles for a rough, recent position, and doesn't wait for long", () => {
  withFakeGeolocation((pending) => {
    requestDeviceLocation(assert.fail, assert.fail);

    assert.deepEqual(pending[0].options, { timeout: 10000, maximumAge: 60000 });
  });
});

test("tells a denied request from one that failed", () => {
  for (const [code, message] of [
    [1, /turned off/],
    [2, /couldn't find/],
    [3, /couldn't find/],
  ]) {
    withFakeGeolocation((pending) => {
      const messages = [];
      requestDeviceLocation(assert.fail, (text) => messages.push(text));
      pending[0].failure({ code });

      assert.match(messages[0], message);
    });
  }
});

test("calls a position rough from 1 km", () => {
  assert.deepEqual(describeAccuracy(999), {
    rough: false,
    text: "accurate to about 999 m",
  });
  assert.deepEqual(describeAccuracy(1000), {
    rough: true,
    text: "may be off by about 1 km",
  });
});
