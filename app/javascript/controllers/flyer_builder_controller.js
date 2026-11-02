import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = [
    "form",
    "category",
    "cards",
    "count",
    "status",
    "generate",
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
    this.clearPrintout();
    this.generateTarget.textContent = "Generate printout";
  }

  filter() {
    clearTimeout(this.debounce);
    this.revision += 1;
    this.previewRequest?.abort();
    this.printRequest?.abort();
    this.generating = false;
    this.generateTarget.textContent = "Generate printout";
    this.clearPrintout();
    this.printErrorTarget.hidden = true;
    this.setLoading();
    this.debounce = setTimeout(() => this.refresh(), 300);
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
      const section = document.createElement("section");
      section.className = "mt-7 first:mt-0";
      const heading = document.createElement("h3");
      heading.className = "mb-3 text-lg font-semibold text-stone-900";
      heading.textContent = category.name;
      const count = document.createElement("span");
      count.className = "ml-2.5 text-sm font-normal text-stone-600";
      count.textContent = `${category.resources.length} ${category.resources.length === 1 ? "card" : "cards"}`;
      heading.append(count);
      section.append(heading);
      const grid = document.createElement("div");
      grid.className = "grid grid-cols-1 items-start gap-[18px] lg:grid-cols-2";
      category.resources.forEach((resource) => {
        ids.add(resource.id);
        total += 1;
        grid.append(this.card(resource));
      });
      if (category.resources.length === 0) {
        const empty = document.createElement("p");
        empty.className = "text-stone-600";
        empty.textContent = "No matching resources in this category.";
        section.append(empty);
      } else {
        section.append(grid);
      }
      fragment.append(section);
    });
    if (total === 0) {
      fragment.replaceChildren();
      const empty = document.createElement("div");
      empty.className =
        "rounded-[10px] border border-dashed border-stone-300 px-5 py-12 text-center text-stone-600";
      empty.textContent =
        this.selectedCategories().length === 0
          ? "No resources are available to display."
          : "No resources match the selected categories.";
      fragment.append(empty);
    }
    this.cardsTarget.replaceChildren(fragment);
    const scope =
      this.selectedCategories().length === 0
        ? "All available resources · "
        : "";
    this.countTarget.textContent = `${scope}${ids.size} ${ids.size === 1 ? "resource" : "resources"} · ${total} ${total === 1 ? "card" : "cards"} across ${categories.length} ${categories.length === 1 ? "category" : "categories"}`;
    this.hasResults = total > 0;
    this.statusTarget.textContent = "Live preview";
    this.cardsTarget.setAttribute("aria-busy", "false");
    this.generateTarget.disabled = !this.hasResults || this.generating;
  }

  card(resource) {
    const article = document.createElement("article");
    article.className =
      "min-w-0 overflow-hidden rounded-[10px] border border-stone-300 bg-white text-stone-800";
    const title = document.createElement("h4");
    title.className =
      "border-b border-stone-200 bg-stone-100 px-4 py-[13px] font-semibold [overflow-wrap:anywhere]";
    title.textContent = resource.title;
    const details = document.createElement("dl");
    details.className = "grid gap-[9px] px-4 pt-[14px] pb-4";
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
    this.generateTarget.textContent = "Preparing printout…";
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
        this.generateTarget.textContent = "Generate printout";
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
