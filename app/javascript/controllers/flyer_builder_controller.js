import { Controller } from "@hotwired/stimulus";

const DEFAULT_SORT = "default";

export default class extends Controller {
  static targets = [
    "form",
    "category",
    "toolbar",
    "sidebar",
    "desktopSearch",
    "searchField",
    "search",
    "sort",
    "filterButton",
    "filterDialog",
    "draftCategory",
    "draftSort",
    "clearSearchOrder",
    "cards",
    "count",
    "status",
    "generate",
    "generateLabel",
    "previewError",
    "previewErrorMessage",
    "printError",
    "printout",
    "pdfLink",
    "near",
    "lat",
    "lng",
    "useLocation",
    "locationStatus",
    "locationNote",
    "placeError",
    "confirmPlaceButton",
    "skipLocation",
    "locationStep",
    "locationHeading",
    "builderStep",
    "builderHeading",
    "locationSummaryRow",
    "locationSummary",
    "subtitle",
  ];
  static values = { previewUrl: String, locateUrl: String };

  connect() {
    this.revision = (this.revision || 0) + 1;
    this.hasResults = false;
    this.generating = false;
    this.locationRequest = 0;
    // Browsers can restore a page's old field values, but not which screen it was on.
    // Starting clean on the first screen means a location is never used invisibly.
    this.forgetLocationChoice();
    const supported = Boolean(navigator.geolocation);
    this.useLocationTarget.hidden = !supported;
    this.locationNoteTarget.hidden = !supported;
    this.confirmPlaceButtonTarget.hidden = false;
    this.skipLocationTarget.hidden = false;
    this.showLocationStep();
    // The guide loads behind the first screen, so it's ready when the person moves on.
    this.toolbarTarget.hidden = false;
    this.sidebarTarget.classList.add("hidden");
    this.layoutChanged();
    this.updateFilterControls();
    this.refresh();
  }

  disconnect() {
    this.beforeCache();
  }

  beforeCache() {
    this.revision += 1;
    clearTimeout(this.debounce);
    this.previewRequest?.abort();
    this.printRequest?.abort();
    this.closeFilters();
    this.clearPrintout();
    this.forgetLocationChoice();
    this.generateLabelTarget.textContent = "Generate printout";
  }

  filter() {
    this.updateFilterControls();
    clearTimeout(this.debounce);
    this.revision += 1;
    this.previewRequest?.abort();
    this.printRequest?.abort();
    this.generating = false;
    this.generateLabelTarget.textContent = "Generate printout";
    this.clearPrintout();
    this.printErrorTarget.hidden = true;
    this.setLoading();
    this.debounce = setTimeout(() => this.refresh(), 300);
  }

  // The first screen: where distances are measured from. The person has to make a
  // choice here, even if that choice is to skip, before seeing the second screen.
  showLocationStep() {
    this.locationStepTarget.hidden = false;
    this.builderStepTarget.hidden = true;
    this.locationSummaryRowTarget.hidden = true;
    // "Choose what to include" describes the second screen, not this one.
    this.subtitleTarget.hidden = true;
  }

  // The second screen: categories and preview, with a line saying what was chosen.
  // Focus moves to its heading so keyboard and screen reader users follow the change.
  // The preview reloads because its distances depend on the choice just made.
  showBuilderStep(summary) {
    this.locationSummaryTarget.textContent = summary;
    this.locationSummaryRowTarget.hidden = false;
    this.locationStepTarget.hidden = true;
    this.builderStepTarget.hidden = false;
    this.subtitleTarget.hidden = false;
    this.builderHeadingTarget.focus();
    this.refresh();
  }

  // Back to the first screen. Any printout is discarded, because its distances are
  // for the choice being changed. Selected categories and the preview are kept.
  changeLocation() {
    this.discardPrintout();
    this.showLocationStep();
    this.locationHeadingTarget.focus();
  }

  skipLocation() {
    this.forgetLocationChoice();
    this.nearTarget.value = "";
    this.showBuilderStep("Distances won't be shown on your printout.");
  }

  // Typing a place replaces any device location, so only one is ever sent.
  locationChanged() {
    this.forgetLocationChoice();
  }

  // Checks a typed place before moving on, so a place we can't find is corrected here
  // rather than discovered after choosing categories. The coordinates it returns are
  // kept for the preview and printout, so the place is only looked up this once.
  async confirmPlace() {
    const place = this.nearTarget.value.trim();
    this.forgetLocationChoice();
    if (!place) {
      this.showPlaceError(
        "Enter a street address or intersection, or choose another option.",
      );
      return;
    }

    const request = this.locationRequest;
    this.placeCheck = new AbortController();
    this.setCheckingPlace(true);
    const body = new FormData();
    body.append("flyer[near]", place);
    try {
      const response = await fetch(this.locateUrlValue, {
        method: "POST",
        headers: {
          Accept: "application/json",
          "X-CSRF-Token":
            document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        credentials: "same-origin",
        body,
        signal: this.placeCheck.signal,
      });
      const data = await response.json();
      if (request !== this.locationRequest) return;
      this.setCheckingPlace(false);
      if (!response.ok) {
        this.showPlaceError(data.errors.join(" "));
      } else if (data.located) {
        this.latTarget.value = data.lat;
        this.lngTarget.value = data.lng;
        this.showBuilderStep(`Distances from: ${place}.`);
      } else {
        // The geocoder is down. The guide can still print, so this shouldn't stop
        // the person. The printout itself explains any missing distances.
        this.showBuilderStep(
          `We can't check ${place} right now, so your printout may not show distances.`,
        );
      }
    } catch (error) {
      if (error.name === "AbortError" || request !== this.locationRequest)
        return;
      this.setCheckingPlace(false);
      this.showPlaceError(
        "We couldn't check that place. Check your connection and try again.",
      );
    }
  }

  setCheckingPlace(checking) {
    this.confirmPlaceButtonTarget.disabled = checking;
    this.confirmPlaceButtonTarget.textContent = checking
      ? "Checking…"
      : "Continue";
  }

  showPlaceError(message) {
    this.placeErrorTarget.textContent = message;
    this.placeErrorTarget.hidden = false;
  }

  // A printout made for the previous location would show the wrong distances, so
  // it's discarded as soon as the location changes. The preview stays as it is,
  // because the location only affects the printout.
  discardPrintout() {
    this.printRequest?.abort();
    this.clearPrintout();
    this.printErrorTarget.hidden = true;
  }

  // Asks the browser where the device is. The browser shows its own permission prompt
  // the first time, so the answer can take a while, or never come. Only a button press
  // starts this: asking when the page loads would prompt people for no clear reason.
  useMyLocation() {
    this.forgetLocationChoice();
    const request = this.locationRequest;
    this.showLocationStatus("Finding your location…");
    navigator.geolocation.getCurrentPosition(
      (position) => {
        // The person typed a place or cleared this while the browser was working.
        if (request !== this.locationRequest) return;
        this.applyDevicePosition(position.coords);
      },
      (error) => {
        if (request !== this.locationRequest) return;
        this.showLocationStatus(
          // 1 is the Geolocation API's PERMISSION_DENIED.
          error.code === 1
            ? "Location access is turned off for this site. You can type a nearby place instead."
            : "We couldn't find your location. You can try again or type a nearby place instead.",
        );
      },
      // A rough, recent position is enough, and much faster than waiting for GPS.
      { timeout: 10000, maximumAge: 60000 },
    );
  }

  // Rounds to 3 decimal places, about 100 m, before the position leaves the browser.
  applyDevicePosition({ latitude, longitude, accuracy }) {
    this.latTarget.value = latitude.toFixed(3);
    this.lngTarget.value = longitude.toFixed(3);
    this.nearTarget.value = "";
    this.locationStatusTarget.hidden = true;
    this.showBuilderStep(this.deviceLocationMessage(accuracy));
  }

  // Laptops estimate their position from nearby Wi-Fi and can be far off. Saying how
  // accurate it is lets someone spot that before relying on the distances.
  deviceLocationMessage(accuracy) {
    if (accuracy >= 1000) {
      const km = Math.round(accuracy / 1000);
      return `Distances from your location, which may be off by about ${km} km. If that's too far, change it to a nearby place.`;
    }
    return `Distances from your location (accurate to about ${Math.round(accuracy)} m).`;
  }

  // Clears whichever location was chosen, along with any messages about it. Moving on
  // the request number also makes any answer still on its way get ignored, so a late
  // answer can't bring back a location the person has moved on from.
  forgetLocationChoice() {
    this.locationRequest += 1;
    this.placeCheck?.abort();
    this.setCheckingPlace(false);
    this.latTarget.value = "";
    this.lngTarget.value = "";
    this.locationStatusTarget.textContent = "";
    this.locationStatusTarget.hidden = true;
    this.placeErrorTarget.textContent = "";
    this.placeErrorTarget.hidden = true;
  }

  showLocationStatus(message) {
    this.locationStatusTarget.textContent = message;
    this.locationStatusTarget.hidden = false;
  }

  // With a location chosen, the preview needs it to show the same distances as the
  // printout. It goes in a POST body rather than the URL, because web server logs
  // record URLs, and this may be someone's home. Categories have to go in the body with
  // it: Rails doesn't combine a `flyer` from the URL with one from the body, it keeps
  // only the URL's, which would lose the location.
  previewRequestOptions(categories, url) {
    const headers = { Accept: "application/json" };
    const query = this.searchTarget.value.trim();
    const sort = this.sortTarget.value;
    if (!this.hasLatTarget || !this.latTarget.value) {
      categories.forEach((key) =>
        url.searchParams.append("flyer[categories][]", key),
      );
      if (query) url.searchParams.set("flyer[query]", query);
      if (sort !== DEFAULT_SORT) url.searchParams.set("flyer[sort]", sort);
      return { headers };
    }

    const body = new FormData();
    categories.forEach((key) => body.append("flyer[categories][]", key));
    if (query) body.append("flyer[query]", query);
    if (sort !== DEFAULT_SORT) body.append("flyer[sort]", sort);
    body.append("flyer[lat]", this.latTarget.value);
    body.append("flyer[lng]", this.lngTarget.value);
    return {
      method: "POST",
      body,
      headers: {
        ...headers,
        "X-CSRF-Token":
          document.querySelector('meta[name="csrf-token"]')?.content || "",
      },
    };
  }

  finishSearch(event) {
    if (event.isComposing) return;
    event.preventDefault();
    if (this.toolbarTarget.contains(event.currentTarget))
      event.currentTarget.blur();
  }

  openFilters() {
    const selected = new Set(this.selectedCategories());
    this.draftCategoryTargets.forEach((input) => {
      input.checked = selected.has(input.value);
    });
    this.draftSortTarget.value = this.sortTarget.value;
    this.filterDialogTarget.hidden = false;
    this.filterDialogTarget.showModal();
    this.filterButtonTarget.setAttribute("aria-expanded", "true");
  }

  closeFilters() {
    if (this.filterDialogTarget.open) this.filterDialogTarget.close();
    this.filtersClosed();
  }

  filtersClosed() {
    if (this.filterDialogTarget.open) return;
    this.filterDialogTarget.hidden = true;
    this.filterButtonTarget.setAttribute("aria-expanded", "false");
  }

  layoutChanged() {
    const desktop = window.matchMedia("(min-width: 40rem)").matches;
    const destination = desktop ? this.desktopSearchTarget : this.toolbarTarget;
    if (this.searchFieldTarget.parentElement !== destination)
      destination.prepend(this.searchFieldTarget);
    this.desktopSearchTarget.hidden = !desktop;
    if (desktop && this.filterDialogTarget.open) this.closeFilters();
  }

  resetDraft() {
    this.draftCategoryTargets.forEach((input) => (input.checked = false));
    this.draftSortTarget.value = DEFAULT_SORT;
  }

  applyFilters() {
    const selected = new Set(
      this.draftCategoryTargets
        .filter((input) => input.checked)
        .map((input) => input.value),
    );
    this.categoryTargets.forEach((input) => {
      input.checked = selected.has(input.value);
    });
    this.sortTarget.value = this.draftSortTarget.value;
    this.closeFilters();
    this.filter();
  }

  clearSearchAndOrder() {
    this.searchTarget.value = "";
    this.sortTarget.value = DEFAULT_SORT;
    this.filter();
  }

  updateFilterControls() {
    const customOrder = this.sortTarget.value !== DEFAULT_SORT;
    const filtersActive = customOrder || this.selectedCategories().length > 0;
    this.filterButtonTarget.dataset.active = String(filtersActive);
    this.filterButtonTarget.setAttribute(
      "aria-label",
      filtersActive ? "Filters (active)" : "Filters",
    );
    this.clearSearchOrderTarget.hidden =
      !customOrder && this.searchTarget.value.trim() === "";
  }

  async refresh() {
    clearTimeout(this.debounce);
    const revision = ++this.revision;
    this.previewRequest?.abort();
    this.previewRequest = new AbortController();
    this.previewErrorTarget.hidden = true;
    this.setLoading();
    const categories = this.selectedCategories();
    const url = new URL(this.previewUrlValue, window.location.origin);
    const options = this.previewRequestOptions(categories, url);
    try {
      const response = await fetch(url, {
        credentials: "same-origin",
        signal: this.previewRequest.signal,
        ...options,
      });
      const data = await response.json();
      if (!response.ok)
        throw new Error(
          data.errors?.join(" ") ||
            "We couldn't load those resources. Please try again.",
        );
      if (revision !== this.revision) return;
      this.render(data.categories);
    } catch (error) {
      if (error.name === "AbortError" || revision !== this.revision) return;
      this.statusTarget.textContent = "Preview unavailable";
      this.previewErrorMessageTarget.textContent =
        "We couldn't update your guide. Check your connection and try again.";
      this.previewErrorTarget.hidden = false;
      this.cardsTarget.setAttribute("aria-busy", "false");
      this.generateTarget.disabled = true;
    }
  }

  selectedCategories() {
    return this.categoryTargets
      .filter((input) => input.checked)
      .map((input) => input.value);
  }

  setLoading() {
    this.statusTarget.textContent = "Updating…";
    this.cardsTarget.setAttribute("aria-busy", "true");
    this.generateTarget.disabled = true;
  }

  render(categories) {
    const fragment = document.createDocumentFragment();
    const ids = new Set();
    let total = 0;
    categories.forEach((category) => {
      if (category.resources.length === 0) return;
      const section = document.createElement("section");
      section.className = "mt-4 first:mt-0 sm:mt-7";
      const heading = document.createElement("h3");
      heading.className =
        "mb-1.5 text-sm font-semibold text-sage-700 sm:mb-3 sm:text-lg sm:text-stone-900";
      heading.textContent = category.name;
      const count = document.createElement("span");
      count.className =
        "ml-2 text-xs font-normal text-stone-600 sm:ml-2.5 sm:text-sm";
      count.textContent = `${category.resources.length} ${category.resources.length === 1 ? "card" : "cards"}`;
      heading.append(count);
      section.append(heading);
      const grid = document.createElement("div");
      grid.className =
        "grid grid-cols-1 items-start gap-2.5 sm:gap-[18px] lg:grid-cols-2";
      category.resources.forEach((resource) => {
        ids.add(resource.id);
        total += 1;
        grid.append(this.card(resource));
      });
      section.append(grid);
      fragment.append(section);
    });
    if (total === 0) {
      fragment.replaceChildren();
      const empty = document.createElement("div");
      empty.className =
        "rounded-[10px] border border-dashed border-stone-300 px-5 py-12 text-center text-stone-600";
      if (this.searchTarget.value.trim()) {
        empty.textContent = "No resources match your search.";
      } else if (this.selectedCategories().length) {
        empty.textContent = "No resources match the selected categories.";
      } else {
        empty.textContent = "No resources are available to display.";
      }
      fragment.append(empty);
    }
    this.cardsTarget.replaceChildren(fragment);
    this.countTarget.textContent = `${ids.size} ${ids.size === 1 ? "resource" : "resources"} included`;
    this.hasResults = total > 0;
    this.statusTarget.textContent = "";
    this.cardsTarget.setAttribute("aria-busy", "false");
    this.generateTarget.disabled = !this.hasResults || this.generating;
  }

  card(resource) {
    const article = document.createElement("article");
    article.className =
      "min-w-0 overflow-hidden rounded-[10px] border border-stone-200 bg-stone-50 text-stone-800 sm:border-stone-300 sm:bg-white lg:last:odd:col-span-2";
    const title = document.createElement("h4");
    title.className =
      "px-3 pt-2.5 text-sm font-semibold [overflow-wrap:anywhere] sm:border-b sm:border-stone-200 sm:bg-stone-100 sm:px-4 sm:py-[13px] sm:text-base";
    title.textContent = resource.title;
    const details = document.createElement("dl");
    details.className =
      "grid gap-1 px-3 pt-1.5 pb-3 text-[0.8125rem] sm:gap-[9px] sm:px-4 sm:pt-[14px] sm:pb-4 sm:text-base";
    resource.fields.forEach((field) => {
      const row = document.createElement("div");
      row.className = "[overflow-wrap:anywhere]";
      const label = document.createElement("dt");
      label.className = "inline font-semibold";
      label.textContent = `${field.label}: `;
      const value = document.createElement("dd");
      value.className = "m-0 inline whitespace-pre-line";
      value.textContent = field.value;
      row.append(label, value);
      details.append(row);
    });
    article.append(title, details);
    return article;
  }

  async generate(event) {
    event.preventDefault();
    if (!this.hasResults || this.generateTarget.disabled) return;
    const revision = this.revision;
    this.clearPrintout();
    this.printErrorTarget.hidden = true;
    this.generating = true;
    this.generateTarget.disabled = true;
    this.generateLabelTarget.textContent = "Preparing printout…";
    this.printRequest = new AbortController();
    try {
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        headers: {
          Accept: "application/pdf",
          "X-CSRF-Token":
            document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        credentials: "same-origin",
        body: new FormData(this.formTarget),
        signal: this.printRequest.signal,
      });
      if (
        !response.ok ||
        !response.headers.get("Content-Type")?.includes("application/pdf")
      ) {
        const data = response.headers
          .get("Content-Type")
          ?.includes("application/json")
          ? await response.json()
          : null;
        throw new Error(
          data?.errors?.join(" ") ||
            "We couldn't create your printout. Please try again in a moment.",
        );
      }
      const blob = await response.blob();
      if (revision !== this.revision || !this.element.isConnected) return;
      // The person opens the PDF themselves, in a new tab, and prints it from the
      // browser's PDF viewer. The page doesn't try to print it automatically:
      // - Printing from a hidden frame was unreliable. The frame's load event fires
      //   before the browser's PDF viewer has drawn the pages, so print() sometimes
      //   printed blank pages, and browsers give no event for "finished drawing".
      // - A blob: document takes this page's security policy, whose
      //   frame-ancestors 'none' stops it being shown in a frame at all (Safari).
      // - Opening the tab from here, rather than from a click, would be stopped by
      //   popup blockers, because the fetch above means it's no longer a click.
      this.pdfUrl = URL.createObjectURL(blob);
      this.pdfLinkTarget.href = this.pdfUrl;
      this.printoutTarget.hidden = false;
      // Moving focus here lets keyboard and screen reader users reach the new
      // button straight away, rather than searching the page for it.
      this.pdfLinkTarget.focus();
    } catch (error) {
      if (error.name === "AbortError" || revision !== this.revision) return;
      this.printErrorTarget.textContent = error.message;
      this.printErrorTarget.hidden = false;
    } finally {
      if (revision === this.revision) {
        this.generating = false;
        this.generateTarget.disabled = !this.hasResults;
        this.generateLabelTarget.textContent = "Generate printout";
      }
    }
  }

  // A tab the person already opened keeps its copy of the PDF after the link is
  // revoked here, so this only stops the page offering an out-of-date printout.
  clearPrintout() {
    if (this.pdfUrl) URL.revokeObjectURL(this.pdfUrl);
    this.pdfUrl = null;
    this.pdfLinkTarget.removeAttribute("href");
    this.printoutTarget.hidden = true;
  }
}
