import { Controller } from "@hotwired/stimulus";

// Saves and restores the category analysis page filter state so that
// navigating away and coming back (via the nav bar link, not the back
// button) restores the previously selected filters. The browser's back
// button already works because the URL contains all GET params.
export default class extends Controller {
  connect() {
    const currentParams = new URLSearchParams(window.location.search);

    if (currentParams.toString().length > 0) {
      // Page loaded with filters — save them
      sessionStorage.setItem("category_analyses_filters", currentParams.toString());
    } else {
      // Page loaded without filters — check for saved filters
      const saved = sessionStorage.getItem("category_analyses_filters");
      if (saved && saved.length > 0) {
        // Redirect to the same page with saved filters
        window.location.replace(`${window.location.pathname}?${saved}`);
      }
    }
  }
}
