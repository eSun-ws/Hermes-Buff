# project-graph — headless driver for Project Graph

[Project Graph](https://github.com/graphif/project-graph) is a desktop node-graph editor
(Tauri + React + Canvas 2D) for mind maps and flow graphs. It ships **29 built-in tools**
that read and edit a project file (`.prg`), exposed through three adapters: the in-app AI
chat, an MCP *client*, and a **CLI**.

This tool gives you that CLI, headless, plus a small controller (`pgctl`) that owns the
app process, a virtual display, the export keybindings and the failure modes. It is
aimed at agents and scripts: a diagram stays a real `.prg` project the user can open and
drag around afterwards, and it can be rendered to SVG/PNG at any point.

An X display is required, but **never a monitor, a desktop session or a window manager** —
a bare `Xvfb` is enough.

## What it is good for — and what it is not

| Goal | Use |
| --- | --- |
| a one-off picture for chat or a report | generate SVG / Mermaid / Graphviz directly — no app, no build, no display |
| an editable `.prg` mind map or flow graph | this tool |
| an image out of an existing `.prg` | this tool, `pgctl export` |

Reach for this only when the artifact has to stay a node graph. For a throwaway diagram
it is a lot of machinery.

## Requirements

| Dependency | Why | Notes |
| --- | --- | --- |
| Linux x86-64 | upstream ships only `amd64` `.deb`/`.rpm` | no arm64, no AppImage |
| node >= 26 | runs the CLI bundle | reuse an existing install if you have one |
| `libwebkit2gtk-4.1-0` | the app is a WebKitGTK webview | ~100 MB installed |
| `xvfb` | supplies a display without a screen | ~8 MB |
| `xdotool` | keys for save and the export shortcuts | <1 MB |
| `jsdom@29` | the CLI's headless DOM for the "closed project" runtime | installed into `cli/` |
| git + pnpm | only to build the CLI from source | `pnpm` via `corepack enable` |

Roughly 76 MB on disk plus the apt libraries.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/eSun-ws/Hermes-Buff/main/project-graph/install.sh | bash
```

or from a checkout:

```bash
./project-graph/install.sh                 # installs into <HERMES_HOME>/tools/project-graph-<ver>
./project-graph/install.sh --help
```

The installer asserts the system libraries, downloads the upstream release, verifies its
SHA-256, extracts it (**never `dpkg -i`** — the package names `libgtk-3-0`, which was
renamed `libgtk-3-0t64` on newer Ubuntu, so dpkg rejects a dependency that is present),
builds the CLI from source, installs `jsdom`, drops `pgctl` next to them, and finishes by
running `pgctl doctor`, which exits non-zero if anything is missing.

Why the CLI has to be built: `@graphif/project-graph-cli` is `private: true` on npm and no
release asset contains it. Upstream builds it only in tests.

## Use

```bash
P=<install-dir>/bin/pgctl

$P doctor                              # dependency check, non-zero if incomplete
$P new  /abs/dir/diagram.prg           # starter project (one node, current format)
$P start /abs/dir/diagram.prg          # Xvfb + app; prints its lifetime
$P tool get_all_nodes --project /abs/dir/diagram.prg --input '{}'
$P tool describe create_text_node      # JSON schema of one tool
$P tool expand_node_tree_from_node --project /abs/dir/diagram.prg \
     --input '{"ref":"n1","text":"requirements"}'
$P save   /abs/dir/diagram.prg         # Ctrl+S: edits live in the app until saved
$P export /abs/dir/diagram.prg         # -> <workspace>/Media/project-graph/diagram.svg
$P export /abs/dir/diagram.prg out.png # raster
$P status                              # pids, open project, idle/TTL, bridge health
$P repair                              # restart the app after a wedged call
$P forget /abs/dir/reused.prg          # drop stored refs (app must be stopped)
$P stop                                # stops app + Xvfb, then verifies
```

Environment: `PG_DISPLAY` (default `:99`), `PG_TTL_MIN` (idle self-stop, default 60),
`PG_TOOL_TIMEOUT` (per call, default 120 s), `PG_WORKSPACE` (export default root),
`PG_NODE`, `PG_GEOMETRY`.

## Capability tiers

The tool set depends on whether an app instance is running.

| Environment | Tools available |
| --- | --- |
| no X at all | **19 / 29** — everything that does not need a live viewport or selection |
| bare `Xvfb` (no WM) | **29 / 29** — verified with repeated writes and both export paths |
| Xvfb + WM + VNC/Selkies | 29 / 29, plus a human who can watch and click |

Ten tools need the live canvas: `viewport` — `create_text_node`,
`generate_node_tree_by_text`, `get_nodes_in_viewport`, `search_and_add_image_node`;
`selection` — `delete_selected_nodes`, `select_objects`, `get_selected_nodes`,
`get_selected_refs`, `sort_selected_nodes_by_x/y`.

## Shapes and exports

Layout is not a coordinate API: `create_text_node`'s `x`/`y` are ignored. Pick a tool by
the shape you want.

| Want | Call |
| --- | --- |
| mind map / tree (best default) | `expand_node_tree_from_node` with 2-space-indented text, then `Alt+Shift+F` |
| fan-out around one node | `breadth_expand_node {ref, texts[]}` |
| chain / pipeline | `depth_expand_node {ref, texts[]}`, or `auto_layout_dag` to flatten to one row |
| colour by phase | `batch_change_color {refs, color:[r,g,b,a]}` |

| Format | How |
| --- | --- |
| `.prg` (msgpack, format version 2.7.0) | `pgctl save` |
| `.svg` (vector, diffable) | `pgctl export X.prg` |
| `.png` (transparent background) | `pgctl export X.prg out.png` |
| plain text / Markdown / Mermaid / tab-indented | GUI-side, on a selection — not scriptable |

Upstream's documented headless export (`project-graph <path> -o out.svg`) is a **stub in
v4.3.2**: it exits 0 and writes nothing. Use the GUI export path.

Readability rule of thumb: one root, at most three levels, 3–6 children per group, leaves
under about 20 characters. A 16-node, three-group map lands at ≈1770×1430 and stays legible
when a viewer downscales it; long lines push the width to 8000 px and everything turns to
mush.

## The agent contract

`skill/project-graph/SKILL.md` is the procedure an agent should follow, with the full
pitfall list in `skill/project-graph/references/`. Install it into a Hermes profile with:

```bash
ln -s "$PWD/project-graph/skill/project-graph" "$HERMES_HOME/skills/software-development/project-graph"
```

Keep one copy: symlink the live path at this file rather than copying, or the two drift.

## Boundaries

- **Linux x86-64 only.** Upstream publishes nothing else.
- **Project format churn is upstream's.** Legacy `.prg` files (format 2.5.x) fail to load
  headlessly even with `--allow-upgrade`; migrating them needs the GUI.
- **The CLI is not a public upstream interface.** It exists in the source tree and can
  change without notice; `pgctl` is the compatibility layer, not upstream.
- **Not a renderer for huge graphs.** The PNG path can white-screen on very large stages
  (upstream's own warning). SVG is the safe choice above a few hundred nodes.

## Licence

The scripts, `pgctl` and the skill text in this directory are MIT, like the rest of this
repository. The **application is GPL-3.0** and is never redistributed here: the installer
downloads the official release artifact and builds the CLI from the upstream source, both
straight from GitHub. If you repackage the built CLI bundle for distribution, GPL-3.0
applies to that bundle and you must ship the corresponding source too.

`templates/starter.prg` is a two-node project file produced by the application itself.
