import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["input", "submit", "response"];

  initialize() {
    this.responding = false;
    this.widths = new WeakMap();
    this.observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        if (this.widths.get(entry.target) !== entry.contentRect.width) {
          this.widths.set(entry.target, entry.contentRect.width);
          this.resize();
        }
      }
    });
  }

  connect() {
    this.observer.observe(this.inputTarget);
    this.resize();
  }

  disconnect() {
    this.observer.disconnect();
  }

  inputTargetConnected(input) {
    this.observer.observe(input);
    this.resize();
  }

  inputTargetDisconnected(input) {
    this.observer.unobserve(input);
  }

  responseTargetConnected(response) {
    this.responding = response.dataset.responding === "true";
    if (this.hasInputTarget && this.hasSubmitTarget) this.resize();
  }

  resize() {
    const input = this.inputTarget;
    const scrollTop = input.scrollTop;
    input.style.height = "auto";
    input.style.height = `${input.scrollHeight}px`;
    input.scrollTop = scrollTop;

    // Respect Turbo's disabled submit button while a request is in progress.
    if (!input.form.hasAttribute("aria-busy")) {
      this.submitTarget.disabled =
        this.responding || input.value.trim().length === 0;
    }
  }

  submitOnEnter(event) {
    // 229 is the legacy IME key code; confirming text must not submit it.
    if (
      event.key !== "Enter" ||
      event.shiftKey ||
      event.ctrlKey ||
      event.altKey ||
      event.metaKey ||
      event.isComposing ||
      event.keyCode === 229
    )
      return;

    event.preventDefault();
    if (
      event.repeat ||
      this.submitTarget.disabled ||
      !this.inputTarget.value.trim()
    )
      return;

    this.inputTarget.form.requestSubmit(this.submitTarget);
  }

  validate(event) {
    if (!this.inputTarget.value.trim()) {
      event.preventDefault();
      this.inputTarget.focus();
    }
  }

  useSuggestion(event) {
    this.inputTarget.value = event.params.prompt;
    this.resize();
    this.inputTarget.focus();
  }
}
