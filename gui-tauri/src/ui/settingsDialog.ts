// Settings: temp folder, system folder (Open default), TXT folder (Save TXT default), text mode, float format.
import { open as pickFolder } from "@tauri-apps/plugin-dialog";
import { FLOAT_FORMATS, type FloatFormat, type Settings, type SettingsStore, TEXT_MODES, type TextMode } from "../settings";

type FolderKey = "tempDir" | "systemDir" | "txtDir";

const FOLDERS: { key: FolderKey; label: string; hint: string }[] = [
  {
    key: "tempDir",
    label: "Temp folder",
    hint: "Session files go to an L2FileEditor-sessions folder inside it. Used from the next window session (restart the app if a file is open).",
  },
  { key: "systemDir", label: "System folder", hint: "Where Open & Decrypt starts (the client's system folder)." },
  { key: "txtDir", label: "TXT folder", hint: "Where Save TXT starts." },
];

export class SettingsDialog {
  readonly #dialog: HTMLDialogElement;
  readonly #store: SettingsStore;
  readonly #error: HTMLElement;

  constructor(dialog: HTMLDialogElement, store: SettingsStore) {
    this.#dialog = dialog;
    this.#store = store;
    const option = (value: string, label: string) => `<option value="${value}">${label}</option>`;
    dialog.innerHTML = `
      <form method="dialog" class="settings-form">
        <h2>Settings</h2>
        ${FOLDERS.map(
          (f) => `
          <div class="field">
            <label for="set-${f.key}">${f.label}</label>
            <div class="folder-row">
              <input id="set-${f.key}" name="${f.key}" type="text" readonly placeholder="Default" />
              <button type="button" data-choose="${f.key}">Choose…</button>
              <button type="button" data-clear="${f.key}">Default</button>
            </div>
            <p class="hint">${f.hint}</p>
          </div>`,
        ).join("")}
        <div class="field">
          <label for="set-textMode">Text mode</label>
          <select id="set-textMode" name="textMode">${TEXT_MODES.map((m) => option(m.value, m.label)).join("")}</select>
          <p class="hint">Stored only, not used yet: <code>l2dat open/save</code> do not take this flag.</p>
        </div>
        <div class="field">
          <label for="set-floatFormat">Float format</label>
          <select id="set-floatFormat" name="floatFormat">${FLOAT_FORMATS.map((f) => option(f.value, f.label)).join("")}</select>
          <p class="hint">Stored only, not used yet: <code>l2dat open/save</code> do not take this flag.</p>
        </div>
        <p class="form-error" role="alert" hidden></p>
        <div class="dialog-buttons">
          <button type="button" data-action="cancel">Cancel</button>
          <button type="submit" class="primary" data-action="save">Save</button>
        </div>
      </form>`;
    this.#error = dialog.querySelector(".form-error") as HTMLElement;
    const form = dialog.querySelector("form") as HTMLFormElement;

    for (const f of FOLDERS) {
      const input = this.#input(f.key);
      dialog.querySelector(`[data-choose="${f.key}"]`)?.addEventListener("click", async () => {
        const chosen = await pickFolder({
          directory: true,
          title: f.label,
          ...(input.value ? { defaultPath: input.value } : {}),
        });
        if (typeof chosen === "string") input.value = chosen;
      });
      dialog.querySelector(`[data-clear="${f.key}"]`)?.addEventListener("click", () => {
        input.value = "";
      });
    }
    dialog.querySelector('[data-action="cancel"]')?.addEventListener("click", () => dialog.close());
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const save = form.querySelector('[data-action="save"]') as HTMLButtonElement;
      save.disabled = true;
      this.#error.hidden = true;
      try {
        await this.#store.update(this.#read());
        dialog.close();
      } catch (e) {
        this.#error.textContent = `The settings could not be saved: ${e instanceof Error ? e.message : String(e)}`;
        this.#error.hidden = false;
      } finally {
        save.disabled = false;
      }
    });
  }

  show(): void {
    const values = this.#store.values;
    for (const f of FOLDERS) this.#input(f.key).value = values[f.key];
    this.#select("textMode").value = values.textMode;
    this.#select("floatFormat").value = values.floatFormat;
    this.#error.hidden = true;
    this.#dialog.showModal();
  }

  #read(): Partial<Settings> {
    return {
      tempDir: this.#input("tempDir").value,
      systemDir: this.#input("systemDir").value,
      txtDir: this.#input("txtDir").value,
      textMode: this.#select("textMode").value as TextMode,
      floatFormat: this.#select("floatFormat").value as FloatFormat,
    };
  }

  #input(key: FolderKey): HTMLInputElement {
    return this.#dialog.querySelector(`#set-${key}`) as HTMLInputElement;
  }

  #select(key: "textMode" | "floatFormat"): HTMLSelectElement {
    return this.#dialog.querySelector(`#set-${key}`) as HTMLSelectElement;
  }
}
