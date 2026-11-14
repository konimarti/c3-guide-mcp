#!/usr/bin/env python3
"""Update the vendored tree-sitter submodules. They move on their own schedule: the grammar follows a c3c release
some time after it, and the runtime changes rarely. Neither is touched by scripts/gen_corpus.py.

usage: scripts/update_treesitter.py grammar [TAG]    vendor/tree-sitter-c3; TAG defaults to the newest release
       scripts/update_treesitter.py runtime [TAG]    vendor/tree-sitter; TAG defaults to the newest release

Afterwards, with the c3c you are targeting installed, run
    C3_DIR=/path/to/c3 c3c test c3-guide-mcp
test/outline_test.c3 parses every file of that c3c's standard library with the vendored grammar and fails if
any of them does not parse: that is the check that the grammar understands the c3c release. If it fails, the
grammar has not caught up yet - keep the old commit (git -C vendor/<name> checkout <old tag>) and update the
docs snapshot alone.
"""
import os, re, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "..")
PATHS = {"grammar": "vendor/tree-sitter-c3", "runtime": "vendor/tree-sitter"}

def run(*a, cwd=None):
    return subprocess.run(a, check=True, capture_output=True, text=True, cwd=cwd).stdout.strip()

def newest_tag(path):
    run("git", "fetch", "--tags", "--quiet", cwd=path)
    tags = run("git", "tag", cwd=path).splitlines()
    key = lambda t: [int(x) for x in re.findall(r"\d+", t)]
    return max((t for t in tags if re.fullmatch(r"v\d+(\.\d+)*", t)), key=key)

def constant(path, name):
    return int(re.search(r"#define\s+%s\s+(\d+)" % name, open(path, encoding="utf-8").read()).group(1))

def abi_check():
    api = os.path.join(root, "vendor", "tree-sitter", "lib", "include", "tree_sitter", "api.h")
    parser = os.path.join(root, "vendor", "tree-sitter-c3", "src", "parser.c")
    lo, hi = constant(api, "TREE_SITTER_MIN_COMPATIBLE_LANGUAGE_VERSION"), constant(api, "TREE_SITTER_LANGUAGE_VERSION")
    have = constant(parser, "LANGUAGE_VERSION")
    if not lo <= have <= hi:
        sys.exit(f"the grammar is parser ABI {have}, the runtime handles {lo}..{hi}: update the runtime first")
    print(f"parser ABI {have} is within the runtime's {lo}..{hi}")

kind = sys.argv[1] if len(sys.argv) > 1 else sys.exit(__doc__)
if kind not in PATHS:
    sys.exit(__doc__)
path = os.path.join(root, PATHS[kind])
tag = sys.argv[2] if len(sys.argv) > 2 else newest_tag(path)
run("git", "checkout", tag, cwd=path)
commit = run("git", "rev-parse", "--short", "HEAD", cwd=path)
print(f"{PATHS[kind]} -> {tag} (commit {commit})")
abi_check()
print("next: commit the submodule pointer, then")
print("      C3_DIR=<the c3c you target> c3c test c3-guide-mcp   (parses that c3c's whole stdlib with this grammar)")
