---
name: project-graph
description: Use when editing or exporting Project Graph .prg graphs.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [project-graph, prg, node-graph, xvfb, headless, cli, tauri, export, svg, png]
    category: software-development
    related_skills: [gui-app-on-headless-desktop, architecture-diagram, pdf]
---

# Project Graph, headlessly

[Project Graph](https://github.com/graphif/project-graph) is a Tauri/WebKitGTK desktop app for
node-based thinking maps. It ships **29 built-in tools** for reading and editing a project
(`.prg`), exposed through three adapters: the in-app AI chat, an MCP *client*, and a **CLI**.
This skill uses that CLI. It needs an X display but never a monitor, a desktop session or a
window manager — `Xvfb` is enough.

Install and dependencies: `README.md` beside this skill (`project-graph/README.md` in the
repository, or `<HERMES_HOME>/tools/project-graph-<version>-linux-x64/README.md` once the
installer has run). Everything user-facing is one script: `<tool-dir>/bin/pgctl`.

## When to use

- "draw this flow as a node graph", "turn this outline into a mind-map project"
- an existing `.prg` has to be read, batch-edited, re-laid-out, or turned into an image
- a diagram must stay **editable by the user** in a GUI afterwards

**Do not reach for this skill when the deliverable is just a picture.** For a one-shot diagram
with no follow-up editing, generate SVG/Mermaid/Graphviz/HTML directly — that costs a few hundred
tokens and needs no app, no build and no display. Project Graph pays off only when the artifact
must remain a node graph the user can open and drag around.

| Goal | Use |
| --- | --- |
| one-off image for chat/report | inline SVG / Mermaid (no app) |
| editable `.prg` the user keeps editing | this skill |
| image out of an existing `.prg` | this skill, `pgctl export` |

## Install (generic, ~76 MB on disk + ~120 MB of apt libs)

Put it under `HERMES_HOME`, never in a workspace or `/tmp`:

```bash
H=${HERMES_HOME:?}
D=$H/tools/project-graph-4.3.2-linux-x64
apt-get install -y libwebkit2gtk-4.1-0 xvfb xdotool
```

Then, in order — full commands, checksums and the reason for each step are in
`references/install.md`:

1. **app payload** — `dpkg-deb -x` the official `.deb` (never `dpkg -i`: the package names
   `libgtk-3-0`, renamed `libgtk-3-0t64` on 24.04+, so dpkg rejects a dependency that is present);
2. **CLI** — there is **no binary release**: the npm package is `private: true` and no asset
   ships it. Build the SSR bundle from source (`pnpm install` → `vite build -c vite.cli.config.ts`,
   ~4.5 min and ~1.3 GB of transient `node_modules`);
3. **jsdom@29** into `cli/` — the closed-project runtime builds a fake DOM;
4. **ownership helper** next to the bundle — the production entry sets its path as a sibling;
5. `pgctl doctor` — every dependency asserted, non-zero exit if one is missing.

Reuse `<HERMES_HOME>/tools/node-*-linux-x64/bin/node` instead of installing a second Node.

**License:** the app is GPL-3.0 and the CLI bundle is a derivative of it. Keep the built bundle
local; if you redistribute it, ship the corresponding source too.

## Three capability tiers (measure, do not assume)

| Environment | Tools available |
| --- | --- |
| no X at all | **19 / 29** — everything that does not need a live viewport or selection |
| bare `Xvfb` (no WM) | **29 / 29** — verified with repeated writes and both export paths; the GUI-only tools were also called individually under it (`create_text_node`, `get_nodes_in_viewport`, `get_selected_nodes`) and none answered `PROJECT_MUST_BE_OPEN` |
| Xvfb + WM + VNC/Selkies | 29 / 29, plus a human who can watch and click |

Blocked without a GUI (`PROJECT_MUST_BE_OPEN`), by missing capability:
`viewport` → `create_text_node`, `generate_node_tree_by_text`, `get_nodes_in_viewport`,
`search_and_add_image_node`; `selection` → `delete_selected_nodes`, `select_objects`,
`get_selected_nodes`, `get_selected_refs`, `sort_selected_nodes_by_x/y`.
With the app running and the project open, `pgctl tool` reaches those too (forwarded).

## Daily use

```bash
D=$HERMES_HOME/tools/project-graph-4.3.2-linux-x64; P=$D/bin/pgctl

$P new  /abs/dir/diagram.prg            # starter project (1 node, current format)
$P start /abs/dir/diagram.prg           # Xvfb :99 + app; prints its deadline
$P tool get_all_nodes    --project /abs/dir/diagram.prg --input '{}'
$P tool describe         create_text_node        # JSON schema of one tool, ~250 tokens
$P tool expand_node_tree_from_node --project /abs/dir/diagram.prg \
     --input '{"ref":"n1","text":"requirements"}'
$P save   /abs/dir/diagram.prg          # Ctrl+S — edits live in the app, not on disk
$P export /abs/dir/diagram.prg          # → <workspace>/Media/project-graph/diagram.svg
$P export /tmp/../diagram.prg out.png   # raster
$P status                               # pids, project, idle/TTL, bridge health
$P repair                               # restart the app after a wedged call
$P stop                                 # kills app + Xvfb, then verifies
$P forget /abs/dir/reused.prg           # drop stored refs/ownership (app must be stopped)
```

Tokens: a write answers ~110 bytes, `get_all_nodes` for 3 objects ~150 bytes, one
`describe` ~770 bytes. Load schemas on demand — dumping all 29 is ~14.6 KB per round.

**Output location:** default is `<workspace>/Media/project-graph/<name>.svg`. The workspace
root may hold directories only (HERMES.md), so nothing is written there. Pass an explicit path
for anywhere else; `pgctl` creates the parent directory.

**Path identity:** the ownership lock is keyed on `sha256(realpath)`, so the GUI, the CLI and
any container must see the *same* path. Keep projects on a persistent directory, never `/tmp`
if the app runs elsewhere, and run the CLI as the same user as the app.

## Before you author: read the feature docs, not just the tool list

The 29 tools expose *verbs*; they do not reveal layouts, gestures, styles or export options. Read
these pages before drawing anything (`graphif.dev/docs/prg/...`):

| Page | Why it changes the output |
| --- | --- |
| `features/feature/tree` | growth directions, `Alt+Shift+F` formatting, frames, how edges decide the shape |
| `features/feature/export` | which formats exist and that PNG may white-screen on a huge stage |
| `features/feature/cli` | the advertised `-o` export — a stub in the shipped build, do not build on it |
| `examples/graph-types/tree` | what the finished tree/DAG shapes look like |

Authoring from the tool list alone produces a flat strip of boxes; the shapes come from the docs.

## Shape the diagram (docs: `graphif.dev/docs/prg/features/feature/tree`)

`auto_layout_dag` is only one of several layout tools, and on its own it always produces a single
left-to-right row — using it alone is why a first attempt looks like a flat strip. `create_text_node`'s
`x`/`y` are ignored, so position comes from the tools below or from the format pass, never from
coordinates. Pick by shape:

| Want | Call | Notes |
| --- | --- | --- |
| mind map / tree (best default) | `expand_node_tree_from_node` with 2-space-indented text, then `Alt+Shift+F` | builds a whole subtree in one call; the format pass arranges it by **edge endpoints** |
| fan-out / star around one node | `breadth_expand_node {ref, texts[]}` | one level of children in a single call |
| chain / pipeline | `depth_expand_node {ref, texts[]}` | or build edges then `auto_layout_dag` to flatten to one row |
| bend a chain, up/down branches | `W W` / `S S` / `A A` / `D D` then `Tab` growth | direction is carried by the edge endpoint; **keys only affect Tab growth** — CLI-created edges are right-facing |
| group into a frame (nestable) | `select_objects` then `Ctrl+G` | a pure-text tree wrapped this way takes the root node's text as the frame title |
| colour by phase | `batch_change_color {refs, color:[r,g,b,a]}` | colour the root + group nodes, leave leaves neutral |

A frame (`Ctrl+G`) plus a tree is the documented way to keep a big graph legible; frames can nest
arbitrarily (fractal mind maps), and formatting never crosses a frame boundary.

## Looks: the rules that actually matter

1. **One root, ≤3 levels, 3-6 children per group.** Deeper trees turn into hairballs when
exported; split into two diagrams instead.
2. **Leaves short** (≤ 2 lines, ~20 chars) — node width drives total width, and a viewer
downscaling an 8000 px image makes everything unreadable. A 16-node, 3-group map lands at
≈1770×1430 and stays legible; a 12-node chain with long lines reached 4276×516.
3. **Colour the hierarchy, not everything**: root one accent, each group its own, leaves unstyled
(dark theme background is `#1e1e2e`, so anything lighter reads well).
4. **Format before exporting** (`Alt+Shift+F`) — CLI-built edges are all right-facing, so without a
format pass the tree keeps whatever geometry the creation tools left.
5. **PNG is transparent** by default in the export panel; the docs warn that a very large stage can
crash the PNG renderer (white window) — export SVG for huge graphs.

## Export formats

`references/formats.md` has the verified commands and the exact keybind ids. Summary:

| Format | How | Verified |
| --- | --- | --- |
| `.prg` (native, msgpack, format 2.7.0) | `pgctl save` | yes, byte size + reload |
| `.svg` (vector, text, diffable) | `pgctl export X.prg` (`C-S-e`) | yes, 21 KB for 4 nodes |
| `.png` (raster, scale/alpha/grid) | `pgctl export X.prg out.png` (`C-S-p`) | yes, 936×372 RGBA |
| plain text / Markdown / Tab / Mermaid | keybinds on a selection, GUI-side | source read, not scripted |
| `prg://` deep link | `exportCurrentViewPrgDeepLink` | source read |

Export actions have **no default shortcut**; `pgctl` injects `C-S-e` / `C-S-p` into
`<XDG_DATA_HOME>/liren.project-graph/keybinds2.json` before starting the app (the file is read
at start-up, so the keybind is only live after a `start`).

## Pitfalls that cost hours

Read `references/pitfalls.md` before debugging. These bite first:

1. **The released binary is not a CLI.** `project-graph --version` aborts with
   `Failed to initialize gtk backend!` without `DISPLAY` — Tauri initializes GTK before argv.
   The usable CLI is the separately built Node bundle.
2. **First write on an unknown project fails** with `PROJECT_LOAD_FAILED` (misleading: the real
   cause is the reference store not knowing the path). `pgctl tool` primes with one
   `get_all_nodes` before writing — do the same if you call the CLI directly.
3. **An empty project cannot be started by CLI.** Creating the *first* node needs `viewport`;
   `pgctl new` copies `<tool-dir>/templates/starter.prg` (1 node) so the graph has somewhere to
   start. Deleting nodes down to an empty canvas is fine — creating afterwards still works.
4. **A hung call blocks everything.** The ownership lock is held by the live process; a call
   killed mid-flight can wedge the runtime bridge so every later call queues forever.
   `pgctl repair` (restart) is the cure; `pgctl status` pings the bridge before you trust it.
5. **Keys need focus** — both for the window and for the save dialog. On a bare Xvfb nothing
   holds focus, so `Ctrl+S`/export shortcuts go nowhere and typed paths land in the app instead
   of the chooser. `pgctl` activates the window, then finds the dialog by "any visible window
   that is not the app" and focuses it before typing (titles are localized, so matching on
   "Save File" is not enough).
6. **Reusing a path leaves stale refs.** Overwrite a `.prg` at a path the store already knows and
   ref-based tools answer `stale_ref` (the refs point at deleted uuids). `pgctl forget <path>`
   with the app stopped; never call it while the file is open, or Ctrl+S degrades to save-as.
7. **Never `pkill -f project-graph`** on a host whose containers share the PID namespace — use
   your install's absolute path, or a bracket pattern that cannot match the shell running it.

## Lifetime (background instance)

`pgctl start` prints how long the instance lives and arms an idle watchdog (`PG_TTL_MIN`,
default 60) that stops it. Tell the user these three things when you start one: what it is, the
deadline, and how it comes back (`pgctl status` / the file it wrote). `pgctl stop` re-checks
`pgrep` and fails loudly if the app survived — a dead wrapper with a live app is a failure.

## Verify before reporting

```bash
$P doctor                                   # deps
$P tool get_all_nodes --project X.prg --input '{}'   # bridge + project readable
$P export X.prg /tmp/x.svg && head -c 100 /tmp/x.svg # a real <svg …> header
$P stop && pgrep -f "$D/app/project-graph" || echo clean
```

An export that returns no file, or an `<svg>` whose `viewBox` is 0×0, is a failed export — a
running process is not evidence of a working tool.
