import { Controller } from "@hotwired/stimulus";

const DEFAULT_SORT = "default";

export default class extends Controller {
  static targets = [
    "form",
    "category",
    "categoryMarker",
    "organization",
    "toolbar",
    "sidebar",
    "desktopSearch",
    "desktopSort",
    "desktopSortOption",
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
    "includeResource",
    "count",
    "status",
    "generate",
    "generateLabel",
    "previewError",
    "previewErrorMessage",
    "printError",
    "printout",
    "pdfLink",
    "lat",
    "lng",
  ];
  static values = {
    previewUrl: String,
    summaryLabels: Array,
    fromQuestionnaire: Boolean,
  };

  connect() {
    this.revision = (this.revision || 0) + 1;
    this.hasResults = false;
    this.generating = false;
    this.excludedServiceIds = new Set();
    this.toolbarTarget.hidden = false;
    this.sidebarTarget.classList.add("hidden");
    this.layoutChanged();
    this.updateFilterControls();
    this.refresh();
  }

  disconnect() {
    this.beforeCache();
  }

  categoryMarkerTargetConnected(marker) {
    marker.style.backgroundColor = `#${marker.dataset.categoryColour}`;
  }

  beforeCache() {
    this.revision += 1;
    clearTimeout(this.debounce);
    this.previewRequest?.abort();
    this.printRequest?.abort();
    this.closeFilters();
    this.clearPrintout();
    if (this.hasLatTarget) {
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

  // Resource selections and print settings change what belongs in the PDF.
  discardPrintout() {
    this.printRequest?.abort();
    this.clearPrintout();
    this.printErrorTarget.hidden = true;
  }

  // Keep questionnaire answers and locations in the POST body so they stay out
  // of URLs. Rails takes the complete flyer input from either the URL or the body.
  previewRequestOptions(categories, url) {
    const headers = { Accept: "application/json" };
    const query = this.searchTarget.value.trim();
    const sort = this.sortTarget.value;
    const hasLocation =
      this.hasLatTarget && this.latTarget.value && this.lngTarget.value;
    if (!this.fromQuestionnaireValue) {
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
    if (hasLocation) {
      body.append("flyer[lat]", this.latTarget.value);
      body.append("flyer[lng]", this.lngTarget.value);
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
    const desktop = window.matchMedia("(min-width: 40rem)").matches;
    const destination = desktop ? this.desktopSearchTarget : this.toolbarTarget;
    if (this.searchFieldTarget.parentElement !== destination)
      destination.prepend(this.searchFieldTarget);
    this.desktopSearchTarget.hidden = !desktop;
    if (!desktop) this.desktopSortTarget.open = false;
    if (desktop && this.filterDialogTarget.open) this.closeFilters();
  }

  closeDesktopSort() {
    if (!this.desktopSortTarget.open) return;
    this.desktopSortTarget.open = false;
    this.desktopSortTarget.querySelector("summary").focus();
  }

  hoverDesktopSort(event) {
    if (event.pointerType === "mouse") this.desktopSortTarget.open = true;
  }

  leaveDesktopSort(event) {
    if (
      event.pointerType === "mouse" &&
      !this.desktopSortTarget.contains(document.activeElement)
    )
      this.desktopSortTarget.open = false;
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
    const customOrder = this.sortTarget.value !== DEFAULT_SORT;
    this.desktopSortOptionTargets.forEach((option) => {
      const order = option.dataset.flyerBuilderOrderParam;
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
    this.statusTarget.textContent = "Updating…";
    this.cardsTarget.setAttribute("aria-busy", "true");
    this.generateTarget.disabled = true;
  }

  render(categories) {
    const fragment = document.createDocumentFragment();
    const ids = new Set();
    categories.forEach((category) => {
      if (category.resources.length === 0) return;
      const section = document.createElement("section");
      section.className = "mt-7 first:mt-0 sm:mt-9";
      const heading = document.createElement("h3");
      heading.className =
        "mb-2 text-sm font-semibold text-stone-900 sm:mb-3 sm:text-lg";
      heading.textContent = category.name;
      if (category.colour) {
        const colour = `#${category.colour}`;
        section.className += " flyer-category-group";
        section.style.setProperty("--flyer-category-colour", colour);
        heading.style.color = colour;
      }
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
        ids.add(String(resource.id));
        grid.append(this.card(resource));
      });
      section.append(grid);
      fragment.append(section);
    });
    if (ids.size === 0) {
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
    this.resourceIds = ids;
    this.statusTarget.textContent = "";
    this.cardsTarget.setAttribute("aria-busy", "false");
    this.updateIncludedResources();
  }

  selectedServiceIds() {
    return [...this.resourceIds].filter(
      (id) => !this.excludedServiceIds.has(id),
    );
  }

  toggleResource(event) {
    const { value, checked } = event.currentTarget;
    if (checked) this.excludedServiceIds.delete(value);
    else this.excludedServiceIds.add(value);
    this.includeResourceTargets.forEach((input) => {
      if (input.value === value) input.checked = checked;
    });
    this.discardPrintout();
    this.updateIncludedResources();
  }

  updateIncludedResources() {
    const count = this.selectedServiceIds().length;
    this.countTarget.textContent = `${count} ${count === 1 ? "resource" : "resources"} included`;
    this.hasResults = count > 0;
    this.generateTarget.disabled =
      !this.hasResults ||
      this.generating ||
      this.cardsTarget.getAttribute("aria-busy") === "true" ||
      !this.previewErrorTarget.hidden;
  }

  card(resource) {
    const article = document.createElement("article");
    article.className =
      "min-w-0 overflow-hidden rounded-[10px] border border-stone-200 bg-stone-50 text-stone-800 sm:border-stone-300 sm:bg-white lg:last:odd:col-span-2";
    const title = document.createElement("h4");
    title.className =
      "min-w-0 py-2.5 text-sm font-semibold [overflow-wrap:anywhere] sm:text-base";
    title.textContent = resource.title;
    const header = document.createElement("header");
    header.className =
      "flex items-center justify-between gap-2 px-3 sm:border-b sm:border-stone-200 sm:bg-stone-100 sm:px-4";
    const inclusion = document.createElement("label");
    inclusion.className =
      "flex min-h-11 shrink-0 cursor-pointer items-center gap-1.5 text-sm";
    const checkbox = document.createElement("input");
    checkbox.type = "checkbox";
    checkbox.value = String(resource.id);
    checkbox.checked = !this.excludedServiceIds.has(checkbox.value);
    checkbox.className = "size-4 accent-sage-700";
    checkbox.setAttribute(
      "aria-label",
      `Include ${resource.title} in printout`,
    );
    checkbox.dataset.flyerBuilderTarget = "includeResource";
    checkbox.dataset.action = "change->flyer-builder#toggleResource";
    inclusion.append(checkbox, "Include");
    header.append(title, inclusion);
    const summaryFields = resource.fields.filter((field) =>
      this.summaryLabelsValue.includes(field.label),
    );
    const detailFields = resource.fields.filter(
      (field) => !this.summaryLabelsValue.includes(field.label),
    );
    article.append(header);
    if (summaryFields.length) {
      const summary = this.fieldList(summaryFields);
      summary.className += " px-3 pt-2 sm:px-4";
      article.append(summary);
    }

    const disclosure = document.createElement("details");
    disclosure.className = "px-3 pb-2 sm:px-4";
    const toggle = document.createElement("summary");
    toggle.className =
      "min-h-11 cursor-pointer py-3 text-sm font-medium text-sage-700 focus-visible:outline-sage-600";
    toggle.textContent = "See details";
    disclosure.append(toggle);
    if (detailFields.length) {
      disclosure.append(this.fieldList(detailFields));
    } else {
      const empty = document.createElement("p");
      empty.className = "text-sm text-stone-600";
      empty.textContent = "No additional details available.";
      disclosure.append(empty);
    }
    article.append(disclosure);
    return article;
  }

  fieldList(fields) {
    const list = document.createElement("dl");
    list.className = "grid gap-1 text-sm";
    fields.forEach((field) => {
      const row = document.createElement("div");
      row.className = "[overflow-wrap:anywhere]";
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
    this.selectedServiceIds().forEach((id) =>
      body.append("flyer[service_ids][]", id),
    );
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
      if (revision === this.revision) {
        this.generating = false;
        this.updateIncludedResources();
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
