#!/usr/bin/env python3
"""The committed snapshot must match the installed c3c: python3 test/corpus_test.py C3_DIR
Regenerates WITHOUT all.md (that page changes over time) and requires every generated record to be in
data/corpus.dat, and the snapshot's c3c version to match."""
import os, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
c3_dir = sys.argv[1]
tmp = os.path.join(tempfile.mkdtemp(), "corpus.dat")
subprocess.run([sys.executable, os.path.join(here, "..", "scripts", "gen_corpus.py"), c3_dir], check=True, cwd=os.path.join(here, ".."), env=dict(os.environ, C3GUIDE_OUT=tmp))
read = lambda p: open(p, encoding="utf-8").read().split("\x1e")
new, old = read(tmp), read(os.path.join(here, "..", "data", "corpus.dat"))
ver = lambda recs: recs[0].split("\x1f")[2]
missing = set(new[1:]) - set(old[1:])
print("c3c version: generated %s, committed %s; generated records %d, committed %d, missing from committed %d" % (ver(new), ver(old), len(new) - 1, len(old) - 1, len(missing)))
for m in list(missing)[:3]:
    print("  e.g.", repr(m[:120]))
# recipes come from this repo, not from the c3c install: a committed recipe the repo no longer has is stale
kind = lambda r: r.split("\x1f")[0]
stale = {r for r in old[1:] if kind(r) == "recipe"} - {r for r in new[1:] if kind(r) == "recipe"}
if stale:
    print("stale recipes in the snapshot (run scripts/update_recipes.py):", len(stale))
sys.exit(0 if ver(new) == ver(old) and not missing and not stale else 1)
