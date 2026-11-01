#!/usr/bin/env python3
"""Search quality: each question must have the expected text in the top-3 results.
python3 test/quality_test.py  (prints the score; fails below the threshold)"""
import json, os, subprocess, sys

BIN = os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
THRESHOLD = 1.0   # a regression set: every question must keep working

# (tool, argument, substring expected in one of the top-3 results)
CASES = [
    ("c3_search", "foreach with index", "Foreach"),
    ("c3_search", "defer catch", "defer catch"),
    ("c3_search", "optional fault catch", "ptional"),
    ("c3_search", "macro vararg", "Macro vaargs"),
    ("c3_search", "how to define a fault", "excuse"),
    ("c3_search", "contracts require ensure", "ontract"),
    ("c3_search", "temp allocator pool", "pool"),
    ("c3_search", "enum associated values", "ssociated"),
    ("c3_search", "bitstruct", "itstruct"),
    ("c3_search", "generic module type parameters", "eneric"),
    ("c3_symbol", "String.split", "String.split"),
    ("c3_symbol", "printfn", "std::io::printfn"),
    ("c3_symbol", "talloc_array", "talloc_array"),
    ("c3_symbol", "HashMap", "HashMap"),
    ("c3_symbol", "tnew_array", "does not exist"),
    ("c3_changes", "faultdef", "faultdef"),
    ("c3_changes", "foreach", "foreach"),
    ("c3_changes", "type properties", "propert"),
    ("c3_changes", "void! main", "main"),
    ("c3_syntax", "attributes", "@noreturn"),
    ("c3_search", "@require", "@require"),
    ("c3_search", "$for", "$for"),
]

def ask(calls):
    reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}]
    for i, (tool, arg, _) in enumerate(calls, 1):
        key = {"c3_search": "query", "c3_symbol": "name", "c3_changes": "topic", "c3_syntax": "topic"}[tool]
        reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": tool, "arguments": {key: arg, **({"limit": 3} if tool in ("c3_search", "c3_changes") else {})}}})
    p = subprocess.run([BIN], input="\n".join(map(json.dumps, reqs)) + "\n", capture_output=True, text=True, timeout=120)
    out = {json.loads(l)["id"]: json.loads(l) for l in p.stdout.splitlines()}
    return [out[i]["result"]["content"][0]["text"] for i in range(1, len(calls) + 1)]

texts = ask(CASES)
hits = 0
for (tool, arg, want), text in zip(CASES, texts):
    ok = want.lower() in text.lower()
    hits += ok
    print(("ok   " if ok else "MISS ") + "%-10s %-34s want %r" % (tool, arg, want))
score = hits / len(CASES)
print("score %d/%d = %.2f" % (hits, len(CASES), score))
sys.exit(0 if score >= THRESHOLD else 1)
