import { Controller } from "@hotwired/stimulus";
import { describeAccuracy, deviceLocationSupported, requestDeviceLocation } from "../lib/device_location.js";

const DEFAULT_SORT = "default";
const DISTANCE_SORT = "distance";
const ADD_DISTANCES = "Add distances";

export default class extends Controller {
  static targets = [
    "form",
    "category",
    "categoryMarker",
    "categoryGroup",
    "organization",
    "toolbar",
    "sidebar",
    "desktopSearch",
    "desktopSort",
    "desktopSortOption",
    "advancedFilters",
    "resourceDetail",
    "searchField",
    "search",
    "sort",
    "filterButton",
    "filterDialog",
    "draftCategory",
    "draftOrganization",
    "draftSort",
    "clearSearchOrder",
    "cards",
    "count",
    "resourceSelection",
    "selectAll",
    "deselectAll",
    "status",
    "generate",
    "generateLabel",
    "printSettings",
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
    "locationSummary",
    "desktopActions",
    "previewActions",
    "mobileDistances",
    "distanceButton",
    "distanceLabel",
    "distanceWarning",
  ];
  static values = {
    previewUrl: String,
    locateUrl: String,
    fromQuestionnaire: Boolean,
    guided: Boolean,
  };

  connect() {
    this.revision = (this.revision || 0) + 1;
    this.hasResults = false;
    this.generating = false;
    this.excludedServiceIds = new Set();
    this.previewReady = false;
    this.locationRequest = 0;
    this.locationBeforeEdit = null;
    if (this.guidedValue) {
      this.resourceIds = new Set(
        this.resourceSelectionTargets.map((input) => input.value),
      );
      this.resourceSelectionTargets.forEach((input) => {
        if (!input.checked) this.excludedServiceIds.add(input.value);
      });
      this.previewReady = true;
      this.updateSelectionControls();
      return;
    }
    const supported = deviceLocationSupported();
    this.useLocationTarget.hidden = !supported;
    this.locationNoteTarget.hidden = !supported;
    this.confirmPlaceButtonTarget.hidden = false;
    this.skipLocationTarget.hidden = false;
    this.distanceButtonTarget.hidden = false;
    this.toolbarTarget.hidden = false;
    this.sidebarTarget.classList.add("hidden");
    this.layoutChanged();
    this.updateResourceDetails();
    if (this.latTarget.value && this.lngTarget.value) {
      this.distanceLabelTarget.textContent = this.nearTarget.value || "Provided location";
    }
    this.updateFilterControls();
    this.refresh();
  }

  closePrintSettingsOutside(event) {
    const settings = this.printSettingsTarget;
    if (settings.open && !settings.contains(event.target))
      settings.open = false;
  }

  disconnect() {
    this.beforeCache();
  }

  categoryMarkerTargetConnected(marker) {
    marker.style.backgroundColor = `#${marker.dataset.categoryColour}`;
  }

  categoryGroupTargetConnected(section) {
    this.applyCategoryColour(
      section,
      section.querySelector("h3"),
      section.dataset.categoryColour,
    );
  }

  applyCategoryColour(section, heading, colour) {
    const hex = `#${colour}`;
    section.style.setProperty("--flyer-category-colour", hex);
    heading.style.color = hex;
  }

  beforeCache() {
    this.revision += 1;
    clearTimeout(this.debounce);
    this.previewRequest?.abort();
    this.printRequest?.abort();
    if (this.hasFilterDialogTarget) this.closeFilters();
    this.clearPrintout();
    if (this.hasLocationStepTarget) {
      if (this.locationBeforeEdit) this.closeDistanceDialog();
      this.locationBeforeEdit = null;
      this.forgetLocationChoice();
      this.nearTarget.value = "";
      this.locationSummaryTarget.textContent = "";
      this.distanceLabelTarget.textContent = ADD_DISTANCES;
      this.distanceWarningTarget.textContent = "";
    } else if (this.hasLatTarget) {
      this.latTarget.value = "";
      this.lngTarget.value = "";
    }
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

  applyLocation(summary = "", { warn = false, locationLabel = "" } = {}) {
    const hasLocation = Boolean(this.latTarget.value && this.lngTarget.value);
    this.locationSummaryTarget.textContent = summary;
    this.locationSummaryTarget.hidden = !summary;
    this.distanceWarningTarget.textContent = warn ? summary : "";
    this.distanceWarningTarget.hidden = !warn;
    this.distanceLabelTarget.textContent = hasLocation ? locationLabel : ADD_DISTANCES;
    this.locationBeforeEdit = null;
    this.closeDistanceDialog();
    this.updateFilterControls();
    this.distanceButtonTarget.focus();
    this.refresh();
  }

  changeLocation() {
    this.locationBeforeEdit = {
      near: this.nearTarget.value,
      lat: this.latTarget.value,
      lng: this.lngTarget.value,
    };
    this.discardPrintout();
    this.locationStepTarget.hidden = false;
    this.locationStepTarget.showModal();
    this.locationHeadingTarget.focus();
  }

  cancelLocation() {
    if (!this.locationBeforeEdit) return;
    const { near, lat, lng } = this.locationBeforeEdit;
    this.forgetLocationChoice();
    this.nearTarget.value = near;
    this.latTarget.value = lat;
    this.lngTarget.value = lng;
    this.locationBeforeEdit = null;
    this.closeDistanceDialog();
    this.distanceButtonTarget.focus();
  }

  closeDistanceDialog() {
    this.locationStepTarget.close();
    this.locationStepTarget.hidden = true;
  }

  skipLocation() {
    this.forgetLocationChoice();
    this.nearTarget.value = "";
    this.applyLocation();
  }

  // Typing a place replaces any device location, so only one is ever sent.
  locationChanged() {
    this.forgetLocationChoice();
  }

  // Keep the checked coordinates for both the preview and the printout.
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
        this.applyLocation(`Distances from: ${place}.`, {
          locationLabel: place,
        });
      } else {
        // The geocoder is down. The guide can still print, so this shouldn't stop
        // the person. The printout itself explains any missing distances.
        this.applyLocation(
          `We can't check ${place} right now, so your printout may not show distances.`,
          { warn: true },
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

  // Remove any generated or pending printout when the builder's inputs change.
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
    requestDeviceLocation(
      (position) => {
        if (request !== this.locationRequest) return;
        this.applyDevicePosition(position);
      },
      (message) => {
        if (request !== this.locationRequest) return;
        this.showLocationStatus(message);
      },
    );
  }

  applyDevicePosition({ lat, lng, accuracy }) {
    this.latTarget.value = lat;
    this.lngTarget.value = lng;
    this.nearTarget.value = "";
    this.locationStatusTarget.hidden = true;
    const { rough, text } = describeAccuracy(accuracy);
    const summary = rough
      ? "Distances from your location, which " + text + ". If that’s too far, change it to a nearby place."
      : "Distances from your location (" + text + ").";
    this.applyLocation(summary, { warn: rough, locationLabel: "Current location" });
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

  // Keep questionnaire answers and locations in the POST body so they stay out
  // of URLs. Rails takes the complete flyer input from either the URL or the body.
  previewRequestOptions(categories, url) {
    const headers = { Accept: "application/json" };
    const query = this.searchTarget.value.trim();
    const sort = this.sortTarget.value;
    const lat =
      this.locationBeforeEdit?.lat ??
      (this.hasLatTarget ? this.latTarget.value : "");
    if (!this.fromQuestionnaireValue && !lat) {
      categories.forEach((key) =>
        url.searchParams.append("flyer[categories][]", key),
      );
      this.selectedOrganizations().forEach((key) =>
        url.searchParams.append("flyer[organizations][]", key),
      );
      if (query) url.searchParams.set("flyer[query]", query);
      if (sort !== DEFAULT_SORT) url.searchParams.set("flyer[sort]", sort);
      return { headers };
    }

    const body = new FormData();
    categories.forEach((key) => body.append("flyer[categories][]", key));
    this.selectedOrganizations().forEach((key) =>
      body.append("flyer[organizations][]", key),
    );
    if (query) body.append("flyer[query]", query);
    if (sort !== DEFAULT_SORT) body.append("flyer[sort]", sort);
    if (lat) {
      body.append("flyer[lat]", lat);
      body.append(
        "flyer[lng]",
        this.locationBeforeEdit?.lng ?? this.lngTarget.value,
      );
    }
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
    const organizations = new Set(this.selectedOrganizations());
    this.draftOrganizationTargets.forEach((input) => {
      input.checked = organizations.has(input.value);
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
    if (this.guidedValue) return;
    const desktop = window.matchMedia("(min-width: 40rem)").matches;
    const destination = desktop ? this.desktopSearchTarget : this.toolbarTarget;
    if (this.searchFieldTarget.parentElement !== destination)
      destination.prepend(this.searchFieldTarget);
    const nextControl = desktop
      ? this.desktopSortTarget
      : this.filterButtonTarget;
    const advanced = this.advancedFiltersTarget;
    if (advanced.nextElementSibling !== nextControl) {
      advanced.open = false;
      nextControl.before(advanced);
    }
    const distanceDestination = desktop
      ? this.desktopActionsTarget
      : this.mobileDistancesTarget;
    if (this.distanceButtonTarget.parentElement !== distanceDestination)
      distanceDestination.prepend(this.distanceButtonTarget);
    const generateDestination = desktop
      ? this.desktopActionsTarget
      : this.previewActionsTarget;
    if (this.generateTarget.parentElement !== generateDestination) {
      this.printSettingsTarget.open = false;
      generateDestination.append(this.generateTarget, this.printSettingsTarget);
    }
    this.desktopSearchTarget.hidden = !desktop;
    if (!desktop) this.desktopSortTarget.open = false;
    if (desktop && this.filterDialogTarget.open) this.closeFilters();
  }

  closeDesktopSort() {
    if (!this.desktopSortTarget.open) return;
    this.desktopSortTarget.open = false;
    this.desktopSortTarget.querySelector("summary").focus();
  }

  closeDesktopSortOutside(event) {
    const sort = this.desktopSortTarget;
    if (sort.open && !sort.contains(event.target)) sort.open = false;
  }

  closeAdvancedFilters() {
    const advanced = this.advancedFiltersTarget;
    if (!advanced.open) return;

    advanced.open = false;
    advanced.querySelector("summary").focus();
  }

  closeAdvancedFiltersOutside(event) {
    const advanced = this.advancedFiltersTarget;
    if (advanced.open && !advanced.contains(event.target))
      advanced.open = false;
  }

  updateResourceDetails(event) {
    this.hiddenDetailLabels = new Set(
      this.resourceDetailTargets
        .filter((input) => !input.checked)
        .flatMap((input) => input.dataset.fieldLabels.split(",")),
    );
    for (const row of this.cardsTarget.querySelectorAll(
      "[data-detail-label]",
    )) {
      row.hidden = this.hiddenDetailLabels.has(row.dataset.detailLabel);
    }
    if (event) this.discardPrintout();
  }

  applyDesktopSort(event) {
    this.sortTarget.value = event.params.order;
    this.closeDesktopSort();
    this.filter();
  }

  resetDraft() {
    this.draftCategoryTargets.forEach((input) => (input.checked = false));
    this.draftOrganizationTargets.forEach((input) => (input.checked = false));
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
    const organizations = new Set(
      this.draftOrganizationTargets
        .filter((input) => input.checked)
        .map((input) => input.value),
    );
    this.organizationTargets.forEach((input) => {
      input.checked = organizations.has(input.value);
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
    const canSortByDistance =
      this.latTarget.value !== "" && this.lngTarget.value !== "";
    if (!canSortByDistance) {
      if (this.sortTarget.value === DISTANCE_SORT)
        this.sortTarget.value = DEFAULT_SORT;
      if (this.draftSortTarget.value === DISTANCE_SORT)
        this.draftSortTarget.value = DEFAULT_SORT;
    }
    this.draftSortTarget.querySelector(
      `option[value="${DISTANCE_SORT}"]`,
    ).disabled = !canSortByDistance;
    const customOrder = this.sortTarget.value !== DEFAULT_SORT;
    this.desktopSortOptionTargets.forEach((option) => {
      const order = option.dataset.flyerBuilderOrderParam;
      option.disabled = order === DISTANCE_SORT && !canSortByDistance;
      option.setAttribute(
        "aria-pressed",
        String(order === this.sortTarget.value),
      );
    });
    const filtersActive =
      customOrder ||
      this.selectedCategories().length > 0 ||
      this.selectedOrganizations().length > 0;
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

  selectedOrganizations() {
    return this.organizationTargets
      .filter((input) => input.checked)
      .map((input) => input.value);
  }

  setLoading() {
    this.previewReady = false;
    this.selectAllTarget.disabled = true;
    this.deselectAllTarget.disabled = true;
    this.resourceSelectionTargets.forEach((input) => {
      input.disabled = true;
    });
    this.statusTarget.textContent = "Updating…";
    this.cardsTarget.setAttribute("aria-busy", "true");
    this.generateTarget.disabled = true;
  }

  render(categories) {
    this.previewCategories = categories;
    this.previewReady = true;
    this.renderCards();
  }

  matchingResources() {
    return new Map(
      this.previewCategories.flatMap(({ resources }) =>
        resources.map((resource) => [String(resource.id), resource]),
      ),
    );
  }

  toggleResource({ target }) {
    if (!this.previewReady) return;
    this.setResourceSelected(target.value, target.checked);
    this.updateResourceSelection();
  }

  // Bulk actions affect only matching results, preserving choices outside the
  // current search and category filters. A shared resource is selected once.
  selectResources({ params: { selected } }) {
    if (!this.previewReady) return;
    for (const id of this.matchingResources().keys()) {
      this.setResourceSelected(id, selected);
    }
    this.updateResourceSelection();
  }

  setResourceSelected(id, selected) {
    if (selected) this.excludedServiceIds.delete(id);
    else this.excludedServiceIds.add(id);
  }

  selectedServiceIds() {
    const ids = this.guidedValue ? this.resourceIds : this.matchingResources().keys();
    return [...ids].filter((id) => !this.excludedServiceIds.has(id));
  }

  updateResourceSelection() {
    if (this.generating) {
      this.revision += 1;
      this.generating = false;
      this.generateLabelTarget.textContent = "Generate printout";
    }
    this.discardPrintout();
    this.updateSelectionControls();
  }

  updateSelectionControls() {
    const included = this.selectedServiceIds().length;
    // Update in place so keyboard focus stays on the checkbox the person changed.
    this.resourceSelectionTargets.forEach((input) => {
      input.checked = !this.excludedServiceIds.has(input.value);
      input.disabled = !this.previewReady;
    });
    this.countTarget.textContent = `${included} ${included === 1 ? "resource" : "resources"} included`;
    if (this.hasSelectAllTarget) {
      this.selectAllTarget.disabled = !this.previewReady || included === this.matchingResources().size;
      this.deselectAllTarget.disabled = !this.previewReady || included === 0;
    }
    this.hasResults = included > 0;
    this.generateTarget.disabled =
      !this.previewReady || !this.hasResults || this.generating;
  }

  renderCards() {
    const fragment = document.createDocumentFragment();
    this.previewCategories.forEach((category) => {
      const resources = category.resources;
      if (resources.length === 0) return;
      const section = document.createElement("section");
      section.className = "mt-7 first:mt-0 sm:mt-9";
      const heading = document.createElement("h3");
      heading.className =
        "mb-2 text-sm font-semibold text-stone-900 sm:mb-3 sm:text-lg";
      heading.textContent = category.name;
      if (category.colour) {
        section.className += " flyer-category-group";
        this.applyCategoryColour(section, heading, category.colour);
      }
      const count = document.createElement("span");
      count.className =
        "ml-2 text-xs font-normal text-stone-600 sm:ml-2.5 sm:text-sm";
      count.textContent = `${resources.length} ${resources.length === 1 ? "card" : "cards"}`;
      heading.append(count);
      section.append(heading);
      const grid = document.createElement("div");
      grid.className =
        "grid grid-cols-1 items-start gap-2.5 sm:gap-[18px] lg:grid-cols-2";
      resources.forEach((resource) => {
        grid.append(this.card(resource));
      });
      section.append(grid);
      fragment.append(section);
    });
    if (this.matchingResources().size === 0) {
      fragment.replaceChildren();
      const empty = document.createElement("div");
      empty.className =
        "rounded-[10px] border border-dashed border-stone-300 px-5 py-12 text-center text-stone-600";
      if (this.searchTarget.value.trim()) {
        empty.textContent = "No resources match your search.";
      } else if (this.selectedOrganizations().length) {
        empty.textContent = "No resources match the selected organizations.";
      } else if (this.selectedCategories().length) {
        empty.textContent = "No resources match the selected categories.";
      } else {
        empty.textContent = "No resources are available to display.";
      }
      fragment.append(empty);
    }
    this.cardsTarget.replaceChildren(fragment);
    this.updateSelectionControls();
    this.statusTarget.textContent = "";
    this.cardsTarget.setAttribute("aria-busy", "false");
  }

  card(resource) {
    const article = document.createElement("article");
    article.className =
      "min-w-0 overflow-hidden rounded-[10px] border border-stone-200 bg-stone-50 text-stone-800 has-[input:not(:checked)]:bg-stone-50/60 has-[input:not(:checked)]:text-stone-600 sm:border-stone-300 sm:bg-white sm:has-[input:not(:checked)]:bg-white/60 lg:last:odd:col-span-2";
    const header = document.createElement("header");
    header.className =
      "flex items-start gap-2 px-3 py-1 sm:border-b sm:border-stone-200 sm:bg-stone-100 sm:px-4 sm:has-[input:not(:checked)]:bg-stone-100/60";
    const title = document.createElement("h4");
    title.className =
      "min-w-0 flex-1 py-2.5 text-sm font-semibold [overflow-wrap:anywhere] sm:text-base";
    title.textContent = resource.title;
    const selection = document.createElement("label");
    selection.className =
      "flex min-h-11 min-w-11 shrink-0 cursor-pointer items-center justify-center rounded-lg hover:bg-sage-50";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.value = String(resource.id);
    checkbox.checked = !this.excludedServiceIds.has(checkbox.value);
    checkbox.className =
      "size-4 cursor-pointer accent-sage-600 focus-visible:outline-sage-600";
    checkbox.setAttribute(
      "aria-label",
      `Include ${resource.title} in printout`,
    );
    checkbox.dataset.flyerBuilderTarget = "resourceSelection";
    checkbox.dataset.action = "change->flyer-builder#toggleResource";
    const selectionLabel = document.createElement("span");
    selectionLabel.className = "sr-only";
    selectionLabel.textContent = `Include ${resource.title} in printout`;
    selection.append(checkbox, selectionLabel);
    header.append(title, selection);
    article.append(header);
    if (resource.fields.length) {
      article.append(this.fieldList(resource.fields));
    }
    return article;
  }

  fieldList(fields) {
    const list = document.createElement("dl");
    list.className = "grid gap-1 px-3 py-2 text-sm sm:px-4";
    fields.forEach((field) => {
      const row = document.createElement("div");
      row.className = "[overflow-wrap:anywhere]";
      row.setAttribute("data-detail-label", field.label);
      row.hidden = this.hiddenDetailLabels?.has(field.label) ?? false;
      const label = document.createElement("dt");
      label.className = "inline font-semibold";
      label.textContent = `${field.label}: `;
      const value = document.createElement("dd");
      value.className = "m-0 inline whitespace-pre-line";
      value.textContent = field.value;
      row.append(label, value);
      list.append(row);
    });
    return list;
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
    const { signal } = this.printRequest;
    const body = new FormData(this.formTarget);
    if (!this.guidedValue) {
      this.selectedServiceIds().forEach((id) =>
        body.append("flyer[service_ids][]", id),
      );
    }
    // Open from the click, before the asynchronous PDF request can lose user activation.
    const tab = window.open("about:blank", "_blank");
    this.pendingPrintoutTab = tab;
    try {
      if (tab) {
        tab.opener = null;
        tab.document.title = "Preparing printout";
        tab.document.body.textContent = "Preparing your printout…";
      }
      const response = await fetch(this.formTarget.action, {
        method: "POST",
        headers: {
          Accept: "application/pdf",
          "X-CSRF-Token":
            document.querySelector('meta[name="csrf-token"]')?.content || "",
        },
        credentials: "same-origin",
        body,
        signal,
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
      if (
        signal.aborted ||
        revision !== this.revision ||
        !this.element.isConnected
      )
        return;
      this.pdfUrl = URL.createObjectURL(blob);
      this.pdfLinkTarget.href = this.pdfUrl;
      this.printoutTarget.hidden = false;
      if (this.isPreparingTab(tab)) {
        tab.location.replace(this.pdfUrl);
        this.pendingPrintoutTab = null;
      } else {
        this.pdfLinkTarget.focus();
      }
    } catch (error) {
      if (signal.aborted || revision !== this.revision) return;
      this.printErrorTarget.textContent = error.message;
      this.printErrorTarget.hidden = false;
    } finally {
      if (this.pendingPrintoutTab === tab) this.closePreparingTab();
      if (revision === this.revision && signal === this.printRequest?.signal) {
        this.generating = false;
        this.updateSelectionControls();
        this.generateLabelTarget.textContent = "Generate printout";
      }
    }
  }

  isPreparingTab(tab) {
    try {
      return tab && !tab.closed && tab.location.href === "about:blank";
    } catch {
      // The user navigated the tab somewhere else while waiting.
      return false;
    }
  }

  closePreparingTab() {
    const tab = this.pendingPrintoutTab;
    if (this.isPreparingTab(tab)) tab.close();
    this.pendingPrintoutTab = null;
  }

  // A tab the person already opened keeps its copy of the PDF after the link is
  // revoked here, so this only stops the page offering an out-of-date printout.
  clearPrintout() {
    this.closePreparingTab();
    if (this.pdfUrl) URL.revokeObjectURL(this.pdfUrl);
    this.pdfUrl = null;
    this.pdfLinkTarget.removeAttribute("href");
    this.printoutTarget.hidden = true;
  }
}
