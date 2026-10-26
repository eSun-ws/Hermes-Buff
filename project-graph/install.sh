#!/usr/bin/env bash
# install.sh — one-shot installer for the headless Project Graph driver.
#
# What it does, in order:
#   1. assert the system libraries (webkit2gtk-4.1, xvfb, xdotool)
#   2. download the official upstream release and verify its SHA-256
#   3. extract the payload (never `dpkg -i`: the package names libgtk-3-0, renamed
#      libgtk-3-0t64 on newer Ubuntu, so dpkg rejects a dependency that IS installed)
#   4. build the tool CLI from upstream source (there is no published binary)
#   5. install jsdom into the CLI directory
#   6. drop pgctl + the starter template into place
#   7. run `pgctl doctor` and print the next steps
#
# Re-running it is safe: finished steps are skipped.
set -euo pipefail

VERSION=${PG_VERSION:-4.3.2}
REPO_URL=${PG_REPO_URL:-https://github.com/graphif/project-graph}
DEB_URL="$REPO_URL/releases/download/v$VERSION/Project.Graph_${VERSION}_amd64.deb"
DEB_SHA256=${PG_DEB_SHA256:-0557b341d26d65f8fcb3f83421586c454e8472622736d2071299ada641245941}
CLI_VERSION=${PG_CLI_VERSION:-11.3.0}

HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
PREFIX=${PG_PREFIX:-$HERMES_HOME/tools/project-graph-$VERSION-linux-x64}
SKIP_DEPS=0
SKIP_BUILD=0
WITH_SKILL=0
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install.sh [options]

  --prefix <dir>   install root (default: \$HERMES_HOME/tools/project-graph-$VERSION-linux-x64)
  --version <v>    upstream release to install (default: $VERSION)
  --skip-deps      do not apt-install the system libraries, only check them
  --skip-build     reuse an existing CLI build in <prefix>/cli (development)
  --with-skill     symlink the agent skill into \$HERMES_HOME/skills/software-development/
  -h, --help       this text

Environment: HERMES_HOME, PG_PREFIX, PG_NODE (node binary to use),
             PG_VERSION, PG_REPO_URL, PG_DEB_SHA256
EOF
}

while (($#)); do
  case $1 in
    --prefix) PREFIX=${2:?--prefix needs a directory}; shift 2 ;;
    --version) VERSION=${2:?--version needs a value}; shift 2
               DEB_URL="$REPO_URL/releases/download/v$VERSION/Project.Graph_${VERSION}_amd64.deb" ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --with-skill) WITH_SKILL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

START=$(date +%s)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pg-install.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

say "installing Project Graph $VERSION (headless driver)"
note "install root : $PREFIX"
note "work dir     : $WORK"
note "log          : stdout"

# ---------------------------------------------------------------- 1. dependencies
say "1/7 system libraries"
need_pkgs=()
dpkg -s libwebkit2gtk-4.1-0 >/dev/null 2>&1 || need_pkgs+=(libwebkit2gtk-4.1-0)
dpkg -s xvfb               >/dev/null 2>&1 || need_pkgs+=(xvfb)
dpkg -s xdotool            >/dev/null 2>&1 || need_pkgs+=(xdotool)

if ((${#need_pkgs[@]})); then
  if ((SKIP_DEPS)); then
    die "missing packages: ${need_pkgs[*]} (re-run without --skip-deps)"
  fi
  note "installing: ${need_pkgs[*]}"
  if [[ $EUID -eq 0 ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_pkgs[@]}"
  else
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_pkgs[@]}"
  fi
else
  note "already present"
fi

# node >= 26
NODE=${PG_NODE:-}
if [[ -z $NODE ]]; then
  for cand in "$HERMES_HOME"/tools/node-*-linux-x64/bin/node "$(command -v node || true)"; do
    [[ -x $cand ]] && NODE=$cand && break
  done
fi
[[ -n ${NODE:-} && -x $NODE ]] || die "node not found — install node >= 26 or set PG_NODE"
node_major=$("$NODE" -p 'process.versions.node.split(".")[0]')
(( node_major >= 26 )) || die "node $("$NODE" -v) is too old, need >= 26 (the CLI bundle targets node26)"
note "node: $NODE ($("$NODE" -v))"

command -v git  >/dev/null || die "git is required to build the CLI"
command -v curl >/dev/null || die "curl is required to download the release"

# ---------------------------------------------------------------- 2. app payload
say "2/7 download + verify the release artifact"
mkdir -p "$PREFIX/app"
if [[ -x "$PREFIX/app/project-graph" ]]; then
  note "app already installed, skipping download"
else
  curl -fL --retry 3 -o "$WORK/app.deb" "$DEB_URL" || die "download failed: $DEB_URL"
  got=$(sha256sum "$WORK/app.deb" | cut -d' ' -f1)
  if [[ $got != "$DEB_SHA256" ]]; then
    warn "sha256 mismatch"
    note "expected: $DEB_SHA256"
    note "got     : $got"
    die "refusing to install an unverified artifact (set PG_DEB_SHA256 if upstream changed it)"
  fi
  note "sha256 ok"

  dpkg-deb -x "$WORK/app.deb" "$WORK/payload"
  mv "$WORK/payload/usr/bin/"* "$PREFIX/app/"
  [[ -d $WORK/payload/usr/share ]] && mv "$WORK/payload/usr/share" "$PREFIX/app/share"
  chmod +x "$PREFIX/app/project-graph" "$PREFIX/app/project-graph-ownership-helper"
  note "payload extracted to $PREFIX/app"
fi

# ---------------------------------------------------------------- 3. CLI build
say "3/7 CLI (built from source — upstream publishes no binary)"
if ((SKIP_BUILD)) && [[ -f $PREFIX/cli/project-graph.mjs ]]; then
  note "reusing existing build in $PREFIX/cli"
else
  if ! command -v pnpm >/dev/null; then
    note "pnpm not found, enabling through corepack"
    if command -v corepack >/dev/null; then
      corepack enable || warn "corepack enable failed"
      corepack prepare "pnpm@$CLI_VERSION" --activate || warn "corepack prepare failed"
    fi
  fi
  if ! command -v pnpm >/dev/null; then
    note "falling back to npm i -g pnpm@$CLI_VERSION"
    npm i -g "pnpm@$CLI_VERSION" || die "cannot install pnpm"
  fi

  note "cloning upstream (sparse)…"
  git clone --depth 1 --filter=blob:none --sparse "$REPO_URL.git" "$WORK/src"
  git -C "$WORK/src" sparse-checkout set app packages
  git -C "$WORK/src" checkout "v$VERSION" 2>/dev/null \
    || note "tag v$VERSION not found, building the default branch"

  note "pnpm install (this is the slow step: ~4-5 min, ~1.3 GB transient)…"
  ( cd "$WORK/src" && pnpm install --ignore-scripts )

  note "building the SSR bundle…"
  mkdir -p "$PREFIX/cli"
  (
    cd "$WORK/src/app"
    PROJECT_GRAPH_CLI_VERSION="$VERSION" "$NODE" ./node_modules/vite/bin/vite.js build \
      --config vite.cli.config.ts --outDir "$PREFIX/cli"
  )
  cp "$PREFIX/app/project-graph-ownership-helper" "$PREFIX/cli/"
  chmod +x "$PREFIX/cli/project-graph-ownership-helper"
  note "CLI built into $PREFIX/cli"
fi

# ---------------------------------------------------------------- 4. jsdom
say "4/7 jsdom (the CLI's headless DOM)"
if [[ -d $PREFIX/cli/node_modules/jsdom ]]; then
  note "already installed"
else
  ( cd "$PREFIX/cli" && npm init -y >/dev/null 2>&1 && npm i jsdom@29.1.1 --no-audit --no-fund )
  note "jsdom installed"
fi

# ---------------------------------------------------------------- 5. controller
say "5/7 pgctl controller"
mkdir -p "$PREFIX/bin" "$PREFIX/templates"
install -m 0755 "$HERE/scripts/pgctl" "$PREFIX/bin/pgctl"
install -m 0644 "$HERE/templates/starter.prg" "$PREFIX/templates/starter.prg"
note "$PREFIX/bin/pgctl"

# ---------------------------------------------------------------- 6. agent skill
say "6/7 agent skill (optional)"
if ((WITH_SKILL)); then
  target="$HERMES_HOME/skills/software-development/project-graph"
  mkdir -p "$(dirname "$target")"
  if [[ -e $target && ! -L $target ]]; then
    warn "$target exists and is not a symlink — leaving it alone"
  else
    ln -sfn "$HERE/skill/project-graph" "$target"
    note "linked $target -> $HERE/skill/project-graph"
  fi
else
  note "skipped (pass --with-skill to link it into \$HERMES_HOME/skills)"
fi

# ---------------------------------------------------------------- 7. doctor
say "7/7 self-check"
PG_NODE="$NODE" "$PREFIX/bin/pgctl" doctor || die "pgctl doctor failed — see the MISS lines above"

ELAPSED=$(( $(date +%s) - START ))
cat <<EOF

Installed in ${ELAPSED}s.

  controller : $PREFIX/bin/pgctl
  agent skill: $HERE/skill/project-graph/SKILL.md
  docs       : $HERE/README.md

Next:
  $PREFIX/bin/pgctl new  /tmp/demo.prg
  $PREFIX/bin/pgctl start /tmp/demo.prg
  $PREFIX/bin/pgctl tool get_all_nodes --project /tmp/demo.prg --input '{}'
  $PREFIX/bin/pgctl export /tmp/demo.prg /tmp/demo.svg
  $PREFIX/bin/pgctl stop

The app needs an X display and nothing else: pgctl starts a bare Xvfb on \${PG_DISPLAY:-:99}.
It stops itself after \${PG_TTL_MIN:-60} idle minutes, and \`pgctl stop\` verifies nothing is left behind.
EOF
