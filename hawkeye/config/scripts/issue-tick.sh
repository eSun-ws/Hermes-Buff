#!/bin/bash
# One scheduled tick for an issue ledger: detect, record, decide, and only then signal.
#
# The split matters. A no_agent cron job is the cheapest thing on the box (a script, no model, no
# session), but cron cannot address an existing conversation -- delivery targets are platforms, and
# `webui` is not one. The only way to continue a conversation on a schedule is to end a supervised
# background process inside it, so the tick touches a signal file and the armed `hk watch-file` exits.
#
# A wake costs a whole agent turn in a human session: context, money, and -- because a wake arrives as
# an ordinary message -- whatever memory the session's plugin extracts from it. So detection and
# judgement are separated: this script records every round, and `wake-policy.py` decides whether the
# round is allowed to wake anyone. Progress notes stay silent; a new issue or a human reply does not.
#
# Nothing on stdout: the scheduler delivers it verbatim. Detail goes to stderr (kept in run history).
set -u

REPO="${IW_REPO:-eSun-ws/Hermes-Buff}"
HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SHIP_DIR="$(dirname "$SELF")"
REPO_DIR="${IW_REPO_DIR:-$(cd "$SHIP_DIR/../.." 2>/dev/null && pwd)}"
# An installed host has the scripts next to this one and no checkout; a developer host has the
# checkout. Prefer the checkout when it exists so a stale $HERMES_HOME copy cannot shadow a fix.
_pick() {
  if [ -n "${2:-}" ] && [ -f "$2" ]; then printf '%s' "$2"; return; fi
  if [ -n "${REPO_DIR:-}" ] && [ -f "$REPO_DIR/config/scripts/$1" ]; then
    printf '%s' "$REPO_DIR/config/scripts/$1"; return
  fi
  printf '%s' "$SHIP_DIR/$1"
}
WATCH="$(_pick issue-watch.py "${IW_WATCH:-}")"
POLICY="$(_pick wake-policy.py "${IW_POLICY:-}")"
# Same resolution as WATCH/POLICY: a stale $HERMES_HOME copy must not shadow a fix in the checkout.
LEDGER_ROUND="$(_pick ledger-round.sh "${IW_LEDGER_ROUND:-}")"
LEDGER="${IW_LEDGER:-}"
IGNORE_AUTHORS="${IW_IGNORE_AUTHORS:-eSun-ws}"
WORK="${IW_WORK:-$HOME_DIR/cache/hawkeye/issue-ledger}"
STATE="$WORK/state.json"
POLICY_STATE="$WORK/wake.json"
ENTRY="$WORK/entry.raw"
SIGNAL="${IW_SIGNAL:-$WORK/signal.md}"
mkdir -p "$WORK" || { echo "issue-tick: cannot create $WORK" >&2; exit 1; }

for f in "$WATCH" "$POLICY"; do
  [ -f "$f" ] || { echo "issue-tick: missing $f" >&2; exit 1; }
done

if [ -z "${GITHUB_TOKEN:-}${GH_TOKEN:-}" ] && [ -f "$HOME_DIR/.env" ]; then
  GITHUB_TOKEN="$(grep -m1 -E '^[[:space:]]*(export[[:space:]]+)?GITHUB_TOKEN=' "$HOME_DIR/.env" \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?GITHUB_TOKEN=[[:space:]]*//; s/^[\"'\'']//; s/[\"'\'']$//' \
    | tr -d '\r')"
  export GITHUB_TOKEN
fi

rc=0
python3 "$WATCH" --repo "$REPO" --state "$STATE" --mark-seen \
  --ignore-authors "$IGNORE_AUTHORS" --max-body 1500 --json > "$ENTRY" 2>"$ENTRY.err" || rc=$?

# A transient GitHub or network failure must not look like "nothing new", and must not touch the
# state file: the same marker is retried on the next tick.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 10 ]; then
  echo "issue-tick: detector exited $rc: $(tail -1 "$ENTRY.err" 2>/dev/null)" >&2
  exit "$rc"
fi
[ "$rc" -eq 10 ] || exit 0

# Record first, decide second: a held wake must still leave the round in the ledger, or coalescing
# would become loss.
if [ -n "$LEDGER" ] && [ -x "$LEDGER_ROUND" ]; then
  if ! IW_STATE_DIR="$WORK" IW_LEDGER="$LEDGER" "$LEDGER_ROUND" detect "$ENTRY" >>"$WORK/tick.log" 2>>"$ENTRY.err"; then
    echo "issue-tick: could not record the detection (see $ENTRY.err)" >&2
  fi
else
  echo "issue-tick: IW_LEDGER not set or $LEDGER_ROUND not executable; detection recorded only on disk" >&2
fi

# No pipe: `| head -1` made the pipeline's status that of `head`, so the policy's own refusal
# (exit 1 on a corrupt state file, exactly so the cooldown is not reset) looked like an empty
# verdict -- and the fallback branch below then signalled a wake on every tick, reinstating the
# unconditional `>> signal.md` this script was written to remove.
policy_out="$(python3 "$POLICY" --state "$POLICY_STATE" --items "$ENTRY" \
  --self "${IW_SELF:-${IGNORE_AUTHORS%%,*}}" 2>>"$WORK/tick.log")"
policy_rc=$?
verdict="$(printf '%s\n' "$policy_out" | head -1)"
case "$verdict" in
  wake*)
    # Append, never rewrite: the watcher polls the file size.
    printf '%s %s\n' "$(date -u +%FT%TZ)" "${verdict#wake }" >> "$SIGNAL"
    echo "issue-tick: woke the armed conversation -- ${verdict#wake }" >&2
    ;;
  hold*)
    echo "issue-tick: held the wake -- ${verdict#hold }" >&2
    ;;
  *)
    if [ "$policy_rc" -ne 0 ]; then
      # The policy could not answer (corrupt state, missing file). The round is already in the ledger,
      # so holding loses nothing; waking on every tick would lose the cooldown instead. Report the
      # broken state once per window so it stays visible instead of silent.
      marker="$WORK/policy-broken"
      age=$(( $(date +%s) - $(stat -c %Y "$marker" 2>/dev/null || echo 0) ))
      if [ ! -f "$marker" ] || [ "$age" -ge "${IW_WAKE_MIN_INTERVAL:-3600}" ]; then
        printf '%s wake-policy unavailable (rc=%s) -- fix %s\n' \
          "$(date -u +%FT%TZ)" "$policy_rc" "$POLICY_STATE" >> "$SIGNAL"
        touch "$marker"
        echo "issue-tick: policy exited $policy_rc; waking ONCE to report the broken state" >&2
      else
        echo "issue-tick: policy exited $policy_rc; still inside the report window (${age}s) -- holding" >&2
      fi
    else
      # The policy ran and answered with something unrecognisable: that is its bug, not a state we can
      # judge, so surface it rather than swallow the round.
      printf '%s policy verdict unreadable, waking\n' "$(date -u +%FT%TZ)" >> "$SIGNAL"
      echo "issue-tick: wake-policy gave no verdict (${verdict:-empty}); signalled anyway" >&2
    fi
    ;;
esac
exit 0
