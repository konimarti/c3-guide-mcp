#!/usr/bin/env python3
"""Update the vendored tree-sitter pieces. They move on their own schedule: the grammar follows a c3c release
some time after it, and the runtime changes rarely. Neither is touched by scripts/gen_corpus.py.

usage: scripts/update_treesitter.py grammar [TAG]    tree-sitter-c3 (src/ only); TAG defaults to the newest release
       scripts/update_treesitter.py runtime [TAG]    the tree-sitter runtime (lib/src, lib/include)

Afterwards, with the c3c you are targeting installed, run
    C3_DIR=/path/to/c3 c3c test c3-guide-mcp
test/outline_test.c3 parses every file of that c3c's standard library with the vendored grammar and fails if
any of them does not parse: that is the check that the grammar understands the c3c release. If it fails, the
grammar has not caught up yet - keep the old one (git checkout vendor/) and update the docs snapshot alone."""
import os, re, shutil, subprocess, sys, tempfile

here = os.path.dirname(os.path.abspath(__file__))
vendor = os.path.join(here, "..", "vendor")
URLS = {"grammar": "https://github.com/c3lang/tree-sitter-c3.git", "runtime": "https://github.com/tree-sitter/tree-sitter.git"}

def run(*a, cwd=None):
    return subprocess.run(a, check=True, capture_output=True, text=True, cwd=cwd).stdout.strip()

def newest_tag(url):
    tags = [l.split("refs/tags/")[1] for l in run("git", "ls-remote", "--tags", "--refs", url).splitlines()]
    key = lambda t: [int(x) for x in re.findall(r"\d+", t)]
    return max((t for t in tags if re.fullmatch(r"v\d+(\.\d+)*", t)), key=key)

def constant(path, name):
    return int(re.search(r"#define\s+%s\s+(\d+)" % name, open(path, encoding="utf-8").read()).group(1))

def abi_check():
    api = os.path.join(vendor, "tree-sitter", "include", "tree_sitter", "api.h")
    parser = os.path.join(vendor, "tree-sitter-c3", "src", "parser.c")
    lo, hi = constant(api, "TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION"), constant(api, "TREE_SITTER_LANGUAGE_VERSION")
    have = constant(parser, "LANGUAGE_VERSION")
    if not lo <= have <= hi:
        sys.exit(f"the grammar is parser ABI {have}, the runtime handles {lo}..{hi}: update the runtime first")
    print(f"parser ABI {have} is within the runtime's {lo}..{hi}")

def copy_tree(src, dst):
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)

kind = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
if kind not in URLS:
    sys.exit(__doc__)
tag = sys.argv[2] if len(sys.argv) > 2 else newest_tag(URLS[kind])
with tempfile.TemporaryDirectory() as tmp:
    run("git", "clone", "--depth", "1", "--branch", tag, URLS[kind], tmp)
    commit = run("git", "rev-parse", "--short", "HEAD", cwd=tmp)
    if kind == "grammar":
        dst = os.path.join(vendor, "tree-sitter-c3")
        os.makedirs(os.path.join(dst, "src"), exist_ok=True)
        for f in ("parser.c", "scanner.c"):
            shutil.copy(os.path.join(tmp, "src", f), os.path.join(dst, "src", f))
        copy_tree(os.path.join(tmp, "src", "tree_sitter"), os.path.join(dst, "src", "tree_sitter"))
        shutil.copy(os.path.join(tmp, "LICENSE"), os.path.join(dst, "LICENSE"))
        change = re.search(r"##\s*[\d.]+\s*\n([^\n]*C3 [\d.]+[^\n]*)", open(os.path.join(tmp, "CHANGELOG.md"), encoding="utf-8").read())
        target = re.search(r"C3 ([\d.]*\d)", change.group(1)).group(1) if change else "unknown"
        line = f"tree-sitter-c3 {tag} (commit {commit}, grammar for C3 {target}; src/ only), MIT, {URLS[kind][:-4]}\n"
        open(os.path.join(dst, "SOURCE"), "w").write(line)
    else:
        dst = os.path.join(vendor, "tree-sitter")
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(os.path.join(dst, "src"))
        for f in os.listdir(os.path.join(tmp, "lib", "src")):
            p = os.path.join(tmp, "lib", "src", f)
            if os.path.isfile(p) and f.endswith((".c", ".h")):
                shutil.copy(p, os.path.join(dst, "src", f))
        for d in ("unicode", "portable"):
            copy_tree(os.path.join(tmp, "lib", "src", d), os.path.join(dst, "src", d))
        os.makedirs(os.path.join(dst, "include", "tree_sitter"))
        shutil.copy(os.path.join(tmp, "lib", "include", "tree_sitter", "api.h"), os.path.join(dst, "include", "tree_sitter", "api.h"))
        shutil.copy(os.path.join(tmp, "LICENSE"), os.path.join(dst, "LICENSE"))
        open(os.path.join(dst, "SOURCE"), "w").write(f"tree-sitter {tag} (lib/src, lib/include), MIT, {URLS[kind][:-4]}\n")
    print(open(os.path.join(dst, "SOURCE")).read().strip())
abi_check()
print("next: C3_DIR=<the c3c you target> c3c test c3-guide-mcp   (it parses that c3c's whole stdlib with this grammar)")
