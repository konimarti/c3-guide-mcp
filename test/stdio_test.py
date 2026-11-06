#!/usr/bin/env python3
"""The JSON-RPC layer of the built binary: python3 test/stdio_test.py [binary]
What the tools answer is tested in C3 (`c3c test c3-guide-mcp`); this checks only what goes over the pipe."""
import json, os, subprocess, sys

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
MAX_TEXT = 4300  # reply cap (4000) plus the version notes

def session(calls):
    reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
    for i, (name, args) in enumerate(calls, 2):
        reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})
    p = subprocess.run([BIN], input="\n".join(json.dumps(r) for r in reqs) + "\n", capture_output=True, text=True, timeout=60,
                       env=os.environ)
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

r = session([("c3_lookup", {"query": "printfn", "examples": 0}), ("c3_search", {"query": "defer", "limit": 99}), ("c3_search", {}),
             ("no_such_tool", {}), ("c3_lookup", {"query": "a" * 3190 + "\U0001F980" * 4}), ("c3_lookup", {})])
check("initialize carries instructions", "instructions" in r[0]["result"], json.dumps(r[0]))
names = sorted(t["name"] for t in r[1]["result"]["tools"])
check("tools/list = 6 tools", names == ["c3_check", "c3_lookup", "c3_refs", "c3_run", "c3_search", "c3_test"], str(names))
check("instructions name every tool", all(n in r[0]["result"]["instructions"] for n in names))
check("tool call returns text", "fn sz? printfn" in r[2]["result"]["content"][0]["text"], json.dumps(r[2]))
check("reply is capped", len(r[3]["result"]["content"][0]["text"]) <= MAX_TEXT)
check("no argument is a plain message, not a protocol error", "query" in r[4]["result"]["content"][0]["text"], json.dumps(r[4]))
check("unknown tool -> error", "error" in r[5] or r[5]["result"].get("isError"), json.dumps(r[5]))
check("multibyte cut stays valid JSON", "�" not in r[6]["result"]["content"][0]["text"])
check("lookup without a query says what to give", "give query" in r[7]["result"]["content"][0]["text"])
sys.exit(1 if fails else 0)
