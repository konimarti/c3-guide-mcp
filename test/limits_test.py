#!/usr/bin/env python3
"""c3_check limits, tested with fake compilers (C3C points at a script): python3 test/limits_test.py
  (the fakes `exec` their work: a grandchild would keep the pipe open and only the SDK's 30 s @Timeout would end the call)
  - a compiler that never ends is killed after 10 s and the server keeps serving
  - a compiler that floods stdout is cut at the output cap and killed"""
import json, os, stat, subprocess, sys, tempfile, time, shutil

BIN = os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
work = tempfile.mkdtemp(prefix="c3guide-fake-")

def fake(name, body):
    p = os.path.join(work, name)
    open(p, "w").write("#!/bin/sh\n" + body + "\n")
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    return p

def run(c3c):
    reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "c3_check", "arguments": {"code": "fn void f() {}"}}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "c3_search", "arguments": {"query": "defer"}}}]
    t = time.time()
    p = subprocess.run([BIN], input="\n".join(map(json.dumps, reqs)) + "\n", capture_output=True, text=True, timeout=60, env=dict(os.environ, C3C=c3c))
    out = {json.loads(l)["id"]: json.loads(l) for l in p.stdout.splitlines()}
    return time.time() - t, out[1]["result"]["content"][0]["text"], "result" in out[2]

fails = 0
def check(label, cond, detail=""):
    global fails
    fails += not cond
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else "  -> " + detail[:200]))

dt, txt, alive = run(fake("hang", "exec sleep 60"))
check("never-ending compiler: returns after the 10 s limit", 9 < dt < 20 and "[timeout" in txt, "%.1fs %s" % (dt, txt))
check("never-ending compiler: server keeps serving", alive)
dt, txt, alive = run(fake("flood", "exec yes 'error: x'"))
check("flooding compiler: output capped and killed", len(txt) < 4200 and "[output cut]" in txt and dt < 5, "%.1fs len=%d" % (dt, len(txt)))
check("flooding compiler: server keeps serving", alive)
# the deadline must not depend on a `timeout` program: run with a PATH that has no `timeout` at all
bindir = os.path.join(work, "bin"); os.makedirs(bindir)
for tool in ("sleep", "yes"):
    os.symlink(shutil.which(tool), os.path.join(bindir, tool))
saved = os.environ["PATH"]; os.environ["PATH"] = bindir
dt, txt, alive = run(fake("hang2", "exec sleep 60"))
os.environ["PATH"] = saved
check("no `timeout` on PATH: deadline still enforced", 9 < dt < 20 and "[timeout" in txt, "%.1fs %s" % (dt, txt))
shutil.rmtree(work)
sys.exit(1 if fails else 0)
