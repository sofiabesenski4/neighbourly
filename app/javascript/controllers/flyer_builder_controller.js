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
  ];
  static values = { previewUrl: String };

  connect() {
    this.revision = (this.revision || 0) + 1;
    this.hasResults = false;
    this.generating = false;
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
    categories.forEach((key) =>
      url.searchParams.append("flyer[categories][]", key),
    );
    const query = this.searchTarget.value.trim();
    if (query) url.searchParams.set("flyer[query]", query);
    if (this.sortTarget.value !== DEFAULT_SORT)
      url.searchParams.set("flyer[sort]", this.sortTarget.value);
    try {
      const response = await fetch(url, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
        signal: this.previewRequest.signal,
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
      this.pdfUrl = URL.createObjectURL(blob);
      this.pdfLinkTarget.href = this.pdfUrl;
      this.printoutTarget.hidden = false;
      this.printFrame = document.createElement("iframe");
      this.printFrame.className = "fixed right-0 bottom-0 h-px w-px border-0";
      this.printFrame.title = "Printable resource guide";
      this.printFrame.setAttribute("aria-hidden", "true");
      this.printFrame.tabIndex = -1;
      this.printFrame.addEventListener(
        "load",
        () => {
          if (revision !== this.revision) return;
          try {
            this.printFrame.contentWindow.focus();
            this.printFrame.contentWindow.print();
          } catch {
            // The visible PDF link supports browsers without automatic PDF printing.
          }
        },
        { once: true },
      );
      this.printFrame.src = this.pdfUrl;
      this.element.append(this.printFrame);
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

  clearPrintout() {
    this.printFrame?.remove();
    this.printFrame = null;
    if (this.pdfUrl) URL.revokeObjectURL(this.pdfUrl);
    this.pdfUrl = null;
    this.pdfLinkTarget.removeAttribute("href");
    this.printoutTarget.hidden = true;
  }
}
