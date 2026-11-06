const headerName = "X-Neighbourly-Guest-Token";
let tabKey;
let conversationPath;
let restoringPrivatePage = false;

function guestPage() {
  return document.body?.dataset.guestChatPage === "true";
}

function guestSupportPage() {
  return document.body?.dataset.guestSupportPage === "true";
}

function clearTabAccess() {
  tabKey = undefined;
  conversationPath = undefined;
}

function chatUrl(url) {
  return (
    url.origin === window.location.origin &&
    /^\/(?:start-chat$|(?:guest-)?chats(?:\/|$))/.test(url.pathname)
  );
}

export function guestChatHeaders(url) {
  return guestSupportPage() && tabKey && chatUrl(url)
    ? { [headerName]: tabKey }
    : {};
}

document.addEventListener("turbo:before-fetch-request", (event) => {
  const { url, fetchOptions } = event.detail;
  if (!guestSupportPage() || !chatUrl(url)) return;

  if (
    !tabKey &&
    fetchOptions.method.toUpperCase() === "POST" &&
    ["/start-chat", "/chats"].includes(url.pathname)
  ) {
    const bytes = window.crypto.getRandomValues(new Uint8Array(32));
    tabKey = Array.from(bytes, (byte) =>
      byte.toString(16).padStart(2, "0"),
    ).join("");
  }

  if (tabKey) {
    const headers = new Headers(fetchOptions.headers);
    headers.set(headerName, tabKey);
    fetchOptions.headers = headers;
  }
});

document.addEventListener("turbo:before-render", (event) => {
  if (event.detail.newBody.dataset.guestSupportPage !== "true")
    clearTabAccess();
});

document.addEventListener("turbo:load", () => {
  if (!guestSupportPage() || !tabKey) return;

  const path = window.location.pathname;
  if (/^\/guest-chats\/\d+$/.test(path)) conversationPath = path;

  if (conversationPath) {
    document
      .querySelector("a[data-guest-chat-return]")
      ?.setAttribute("href", conversationPath);
  }
  for (const link of document.querySelectorAll("a[data-guest-printout-link]")) {
    link.removeAttribute("data-turbo");
  }
});

// Full document navigation also covers browsers that keep the old page alive
// in their back/forward cache. Hide its contents before the browser saves it.
window.addEventListener("pagehide", () => {
  clearTabAccess();
  if (guestPage()) {
    const main = document.querySelector("main");
    if (main) main.hidden = true;
    restoringPrivatePage = true;
  }
});

window.addEventListener("pageshow", (event) => {
  if (event.persisted && restoringPrivatePage) window.location.reload();
});
