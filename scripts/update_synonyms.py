#!/usr/bin/env python3
"""Write data/synonyms.txt from scripts/synonyms_seed.txt, checked against data/corpus.dat.

usage: scripts/update_synonyms.py [--check]
A group stays only if the stdlib uses at least one of its words (in a symbol name or doc comment): that is the
word the others lead to. The other words are what people type, so they stay even when no symbol uses them. Run it after the snapshot changes (a new c3c release). --check fails when the committed file is
out of date (used by test/corpus_test.py). Dropped words are listed so the seed can be reviewed."""
import os, re, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..")
words = set()
for rec in open(os.path.join(root, "data", "corpus.dat"), encoding="utf-8").read().split("\x1e"):
    f = rec.split("\x1f")
    if len(f) >= 3 and f[0] in ("fn", "macro", "method", "mmethod", "type", "var"):
        words.update(w.lower() for w in re.findall(r"[A-Za-z0-9]+", f[1].rsplit("::", 1)[-1].replace("_", " ") + " " + f[2]))
used = lambda w: w in words or w + "s" in words or w.rstrip("s") in words
out, dropped = [], []
for line in open(os.path.join(here, "synonyms_seed.txt"), encoding="utf-8"):
    line = line.split("#")[0].strip()
    if not line:
        continue
    group = line.split()
    if len(group) >= 2 and any(used(w) for w in group):
        out.append(" ".join(group))
    else:
        dropped.append(line)
text = "\n".join(out) + "\n"
path = os.path.join(root, "data", "synonyms.txt")
if "--check" in sys.argv:
    sys.exit(0 if os.path.exists(path) and open(path, encoding="utf-8").read() == text else "data/synonyms.txt is out of date: run scripts/update_synonyms.py")
open(path, "w", encoding="utf-8").write(text)
print(f"{len(out)} groups written" + (f"; groups dropped (no word is in this stdlib): {' | '.join(dropped)}" if dropped else ""))
