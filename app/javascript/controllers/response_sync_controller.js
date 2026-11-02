import { Controller } from "@hotwired/stimulus";
import { Turbo } from "@hotwired/turbo-rails";

// Cable delivers live updates; HTTP repairs gaps after reconnecting or resuming.
export default class extends Controller {
  static targets = ["status"];
  static values = { url: String, streamId: String };

  connect() {
    this.active = true;
    this.latest = [0n, 0n];
    this.assistantIds = new Map();
    this.boundary = "0";
    this.needsReconcile = false;
    this.beforeStream = this.beforeStream.bind(this);
    this.resume = this.resume.bind(this);
    document.addEventListener("turbo:before-stream-render", this.beforeStream);
    document.addEventListener("visibilitychange", this.resume);
    window.addEventListener("online", this.resume);
    window.addEventListener("pageshow", this.resume);
    window.addEventListener("focus", this.resume);
    this.stream = document.getElementById(this.streamIdValue);
    this.observer = new MutationObserver(() => {
      if (this.connected) this.refresh();
      this.schedulePoll();
    });
    if (this.stream) {
      this.observer.observe(this.stream, {
        attributes: true,
        attributeFilter: ["connected"],
      });
    }
    if (this.hasStatusTarget) this.statusTargetConnected(this.statusTarget);
    this.refresh();
  }

  disconnect() {
    this.active = false;
    document.removeEventListener(
      "turbo:before-stream-render",
      this.beforeStream,
    );
    document.removeEventListener("visibilitychange", this.resume);
    window.removeEventListener("online", this.resume);
    window.removeEventListener("pageshow", this.resume);
    window.removeEventListener("focus", this.resume);
    this.observer.disconnect();
    this.request?.abort();
    this.request = null;
    clearTimeout(this.poll);
    clearTimeout(this.reconcile);
  }

  statusTargetConnected(element) {
    if (!this.latest) return;
    const token = this.token(element);
    if (this.older(token)) return;
    const responseId = element.dataset.responseId;
    const assistantId = element.dataset.assistantMessageId;
    const previousId = this.assistantIds.get(responseId);
    if (previousId && previousId !== assistantId) {
      this.element
        .querySelector(`#message_${CSS.escape(previousId)}`)
        ?.remove();
    }
    this.assistantIds.set(responseId, assistantId);
    this.remember(token);
    this.schedulePoll();
  }

  get connected() {
    return this.stream?.hasAttribute("connected") || false;
  }

  token(element) {
    return [
      BigInt(element.dataset.responseId || "0"),
      BigInt(element.dataset.responseVersion || "0"),
    ];
  }

  older(token) {
    return (
      token[0] < this.latest[0] ||
      (token[0] === this.latest[0] && token[1] < this.latest[1])
    );
  }

  remember(token) {
    if (!this.older(token)) this.latest = token;
  }

  beforeStream(event) {
    const stream = event.target;
    const status = stream.templateElement.content.querySelector(
      '[data-response-sync-target~="status"]',
    );
    const snapshot = stream.dataset.responseSnapshot === "true";
    const message =
      stream.templateElement.content.firstElementChild?.hasAttribute(
        "data-message-version",
      );
    if (status && (!this.hasStatusTarget || status.id !== this.statusTarget.id))
      return;
    if (!status && !snapshot && !message) return;
    if (
      (snapshot || message) &&
      !this.element.querySelector(`#${CSS.escape(stream.target)}`) &&
      stream.target !== "messages"
    )
      return;

    const token = status || snapshot ? this.token(status || stream) : null;
    const originalRender = event.detail.render;
    event.detail.render = async (element) => {
      // Check at render time too: a newer Cable stream may arrive while HTTP waits.
      if (token && this.older(token)) {
        if (snapshot) {
          // This HTTP batch lost a race with Cable. Recheck its historical gap.
          this.boundary = "0";
          this.needsReconcile = true;
          clearTimeout(this.reconcile);
          this.reconcile = setTimeout(() => this.refresh(), 0);
        }
        return;
      }
      if (snapshot || message) {
        const incoming = stream.templateElement.content.firstElementChild;
        const current = incoming && document.getElementById(incoming.id);
        if (current && this.element.contains(current)) {
          const incomingVersion = BigInt(
            incoming.dataset.messageVersion || "0",
          );
          const currentVersion = BigInt(current.dataset.messageVersion || "0");
          if (incomingVersion < currentVersion) return;
          if (incomingVersion === currentVersion) {
            if (
              incoming.dataset.messageEnrichment ===
                current.dataset.messageEnrichment ||
              this.sameEnrichment(incoming, current)
            )
              return;
          }
        }
      }
      if (token) this.remember(token);
      await originalRender(element);
      if (message)
        this.orderMessage(stream.templateElement.content.firstElementChild?.id);
    };
  }

  orderMessage(id) {
    if (!id?.match(/^message_\d+$/)) return;
    const message = this.element.querySelector(`#${CSS.escape(id)}`);
    const transcript = message?.parentElement;
    if (transcript?.id !== "messages") return;
    const next = Array.from(transcript.children).find(
      (candidate) =>
        candidate.id.match(/^message_\d+$/) &&
        BigInt(candidate.id.slice(8)) > BigInt(id.slice(8)),
    );
    if (next) transcript.insertBefore(message, next);
  }

  resume() {
    if (!document.hidden) this.refresh();
  }

  sameEnrichment(incoming, current) {
    const references = (element) =>
      Array.from(
        element.querySelectorAll("[data-reference-id]"),
        (reference) => reference.dataset.referenceId,
      ).join(",");
    const model = (element) =>
      element.querySelector("[data-reply-model]")?.textContent.trim() || "";
    return (
      references(incoming) === references(current) &&
      model(incoming) === model(current)
    );
  }

  async refresh() {
    if (!this.active || this.request || document.hidden || !this.hasUrlValue)
      return;
    const request = new AbortController();
    this.request = request;
    this.needsReconcile = false;
    try {
      const url = new URL(this.urlValue, window.location.href);
      url.searchParams.set("after_response_id", this.boundary);
      const response = await fetch(url, {
        headers: { Accept: "text/vnd.turbo-stream.html" },
        credentials: "same-origin",
        cache: "no-store",
        signal: request.signal,
      });
      if (
        response.ok &&
        !response.redirected &&
        response.headers
          .get("Content-Type")
          ?.includes("text/vnd.turbo-stream.html") &&
        this.active &&
        !request.signal.aborted
      ) {
        Turbo.renderStreamMessage(await response.text());
        const boundary =
          response.headers.get("X-Chat-Response-Boundary") || "0";
        if (BigInt(boundary) > BigInt(this.boundary)) this.boundary = boundary;
      }
    } catch (error) {
      // A lost connection is retried on reconnect, resume, or the busy fallback.
      if (error.name !== "AbortError") this.schedulePoll();
    } finally {
      if (this.request === request) {
        this.request = null;
        this.schedulePoll();
        if (this.needsReconcile) {
          clearTimeout(this.reconcile);
          this.reconcile = setTimeout(() => this.refresh(), 0);
        }
      }
    }
  }

  schedulePoll() {
    clearTimeout(this.poll);
    if (
      this.active &&
      !document.hidden &&
      this.hasStatusTarget &&
      this.statusTarget.dataset.responding === "true"
    ) {
      this.poll = setTimeout(
        () => this.refresh(),
        this.connected ? 15000 : 5000,
      );
    }
  }
}
