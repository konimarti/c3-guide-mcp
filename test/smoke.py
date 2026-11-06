#!/usr/bin/env python3
"""Cross-platform smoke test of a built binary: python3 test/smoke.py build/c3-guide-mcp[.exe]
Needs c3c on PATH or C3C set (only c3_check uses it). Exit 1 on the first failed check."""
import json, os, subprocess, sys

binary = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
INIT = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}}}
CALLS = [("c3_search", {"query": "defer"}), ("c3_lookup", {"query": "String.split"}), ("c3_search", {"query": "foreach", "scope": "changes"}),
         ("c3_search", {"query": "attributes", "scope": "syntax"}), ("c3_check", {"code": "fn void f() {}"}),
         ("c3_check", {"code": "fn void f() { int x = ; }"}), ("c3_check", {"code": 'const char[*] X = $embed("x");'}),
         ("c3_check", {"code": "fn void f() { usz n = int.sizeof; }"}), ("c3_lookup", {"query": "HashMap"}),
         ("c3_check", {"path": os.path.dirname(os.path.abspath(__file__)), "target": "--trust=full"}),
         ("c3_search", {"query": "word " * 5000}),
         ("c3_run", {"code": "import std::io;\nfn void main(String[] a) { io::printfn(\"%d\", a.len); }", "args": "x\ny"}),
         ("c3_refs", {"query": "main", "path": os.path.dirname(os.path.dirname(os.path.abspath(__file__)))})]
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
check("6 tools", names == ["c3_check", "c3_lookup", "c3_refs", "c3_run", "c3_search", "c3_test"], names)
check("c3_search defer", "defer" in text(2).lower(), text(2))
check("c3_lookup String.split", "split" in text(3), text(3))
check("c3_search changes foreach", "foreach" in text(4).lower(), text(4))
check("c3_search syntax attributes", "@" in text(5), text(5))
check("c3_check valid code is OK", text(6).startswith("OK"), text(6))
check("c3_check invalid code reports an error", "error" in text(7).lower(), text(7))
check("c3_check rejects $embed", "rejected" in text(8), text(8))
check("c3_check rewrites .sizeof and verifies", "int::size" in text(9) and "no errors" in text(9).lower(), text(9))
check("c3_lookup HashMap", "HashMap" in text(10), text(10))
check("c3_check refuses a target that is an option", "build target name" in text(11), text(11))
check("c3_search survives a 5000-word query", len(text(12)) > 0, text(12))
check("c3_run passes arguments", "3" in text(13), text(13))
check("c3_refs finds main", "use(s) of 'main'" in text(14), text(14))
