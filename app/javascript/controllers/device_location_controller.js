import { Controller } from "@hotwired/stimulus";
import {
  deviceLocationSupported,
  describeAccuracy,
  requestDeviceLocation,
} from "../lib/device_location.js";

// "Use my location" on the questionnaire's location question.
//
// Architecture: lives in app/views/questionnaires/_location.html.erb. It fills in hidden
// fields, which the form submits with everything else. It doesn't submit the form itself,
// so someone can see how accurate the position is before pressing Next. The printout has
// its own controller, and both use lib/device_location.js to ask the browser.
//
// Without JavaScript the button stays hidden and a place can still be typed.
export default class extends Controller {
  static targets = [
    "offer",
    "status",
    "near",
    "device",
    "checked",
    "lat",
    "lng",
  ];

  connect() {
    this.request = 0;
    this.offerTarget.hidden = !deviceLocationSupported();
  }

  // An answer that comes after the page has gone must not change anything.
  disconnect() {
    this.request += 1;
  }

  use() {
    this.forget();
    const request = this.request;
    this.showStatus("Finding your location…");
    requestDeviceLocation(
      (position) => {
        // The person typed a place or asked again while the browser was working.
        if (request === this.request) this.apply(position);
      },
      (message) => {
        if (request === this.request) this.showStatus(message);
      },
    );
  }

  // A typed place and a device location replace each other, so it's always clear which
  // one is being used. `checked` belongs to a typed place, and forget has emptied it.
  apply({ lat, lng, accuracy }) {
    this.deviceTarget.value = "1";
    this.latTarget.value = lat;
    this.lngTarget.value = lng;
    this.nearTarget.value = "";

    const { rough, text } = describeAccuracy(accuracy);
    this.showStatus(
      rough
        ? `Using your location, which ${text}. If that's too far, type a nearby place instead.`
        : `Using your location (${text}). Press Next to continue.`,
    );
  }

  // Runs as someone types. Moving on the request number means an answer still on its way
  // is ignored.
  forget() {
    this.request += 1;
    this.deviceTarget.value = "";
    this.checkedTarget.value = "";
    this.latTarget.value = "";
    this.lngTarget.value = "";
    this.statusTarget.textContent = "";
    this.statusTarget.hidden = true;
  }

  showStatus(message) {
    this.statusTarget.textContent = message;
    this.statusTarget.hidden = false;
  }
}
