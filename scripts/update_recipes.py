#!/usr/bin/env python3
"""Refresh only the recipe records of data/corpus.dat from recipes/*.c3, keeping every other record.

usage: scripts/update_recipes.py C3_DIR
The committed snapshot was built with all.md (a live web page, not reproducible), so adding a recipe must not
mean regenerating everything. C3_DIR is the c3c install the snapshot belongs to (its version is checked)."""
import os, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
dat = os.path.join(here, "..", "data", "corpus.dat")
tmp = os.path.join(tempfile.mkdtemp(), "corpus.dat")
subprocess.run([sys.executable, os.path.join(here, "gen_corpus.py"), sys.argv[1]], check=True, env=dict(os.environ, C3GUIDE_OUT=tmp))
read = lambda p: open(p, encoding="utf-8").read().split("\x1e")[:-1]   # records end with \x1e
kind = lambda r: r.split("\x1f")[0]
new, old = read(tmp), read(dat)
ver = lambda recs: recs[0].split("\x1f")[2]
if ver(new) != ver(old):
    sys.exit(f"snapshot is c3c {ver(old)}, but {sys.argv[1]} is {ver(new)}: regenerate the whole snapshot instead")
fresh = [r for r in new[1:] if kind(r) == "recipe"]
body = old[1:]
at = next(i for i, r in enumerate(body) if kind(r) == "recipe")
body = [r for r in body if kind(r) != "recipe"]
body[at:at] = fresh
meta = old[0].split("\x1f")
meta[3] = f"records={len(body)}"
with open(dat, "w", encoding="utf-8") as f:
    f.write("\x1f".join(meta) + "\x1e" + "".join(r + "\x1e" for r in body))
print(f"{len(fresh)} recipes, {len(body)} records, {os.path.getsize(dat)/1024:.0f} KB")
