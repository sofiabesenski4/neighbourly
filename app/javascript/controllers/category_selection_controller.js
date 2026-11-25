import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["option", "actions"];

  connect() {
    if (this.hasActionsTarget) this.actionsTarget.hidden = this.optionTargets.length === 0;
    const selected = new Set();
    // Both views render each parent before its descendants.
    for (const option of this.optionTargets) {
      if (selected.has(option.dataset.categorySelectionParent)) {
        option.checked = true;
      }
      if (option.checked) selected.add(option.value);
    }
  }

  setAll({ params: { checked } }) {
    if (this.optionTargets.every((option) => option.checked === checked)) return;
    this.optionTargets.forEach((option) => (option.checked = checked));
    this.dispatch("selection-changed");
  }

  update({ target }) {
    const options = this.optionTargets;
    if (!options.includes(target)) return;

    const changed = new Set([target.value]);
    for (const option of options) {
      if (changed.has(option.dataset.categorySelectionParent)) {
        option.checked = target.checked;
        changed.add(option.value);
      }
    }

    if (target.checked) return;

    // A checked ancestor would include a child the user just cleared.
    const optionsByValue = new Map(
      options.map((option) => [option.value, option]),
    );
    let parent = optionsByValue.get(target.dataset.categorySelectionParent);
    while (parent) {
      parent.checked = false;
      parent = optionsByValue.get(parent.dataset.categorySelectionParent);
    }
  }
}
