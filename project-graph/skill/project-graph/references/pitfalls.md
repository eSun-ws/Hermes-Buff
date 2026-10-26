# Pitfalls and failure modes

Every item below was hit in practice, in this order. Cost of ignoring them: hours.

## The binary is not a CLI

```
$ project-graph --version
thread 'main' panicked at tao-0.37.1/src/platform_impl/linux/event_loop.rs:217
Failed to initialize gtk backend! … gtk::rt::init
```

Tauri initializes GTK **before** parsing argv, so the released binary cannot do anything without
a display — not even `--help`. The usable CLI is the Node bundle built from source; it needs no
display at all.

Corollary: the GUI's own legacy CLI (`--output x.svg`) is a stub — the svg branch in `runCli` is
commented out. It exits without writing a file.

## Writes need the project to be known

First write against a project path the reference store has never seen:

```
{"code":"PROJECT_LOAD_FAILED","message":"Project file could not be loaded."}
```

Nothing is wrong with the file — a read of the *same* file works, and repeating the write after a
read succeeds. The real failure is in the reference/ownership layer and the code maps it to a
load error. Always prime: one `get_all_nodes` before the first mutation (`pgctl tool` does it).

A fresh copy of a working project reproduces this every time, so it is a per-path state, not a
corrupt file.

## Empty projects cannot be started by CLI

The two tools that create the first node (`create_text_node`, `generate_node_tree_by_text`) both
require the `viewport` capability, which the headless runtime refuses. Every other creation tool
is reference-based (`expand_node_tree_from_node`, `breadth_expand_node`, …) and needs an existing
`n1`. Ship a **starter project with one node** and copy it — do not fight this.

## A hung call wedges the bridge

The runtime bridge serves forwarded calls over `tcp://127.0.0.1:<port>` (the endpoint is recorded
in `<XDG_DATA_HOME>/liren.project-graph/project-ownership/<sha256(path)>.connectable`). The
project's ownership lock is held by the live process, so a single call that never returns makes
every later call queue behind it, for every tool, including reads.

- Give calls a generous timeout; killing one mid-flight is the classic way to trigger this.
- `pgctl status` pings the bridge (`bridge: responsive`) — check it before blaming the tool.
- Cure: `pgctl repair` (kill stragglers, restart app + Xvfb, reopen the project). Restarting is
  cheap; theorising is not.
- `pgctl tool` kills stragglers itself after a timeout (`PG_TOOL_TIMEOUT`, default 120 s).

## Keys go nowhere without focus

On a bare Xvfb no window holds focus. `xdotool key ctrl+s` then silently does nothing and `save`
looks broken. Call `xdotool windowfocus` (a WM is not needed for that). Do not rely on
`windowactivate` alone — see the trap below.

The **save dialog** is the same problem one level deeper: it is a separate top-level window that
never takes focus by itself without a WM, so a typed path goes into the app window and the export
"succeeds" with no file. Do **not** match a dialog by title — titles are localized, so a literal such
as `Save File` is only a sample; pick the newest visible window whose name is not the app's, focus
it, then type.
A dialog left open by an earlier failed attempt then steals focus from the next one — clear with
`Escape` (up to 3×) before starting a new export.

Two more traps on the same path, both found by running the export immediately after `start`:

- **`windowactivate` lies when there is no WM.** It prints a warning about
  `_NET_ACTIVE_WINDOW` but still exits 0, so a `windowactivate || windowfocus` fallback never
  runs and the focus never moves. Call `windowfocus` **unconditionally** after it.
- **The PNG export panel stays open and swallows global shortcuts.** After it has written the
  file, the panel remains on screen; while it is open the app ignores `Ctrl+S`, so the next save
  does nothing and looks like "no changes". Dismiss it with `Escape` (this is why the panel-export
  path must not be the last thing you do before saving).
- **The first key press of a cold instance is swallowed.** The window exists before the webview
  has wired its keyboard handlers, so an export fired right after `start` opens nothing and a
  retry one second later succeeds. `pgctl` sleeps briefly in `start` and retries the whole
  export gesture (key, click, wait) up to three times before giving up.

## A killed call blocks every later call

The one failure mode that reproduces on demand is not about the graph: **killing a forwarded call
mid-flight wedges the runtime bridge**, after which every tool — including plain reads — hangs until
the app is restarted. Observed sequence, twice: a call exceeded its timeout, the wrapper killed it,
and from then on `get_all_nodes` never returned either.

What does **not** cause it (both tested after the first wrong guess):

- an empty canvas — `delete_nodes` down to `{"objects":[]}` then `create_text_node` → succeeded;
- reusing a path — `rm` + `new` + `forget` + `start` on the same filename → `create_text_node`
  succeeded.

Rules: give forwarded calls a generous timeout (`PG_TOOL_TIMEOUT`, ≥120 s; `delete_all_nodes` on a
graph with many edges ran past 120 s on its own), never SIGKILL one that is still in flight, and
reach for `pgctl repair` — not for theories — when the bridge stops answering.

## `pgctl forget` before start, never after

## `create_text_node` ignores x/y — layout comes from the tools, not coordinates

`create_text_node` accepts `x`/`y` in its schema but **ignores them**: three nodes requested at
(0,0), (900,0) and (0,600) all landed on the same spot. Positioning comes from:

- `expand_node_tree_from_node` / `breadth_expand_node` / `depth_expand_node` — these place their
  children themselves;
- `auto_layout_dag` — one left-to-right row, for DAG-shaped graphs;
- `Alt+Shift+F` — tree formatting, which arranges by edge endpoints (this is what gives up/down/
  left/right trees, not `auto_layout_dag`).

Corollary: never conclude "this tool only lays out one row" from `auto_layout_dag` alone — that is
the DAG layout, and a CLI-only workflow ends up using it by default because the Tab-growth
keybinds (`W W`/`S S`/`A A`/`D D`) that shape trees are GUI gestures, and the tools create
right-facing edges only.

## `pgctl forget` before start, never after

Refs (`n1`, `e3`, …) are persisted per path in `ai-project-references.json`. If you delete a `.prg`
and write a new one at the same path, the store still maps the old uuids:

```json
{"code":"stale_ref","details":{"ref":"n2"},"message":"Project Object Reference points to a deleted object."}
```

Remove the store entry (and the path's ownership records) **with the app stopped** — deleting them
under a live window makes the app lose ownership, after which `Ctrl+S` turns into a save-as dialog
and the file silently stops updating. `pgctl forget <path>` does this, and refuses while the file
is open.

## pkill can kill your own shell — and other people's processes

`pkill -f "project-graph"` matches the shell running it when the pattern appears in its command
line, and on a host whose containers share the PID namespace it also matches processes inside
those containers. Both happened here: the shell died with SIGTERM mid-script, and a container's
app was killed by a host-side pattern.

- Match the **absolute path of your install** (`$D/app/project-graph`), never a bare name.
- Or bracket the first character (`[p]roject-graph`) **and** make sure the plain string appears
  nowhere else in the same command line — no `echo "... project-graph ..."` alongside it.
- Prefer killing by PID: `PIDS=$(pgrep -f "$PAT"); kill $PIDS`.

## Path identity is the project identity

Ownership keys are `sha256(realpath)`. Host `/tmp/x.prg` and container `/tmp/x.prg` are two
different projects with two different locks; the CLI will report `PROJECT_MUST_BE_OPEN` forever
because the GUI never opened *its* idea of that path. Mount the same directory, or run the CLI
inside the same namespace as the app.

Related: the reference store lives in `<XDG_DATA_HOME>/liren.project-graph/`. Run the CLI as the
same **user** as the app, or the two will use separate stores and locks.

## GUI-runtime-only tools

`create_text_node`, `generate_node_tree_by_text`, `get_nodes_in_viewport`,
`search_and_add_image_node` need `viewport`; `delete_selected_nodes`, `select_objects`,
`get_selected_nodes`, `get_selected_refs`, `sort_selected_nodes_by_x/y` need `selection`.
Headless they answer `PROJECT_MUST_BE_OPEN`. With the app running and the project open, the same
CLI call is forwarded to the window and works — so "needs a GUI" means "needs the app running",
not "needs a mouse".

## One tool's error is not the CLI's contract

`create_text_node` answering `PROJECT_MUST_BE_OPEN` once produced the confident, wrong conclusion
"this CLI is read-only without a GUI". The capability set is a single constant
(`closedProjectCapabilities` minus `selection`/`viewport`); read it and test one tool per group.

## Software rendering is not a crash

```
libEGL warning: DRI3 error: Could not get DRI3 device
libEGL warning: Ensure your X server supports DRI3 to get accelerated rendering
```

On Xvfb there is no DRI3; WebKit falls back to software rendering and the app works. Judge by a
screenshot or an exported file, never by these lines.
