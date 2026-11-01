#!/usr/bin/env python3
"""The JSON-RPC layer of the built binary: python3 test/stdio_test.py [binary]
What the tools answer is tested in C3 (`c3c test c3-guide-mcp`); this checks only what goes over the pipe."""
import json, os, subprocess, sys

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
MAX_TEXT = 3300  # reply cap (3200) plus the cut marker

def session(calls):
    reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
    for i, (name, args) in enumerate(calls, 2):
        reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})
    p = subprocess.run([BIN], input="\n".join(json.dumps(r) for r in reqs) + "\n", capture_output=True, text=True, timeout=60)
    assert p.returncode == 0, p.stderr
    out = {}
    for line in p.stdout.splitlines():
        m = json.loads(line)  # every line must be valid JSON
        out[m["id"]] = m
    return out

fails = 0
def check(label, cond, detail=""):
    global fails
    fails += not cond
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else "  -> " + detail[:300]))

r = session([("c3_symbol", {"name": "printfn"}), ("c3_search", {"query": "defer", "limit": 99}), ("c3_search", {}),
             ("no_such_tool", {}), ("c3_symbol", {"name": "a" * 3190 + "\U0001F980" * 4})])
check("initialize carries instructions", "instructions" in r[0]["result"], json.dumps(r[0]))
names = sorted(t["name"] for t in r[1]["result"]["tools"])
check("tools/list = 5 tools", names == ["c3_changes", "c3_check", "c3_search", "c3_symbol", "c3_syntax"], str(names))
check("tool call returns text", "fn sz? printfn" in r[2]["result"]["content"][0]["text"], json.dumps(r[2]))
check("reply is capped", len(r[3]["result"]["content"][0]["text"]) <= MAX_TEXT)
check("missing required arg -> -32602", r[4].get("error", {}).get("code") == -32602, json.dumps(r[4]))
check("unknown tool -> error", "error" in r[5] or r[5]["result"].get("isError"), json.dumps(r[5]))
check("multibyte cut stays valid JSON", "�" not in r[6]["result"]["content"][0]["text"])
sys.exit(1 if fails else 0)
