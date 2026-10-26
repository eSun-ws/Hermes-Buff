#!/usr/bin/env python3
"""Decide whether a detection is worth waking a human conversation.

The watcher answers "did anything change?". That is not the same question as "does a person need to
look at this now?", and answering the second with the first is what made a monitoring loop wake its
conversation every few minutes with progress notes. A machine event is cheap to record and expensive
to wake: waking runs a whole agent turn in a human session, which costs context, money, and -- when
the wake is indistinguishable from a message the human typed -- pollutes long-term memory.

So the detector stays dumb (it prints what changed) and this file holds the only judgement:

  * a brand-new issue                 -> wake now (someone opened a door and is waiting)
  * anything else that counts as news -> at most one wake per --min-interval, coalesced
  * while coalescing                  -> the round is still recorded; only the wake is deferred

Nothing is dropped by deferring: `pending` counts the rounds that arrived while quiet, and the next
wake says how many rounds it speaks for.

Exit code is 0 whether the answer is wake or hold; the verdict is the first word on stdout, so a
caller can read it without parsing prose. `hold` also means "do not touch the signal file".

Usage:
    wake-policy.py --state <wake.json> --items <detector.json> [--min-interval 3600] [--now ISO8601]
    wake-policy.py --state <wake.json> --items <detector.json> --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_INTERVAL = 3600


def _now(text: str | None) -> datetime:
    if not text:
        return datetime.now(timezone.utc)
    cleaned = text.strip().replace("Z", "+00:00")
    stamp = datetime.fromisoformat(cleaned)
    return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


def _read_json(path: str, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default
    except json.JSONDecodeError as exc:
        # A half-written state file must not silently reset the cooldown: that would turn a crash into
        # a burst of wakes, which is the failure this file exists to prevent.
        raise SystemExit("wake-policy: %s is not valid JSON (%s); refusing to guess" % (path, exc))


def _items(payload) -> list[dict]:
    if isinstance(payload, list):
        return [item for item in payload if isinstance(item, dict)]
    if isinstance(payload, dict):
        for key in ("items", "issues", "news"):
            value = payload.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def _commenters(item: dict) -> list[str]:
    authors = []
    for comment in item.get("new_comments") or []:
        user = (comment or {}).get("user") or {}
        login = user.get("login")
        if login:
            authors.append(login)
    return authors


def _write_state(path: str, state: dict) -> None:
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=1)
        handle.write("\n")
    os.replace(tmp, path)


def _who(item: dict, self_login: str) -> str:
    """Name the person who spoke, not the first comment in the list.

    A round often mixes our own reply with theirs; printing ``by eSun-ws`` for such a pair reads like
    an echo of ourselves and makes the wake look pointless, which is how a wake message loses its
    reader. The other party is the reason to wake, so say that first.
    """
    logins = _commenters(item)
    others = [name for name in logins if name.lower() != (self_login or "").lower()]
    shown = []
    for name in (others or logins):
        if name not in shown:
            shown.append(name)
    own = len(logins) - len(others)
    label = ",".join(shown[:3])
    return "%s%s" % (label, " +%d own" % own if own and others else "")


def decide(items: list[dict], state: dict, now: datetime, interval: int,
           self_login: str = "") -> tuple[str, str, dict]:
    fresh = [item for item in items if item.get("first_seen")]
    replies = [item for item in items if not item.get("first_seen") and _commenters(item)]

    pending = int(state.get("pending") or 0) + len(items)
    last_wake = state.get("last_wake_at")
    quiet_for = None
    if last_wake:
        try:
            quiet_for = now - _now(str(last_wake))
        except ValueError:
            quiet_for = None      # unreadable timestamp is not a reason to stay silent

    reason_parts = []
    if fresh:
        reason_parts.append("%d new issue%s (%s)" % (
            len(fresh), "" if len(fresh) == 1 else "s",
            ",".join("#%s" % item.get("number") for item in fresh[:4])))
    if replies:
        reason_parts.append("%d repl%s (%s)" % (
            len(replies), "y" if len(replies) == 1 else "ies",
            ",".join("#%s by %s" % (item.get("number"), _who(item, self_login)) for item in replies[:4])))
    detail = "; ".join(reason_parts) or "activity"

    if fresh:
        verdict = "wake"
        why = "%s -- a new issue is a decision, not a progress note" % detail
    elif quiet_for is None:
        verdict = "wake"
        why = "%s -- no previous wake on record, so there is no cooldown to respect" % detail
    elif quiet_for >= timedelta(seconds=interval):
        verdict = "wake"
        why = "%s -- %ds of quiet, cooldown is %ds" % (detail, quiet_for.total_seconds(), interval)
    else:
        verdict = "hold"
        wait = int((timedelta(seconds=interval) - quiet_for).total_seconds())
        why = "%s -- %ds since the last wake, %ds to go (pending=%d)" % (
            detail, quiet_for.total_seconds(), wait, pending)

    if verdict == "wake":
        state["last_wake_at"] = now.isoformat()
        state["last_wake_reason"] = detail
        state["pending"] = 0
        state["wakes"] = int(state.get("wakes") or 0) + 1
    else:
        state["pending"] = pending
        state["held"] = int(state.get("held") or 0) + len(items)
    return verdict, why, state


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Decide whether a detection should wake a conversation.")
    parser.add_argument("--state", required=True, help="policy state file (created on first wake)")
    parser.add_argument("--items", required=True, help="detector JSON: a list or an object holding one")
    parser.add_argument("--min-interval", type=int,
                        default=int(os.environ.get("IW_WAKE_MIN_INTERVAL") or DEFAULT_INTERVAL),
                        help="seconds between coalesced wakes (default %d, env IW_WAKE_MIN_INTERVAL)"
                             % DEFAULT_INTERVAL)
    parser.add_argument("--now", default=None, help="ISO8601 clock override, for tests")
    parser.add_argument("--self", dest="self_login", default=os.environ.get("IW_SELF", ""),
                        help="our own login, so the reason names the other party (env IW_SELF)")
    parser.add_argument("--dry-run", action="store_true", help="print the verdict, write nothing")
    args = parser.parse_args(argv)

    payload = _read_json(args.items, None)
    if payload is None:
        print("wake-policy: %s is missing; the detector produced nothing to judge" % args.items,
              file=sys.stderr)
        return 2
    state = _read_json(args.state, {})
    now = _now(args.now)
    verdict, why, state = decide(_items(payload), state, now, max(0, args.min_interval),
                                 args.self_login)
    if not args.dry_run:
        state["checked_at"] = now.isoformat()
        _write_state(args.state, state)
    print("%s %s" % (verdict, why))
    print("wake-policy: %s" % why, file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
