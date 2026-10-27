// Persisted settings in `settings.json` (tauri-plugin-store). Rust reads `tempDir` from the same store.
import { load, type Store } from "@tauri-apps/plugin-store";

export const TEXT_MODES = [
  { value: "default", label: "Default (no flag)" },
  { value: "ascii", label: "Force ASCII (-f)" },
  { value: "utf8", label: "UTF-8 strings (-a UTF-8)" },
] as const;

export const FLOAT_FORMATS = [
  { value: "f", label: "Fixed (l2dat -o f)" },
  { value: "e", label: "Exponent (l2dat -o e)" },
] as const;

export type TextMode = (typeof TEXT_MODES)[number]["value"];
export type FloatFormat = (typeof FLOAT_FORMATS)[number]["value"];

export interface Settings {
  /** Chronicle folder name under DAT_defs (e.g. "CT2_6"); empty = the bundled default. */
  chronicle: string;
  /** Lineage2Ver used by Save & Encrypt; 0 = the default (413). */
  protocol: number;
  textMode: TextMode;
  floatFormat: FloatFormat;
  /** Parent of the session temp folders; empty = the app cache folder. */
  tempDir: string;
  /** Default folder of the Open dialog (the original's DirSys). */
  systemDir: string;
  /** Default folder of the Save TXT dialog. */
  txtDir: string;
}

const DEFAULTS: Settings = {
  chronicle: "",
  protocol: 0,
  textMode: "default",
  floatFormat: "f",
  tempDir: "",
  systemDir: "",
  txtDir: "",
};

export class SettingsStore {
  readonly #store: Store;
  #values: Settings;

  private constructor(store: Store, values: Settings) {
    this.#store = store;
    this.#values = values;
  }

  static async open(): Promise<SettingsStore> {
    const store = await load("settings.json", { defaults: {}, autoSave: 100 });
    const values: Settings = { ...DEFAULTS };
    for (const key of Object.keys(DEFAULTS) as (keyof Settings)[]) {
      const stored = await store.get(key);
      if (typeof stored === typeof DEFAULTS[key]) Object.assign(values, { [key]: stored });
    }
    return new SettingsStore(store, values);
  }

  get values(): Readonly<Settings> {
    return this.#values;
  }

  async update(changes: Partial<Settings>): Promise<void> {
    this.#values = { ...this.#values, ...changes };
    for (const [key, value] of Object.entries(changes)) await this.#store.set(key, value);
    await this.#store.save();
  }
}
