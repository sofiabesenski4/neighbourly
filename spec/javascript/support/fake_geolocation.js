// Runs a test with a fake navigator.geolocation that holds the browser's answer until the
// test gives it. Pass {supported: false} for a browser without geolocation.
export function withFakeGeolocation(run, { supported = true } = {}) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "navigator");
  const pending = [];
  const geolocation = {
    getCurrentPosition: (success, failure, options) =>
      pending.push({ success, failure, options }),
  };
  Object.defineProperty(globalThis, "navigator", {
    configurable: true,
    value: supported ? { geolocation } : {},
  });
  try {
    run(pending);
  } finally {
    if (previous) Object.defineProperty(globalThis, "navigator", previous);
    else delete globalThis.navigator;
  }
}
