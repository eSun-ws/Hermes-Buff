#!/bin/bash
# Regression arms for two defects that both hid behind "it looks fine":
#
#   #23  `set -e` aborted at the `timeout` line, so the 124/137 handler that clears a hung call's
#        ownership lock was dead code. The arm asserts the handler is *reachable*, not just that the
#        exit code is non-zero (the broken version also exited non-zero -- at the wrong line).
#   #24  `save` compared whole-second mtimes, so a save landing in the same second read as
#        "unchanged" and the DIRTY_FILE marker survived a save that did reach the app. The arm
#        performs two saves inside one second and requires both to report success.
#
# No app, no X server, no node: the arm substitutes them and only exercises pgctl's own control flow.
#
#   ./tests/pgctl_selftest.sh          # run
#   bash -x ./tests/pgctl_selftest.sh  # trace this harness, not pgctl
set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PGCTL="$HERE/../scripts/pgctl"
[[ -f $PGCTL ]] || { echo "cannot find $PGCTL"; exit 2; }

PASS=0
FAIL=0
check() { # check <label> <ok:0|1> [detail]
  if [[ $2 -eq 0 ]]; then
    printf '  PASS %s\n' "$1"; PASS=$((PASS + 1))
  else
    printf '  FAIL %s%s\n' "$1" "${3:+  <<< $3}"; FAIL=$((FAIL + 1))
  fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/pgctl-selftest-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ── #23: the timeout handler must be reachable ────────────────────────────────────────────────────
state="$WORK/state23"
mkdir -p "$state"
trace="$WORK/trace23.txt"
PG_NODE=/bin/false PG_STATE="$state" bash -x "$PGCTL" tool invoke get_project \
  >"$WORK/out23.txt" 2>"$trace"
rc23=$?
line_timeout=$(grep -n 'timeout --signal=TERM' "$trace" | head -1 | cut -d: -f1)
line_after=$(awk -v t="${line_timeout:-0}" 'NR > t && /(rc=|\$\?)/ {print NR; exit}' "$trace")

check "tool invoke: a failing call still exits non-zero" "$([[ $rc23 -ne 0 ]] && echo 0 || echo 1)" "rc=$rc23"
check "tool invoke: the script reaches its own status capture after \`timeout\`" \
  "$([[ -n ${line_after:-} ]] && echo 0 || echo 1)" \
  "trace ends at line ${line_timeout:-?}; no post-timeout line"
check "tool invoke: the 124/137 handler is still in the tree" \
  "$(grep -q 'rc == 124' "$PGCTL" && echo 0 || echo 1)" "handler missing"

# ── #24: two saves inside one second both count ──────────────────────────────────────────────────
# The stand-ins: `node` is never called by `save`; `xdotool` fakes the window and, on `ctrl+s`,
# appends a byte to the project the way the app would on disk.
state="$WORK/state24"
mkdir -p "$state/bin"
proj="$WORK/demo.prg"
printf 'nodes: []\n' >"$proj"
cat >"$state/bin/xdotool" <<'FAKE'
#!/bin/bash
case "$*" in
  *"key"*"ctrl+s"*) printf '#\n' >>"${PGFILE:?}" ;;
  **search**) echo 4242 ;;
  *) : ;;
esac
exit 0
FAKE
chmod +x "$state/bin/xdotool"
cat >"$state/bin/node" <<'FAKE'
#!/bin/bash
exit 0
FAKE
chmod +x "$state/bin/node"
printf '%s\n' "$proj" >"$state/open-project"

run_save() {
  env PATH="$state/bin:$PATH" PG_NODE="$state/bin/node" PG_STATE="$state" PGFILE="$proj" \
      PG_DISPLAY=:0 "$PGCTL" save "$proj" 2>&1
}

# Two saves back to back: the second lands in the same wall-clock second as the first more often
# than not, which is exactly the case whole-second mtimes got wrong.
: >"$state/unsaved-changes"        # a mutation happened and has not been proven saved yet
out1=$(run_save); rc1=$?
: >"$state/unsaved-changes"
out2=$(run_save); rc2=$?

check "save: a save that reaches the app succeeds" \
  "$([[ $rc1 -eq 0 ]] && echo 0 || echo 1)" "rc=$rc1 out=$(echo "$out1" | tail -1)"
check "save: a second save inside the same second also succeeds" \
  "$([[ $rc2 -eq 0 ]] && echo 0 || echo 1)" "rc=$rc2 out=$(echo "$out2" | tail -1)"
check "save: the dirty marker is cleared by a save that proved itself" \
  "$([[ ! -f $state/unsaved-changes ]] && echo 0 || echo 1)" "marker still present"
check "save: the judgement is finer than a second (stamp, not %Y)" \
  "$(grep -q 'pgctl-save-stamp' "$PGCTL" && ! grep -q 'before=$(stat -c %Y' "$PGCTL" && echo 0 || echo 1)" \
  "still compares whole-second mtimes"

# The mechanism itself, independent of how long `save` takes: sample a whole-second mtime, write
# immediately, and require the stamp idiom to see the change -- while the old `%Y` comparison, on the
# same pair, does not. A same-second write is the only case where the two disagree, so retry until one
# happens rather than assuming the filesystem is slow enough.
same_second=""
for _ in $(seq 1 200); do
  probe="$WORK/same-second.txt"
  : >"$probe"; before_s=$(stat -c %Y "$probe")
  : >"$WORK/stamp"; sleep 0 2>/dev/null || true
  printf 'x' >>"$probe"; after_s=$(stat -c %Y "$probe")
  if [[ $before_s == "$after_s" ]]; then same_second=yes; break; fi
done
if [[ -n $same_second ]]; then
  # Requirement: the stamp idiom sees the write (new behaviour), and the whole-second comparison does
  # not (the old behaviour, on the very same pair of writes).
  ok=1
  if [[ $probe -nt $WORK/stamp && $after_s -le $before_s ]]; then ok=0; fi
  check "save: a same-second write is visible to the stamp idiom and invisible to %Y" "$ok" \
    "stamp_sees=$([[ $probe -nt $WORK/stamp ]] && echo yes || echo no) %Y=${before_s}->${after_s}"
else
  printf '  SKIP save: could not produce two writes inside one second\n'
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] && echo "  result: all passed" || echo "  result: failed $FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
