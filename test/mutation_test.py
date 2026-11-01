import os, shutil, subprocess, sys
root = "/opt/data/c3/c3-guide-mcp/"
C3C = "/opt/data/c3/c3/c3c"
env = dict(os.environ, C3C=C3C)
MUT = [
    ("remove --trust=none", "src/check.c3", '"--trust=none", ', ''),
    ("remove --no-obj", "src/check.c3", '"--no-obj", ', ''),
    ("remove $embed guard", "src/check.c3", '{ "$embed", "$include", "$exec" }', '{ "$zzz" }'),
    ("remove stopwords", "src/search.c3", '{ "how", "to", "a", "an", "the", "of", "in", "is", "do", "does", "i", "with", "for", "what", "use", "using", "can" }', '{ "zzzz" }'),
    ("invert version sort", "src/tools.c3", 'version_key(corpus::entries[b.idx].title) - version_key(corpus::entries[a.idx].title)', 'version_key(corpus::entries[a.idx].title) - version_key(corpus::entries[b.idx].title)'),
    ("no utf8 boundary", "src/util.c3", 'while (n > 0 && (s[n] & 0xC0) == 0x80) n--;', ''),
    ("exit code ignored", "src/check.c3", 'return status == 0 ? "OK: no errors" : string::tformat("c3c failed (exit code %d) without a message", status);', 'return "OK: no errors";'),
    ("deadline disabled", "src/check.c3", 'const ulong DEADLINE_MS = 10000;', 'const ulong DEADLINE_MS = 100000000;'),
]
only = sys.argv[1:]
shutil.copytree(root + "src", "/opt/data/cache/scratch/src_pristine", dirs_exist_ok=True)
try:
    for name, f, old, new in MUT:
        s = open(root + f).read()
        assert old in s, name + ": pattern not found"
        open(root + f, "w").write(s.replace(old, new, 1))
        b = subprocess.run([C3C, "build", "c3-guide-mcp", "-O3"], cwd=root, capture_output=True, text=True)
        caught = []
        if b.returncode == 0:
            for t in ("stdio", "limits", "quality"):
                r = subprocess.run(["python3", "test/%s_test.py" % t], cwd=root, capture_output=True, text=True, env=env, timeout=200)
                if r.returncode != 0: caught.append(t)
        else:
            caught = ["BUILD BROKEN"]
        print("%-24s %s" % (name, ", ".join(caught) or "NOT CAUGHT"), flush=True)
        shutil.copy("/opt/data/cache/scratch/src_pristine/" + f.split("/")[1], root + f)
finally:
    for fn in os.listdir("/opt/data/cache/scratch/src_pristine"):
        shutil.copy("/opt/data/cache/scratch/src_pristine/" + fn, root + "src/" + fn)
    subprocess.run([C3C, "build", "c3-guide-mcp", "-O3"], cwd=root, capture_output=True)
