#!/usr/bin/env python3
"""Every recipe in recipes/ must compile and print exactly its `// expect:` lines.
Recipes are what the server shows to a model as "this works"; a recipe that does not compile is worse than none.
Usage: C3C=/path/to/c3c python3 test/recipes_test.py"""
import glob, os, shutil, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
c3c = os.environ.get("C3C") or shutil.which("c3c") or sys.exit("set C3C or put c3c on PATH")
exe = ".exe" if sys.platform == "win32" else ""
bad = 0
files = sorted(glob.glob(os.path.join(here, "..", "recipes", "*.c3")))
for path in files:
    name = os.path.basename(path)[:-3]
    text = open(path, encoding="utf-8").read()
    want = [l[len("// expect:"):].strip() for l in text.split("\n") if l.startswith("// expect:")]
    stdin = "".join(l[len("// stdin:"):].strip().encode().decode("unicode_escape") for l in text.split("\n") if l.startswith("// stdin:"))
    ok = text.startswith("// Recipe: ") and want
    tmp = tempfile.mkdtemp()
    try:
        r = subprocess.run([c3c, "compile", path, "-o", os.path.join(tmp, name)], capture_output=True, text=True, cwd=tmp)
        out = ""
        if r.returncode == 0:
            p = subprocess.run([os.path.join(tmp, name + exe)], capture_output=True, text=True, cwd=tmp, timeout=30, input=stdin)
            out = p.stdout
        got = [l.strip() for l in out.strip().split("\n")] if out.strip() else []
        ok = ok and r.returncode == 0 and got == want
        print(("ok   " if ok else "FAIL ") + name)
        if not ok:
            bad += 1
            print("   want:", want, "\n   got: ", got, "\n  ", (r.stdout + r.stderr)[-600:] if r.returncode else "")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
print(f"{len(files) - bad}/{len(files)} recipes pass")
sys.exit(1 if bad else 0)
