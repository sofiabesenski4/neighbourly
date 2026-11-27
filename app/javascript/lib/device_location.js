// Finding where the device is, for the printout and the questionnaire.
//
// Architecture: this asks the browser and prepares what it says. Each page's controller
// decides what to do with the result, and whether it's still wanted by the time it comes.
// It uses callbacks because that's how the browser answers: a promise would add a delay
// between the answer arriving and the page using it.
//
// Privacy: positions are rounded to 3 decimal places, about 100 m, before anything else
// sees them, so an exact position never leaves the browser.

// Whether the browser can do this at all.
export function deviceLocationSupported() {
  return Boolean(navigator.geolocation);
}

// Asks the browser where the device is. The browser shows its own permission prompt the
// first time, so the answer can take a while, or never come. Call this only when a button
// is pressed: asking when a page loads would prompt people for no clear reason.
//
// `found` gets {lat, lng, accuracy}, with rounded text coordinates and accuracy in metres.
// `failed` gets a message to show.
export function requestDeviceLocation(found, failed) {
  navigator.geolocation.getCurrentPosition(
    ({ coords: { latitude, longitude, accuracy } }) =>
      found({ lat: latitude.toFixed(3), lng: longitude.toFixed(3), accuracy }),
    (error) =>
      failed(
        // 1 is the Geolocation API's PERMISSION_DENIED.
        error.code === 1
          ? "Location access is turned off for this site. You can type a nearby place instead."
          : "We couldn't find your location. You can try again or type a nearby place instead.",
      ),
    // A rough, recent position is enough, and much faster than waiting for GPS.
    { timeout: 10000, maximumAge: 60000 },
  );
}

// Laptops estimate their position from nearby Wi-Fi and can be far off. Saying how
// accurate it is lets someone spot that before relying on the distances.
export function describeAccuracy(accuracy) {
  return accuracy >= 1000
    ? {
        rough: true,
        text: `may be off by about ${Math.round(accuracy / 1000)} km`,
      }
    : { rough: false, text: `accurate to about ${Math.round(accuracy)} m` };
}
