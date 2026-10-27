// "Program Log": read-only, append-only, capped, batched per animation frame.
import type { LogLine } from "../ipc";

const MAX_LINES = 5000;

export class LogPane {
  readonly #root: HTMLElement;
  #queue: LogLine[] = [];
  #scheduled = false;

  constructor(root: HTMLElement) {
    this.#root = root;
  }

  append(line: LogLine): void {
    this.#queue.push(line);
    if (!this.#scheduled) {
      this.#scheduled = true;
      requestAnimationFrame(() => this.#flush());
    }
  }

  #flush(): void {
    this.#scheduled = false;
    const root = this.#root;
    const stick = root.scrollHeight - root.scrollTop - root.clientHeight < 24;
    const fragment = document.createDocumentFragment();
    for (const line of this.#queue.splice(0)) {
      const row = document.createElement("div");
      row.className = `log-line log-${classOf(line)}`;
      row.textContent = line.stream === "stdout" || line.stream === "stderr" ? `|    ${line.text}` : line.text;
      fragment.append(row);
    }
    root.append(fragment);
    while (root.childElementCount > MAX_LINES) root.firstElementChild?.remove();
    if (stick) root.scrollTop = root.scrollHeight;
  }
}

function classOf(line: LogLine): string {
  if (line.stream === "info" && (line.text.startsWith("========") || line.text.startsWith("}"))) return "frame";
  if (line.stream === "stderr" && /^warning:/i.test(line.text)) return "warning";
  return line.stream;
}
