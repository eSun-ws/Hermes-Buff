# Export formats

Everything here was read from the source and, where marked verified, executed.

## Summary

| Format | Trigger | Mechanism | Status |
| --- | --- | --- | --- |
| `.prg` (native) | `pgctl save` → `Ctrl+S` | msgpack save, format version **2.7.0** | verified (bytes change + reload) |
| `.svg` | `pgctl export X.prg [out.svg]` → keybind `C-S-e` | `StageExportSvg.exportStageToSVGFile` | verified (21 695 bytes, 4 nodes) |
| `.png` | `pgctl export X.prg out.png` → keybind `C-S-p`, then one click | `ExportPngWindow` | verified (936×372 RGBA, 22 591 bytes) |
| plain text | `exportSelectedNetStructureToPlainText` | clipboard, needs selection | source read |
| Markdown | `exportSelectedTreeStructureToMarkdown` | clipboard/dialog | source read |
| Tab-indented | `exportSelectedTreeStructureToPlainText` | clipboard | source read |
| Mermaid | `exportSelectedNetStructureToMermaid` | clipboard, needs selection | source read |
| `prg://` deep link | `exportCurrentViewPrgDeepLink`, `exportSelectedEntityPrgDeepLink`, `exportCurrentFilePrgDeepLink` | dialog with a URL | source read |

## The native file: `.prg`

- msgpack (`@msgpack/msgpack`), not JSON — do not try to hand-edit it.
- The file carries a schema version; current is `2.7.0` (`LATEST_PROJECT_VERSION`).
- A **newer** file → `PROJECT_VERSION_UNSUPPORTED`; an **older** one → `PROJECT_UPGRADE_REQUIRED`,
  and `--allow-upgrade` runs `ProjectUpgrader` in-process. Old repo samples (format 2.5.x) still
  failed to load after upgrade in testing: **migration of legacy projects needs the GUI**.
- CLI edits live in the running app's memory. Nothing reaches disk until `Ctrl+S` (`pgctl save`).
  A CLI call that reports `success:true` and an unchanged file size is not a bug — it is unsaved.

## SVG

`StageExportSvg` has two entry points: `exportStageToSVGFile` (whole stage, keybind
`exportSvgAll`) and `exportSelectedToSVGFile` (`exportSvgSelected`). Output is a real vector file
with a `viewBox` sized to the content and an embedded background colour — diffable, drop it into a
report or a deck as-is.

Note: the official docs advertise a headless export — `xvfb-run -a project-graph <path> -o out.svg`
(with `-` for stdout). In **v4.3.2 it is a stub**: `-o out.svg`, `-o -` and `--output out.svg` all
exit 0 and write nothing (the SVG dump in `runCli` is commented out). Treat the GUI export path as
the only real one, and do not build automation on `-o`.

Aside: `StageExportSvg` also has `exportSelectedToSVGFile` (`exportSvgSelected`), so "selected → SVG"
exists as a separate action; it needs a selection.

## Text exports

The docs' "export plain text" menu has three flavours, all driven from a selection: indented text, Markdown, and a
plain graph listing (`A\nB\n\nA --> B`). Keybind ids: `exportSelectedTreeStructureToPlainText`,
`exportSelectedTreeStructureToMarkdown`, `exportSelectedNetStructureToPlainText`,
`exportSelectedNetStructureToMermaid`. They write via clipboard / dialog, not to a path, so a
headless caller cannot collect the result without the GUI.

## PNG

The panel (`ExportPngWindow`) offers: scale (1×…, i.e. a multiplier over the content size),
preserve aspect ratio, transparent background, show grid, render interval (default 2 ms).
Flow: open (`C-S-p`) → click the render button (its label is localized; it is the only button in the
  panel) → a save dialog appears → type an absolute path → Enter.
The click point is a fraction of the **window box**, not the screen; measured on a 1200×800
window the button sits at ≈(12%, 70%). `pgctl` tries that point first and falls back through a
short candidate list, verifying that a chooser window appeared before typing.

## Keybind injection

Export actions ship with `defaultKey: ""` — no shortcut at all. The app reads custom bindings from
`<XDG_DATA_HOME>/liren.project-graph/keybinds2.json` at start-up:

```json
{
  "exportSvgAll":    { "isEnabled": true, "key": "C-S-e" },
  "exportPngLegacy": { "isEnabled": true, "key": "C-S-p" }
}
```

Syntax is Emacs-style (`parseSingleEmacsKey`): modifiers as prefixes `C-`, `S-`, `A-`, `M-`, a
space separates a key sequence, `<1>`/`<MWU>` denote mouse buttons and wheel. Examples in the
source's own docs: `C-home`, `C-S-end`, `C-s`, `C-<MWU>`, and sequences like `C-k C-t`.

Because the file is read at start-up, writing a keybind while the app runs has no effect — start
(or restart) the app afterwards. `pgctl` does this for you before every `start`.

## Selection-based exports

Plain text / Markdown / Tab / Mermaid all operate on the current **selection**, and therefore need
the app to have a selection — which is the `selection` capability the closed runtime does not
provide. Run them from the GUI (menu or a keybind you add), not from the CLI.
