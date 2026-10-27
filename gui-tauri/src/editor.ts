// The text editor: CodeMirror 6, no line wrapping, monospace, search/replace and go-to-line.
// The editor document is the single source of truth; its text is read only when saving.
import { Compartment, EditorState, type Extension, Prec } from "@codemirror/state";
import {
  crosshairCursor,
  drawSelection,
  dropCursor,
  EditorView,
  highlightActiveLine,
  highlightActiveLineGutter,
  highlightSpecialChars,
  keymap,
  lineNumbers,
  placeholder,
  rectangularSelection,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, insertTab } from "@codemirror/commands";
import { gotoLine, highlightSelectionMatches, openSearchPanel, search, searchKeymap } from "@codemirror/search";

const EMPTY_HINT = "No file open. Use Open & Decrypt to load a .dat, .ini, .int or .htm file.";

const theme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "var(--editor-bg)", color: "var(--text)" },
  "&.cm-focused": { outline: "none" },
  ".cm-scroller": { fontFamily: "var(--mono)", fontSize: "13px", lineHeight: "1.45", overflow: "auto" },
  ".cm-content": { caretColor: "var(--accent)" },
  ".cm-gutters": {
    backgroundColor: "var(--gutter-bg)",
    color: "var(--muted)",
    borderRight: "1px solid var(--border)",
  },
  ".cm-activeLine": { backgroundColor: "var(--active-line)" },
  ".cm-activeLineGutter": { backgroundColor: "var(--active-line)" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
    backgroundColor: "var(--selection) !important",
  },
  ".cm-searchMatch": { backgroundColor: "var(--search-match)" },
  ".cm-searchMatch-selected": { backgroundColor: "var(--search-current)" },
  ".cm-panels": { backgroundColor: "var(--panel-bg)", color: "var(--text)" },
  ".cm-panels-top": { borderBottom: "1px solid var(--border)" },
  // Search and go-to-line panels. "&.cm-editor" outranks CodeMirror's own light/dark base rules.
  "&.cm-editor .cm-panel .cm-textfield": {
    backgroundColor: "var(--editor-bg)",
    color: "var(--text)",
    border: "1px solid var(--border)",
    borderRadius: "3px",
  },
  "&.cm-editor .cm-panel .cm-button": {
    backgroundColor: "var(--button-bg)",
    backgroundImage: "none",
    color: "var(--text)",
    border: "1px solid var(--border)",
    borderRadius: "3px",
  },
  "&.cm-editor .cm-panel .cm-button:hover": { backgroundColor: "var(--button-hover)" },
  ".cm-placeholder": { color: "var(--muted)", fontFamily: "var(--ui-font)" },
});

/** basicSetup without line wrapping, bracket closing or autocompletion (they would alter cells while typing). */
const setup: Extension = [
  lineNumbers(),
  highlightActiveLineGutter(),
  highlightSpecialChars(),
  history(),
  drawSelection(),
  dropCursor(),
  EditorState.allowMultipleSelections.of(true),
  rectangularSelection(),
  crosshairCursor(),
  highlightActiveLine(),
  highlightSelectionMatches(),
  search({ top: true }),
  placeholder(EMPTY_HINT),
  Prec.highest(
    keymap.of([
      { key: "Mod-g", run: gotoLine, preventDefault: true },
      { key: "Mod-r", run: openSearchPanel, preventDefault: true },
      { key: "Mod-Alt-f", run: openSearchPanel, preventDefault: true },
    ]),
  ),
  keymap.of([{ key: "Tab", run: insertTab }, ...searchKeymap, ...historyKeymap, ...defaultKeymap]),
  theme,
];

export class Editor {
  readonly #view: EditorView;
  readonly #readOnly = new Compartment();
  readonly #onDirtyChange: (dirty: boolean) => void;
  /** Bumped on every document change; a save marks clean only the revision it read. */
  #revision = 0;
  #savedRevision = 0;
  #reportedDirty = false;

  constructor(parent: HTMLElement, onDirtyChange: (dirty: boolean) => void) {
    this.#onDirtyChange = onDirtyChange;
    this.#view = new EditorView({ parent, state: this.#createState("", null, true) });
  }

  get dirty(): boolean {
    return this.#revision !== this.#savedRevision;
  }

  get revision(): number {
    return this.#revision;
  }

  /** Replaces the document (fresh undo history); `lineSeparator` keeps CRLF/CR text byte-exact. */
  setDocument(text: string, lineSeparator: string | null): void {
    this.#view.setState(this.#createState(text, lineSeparator, false));
    this.#revision = 0;
    this.#savedRevision = 0;
    this.#reportDirty();
    this.#view.scrollDOM.scrollTo(0, 0);
  }

  /** The text joined with the document's line separator. */
  getText(): string {
    return this.#view.state.sliceDoc();
  }

  markSaved(revision: number): void {
    this.#savedRevision = revision;
    this.#reportDirty();
  }

  setReadOnly(readOnly: boolean): void {
    this.#view.dispatch({ effects: this.#readOnly.reconfigure(EditorState.readOnly.of(readOnly)) });
  }

  /** Moves the caret to a 1-based line and column (columns count code points) and focuses the editor. */
  jumpTo(line: number, column: number | null): void {
    const doc = this.#view.state.doc;
    const target = doc.line(Math.min(Math.max(1, line), doc.lines));
    let offset = 0;
    for (let at = 1; at < (column ?? 1) && offset < target.length; at++) {
      offset += (target.text.codePointAt(offset) ?? 0) > 0xffff ? 2 : 1;
    }
    const pos = target.from + offset;
    this.#view.dispatch({
      selection: { anchor: pos },
      effects: EditorView.scrollIntoView(pos, { y: "center", x: "center" }),
    });
    this.#view.focus();
  }

  openSearch(): void {
    openSearchPanel(this.#view);
  }

  gotoLine(): void {
    gotoLine(this.#view);
  }

  focus(): void {
    this.#view.focus();
  }

  #createState(text: string, lineSeparator: string | null, readOnly: boolean): EditorState {
    return EditorState.create({
      doc: text,
      extensions: [
        setup,
        lineSeparator ? EditorState.lineSeparator.of(lineSeparator) : [],
        this.#readOnly.of(EditorState.readOnly.of(readOnly)),
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            this.#revision++;
            this.#reportDirty();
          }
        }),
      ],
    });
  }

  #reportDirty(): void {
    if (this.dirty !== this.#reportedDirty) {
      this.#reportedDirty = this.dirty;
      this.#onDirtyChange(this.dirty);
    }
  }
}
