import { Controller } from "@hotwired/stimulus";

export default class extends Controller {
  static targets = ["content", "references"];

  connect() {
    this.refresh();
  }

  referencesTargetConnected() {
    this.refresh();
  }

  refresh() {
    if (!this.hasContentTarget || !this.hasReferencesTarget) return;

    const references = new Map(
      Array.from(
        this.referencesTarget.querySelectorAll("[data-reference-id]"),
      ).map((reference) => [reference.dataset.referenceId, reference]),
    );
    const cited = new Set();

    // A reference panel can be replaced after citations have already rendered.
    // Keep those links and their Cited badges in sync with the current metadata.
    this.contentTarget
      .querySelectorAll("a[data-citation-reference]")
      .forEach((link) => {
        const reference = references.get(link.dataset.citationReference);
        if (reference) {
          this.updateLink(link, reference);
          cited.add(reference.dataset.referenceId);
        } else {
          link.replaceWith(
            document.createTextNode(`[ref:${link.dataset.citationReference}]`),
          );
        }
      });

    const walker = document.createTreeWalker(
      this.contentTarget,
      NodeFilter.SHOW_TEXT,
      {
        acceptNode(node) {
          if (
            node.parentElement.closest("pre, code, a") ||
            !node.data.includes("[ref:")
          ) {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        },
      },
    );
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);

    nodes.forEach((node) => {
      const fragment = document.createDocumentFragment();
      let offset = 0;
      for (const match of node.data.matchAll(/\[ref:(\d+)\]/g)) {
        fragment.append(
          document.createTextNode(node.data.slice(offset, match.index)),
        );
        const reference = references.get(match[1]);
        if (reference) {
          const link = document.createElement("a");
          this.updateLink(link, reference);
          fragment.append(link);
          cited.add(match[1]);
        } else {
          fragment.append(document.createTextNode(match[0]));
        }
        offset = match.index + match[0].length;
      }
      fragment.append(document.createTextNode(node.data.slice(offset)));
      node.replaceWith(fragment);
    });

    references.forEach((reference, id) => {
      reference.querySelector("[data-citation-status]").hidden = !cited.has(id);
    });
  }

  updateLink(link, reference) {
    const number = reference.dataset.referenceNumber;
    link.href = `#${reference.id}`;
    link.textContent = `[${number}]`;
    link.dataset.citationReference = reference.dataset.referenceId;
    link.setAttribute(
      "aria-label",
      `Reference ${number}: ${reference.dataset.referenceTitle}`,
    );
    link.className =
      "rounded px-0.5 text-xs font-medium text-sage-700 focus-visible:outline-sage-600";
  }

  follow(event) {
    const link = event.target.closest("a[data-citation-reference]");
    if (!link || !this.contentTarget.contains(link)) return;
    if (
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey ||
      event.button !== 0
    )
      return;

    const reference = Array.from(
      this.referencesTarget.querySelectorAll("[data-reference-id]"),
    ).find(
      (item) => item.dataset.referenceId === link.dataset.citationReference,
    );
    if (!reference) return;

    event.preventDefault();
    this.referencesTarget.querySelector("details").open = true;
    reference.focus({ preventScroll: true });
    reference.scrollIntoView({ block: "nearest" });
  }
}
