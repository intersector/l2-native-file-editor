// Wiring: toolbar and shortcuts -> Rust commands (which run l2dat) -> editor, log and status bar.
import { listen } from "@tauri-apps/api/event";
import { basename, dirname, join } from "@tauri-apps/api/path";
import { ask, message, open as openDialog, save as saveDialog } from "@tauri-apps/plugin-dialog";
import { Editor } from "./editor";
import { type AppError, ipc, type LogLine, type SaveResult, toAppError } from "./ipc";
import { SettingsStore } from "./settings";
import { LogPane } from "./ui/logPane";
import { SettingsDialog } from "./ui/settingsDialog";
import { type FileSummary, StatusBar } from "./ui/statusBar";
import { type Operation, Toolbar } from "./ui/toolbar";

const OPEN_FILTERS = [
  { name: "All Formats (dat, ini, int, htm)", extensions: ["dat", "ini", "int", "htm"] },
  { name: "DAT", extensions: ["dat"] },
  { name: "INI", extensions: ["ini"] },
  { name: "INT", extensions: ["int"] },
  { name: "HTM", extensions: ["htm"] },
];

/** Failures raised before the Rust pipeline frame starts, so the log does not show them yet. */
const UNLOGGED_KINDS = new Set(["setup", "busy", "unknownChronicle", "noFile", "ipc"]);

interface OpenedDoc extends FileSummary {
  path: string;
}

function el<T extends HTMLElement = HTMLElement>(id: string): T {
  const element = document.getElementById(id);
  if (!element) throw new Error(`#${id} is missing from index.html`);
  return element as T;
}

const seconds = (ms: number): string => `${(ms / 1000).toFixed(2)} s`;

async function main(): Promise<void> {
  const [info, settings] = await Promise.all([ipc.appInfo(), SettingsStore.open()]);
  const mod = info.isMac ? "⌘" : "Ctrl+";
  const workspace = el("workspace");
  const log = new LogPane(el("log"));
  const settingsDialog = new SettingsDialog(el<HTMLDialogElement>("settings"), settings);
  let doc: OpenedDoc | null = null;
  let busy: Operation | null = null;
  /** An open owns the window from its first step until it finishes or is declined. */
  let opening = false;
  let drainWhenIdle = false;

  const status = new StatusBar(el("statusbar"), () => {
    ipc.cancelJob().catch((e: unknown) => log.append({ stream: "error", text: `Cancel failed: ${toAppError(e).message}` }));
  });
  const editor = new Editor(el("editor"), (dirty) => {
    ipc.setDirty(dirty, doc?.name ?? null).catch((e: unknown) => {
      log.append({ stream: "error", text: `Could not record unsaved edits: ${toAppError(e).message}` });
    });
  });
  const toolbar = new Toolbar(el("toolbar"), mod, {
    open: () => void chooseAndOpen(),
    save: () => void save(),
    saveTxt: () => void saveTxt(),
    reopen: () => {
      if (doc) void openPath(doc.path);
    },
    settings: () => settingsDialog.show(),
    chronicleChanged: (chronicle) => {
      void settings.update({ chronicle });
      if (doc) status.info("Chronicle changed: ReOpen to decode the file with this chronicle's DDF.");
    },
    protocolChanged: (protocol) => void settings.update({ protocol }),
  });

  const chronicles = info.chronicles.map((c) => c.dirDDF);
  const chronicle = chronicles.includes(settings.values.chronicle) ? settings.values.chronicle : info.defaultChronicle;
  const protocol = info.protocols.includes(settings.values.protocol) ? settings.values.protocol : info.defaultProtocol;
  toolbar.setChoices(info.chronicles, chronicle, info.protocols, protocol);

  function begin(operation: Operation, step: string): void {
    busy = operation;
    toolbar.setBusy(operation);
    editor.setReadOnly(true);
    workspace.setAttribute("aria-busy", "true");
    status.busy(step);
  }

  function end(): void {
    void status.idle();
    busy = null;
    toolbar.setBusy(null);
    editor.setReadOnly(doc === null);
    workspace.removeAttribute("aria-busy");
    if (drainWhenIdle) {
      drainWhenIdle = false;
      void drainPendingOpens();
    }
  }

  function failure(action: string, error: AppError, jumpToPosition = false): void {
    if (error.kind === "cancelled") {
      status.info(`${action} cancelled.`);
      return;
    }
    status.error(`${action} failed: ${error.message}`);
    if (UNLOGGED_KINDS.has(error.kind)) log.append({ stream: "error", text: `${action} failed: ${error.message}` });
    if (jumpToPosition && error.position) editor.jumpTo(error.position.line, error.position.column);
  }

  /** Save / Don't Save / Cancel when the editor has unsaved edits; true when the caller may go on. */
  async function resolveUnsaved(action: string): Promise<boolean> {
    if (!doc || !editor.dirty) return true;
    const choice = await message(`${doc.name} has unsaved edits. Save them before you ${action}?`, {
      title: "Unsaved edits",
      kind: "warning",
      buttons: { yes: "Save", no: "Don't Save", cancel: "Cancel" },
    });
    if (choice === "Save" || choice === "Yes") return save();
    return choice === "Don't Save" || choice === "No";
  }

  async function chooseAndOpen(): Promise<void> {
    if (busy) return;
    const start = settings.values.systemDir || (doc ? await dirname(doc.path) : "");
    const selected = await openDialog({
      title: "Open & Decrypt",
      multiple: false,
      directory: false,
      filters: OPEN_FILTERS,
      ...(start ? { defaultPath: start } : {}),
    });
    if (typeof selected === "string") await openPath(selected);
  }

  async function openPath(path: string): Promise<void> {
    if (busy || opening) return;
    // Reserved before the first await: `busy` stays free for the Save the unsaved-edits prompt may run.
    opening = true;
    try {
      await openClaimed(path);
    } finally {
      opening = false;
      if (drainWhenIdle && !busy) {
        drainWhenIdle = false;
        void drainPendingOpens();
      }
    }
  }

  async function openClaimed(path: string): Promise<void> {
    const name = await basename(path);
    if (!(await resolveUnsaved(`open ${name}`))) return;
    begin("open", `Opening ${name}…`);
    try {
      const result = await ipc.openFile(path, toolbar.chronicle);
      doc = {
        path: result.path,
        name: result.name,
        protocol: result.protocol,
        records: result.records,
        encoding: result.encoding,
      };
      editor.setDocument(result.text, result.lineSeparator);
      toolbar.setHasFile(true);
      status.showFile(doc);
      status.info(`Opened ${result.name} in ${seconds(result.elapsedMs)}.`);
      if (result.protocol !== toolbar.protocol) {
        log.append({
          stream: "info",
          text: `note: the file is Lineage2Ver${result.protocol}; Save & Encrypt uses Lineage2Ver${toolbar.protocol} (Lineage2Ver picker).`,
        });
      }
    } catch (e) {
      failure("Open", toAppError(e));
    } finally {
      end();
    }
  }

  async function save(): Promise<boolean> {
    if (busy || !doc) return false;
    const opened = doc;
    const revision = editor.revision;
    const target = toolbar.protocol;
    begin("save", `Saving ${opened.name}…`);
    try {
      const text = editor.getText();
      let result: SaveResult;
      try {
        result = await ipc.saveFile(text, target, false);
      } catch (e) {
        const error = toAppError(e);
        if (error.kind !== "changedOnDisk") throw error;
        const replace = await ask(
          `${error.message}\n\nReplace it with the edited text? The file on disk is kept as ${opened.name}.bak first.`,
          { title: "File changed on disk", kind: "warning", okLabel: "Replace", cancelLabel: "Cancel" },
        );
        if (!replace) {
          status.info("Save cancelled; the file on disk was left unchanged.");
          return false;
        }
        result = await ipc.saveFile(text, target, true);
      }
      editor.markSaved(revision);
      doc = { ...opened, protocol: result.protocol };
      status.showFile(doc);
      const rows = result.rows !== null ? `, ${result.rows.toLocaleString("en-US")} rows` : "";
      const backup = `${await basename(result.backup)} ${result.backupKept ? "kept" : "written"}`;
      status.info(`Saved ${opened.name} (Lineage2Ver${result.protocol}${rows}) in ${seconds(result.elapsedMs)}; ${backup}.`);
      return true;
    } catch (e) {
      failure("Save", toAppError(e), true);
      return false;
    } finally {
      end();
    }
  }

  async function saveTxt(): Promise<void> {
    if (busy || !doc) return;
    const folder = settings.values.txtDir || (await dirname(doc.path));
    const stem = doc.name.replace(/\.[^.]+$/, "");
    const target = await saveDialog({
      title: "Save TXT",
      defaultPath: await join(folder, `${stem}.txt`),
      filters: [{ name: "Text", extensions: ["txt"] }],
    });
    if (!target) return;
    const targetName = await basename(target);
    if (busy || opening) {
      status.info("Save TXT skipped: another operation started while you chose the file.");
      return;
    }
    begin("saveTxt", `Saving ${targetName}…`);
    try {
      const result = await ipc.saveTxt(target, editor.getText());
      status.info(`Saved ${result.path} (${result.encoding}, ${result.bytes.toLocaleString("en-US")} bytes).`);
    } catch (e) {
      failure("Save TXT", toAppError(e));
    } finally {
      end();
    }
  }

  /** Opens a file passed with --open or by the OS; waits while another job runs. */
  async function drainPendingOpens(): Promise<void> {
    if (busy || opening) {
      drainWhenIdle = true;
      return;
    }
    const paths = await ipc.takePendingOpens();
    const [first, ...ignored] = paths;
    for (const path of ignored) log.append({ stream: "info", text: `note: one file per window; not opened: ${path}` });
    if (first && (busy || opening)) {
      log.append({ stream: "info", text: `note: another file is being opened; not opened: ${first}` });
    } else if (first) {
      await openPath(first);
    }
  }

  window.addEventListener(
    "keydown",
    (event) => {
      if ((info.isMac ? !event.metaKey : !event.ctrlKey) || event.altKey || el<HTMLDialogElement>("settings").open) return;
      const key = event.key.toLowerCase();
      if (key === "o" && !event.shiftKey) void chooseAndOpen();
      else if (key === "s") void (event.shiftKey ? saveTxt() : save());
      else if ((key === "f" || key === "r") && !event.shiftKey) editor.openSearch();
      else if (key === "g" && !event.shiftKey) editor.gotoLine();
      else return;
      event.preventDefault();
      event.stopPropagation();
    },
    { capture: true },
  );

  setupSplitter(workspace, el("splitter"));

  await listen<LogLine>("log-line", (event) => log.append(event.payload));
  await listen("pending-opens", () => void drainPendingOpens());
  await listen("close-requested", async () => {
    if (await resolveUnsaved("close the window")) {
      await ipc.closeWindow().catch((e: unknown) => failure("Close", toAppError(e)));
    }
  });

  if (info.setupError) {
    status.error(info.setupError);
    log.append({ stream: "error", text: info.setupError });
  } else {
    status.info("Ready.");
  }
  await drainPendingOpens();
}

/** Drag the bar between editor and log to resize the log. */
function setupSplitter(workspace: HTMLElement, splitter: HTMLElement): void {
  splitter.addEventListener("pointerdown", (down) => {
    splitter.setPointerCapture(down.pointerId);
    const bottom = workspace.getBoundingClientRect().bottom;
    const move = (event: PointerEvent): void => {
      const height = Math.min(Math.max(bottom - event.clientY, 60), workspace.clientHeight - 120);
      workspace.style.setProperty("--log-height", `${height}px`);
    };
    const up = (): void => {
      splitter.removeEventListener("pointermove", move);
      splitter.removeEventListener("pointerup", up);
    };
    splitter.addEventListener("pointermove", move);
    splitter.addEventListener("pointerup", up);
  });
}

main().catch((e: unknown) => {
  const text = `The editor failed to start: ${toAppError(e).message}`;
  const statusbar = document.getElementById("statusbar");
  if (statusbar) {
    statusbar.textContent = text;
    statusbar.setAttribute("role", "alert");
  }
});
