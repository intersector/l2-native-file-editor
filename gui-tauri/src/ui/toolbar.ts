// Toolbar: Open & Decrypt, Save & Encrypt, Save TXT, ReOpen, the Chronicle and Lineage2Ver pickers, Settings.
import type { Chronicle } from "../ipc";

export type Operation = "open" | "save" | "saveTxt";

export interface ToolbarActions {
  open: () => void;
  save: () => void;
  saveTxt: () => void;
  reopen: () => void;
  settings: () => void;
  chronicleChanged: (dir: string) => void;
  protocolChanged: (protocol: number) => void;
}

const PENDING_LABEL: Record<Operation, string> = {
  open: "Opening…",
  save: "Saving…",
  saveTxt: "Saving…",
};

export class Toolbar {
  readonly #open: HTMLButtonElement;
  readonly #save: HTMLButtonElement;
  readonly #saveTxt: HTMLButtonElement;
  readonly #reopen: HTMLButtonElement;
  readonly #chronicle: HTMLSelectElement;
  readonly #protocol: HTMLSelectElement;
  #hasFile = false;
  #busy: Operation | null = null;

  constructor(root: HTMLElement, mod: string, actions: ToolbarActions) {
    root.innerHTML = `
      <div class="toolbar-group">
        <button type="button" data-op="open" title="Open & Decrypt (${mod}O)">Open &amp; Decrypt</button>
        <button type="button" data-op="save" title="Save & Encrypt (${mod}S)">Save &amp; Encrypt</button>
        <button type="button" data-op="saveTxt" title="Save TXT (⇧${mod}S)">Save TXT</button>
        <button type="button" data-op="reopen" title="Open the current file again">ReOpen</button>
      </div>
      <div class="toolbar-group">
        <label>Chronicle <select class="chronicle"></select></label>
        <label>Lineage2Ver <select class="protocol"></select></label>
      </div>
      <div class="toolbar-spacer"></div>
      <button type="button" data-op="settings" title="Settings">Settings</button>`;
    const button = (op: string) => root.querySelector(`[data-op="${op}"]`) as HTMLButtonElement;
    this.#open = button("open");
    this.#save = button("save");
    this.#saveTxt = button("saveTxt");
    this.#reopen = button("reopen");
    this.#chronicle = root.querySelector(".chronicle") as HTMLSelectElement;
    this.#protocol = root.querySelector(".protocol") as HTMLSelectElement;
    for (const b of [this.#open, this.#save, this.#saveTxt]) b.dataset.label = b.textContent ?? "";
    this.#open.addEventListener("click", actions.open);
    this.#save.addEventListener("click", actions.save);
    this.#saveTxt.addEventListener("click", actions.saveTxt);
    this.#reopen.addEventListener("click", actions.reopen);
    button("settings").addEventListener("click", actions.settings);
    this.#chronicle.addEventListener("change", () => actions.chronicleChanged(this.#chronicle.value));
    this.#protocol.addEventListener("change", () => actions.protocolChanged(Number(this.#protocol.value)));
    this.#render();
  }

  setChoices(chronicles: Chronicle[], chronicle: string, protocols: number[], protocol: number): void {
    this.#chronicle.replaceChildren(...chronicles.map((c) => new Option(c.name, c.dirDDF)));
    this.#chronicle.value = chronicle;
    this.#protocol.replaceChildren(...protocols.map((p) => new Option(String(p), String(p))));
    this.#protocol.value = String(protocol);
  }

  get chronicle(): string {
    return this.#chronicle.value;
  }

  get protocol(): number {
    return Number(this.#protocol.value);
  }

  setHasFile(hasFile: boolean): void {
    this.#hasFile = hasFile;
    this.#render();
  }

  /** Disables every trigger while a job runs; the active one shows a pending label at its own width. */
  setBusy(operation: Operation | null): void {
    this.#busy = operation;
    this.#render();
  }

  #render(): void {
    const busy = this.#busy !== null;
    this.#open.disabled = busy;
    this.#save.disabled = busy || !this.#hasFile;
    this.#saveTxt.disabled = busy || !this.#hasFile;
    this.#reopen.disabled = busy || !this.#hasFile;
    this.#chronicle.disabled = busy;
    this.#protocol.disabled = busy;
    const active: Record<Operation, HTMLButtonElement> = { open: this.#open, save: this.#save, saveTxt: this.#saveTxt };
    for (const [op, b] of Object.entries(active) as [Operation, HTMLButtonElement][]) {
      if (this.#busy === op) {
        if (!b.style.minWidth) b.style.minWidth = `${b.offsetWidth}px`;
        b.textContent = PENDING_LABEL[op];
        b.setAttribute("aria-busy", "true");
      } else {
        b.textContent = b.dataset.label ?? "";
        b.style.minWidth = "";
        b.removeAttribute("aria-busy");
      }
    }
  }
}
