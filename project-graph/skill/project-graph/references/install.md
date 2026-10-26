# Install: Project Graph, headless

**Prefer `install.sh`** (repository root): it performs every step below, verifies the
artifact checksum and ends with `pgctl doctor`. This page is the manual equivalent — read it
to understand what the installer does, or to run the steps on a host where the script does
not apply.

`$HERMES_HOME` is the Hermes data directory (the one holding `tools/`, `skills/`, `cache/`);
`$WORKSPACE` is the user workspace.

## Directory layout produced

```
$HERMES_HOME/tools/project-graph-<version>-linux-x64/
├── app/                      app/project-graph, app/project-graph-ownership-helper, app/share/
├── cli/                      project-graph.mjs, chunks/, ownership-helper, node_modules/jsdom
├── bin/pgctl
├── templates/starter.prg     1 node (ref n1), current format
└── README.md                 provenance + checksums + this procedure
```

The version in the directory name is the upstream release (`v4.3.2` at the time of writing).
Keeping it there makes a second install side-by-side obvious instead of silently overwriting.

## 1. System dependencies

| Package | Size | Why |
| --- | --- | --- |
| `libwebkit2gtk-4.1-0` | ~100 MB installed | the app *is* a WebKitGTK webview |
| `libgtk-3-0` / `libgtk-3-0t64` | usually present | toolkit |
| `xvfb` | 8 MB | an X display without a screen |
| `xdotool` | <1 MB | keys for Ctrl+S and the export shortcuts |
| node ≥ 26 | reuse existing | runs the CLI bundle; the bundle is built for `node26` |

```bash
apt-get install -y libwebkit2gtk-4.1-0 xvfb xdotool
```

A window manager is **not** required. Verified on a bare `Xvfb` with no WM: three consecutive
write calls plus SVG and PNG export. Install `openbox` only if a tool needs `wmctrl`/EWMH.

## 2. App payload

```bash
D=$HERMES_HOME/tools/project-graph-4.3.2-linux-x64
curl -L -o /tmp/pg.deb \
  https://github.com/graphif/project-graph/releases/download/v4.3.2/Project.Graph_4.3.2_amd64.deb
sha256sum /tmp/pg.deb   # 0557b341d26d65f8fcb3f83421586c454e8472622736d2071299ada641245941
mkdir -p "$D/app"
dpkg-deb -x /tmp/pg.deb "$D/app/payload"
mv "$D/app/payload/usr/bin/"* "$D/app/"
mv "$D/app/payload/usr/share" "$D/app/share"
rm -rf "$D/app/payload"
chmod +x "$D/app/project-graph" "$D/app/project-graph-ownership-helper"
```

**Never `dpkg -i`.** The `.deb` declares `Depends: libwebkit2gtk-4.1-0, libgtk-3-0`; on 24.04+ the
GTK package is `libgtk-3-0t64`, so dpkg refuses a dependency that is in fact installed. Extracting
the payload sidesteps dependency bookkeeping entirely; only the two ELF files matter.

Optional menu entry (only for a machine that has a desktop): copy `app/share/applications/*.desktop`
and `app/share/icons` to `/usr/share/`, then `desktop-file-validate` + `update-desktop-database`.
`Exec=project-graph` needs the binary on `PATH`.

## 3. CLI (built from source — there is no release)

Why you must build it:

- `@graphif/project-graph-cli` on npm → **404**, and in the repo `"private": true`;
- no release asset contains it (the `.deb` ships only the two binaries);
- `app/vite.cli.config.ts` is referenced only by tests — no CI target, no docs.

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/graphif/project-graph.git /tmp/pgsrc
cd /tmp/pgsrc && git sparse-checkout set app packages
pnpm install --ignore-scripts            # ~4.5 min, ~1.3 GB transient
cd app
PROJECT_GRAPH_CLI_VERSION=4.3.2 \
  node ./node_modules/vite/bin/vite.js build --config vite.cli.config.ts --outDir "$D/cli"
```

Notes:

- `PROJECT_GRAPH_CLI_VERSION` is **required** by the config; the build throws without it.
- Do not run `vite build` through a wrapper that watches files — it is a one-shot bundle.
- The output is an SSR bundle: `project-graph.mjs` + `chunks/`, target `node26`.

## 4. Two files the bundle expects

```bash
cp "$D/app/project-graph-ownership-helper" "$D/cli/"   # production entry resolves it as a sibling
cd "$D/cli" && npm init -y >/dev/null && npm i jsdom@29.1.1 --no-audit --no-fund
```

`jsdom` is the only runtime package: the closed-project runtime installs it as `globalThis.window`
and stubs `HTMLCanvasElement.getContext().measureText` to `text.length * 50`.

## 5. Starter template

`.prg` is msgpack, and an empty project cannot be grown by CLI — the first node needs the
`viewport` capability. The installer therefore drops `templates/starter.prg` (one text node,
ref `n1`, current format) into the install root, and `pgctl new <path>` copies it.

To regenerate it (after an upstream format change, for example) do it on a machine where the
whole flow already works:

```bash
# 1. take any existing 4.x project, or save a fresh draft from the GUI
cp some-existing.prg "$D/templates/starter.prg"
# 2. start the app on it and neutralise the label
$D/bin/pgctl start  "$D/templates/starter.prg"
$D/bin/pgctl tool edit_text_node --project "$D/templates/starter.prg" \
   --input '{"ref":"n1","data":{"text":"Root"}}'
$D/bin/pgctl save   "$D/templates/starter.prg"
$D/bin/pgctl stop
```

Any working project is a valid seed: the reference store is keyed by path, so every copy gets
fresh refs from `n1` upward.

## 6. Verify

```bash
$D/bin/pgctl doctor                     # every dependency
$D/bin/pgctl new  /tmp/t.prg
$D/bin/pgctl start /tmp/t.prg
$D/bin/pgctl tool get_all_nodes --project /tmp/t.prg --input '{}'   # → {"objects":[...]}
$D/bin/pgctl export /tmp/t.prg /tmp/t.svg && head -c 60 /tmp/t.svg  # → <svg xmlns=...
$D/bin/pgctl stop
```

Expected: 29 tools listed by `tool list`; `objects` contains `n1`; the SVG starts with `<svg` and
carries a non-zero `viewBox`.
