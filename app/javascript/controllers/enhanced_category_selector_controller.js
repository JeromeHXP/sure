import { Controller } from "@hotwired/stimulus";

// Enhanced category selector with tree view, selection counts, and independent selection.
// Form submission is deferred until the popover closes so users can toggle
// multiple checkboxes without the page reloading on every change.
export default class extends Controller {
  static targets = ["checkbox", "groupContainer", "groupToggle", "groupContent", "selectionCount"];

  connect() {
    this.selectionsChanged = false;
    this.updateSelectionStates();
    this.updateGroupExpansionStates();
    this.setupCloseObserver();
  }

  disconnect() {
    if (this.observer) {
      this.observer.disconnect();
      this.observer = null;
    }
  }

  // Watch the popover content ancestor for the "hidden" class — when the
  // popover closes and the user made changes, submit the form.
  setupCloseObserver() {
    const popoverContent = this.element.closest('[data-ds--popover-target="content"]');
    if (!popoverContent) return;

    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.attributeName === "class" && popoverContent.classList.contains("hidden")) {
          if (this.selectionsChanged) {
            this.submitForm();
          }
        }
      }
    });
    this.observer.observe(popoverContent, { attributes: true, attributeFilter: ["class"] });
  }

  submitForm() {
    const form = document.getElementById("category_analyses_filter_form");
    if (form) {
      form.requestSubmit();
    }
  }

  // Get all descendant category IDs for a given parent
  getAllDescendants(parentId) {
    const children = this.getChildren(parentId);
    const descendants = [];
    children.forEach(childId => {
      descendants.push(childId);
      const nestedChildren = this.getChildren(childId);
      nestedChildren.forEach(nestedId => descendants.push(nestedId));
    });
    return descendants;
  }

  // Get direct children for a parent
  getChildren(parentId) {
    return this.checkboxTargets
      .filter(cb => cb.dataset.parentId === parentId)
      .map(cb => cb.value);
  }

  // Toggle a category group (expand/collapse)
  toggleGroup(event) {
    event.preventDefault();
    const button = event.currentTarget;
    const groupId = button.dataset.enhancedCategorySelectorGroupIdValue;
    const content = this.groupContentTargets.find(c => c.dataset.enhancedCategorySelectorGroupIdValue === groupId);
    const container = this.groupContainerTargets.find(c => c.dataset.enhancedCategorySelectorGroupIdValue === groupId);

    if (content && container) {
      const isExpanded = content.classList.toggle('hidden');
      container.classList.toggle('bg-container-inset-hover', !isExpanded);
      button.querySelector('svg').classList.toggle('rotate-90', !isExpanded);
      button.setAttribute('aria-expanded', !isExpanded);
    }
  }

  // Toggle all groups (expand/collapse all)
  toggleAllGroups(event) {
    event.preventDefault();
    const button = event.currentTarget;
    const action = button.dataset.enhancedCategorySelectorActionTypeValue;
    const shouldExpand = action === 'expand';

    this.groupContentTargets.forEach(content => {
      content.classList.toggle('hidden', !shouldExpand);
    });

    this.groupToggleTargets.forEach(button => {
      button.setAttribute('aria-expanded', shouldExpand);
      button.querySelector('svg').classList.toggle('rotate-90', shouldExpand);
    });
  }

  // Handle checkbox change - independent selection (no parent/child sync)
  handleCheckboxChange(event) {
    this.selectionsChanged = true;
    this.updateSelectionStates();
  }

  // Update selection count displays for parent categories
  updateSelectionStates() {
    const parentCategories = this.checkboxTargets.filter(cb => !cb.dataset.parentId);

    parentCategories.forEach(parentCheckbox => {
      const parentId = parentCheckbox.value;
      const children = this.getChildren(parentId);
      const allInGroup = [parentId, ...children];

      const selectedInGroup = allInGroup.filter(id => {
        const cb = this.checkboxTargets.find(c => c.value === id);
        return cb && cb.checked;
      }).length;

      const totalInGroup = allInGroup.length;

      // Update the selection count display
      const countTarget = this.selectionCountTargets.find(t => t.dataset.enhancedCategorySelectorGroupIdValue === parentId);
      if (countTarget) {
        if (selectedInGroup === 0) {
          countTarget.textContent = '';
          countTarget.classList.add('hidden');
        } else {
          countTarget.textContent = `(${selectedInGroup}/${totalInGroup})`;
          countTarget.classList.remove('hidden');
        }
      }

      // Update parent checkbox indeterminate state
      const allChecked = selectedInGroup === totalInGroup;
      const someChecked = selectedInGroup > 0 && selectedInGroup < totalInGroup;

      if (someChecked) {
        parentCheckbox.indeterminate = true;
      } else {
        parentCheckbox.indeterminate = false;
      }
    });
  }

  // Update expand/collapse state based on whether group has selected items
  updateGroupExpansionStates() {
    this.groupContainerTargets.forEach(container => {
      const groupId = container.dataset.enhancedCategorySelectorGroupIdValue;
      const content = this.groupContentTargets.find(c => c.dataset.enhancedCategorySelectorGroupIdValue === groupId);
      if (!content) return;

      const checkboxesInGroup = this.checkboxTargets.filter(cb => {
        return cb.value === groupId ||
               (cb.dataset.parentId === groupId) ||
               this.getAllDescendants(groupId).includes(cb.value);
      });

      const anySelected = checkboxesInGroup.some(cb => cb.checked);

      if (anySelected) {
        content.classList.remove('hidden');
        const toggle = this.groupToggleTargets.find(t => t.dataset.enhancedCategorySelectorGroupIdValue === groupId);
        if (toggle) {
          toggle.setAttribute('aria-expanded', 'true');
          toggle.querySelector('svg').classList.add('rotate-90');
        }
      }
    });
  }

  // Select/deselect all in a group
  selectGroup(event) {
    event.preventDefault();
    const button = event.currentTarget;
    const groupId = button.dataset.enhancedCategorySelectorGroupIdValue;
    const action = button.dataset.enhancedCategorySelectorActionTypeValue;
    const isSelect = action === 'select';

    const checkboxesInGroup = this.checkboxTargets.filter(cb => {
      return cb.value === groupId ||
             (cb.dataset.parentId === groupId) ||
             this.getAllDescendants(groupId).includes(cb.value);
    });

    checkboxesInGroup.forEach(cb => {
      if (!cb.disabled) {
        cb.checked = isSelect;
      }
    });

    this.selectionsChanged = true;
    this.updateSelectionStates();
  }

  // Explicitly apply changes (via Apply button)
  apply(event) {
    event.preventDefault();
    this.submitForm();
  }

  // Reset all selections
  resetAll(event) {
    event.preventDefault();
    this.checkboxTargets.forEach(cb => {
      cb.checked = false;
      cb.indeterminate = false;
    });
    this.selectionsChanged = true;
    this.updateSelectionStates();
  }

  // Select all
  selectAll(event) {
    event.preventDefault();
    this.checkboxTargets.forEach(cb => {
      if (!cb.disabled) {
        cb.checked = true;
      }
    });
    this.selectionsChanged = true;
    this.updateSelectionStates();
  }
}
