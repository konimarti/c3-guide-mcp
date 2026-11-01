#!/usr/bin/env python3
"""stdio smoke + regression test: python3 test/stdio_test.py [binary]"""
import time, json, subprocess, sys, os, shutil

BIN = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "build", "c3-guide-mcp")
MAX_TEXT = 3300  # reply cap (3200) plus the cut marker

C3C = os.environ.get("C3C") or shutil.which("c3c")

def session(calls, env=None):
    reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]
    for i, (name, args) in enumerate(calls, 2):
        reqs.append({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})
    p = subprocess.run([BIN], input="\n".join(json.dumps(r) for r in reqs) + "\n",
                       capture_output=True, text=True, timeout=60, env=env)
    assert p.returncode == 0, p.stderr
    out = {}
    for line in p.stdout.splitlines():
        m = json.loads(line)  # every line must be valid JSON
        out[m["id"]] = m
    return out

fails = 0
def check(label, cond, detail=""):
    global fails
    if not cond:
        fails += 1
    print(("ok   " if cond else "FAIL ") + label + ("" if cond else "  -> " + detail[:300]))

calls = [
    ("c3_symbol", {"name": "printfn"}),
    ("c3_symbol", {"name": "io::printfn"}),
    ("c3_symbol", {"name": "String.split"}),
    ("c3_symbol", {"name": "tnew_array"}),
    ("c3_search", {"query": "foreach with index"}),
    ("c3_search", {"query": "defer", "limit": 99}),
    ("c3_search", {"query": "zzzqqqxx"}),
    ("c3_changes", {"topic": "faultdef"}),
    ("c3_syntax", {"topic": "type-properties"}),
    ("c3_syntax", {"topic": "@noreturn"}),
    ("c3_search", {}),
    ("no_such_tool", {}),
    ("c3_check", {"code": "fn int add(int a, int b) { return a + b; }"}),
    ("c3_check", {"code": "fn void f() { int x = 1; if (x == 1) return; else return; }"}),
    ("c3_check", {"code": "import std::io;\nfn void main() { io::printn(\"a\") }"}),
    ("c3_check", {"code": ""}),
    ("c3_check", {"code": "fn void f() { $for (int i = 0; i < 10; i++): $endfor }" + " " * 40000}),
]
import glob, tempfile as _t
before = set(glob.glob(os.path.join(_t.gettempdir(), "c3guide-*")))
r = session(calls, dict(os.environ, **({"C3C": C3C} if C3C else {})))
text = lambda i: r[i]["result"]["content"][0]["text"] if "result" in r[i] else json.dumps(r[i])

names = sorted(t["name"] for t in r[1]["result"]["tools"])
check("tools/list = 5 tools", names == ["c3_changes", "c3_check", "c3_search", "c3_symbol", "c3_syntax"], str(names))
check("symbol printfn", "fn sz? printfn" in text(2), text(2))
check("symbol io::printfn qualified", "fn sz? printfn" in text(3), text(3))
check("symbol String.split", "std::core::string::String.split" in text(4), text(4))
check("symbol tnew_array: says it does not exist", "does not exist" in text(5), text(5))
check("symbol tnew_array: no fake signature", "fn " not in text(5).split("\n")[0], text(5))
check("search foreach", "oreach" in text(6), text(6))
check("search limit clamped, reply capped", len(text(7)) <= MAX_TEXT, str(len(text(7))))
check("search no match is a plain message", "no match" in text(8), text(8))
check("changes faultdef", "0.8" in text(9) or "fault" in text(9).lower(), text(9))
check("syntax list", "::" in text(10) or "len" in text(10), text(10))
check("syntax word search", "@noreturn" in text(11), text(11))
check("missing required arg -> -32602", r[12].get("error", {}).get("code") == -32602, json.dumps(r[12]))
check("unknown tool -> error", "error" in r[13] or r[13]["result"].get("isError"), json.dumps(r[13]))
print("c3c:", C3C or "NOT FOUND, compiler tests will fail")
check("check: valid code", text(14).startswith("OK"), text(14))
check("check: if/else braces error reported", "must use" in text(15) and "<code>/snippet.c3" in text(15), text(15))
check("check: syntax error has line:col", "snippet.c3:2:" in text(16), text(16))
check("check: temp path not leaked", "c3guide-" not in text(16), text(16))
check("check: empty code rejected", "give 1 to" in text(17), text(17))
check("check: oversized code rejected", "give 1 to" in text(18), text(18))
m = session([("c3_check", {"code": "fn void f() {}"})], dict(os.environ, C3C="/nonexistent/c3c"))
check("check: missing compiler gives a clear message", "could not start c3c" in m[2]["result"]["content"][0]["text"], json.dumps(m[2]))
import tempfile
work = tempfile.mkdtemp(prefix="c3work-")
marker = os.path.join(work, "marker")
payload = 'module evil;\n$exec("touch", { "%s" });\nfn void main() {}\n' % marker
x = session([("c3_check", {"code": payload})], dict(os.environ, C3C=C3C or ""))
check("exec: c3_check never runs $exec", not os.path.exists(marker), x[2]["result"]["content"][0]["text"])
evil = os.path.join(work, "evil.c3"); open(evil, "w").write(payload)
if C3C: subprocess.run([C3C, "--trust=full", "--no-obj", "--no-entry", "-q", "compile-only", evil], capture_output=True, cwd=work, timeout=60)
check("exec: positive control, payload runs under --trust=full", os.path.exists(marker) or not C3C)
shutil.rmtree(work)
import glob
check("check: temp dir cleaned up", set(glob.glob(os.path.join(tempfile.gettempdir(), "c3guide-*"))) <= before, str(glob.glob(os.path.join(tempfile.gettempdir(), "c3guide-*"))))
# --- review findings (each one reproduced before it was fixed)
def one(name, args, env=None):
    rr = session([(name, args)], env or dict(os.environ, **({"C3C": C3C} if C3C else {})))
    return rr[2]["result"]["content"][0]["text"] if "result" in rr[2] else json.dumps(rr[2])
sdir = tempfile.mkdtemp(prefix="c3secret-")
secret = os.path.join(sdir, "secret.txt")
open(secret, "w").write("rxyz")   # 114 120 121 122: a file of our own, so the test does not depend on /etc/passwd
leak = 'module m; const char[*] X = $embed("%s"); fn void f() { $for var $i = 0; $i < 4; $i++: $echo((int)X[$i]); $endfor }' % secret.replace("\\", "/")
t = one("c3_check", {"code": leak})
check("embed: file read through $embed + $echo is rejected", "rejected" in t and "114" not in t and "120" not in t, t)
if C3C:
    probe = os.path.join(sdir, "probe.c3")
    open(probe, "w").write(leak)
    ctl = subprocess.run([C3C, "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", probe], capture_output=True, text=True)
    check("embed: positive control, the compiler itself prints the file under --trust=none", "114" in (ctl.stdout + ctl.stderr), ctl.stdout + ctl.stderr)
for tok in ("$include", "$exec"):
    check("%s rejected" % tok, "rejected" in one("c3_check", {"code": "module m; " + tok + "(\"x\");"}))
t = one("c3_search", {"query": "@require"})
check("search @require: finds the contract sections", "@require" in t, t[:200])
t = one("c3_search", {"query": "$for"})
check("search $for: not dropped as a stopword", "no match" not in t, t[:200])
check("search @nodiscard", "no match" not in one("c3_search", {"query": "@nodiscard"}))
t = one("c3_symbol", {"name": "a" * 3190 + "\U0001F980" * 4})
check("clip never cuts inside a UTF-8 character", "\ufffd" not in t, repr(t[-40:]))
check("c3_symbol empty name", "give a symbol" in one("c3_symbol", {"name": ""}))
open(os.path.join(work2 := tempfile.mkdtemp(prefix="c3fake-"), "exit1.sh"), "w").write("#!/bin/sh\nexit 1\n")
os.chmod(os.path.join(work2, "exit1.sh"), 0o755)
t = one("c3_check", {"code": "fn void f() {}"}, dict(os.environ, C3C=os.path.join(work2, "exit1.sh")))
check("exit code 1 without output is not reported as OK", "OK" not in t and "exit code 1" in t, t)
# the fixed flags: a fake compiler records its argv (removing --trust=none must fail this test)
argv_file = os.path.join(work2, "argv.txt")
open(os.path.join(work2, "rec.sh"), "w").write('#!/bin/sh\necho "$@" > %s\n' % argv_file)
os.chmod(os.path.join(work2, "rec.sh"), 0o755)
one("c3_check", {"code": "fn void f() {}"}, dict(os.environ, C3C=os.path.join(work2, "rec.sh")))
argv = open(argv_file).read() if os.path.exists(argv_file) else ""
check("compiler flags are fixed", all(f in argv for f in ("--trust=none", "--no-obj", "--no-entry", "compile-only")), argv)
# newest release notes first (inverting the sort must fail this test)
t = one("c3_changes", {"topic": "type properties"})
heads = [l for l in t.split("\n") if l.startswith("### ")]
vers = [tuple(int(x) for x in h[4:].split(" ")[0].split(".")) for h in heads]
check("c3_changes: newest version first", len(vers) >= 2 and vers == sorted(vers, reverse=True), str(heads))
# a killed server leaves c3guide-* behind: the next call removes old ones and keeps fresh ones
old = os.path.join(tempfile.gettempdir(), "c3guide-stale-test"); fresh = os.path.join(tempfile.gettempdir(), "c3guide-fresh-test")
os.makedirs(old, exist_ok=True); os.makedirs(fresh, exist_ok=True)
os.utime(old, (time.time() - 7200, time.time() - 7200))
one("c3_check", {"code": "fn void f() {}"})
check("sweep: stale temp dir removed", not os.path.exists(old))
check("sweep: fresh temp dir kept (another server may use it)", os.path.exists(fresh))
shutil.rmtree(fresh, ignore_errors=True)
shutil.rmtree(work2); shutil.rmtree(sdir)
print("FAILED: %d" % fails if fails else "all passed")
sys.exit(1 if fails else 0)
