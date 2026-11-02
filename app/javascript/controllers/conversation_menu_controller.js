import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["trigger", "menu"];

  connect() {
    this.triggerTarget.popoverTargetElement = this.menuTarget;
    this.syncState({
      newState: this.menuTarget.matches(":popover-open") ? "open" : "closed",
    });
  }

  position() {
    const trigger = this.triggerTarget.getBoundingClientRect();
    const menu = this.menuTarget.getBoundingClientRect();
    const top =
      trigger.bottom + menu.height + 4 <= window.innerHeight
        ? trigger.bottom + 4
        : Math.max(8, trigger.top - menu.height - 4);
    this.menuTarget.style.top = `${top}px`;
    this.menuTarget.style.left = `${Math.max(8, Math.min(trigger.right - menu.width, window.innerWidth - menu.width - 8))}px`;
  }

  focusItem(event) {
    event?.preventDefault();
    this.menuTarget.querySelector("[role='menuitem']").focus();
  }

  close(event) {
    event?.preventDefault();
    this.menuTarget.hidePopover();
    this.triggerTarget.focus();
  }

  leave() {
    this.menuTarget.hidePopover();
  }

  syncState(event) {
    this.triggerTarget.setAttribute(
      "aria-expanded",
      String(event.newState === "open"),
    );
    if (event.newState === "open") {
      this.position();
      this.focusItem();
    }
  }
}
