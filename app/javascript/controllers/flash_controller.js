import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static values = { duration: { type: Number, default: 6000 } };

  connect() {
    this.remaining = this.durationValue;
    this.resume();
  }

  disconnect() {
    clearTimeout(this.timer);
    this.timer = null;
  }

  pause() {
    if (!this.timer) return;

    clearTimeout(this.timer);
    this.timer = null;
    this.remaining = Math.max(
      0,
      this.remaining - (performance.now() - this.startedAt),
    );
  }

  resume() {
    if (
      this.timer ||
      this.durationValue <= 0 ||
      this.element.matches(":hover, :focus-within")
    )
      return;

    this.startedAt = performance.now();
    this.timer = setTimeout(() => this.dismiss(), this.remaining);
  }

  dismiss() {
    this.pause();
    this.element.remove();
  }
}
