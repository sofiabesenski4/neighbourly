import { Controller } from "@hotwired/stimulus";
import { marked } from "marked";
import DOMPurify from "dompurify";

export default class extends Controller {
  static targets = ["source", "output"];

  connect() {
    this.render();
    this.sourceTarget.hidden = true;
    this.outputTarget.hidden = false;

    // Turbo appends escaped text to the source. Reparse the whole response so
    // Markdown split across chunks (such as **bold**) resolves correctly.
    this.observer = new MutationObserver(() => {
      if (this.frame) return;

      this.frame = requestAnimationFrame(() => {
        this.frame = null;
        this.render();
      });
    });
    this.observer.observe(this.sourceTarget, {
      childList: true,
      characterData: true,
      subtree: true,
    });
  }

  disconnect() {
    this.observer.disconnect();
    cancelAnimationFrame(this.frame);
    this.frame = null;
  }

  render() {
    const html = marked.parse(this.sourceTarget.textContent, { async: false });
    this.outputTarget.innerHTML = DOMPurify.sanitize(html, {
      ALLOWED_TAGS: [
        "p",
        "br",
        "strong",
        "em",
        "del",
        "a",
        "h1",
        "h2",
        "h3",
        "h4",
        "h5",
        "h6",
        "ul",
        "ol",
        "li",
        "blockquote",
        "pre",
        "code",
        "hr",
        "table",
        "thead",
        "tbody",
        "tr",
        "th",
        "td",
      ],
      ALLOWED_ATTR: ["href", "title", "start"],
      ALLOW_DATA_ATTR: false,
      ALLOW_ARIA_ATTR: false,
    });
  }
}
