import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["viewport", "content", "jump"];

  initialize() {
    this.pause = () => {
      this.following = false;
    };
    this.wheel = (event) => {
      if (event.deltaY < 0) this.pause();
    };
    this.keydown = (event) => {
      if (
        ["ArrowUp", "PageUp", "Home"].includes(event.key) ||
        (event.key === " " && event.shiftKey)
      )
        this.pause();
    };
  }

  connect() {
    this.following = true;
    this.unseen = false;
    this.frame = null;
    this.rememberGeometry();
    this.viewportTarget.addEventListener("pointerdown", this.pause, {
      passive: true,
    });
    this.viewportTarget.addEventListener("wheel", this.wheel, {
      passive: true,
    });
    this.viewportTarget.addEventListener("keydown", this.keydown);

    this.mutations = new MutationObserver(() => {
      if (!this.following) this.unseen = true;
      this.scheduleUpdate();
    });
    this.mutations.observe(this.contentTarget, {
      childList: true,
      characterData: true,
      subtree: true,
    });

    // Markdown rendering and composer resizing can change the available height
    // after a chunk arrives, without creating another message.
    this.sizes = new ResizeObserver(() => this.scheduleUpdate());
    this.sizes.observe(this.contentTarget);
    this.sizes.observe(this.viewportTarget);
    this.scheduleUpdate();
  }

  disconnect() {
    this.mutations.disconnect();
    this.sizes.disconnect();
    this.viewportTarget.removeEventListener("pointerdown", this.pause);
    this.viewportTarget.removeEventListener("wheel", this.wheel);
    this.viewportTarget.removeEventListener("keydown", this.keydown);
    cancelAnimationFrame(this.frame);
    this.frame = null;
  }

  scrolled() {
    const viewport = this.viewportTarget;
    const distance = this.distanceFromBottom();
    if (distance <= 2) {
      this.following = true;
      this.unseen = false;
      this.scheduleUpdate();
      this.updateJump();
      return;
    }
    // Native scroll anchoring can emit scroll events while Markdown or the
    // composer changes size. Preserve the reading intent across those events.
    if (
      viewport.scrollHeight !== this.contentHeight ||
      viewport.clientHeight !== this.viewportHeight
    ) {
      this.scheduleUpdate();
      return;
    }
    if (distance > 64) this.following = false;
    if (this.following) this.unseen = false;
    this.updateJump();
  }

  jumpToLatest() {
    this.following = true;
    this.unseen = false;
    this.scheduleUpdate();
    this.viewportTarget.focus({ preventScroll: true });
  }

  scheduleUpdate() {
    if (this.frame !== null) return;

    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      if (this.following)
        this.viewportTarget.scrollTop = this.viewportTarget.scrollHeight;
      this.rememberGeometry();
      this.updateJump();
    });
  }

  updateJump() {
    this.jumpTarget.hidden = this.following || !this.unseen;
  }

  distanceFromBottom() {
    const viewport = this.viewportTarget;
    return viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop;
  }

  rememberGeometry() {
    this.contentHeight = this.viewportTarget.scrollHeight;
    this.viewportHeight = this.viewportTarget.clientHeight;
  }
}
