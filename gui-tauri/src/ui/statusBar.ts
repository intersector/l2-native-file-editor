// Status bar: the running step (with a delayed spinner and Cancel), the last result or error, and the file.
const SHOW_DELAY_MS = 250;
const MIN_SHOW_MS = 400;

export interface FileSummary {
  name: string;
  protocol: number;
  records: number | null;
  encoding: string | null;
}

export class StatusBar {
  readonly #message: HTMLElement;
  readonly #spinner: HTMLElement;
  readonly #text: HTMLElement;
  readonly #error: HTMLElement;
  readonly #cancel: HTMLButtonElement;
  readonly #file: HTMLElement;
  readonly #protocol: HTMLElement;
  readonly #records: HTMLElement;
  #showTimer: number | undefined;
  #shownAt = 0;
  #hideTimer: number | undefined;

  constructor(root: HTMLElement, onCancel: () => void) {
    root.innerHTML = `
      <div class="status-left">
        <span class="spinner" aria-hidden="true" hidden></span>
        <span class="status-text" role="status" aria-live="polite"></span>
        <span class="status-error" role="alert" aria-live="assertive" hidden></span>
        <button type="button" class="link-button status-cancel" hidden>Cancel</button>
      </div>
      <div class="status-right">
        <span class="status-file"></span>
        <span class="status-protocol"></span>
        <span class="status-records"></span>
      </div>`;
    this.#message = root.querySelector(".status-left") as HTMLElement;
    this.#spinner = root.querySelector(".spinner") as HTMLElement;
    this.#text = root.querySelector(".status-text") as HTMLElement;
    this.#error = root.querySelector(".status-error") as HTMLElement;
    this.#cancel = root.querySelector(".status-cancel") as HTMLButtonElement;
    this.#file = root.querySelector(".status-file") as HTMLElement;
    this.#protocol = root.querySelector(".status-protocol") as HTMLElement;
    this.#records = root.querySelector(".status-records") as HTMLElement;
    this.#cancel.addEventListener("click", () => {
      this.#cancel.disabled = true;
      onCancel();
    });
    this.showFile(null);
  }

  /** Pending state: step text now, spinner and Cancel after a short delay so fast jobs never flash. */
  busy(step: string): void {
    this.#clearTimers();
    this.#error.hidden = true;
    this.#text.hidden = false;
    this.#text.textContent = step;
    this.#text.title = step;
    this.#message.setAttribute("aria-busy", "true");
    this.#showTimer = window.setTimeout(() => {
      this.#shownAt = performance.now();
      this.#spinner.hidden = false;
      this.#cancel.hidden = false;
      this.#cancel.disabled = false;
    }, SHOW_DELAY_MS);
  }

  /** Ends the pending state; a visible spinner stays for its minimum time. */
  idle(): Promise<void> {
    window.clearTimeout(this.#showTimer);
    this.#showTimer = undefined;
    this.#message.removeAttribute("aria-busy");
    this.#cancel.hidden = true;
    if (this.#spinner.hidden) return Promise.resolve();
    const remaining = Math.max(0, MIN_SHOW_MS - (performance.now() - this.#shownAt));
    return new Promise((resolve) => {
      this.#hideTimer = window.setTimeout(() => {
        this.#spinner.hidden = true;
        resolve();
      }, remaining);
    });
  }

  info(text: string): void {
    this.#error.hidden = true;
    this.#text.hidden = false;
    this.#text.textContent = text;
    this.#text.title = text;
  }

  error(text: string): void {
    this.#text.hidden = true;
    this.#text.textContent = "";
    this.#error.hidden = false;
    this.#error.textContent = text;
    this.#error.title = text;
  }

  showFile(file: FileSummary | null): void {
    if (!file) {
      this.#file.textContent = "No file";
      this.#protocol.textContent = "";
      this.#records.textContent = "";
      return;
    }
    this.#file.textContent = file.name;
    this.#protocol.textContent = `Lineage2Ver${file.protocol}`;
    this.#records.textContent =
      file.records !== null ? `${file.records.toLocaleString("en-US")} records` : (file.encoding ?? "");
  }

  #clearTimers(): void {
    window.clearTimeout(this.#showTimer);
    window.clearTimeout(this.#hideTimer);
    this.#showTimer = undefined;
    this.#hideTimer = undefined;
    this.#spinner.hidden = true;
    this.#cancel.hidden = true;
  }
}
