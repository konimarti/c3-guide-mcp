#!/usr/bin/env python3
"""Memory must not grow with the number of calls: python3 test/growth_test.py"""
import json, os, subprocess, sys, resource

BIN = os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
init = {"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}

def peak_rss_kb(n):
    reqs = [init]
    for i in range(n):
        name, args = [("c3_search", {"query": "foreach with index"}), ("c3_symbol", {"name": "String.split"}),
                      ("c3_changes", {"topic": "faultdef"}), ("c3_syntax", {"topic": "attributes"})][i % 4]
        reqs.append({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": {"name": name, "arguments": args}})
    p = subprocess.Popen([BIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    out, _ = p.communicate("\n".join(map(json.dumps, reqs)).encode() + b"\n")
    assert len(out.splitlines()) == n + 1, "missing replies"
    return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss

a = peak_rss_kb(200)
b = peak_rss_kb(4000)  # maxrss of children is a running maximum: b >= a by construction
print("peak RSS after 200 calls: %d KB, after 4000 calls: %d KB (growth %d KB)" % (a, b, b - a))
ok = b - a < 10 * 1024
print("ok: no growth per call" if ok else "FAIL: memory grows with calls")
sys.exit(0 if ok else 1)
