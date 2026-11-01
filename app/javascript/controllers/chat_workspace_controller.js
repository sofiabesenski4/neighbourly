import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["sidebar", "sidebarToggle", "drawer", "drawerToggle"];

  toggleSidebar() {
    const expanded = this.sidebarTarget.classList.toggle("md:flex");
    this.sidebarToggleTarget.setAttribute("aria-expanded", String(expanded));
  }

  openDrawer() {
    this.drawerTarget.showModal();
    this.drawerToggleTarget.setAttribute("aria-expanded", "true");
  }

  closeDrawer() {
    this.drawerTarget.close();
    this.drawerClosed();
  }

  drawerClosed() {
    this.drawerToggleTarget.setAttribute("aria-expanded", "false");
  }

  closeOutside(event) {
    if (event.target === this.drawerTarget) this.closeDrawer();
  }

  disconnect() {
    this.closeDrawer();
  }
}
