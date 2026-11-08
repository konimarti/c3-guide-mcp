#!/usr/bin/env python3
"""How c3-guide-mcp is used, and what to improve. Offline, read-only, nothing is sent anywhere.

Two sources, both on this machine:
  * the usage log of the server (tool, argument names, duration, outcome kind; never code or queries):
      $C3_GUIDE_LOG, else $XDG_STATE_HOME/c3-guide/usage.jsonl, else ~/.local/state/c3-guide/usage.jsonl
  * Claude Code transcripts (~/.claude/projects/*/*.jsonl), which hold the queries and what the agent did instead.
    Only sessions of the last --days days are read. Pass --no-transcripts to skip them.

The report ends with PROPOSALS: lookups that found nothing, hints that fire often, shell commands an agent typed
instead of a tool. They are suggestions for a person to read; nothing here edits the server.

usage: usage_report.py [--days N] [--log FILE] [--projects DIR] [--no-transcripts]
"""
import argparse
import collections
import glob
import json
import os
import re
import sys
import time

TOOLS = ("c3_lookup", "c3_check", "c3_test", "c3_run", "c3_refs", "c3_search")


def default_log():
    v = os.environ.get("C3_GUIDE_LOG", "")
    if v and v not in ("off", "0", "false"):
        return v
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "c3-guide", "usage.jsonl")


def read_log(path, since):
    rows = []
    for p in (path + ".1", path):
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    try:
                        r = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(r, dict) and r.get("t", 0) >= since:
                        rows.append(r)
        except OSError:
            pass
    return rows


def pct(n, total):
    return f"{100 * n // total}%" if total else "-"


def report_log(rows):
    print(f"== server log: {len(rows)} calls ==")
    if not rows:
        print("  (empty: the server writes it as it is used; C3_GUIDE_LOG=off turns it off)")
        return
    by = collections.defaultdict(list)
    for r in rows:
        by[r.get("tool", "?")].append(r)
    print(f"  {'tool':<10} {'calls':>5} {'ok':>5} {'median ms':>9} {'p95 ms':>7}  outcomes")
    for tool in sorted(by, key=lambda t: -len(by[t])):
        rs = by[tool]
        ms = sorted(r.get("ms", 0) for r in rs)
        outs = collections.Counter(r.get("out", "?") for r in rs)
        ok = outs.get("ok", 0)
        mix = ", ".join(f"{k} {v}" for k, v in outs.most_common() if k != "ok")
        print(f"  {tool:<10} {len(rs):>5} {pct(ok, len(rs)):>5} {ms[len(ms) // 2]:>9} {ms[min(len(ms) - 1, len(ms) * 95 // 100)]:>7}  {mix}")
    args = collections.Counter(a for r in rows for a in r.get("args", []))
    print("  arguments used:", ", ".join(f"{k} {v}" for k, v in args.most_common(12)))
    hints = sum(1 for r in rows if r.get("hint"))
    rew = sum(1 for r in rows if r.get("rewrite"))
    print(f"  replies with a hint: {hints}; with an old-syntax rewrite: {rew}; tool errors: {sum(1 for r in rows if r.get('err'))}")
    unused = [t for t in TOOLS if t not in by]
    if unused:
        print("  never called:", ", ".join(unused))


SHELL_FALLBACKS = [
    (r"\bc3c\s+(?:compile-only|compile|compile-run|test|run)\b", "typed c3c compile/test/run (c3_check, c3_test, c3_run exist)"),
    (r"\b(?:grep|rg)\b[^|;&]*\.c3\b", "grep over .c3 files (c3_refs / c3_lookup exist)"),
    (r"\bsed\s+-i\b[^|;&]*\.c3\b", "sed -i on .c3 files (c3_refs shows every use first)"),
    (r"\bc3c\s+docgen\b|lib/std/[\w/]+\.c3", "reading stdlib source by hand (c3_lookup source=true)"),
]


def transcript_rows(projects, since):
    for f in glob.glob(os.path.join(projects, "*", "*.jsonl")):
        try:
            if os.path.getmtime(f) < since:
                continue
        except OSError:
            continue
        yield f


def strip_heredocs(cmd):
    return re.sub(r"<<-?\s*'?(\w+)'?.*?\n\1\b", "", cmd, flags=re.S)


def report_transcripts(projects, since):
    sessions = 0
    with_c3 = 0
    calls = collections.Counter()
    fallbacks = collections.Counter()
    fallback_examples = collections.defaultdict(list)
    lookups = []  # (query, outcome-ish)
    pending = {}
    zero_use = []
    for f in transcript_rows(projects, since):
        mine = 0
        c3_files = 0
        sessions += 1
        try:
            fh = open(f, encoding="utf-8")
        except OSError:
            continue
        with fh:
            for line in fh:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                content = (d.get("message") or {}).get("content")
                if not isinstance(content, list):
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get("type") == "tool_use":
                        name = b.get("name", "")
                        inp = b.get("input") or {}
                        if name.startswith("mcp__c3-guide__"):
                            short = name.split("__")[-1]
                            calls[short] += 1
                            mine += 1
                            if short in ("c3_lookup", "c3_symbol"):
                                pending[b.get("id")] = inp.get("query") or inp.get("name") or ""
                        elif name == "Bash":
                            cmd = strip_heredocs(inp.get("command", ""))
                            for rx, label in SHELL_FALLBACKS:
                                if re.search(rx, cmd):
                                    fallbacks[label] += 1
                                    if len(fallback_examples[label]) < 2:
                                        fallback_examples[label].append(cmd.strip().replace("\n", " ")[:110])
                                    c3_files += 1
                    elif b.get("type") == "tool_result" and b.get("tool_use_id") in pending:
                        q = pending.pop(b["tool_use_id"])
                        t = b.get("content")
                        if isinstance(t, list):
                            t = " ".join(x.get("text", "") for x in t if isinstance(x, dict))
                        t = str(t or "")
                        if "does not exist" in t or "no symbol matches" in t or "Weak matches" in t:
                            lookups.append((q, "weak" if "Weak matches" in t else "missing"))
        if mine:
            with_c3 += 1
        elif c3_files:
            zero_use.append(os.path.basename(os.path.dirname(f)))
    print(f"\n== Claude Code transcripts: {sessions} sessions, {with_c3} used c3-guide ==")
    if calls:
        print("  c3-guide calls:", ", ".join(f"{k} {v}" for k, v in calls.most_common()))
    if fallbacks:
        print("  shell commands typed where a tool exists:")
        for label, n in fallbacks.most_common():
            print(f"    {n:>4}  {label}")
            for ex in fallback_examples[label]:
                print(f"            e.g. {ex}")
    if zero_use:
        print("  C3 work without any c3-guide call (is the server registered? is there a CLAUDE.md?):")
        for p in sorted(set(zero_use)):
            print("    ", p)
    print("\n== PROPOSALS (for a person to read) ==")
    if lookups:
        print("  lookups that found nothing; each is a missing synonym, an unlisted legacy name or a real gap:")
        for (q, kind), n in collections.Counter(lookups).most_common(15):
            print(f"    {n:>3} x {kind:<7} {q[:80]!r}")
    if not (lookups or fallbacks):
        print("  nothing to propose from these sessions")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--log", default=default_log())
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--no-transcripts", action="store_true")
    a = ap.parse_args()
    since = time.time() - a.days * 86400
    print(f"last {a.days} day(s)\n")
    report_log(read_log(a.log, since))
    if not a.no_transcripts:
        report_transcripts(a.projects, since)


if __name__ == "__main__":
    sys.exit(main())
