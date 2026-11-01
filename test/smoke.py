#!/usr/bin/env python3
"""Cross-platform smoke test of a built binary: python3 test/smoke.py build/c3-guide-mcp[.exe]
Needs c3c on PATH or C3C set (only c3_check uses it). Exit 1 on the first failed check."""
import json, os, subprocess, sys

binary = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
INIT = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}}}
CALLS = [("c3_search", {"query": "defer"}), ("c3_symbol", {"name": "String.split"}), ("c3_changes", {"topic": "foreach"}),
         ("c3_syntax", {"topic": "attributes"}), ("c3_check", {"code": "fn void f() {}"}),
         ("c3_check", {"code": "fn void f() { int x = ; }"}), ("c3_check", {"code": 'const char[*] X = $embed("x");'})]
reqs = [INIT, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
for i, (name, args) in enumerate(CALLS, 2):
    reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})
p = subprocess.run([binary], input="\n".join(map(json.dumps, reqs)) + "\n", capture_output=True, text=True, encoding="utf-8", timeout=120)
out = {}
for line in p.stdout.splitlines():
    if line.strip():
        m = json.loads(line)  # every line must be valid JSON
        out[m["id"]] = m
fails = 0
def check(label, ok, detail=""):
    global fails
    fails += not ok
    print(("ok   " if ok else "FAIL ") + label + ("" if ok else "  -> " + str(detail)[:300]))
text = lambda i: out[i]["result"]["content"][0]["text"]
check("initialize carries instructions", "instructions" in out[0]["result"], out.get(0))
names = sorted(t["name"] for t in out[1]["result"]["tools"])
check("7 tools (c3_test, c3_run only with C3_GUIDE_ALLOW_RUN=1)", names == ["c3_changes", "c3_check", "c3_examples", "c3_fix", "c3_search", "c3_symbol", "c3_syntax"], names)
check("c3_search defer", "defer" in text(2).lower(), text(2))
check("c3_symbol String.split", "split" in text(3), text(3))
check("c3_changes foreach", "foreach" in text(4).lower(), text(4))
check("c3_syntax attributes", "@" in text(5), text(5))
check("c3_check valid code is OK", text(6).startswith("OK"), text(6))
check("c3_check invalid code reports an error", "error" in text(7).lower(), text(7))
check("c3_check rejects $embed", "rejected" in text(8), text(8))
sys.exit(1 if fails else 0)
