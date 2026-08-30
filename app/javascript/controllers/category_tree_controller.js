import { Controller } from "@hotwired/stimulus";

// Connects to data-controller="category-tree"
// Keeps parent/child checkboxes in sync inside the category dropdown:
//   - checking a parent automatically checks all its children
//   - unchecking a parent automatically unchecks all its children
//   - children are disabled (greyed, non-interactive) while their parent
//     is checked, since they roll up into it and would be redundant params
// Children are linked to their parent via `data-parent-id` on the checkbox.
export default class extends Controller {
  static targets = ["checkbox"];

  connect() {
    this.applyState();
  }

  toggle(event) {
    const checkbox = event.target;
    if (!this.hasParentId(checkbox)) return;

    const parentId = checkbox.dataset.parentId;
    const children = this.checkboxTargets.filter(
      (cb) => cb.dataset.parentId === parentId
    );

    if (checkbox.checked) {
      children.forEach((cb) => {
        cb.checked = true;
        cb.disabled = true;
      });
    } else {
      children.forEach((cb) => {
        cb.checked = false;
        cb.disabled = false;
      });
    }
  }

  // On load, sync disabled state for children whose parent is checked.
  applyState() {
    this.checkboxTargets.forEach((cb) => {
      if (!this.hasParentId(cb)) return;
      const parent = this.checkboxTargets.find(
        (p) => p.value === cb.dataset.parentId
      );
      if (parent?.checked) {
        cb.checked = true;
        cb.disabled = true;
      }
    });
  }

  hasParentId(checkbox) {
    return checkbox.dataset.parentId !== undefined;
  }
}
