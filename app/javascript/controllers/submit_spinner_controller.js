import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["button", "spinner"];

  submit() {
    this.buttonTarget.disabled = true;
    this.buttonTarget.classList.add("opacity-50", "cursor-not-allowed");
    this.spinnerTarget.classList.remove("hidden");
    this.spinnerTarget.classList.add("inline-flex");
  }
}
