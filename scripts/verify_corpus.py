#!/usr/bin/env python3
"""Compile the C3 code in the corpus the server serves, with the installed c3c, and report what does not compile.

The manual is prose written by people: some of its code is a fragment, an error shown on purpose, or out of date.
This finds the last kind. Nothing is dropped automatically; a person reads the report, then either fixes the manual
(ERRATA in gen_corpus.py) or marks the block as expected.

  recipes   every recipe must compile as it is (they are ours: a failing one is a bug in the corpus)
  manual    every ```c3 block is tried as it is, then inside `fn void main()` (a statement fragment); one that
            still fails is reported unless it says it is an error on purpose (a line with "error" or "invalid")

usage: verify_corpus.py [--corpus data/corpus.dat] [--jobs 8] [--fail-over N]   (exit 1 when more than N manual blocks fail)
"""
import argparse, concurrent.futures, os, re, shutil, subprocess, sys, tempfile

RS, US = "\x1e", "\x1f"


def load(path):
    text = open(path, "rb").read().decode("utf-8", "replace")
    for rec in text.split(RS):
        f = rec.split(US)
        if len(f) >= 3:
            yield f[0], f[1], f[2]


def compile_only(c3c, code, work):
    src = os.path.join(work, "t.c3")
    with open(src, "w") as fh:
        fh.write(code)
    r = subprocess.run([c3c, "--trust=none", "--no-obj", "--no-entry", "-q", "compile-only", src],
                       capture_output=True, text=True, cwd=work, timeout=60)
    errs = [l for l in (r.stdout + r.stderr).splitlines() if "error:" in l]
    return (r.returncode == 0 and not errs), (errs[0].split("error:", 1)[1].strip() if errs else (r.stdout + r.stderr).strip()[:120])


# A name that is not declared in a snippet says nothing about the language; these errors are not reported.
UNDECLARED = re.compile(r"could not be found|Did you mean|would shadow|is '@private'|not visible|not declared|was expected here, but this looks")
PRELUDE = "import std::io, std::core::mem, std::collections::list, std::collections::map, std::math;\n"


def check_block(c3c, code, recipe=False):
    with tempfile.TemporaryDirectory() as work:
        if recipe:   # ours: complete programs, compiled exactly as they are
            ok, why = compile_only(c3c, code, work)
            return ("ok", "") if ok else ("fail", why)
        ok, why = compile_only(c3c, code, work)
        if ok:
            return "ok", ""
        why2 = ""
        if "module " not in code:
            imports = [l for l in code.splitlines() if l.startswith("import ")]
            rest = "\n".join(l for l in code.splitlines() if not l.startswith("import "))
            head = "\n".join(imports) + "\n" + (PRELUDE if not imports else "")
            ok2, why2 = compile_only(c3c, head + rest, work)
            if ok2:
                return "ok", ""
            ok3, why3 = compile_only(c3c, head + "fn void main()\n{\n" + rest + "\n}\n", work)
            if ok3:
                return "fragment", ""
            why2 = why2 + " | " + why3
        if UNDECLARED.search(why) or UNDECLARED.search(why2) or "auto-generated module" in why:
            return "fragment", ""   # an illustration that uses names it does not declare
        return "fail", why


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--corpus", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data", "corpus.dat"))
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--fail-over", type=int, default=-1)
    a = ap.parse_args()
    c3c = os.environ.get("C3C") or shutil.which("c3c")
    if not c3c:
        sys.exit("verify_corpus: c3c not found (set C3C)")
    items = []
    for kind, title, body in load(a.corpus):
        if kind == "recipe":
            items.append(("recipe", title, body))
        elif kind == "doc":
            for m in re.finditer(r"```c3\n(.*?)```", body, flags=re.S):
                code = m.group(1)
                on_purpose = re.search(r"//.*\b(error|invalid|illegal|not allowed|fails?)\b", code, re.I)
                items.append(("manual", title, code) if not on_purpose else ("on-purpose", title, code))
    todo = [i for i in items if i[0] != "on-purpose"]
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda i: check_block(c3c, i[2], i[0] == "recipe"), todo))
    counts = {"ok": 0, "fragment": 0, "fail": 0}
    bad = {"recipe": [], "manual": []}
    for (kind, title, code), (res, why) in zip(todo, results):
        counts[res] += 1
        if res == "fail":
            bad[kind].append((title, why, code.strip().splitlines()[0][:70] if code.strip() else ""))
    print(f"c3c {subprocess.run([c3c, '--version'], capture_output=True, text=True).stdout.split()[1:3]}")
    print(f"{len(items)} code blocks: {counts['ok']} compile, {counts['fragment']} are fragments, {counts['fail']} do not, {len(items) - len(todo)} are errors on purpose")
    for kind in ("recipe", "manual"):
        if bad[kind]:
            print(f"\n{kind}: {len(bad[kind])} do not compile")
            for title, why, first in bad[kind]:
                print(f"  - {title[:70]}\n      {why[:110]}\n      starts: {first}")
    if bad["recipe"]:
        sys.exit(1)
    if a.fail_over >= 0 and len(bad["manual"]) > a.fail_over:
        sys.exit(1)


if __name__ == "__main__":
    main()
