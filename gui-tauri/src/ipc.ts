// Typed wrappers over the Rust commands. Every file transform happens behind these calls (l2dat).
import { invoke } from "@tauri-apps/api/core";

export type LogStream = "stdout" | "stderr" | "info" | "error";

export interface LogLine {
  stream: LogStream;
  text: string;
}

export interface Chronicle {
  name: string;
  dirDDF: string;
}

export interface AppInfo {
  chronicles: Chronicle[];
  protocols: number[];
  defaultChronicle: string;
  defaultProtocol: number;
  setupError: string | null;
  l2dat: string | null;
  isMac: boolean;
}

export interface OpenResult {
  path: string;
  name: string;
  text: string;
  lineSeparator: string | null;
  protocol: number;
  records: number | null;
  encoding: string | null;
  elapsedMs: number;
}

export interface SaveResult {
  path: string;
  protocol: number;
  rows: number | null;
  backup: string;
  backupKept: boolean;
  elapsedMs: number;
}

export interface SaveTxtResult {
  path: string;
  bytes: number;
  encoding: string;
}

export interface TextPosition {
  line: number;
  column: number | null;
}

/** The serialized Rust `AppError`. */
export interface AppError {
  kind: string;
  message: string;
  position: TextPosition | null;
}

export function isAppError(value: unknown): value is AppError {
  return (
    typeof value === "object" &&
    value !== null &&
    typeof (value as { kind?: unknown }).kind === "string" &&
    typeof (value as { message?: unknown }).message === "string"
  );
}

/** Any rejection as an `AppError` (IPC failures arrive as plain strings). */
export function toAppError(value: unknown): AppError {
  if (isAppError(value)) return value;
  return { kind: "ipc", message: value instanceof Error ? value.message : String(value), position: null };
}

export const ipc = {
  appInfo: (): Promise<AppInfo> => invoke("app_info"),
  takePendingOpens: (): Promise<string[]> => invoke("take_pending_opens"),
  openFile: (path: string, chronicleDir: string): Promise<OpenResult> =>
    invoke("open_file", { path, chronicleDir }),
  saveFile: (text: string, protocol: number, overwriteChanged: boolean): Promise<SaveResult> =>
    invoke("save_file", { text, protocol, overwriteChanged }),
  saveTxt: (path: string, text: string): Promise<SaveTxtResult> => invoke("save_txt", { path, text }),
  cancelJob: (): Promise<void> => invoke("cancel_job"),
  setDirty: (dirty: boolean, name: string | null): Promise<void> => invoke("set_dirty", { dirty, name }),
  closeWindow: (): Promise<void> => invoke("close_window"),
};
