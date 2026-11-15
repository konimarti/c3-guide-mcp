#!/usr/bin/env python3
"""c3-guide-mcp --setup / --doctor on a throw-away HOME: idempotent, keeps the user's text, writes nothing on --dry-run,
never writes through a symlink, writes nothing but CLAUDE.md. Run from the repository root."""
import os, subprocess, sys, tempfile

B = os.path.abspath("build/c3-guide-mcp")
fails = 0

def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "\n" + str(detail)[:400]))
    fails += 0 if ok else 1

def run(home, *args):
    env = {"PATH": "/usr/bin:/bin", "HOME": home}
    r = subprocess.run([B, *args], capture_output=True, text=True, env=env, timeout=30, stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout + r.stderr

with tempfile.TemporaryDirectory() as home:
    cfg = os.path.join(home, ".claude")
    os.makedirs(cfg)
    md = os.path.join(cfg, "CLAUDE.md")
    st = os.path.join(cfg, "settings.json")
    open(md, "w").write("# Mine\n\nkeep this line\n")
    open(st, "w").write('{"theme": "dark"} // my comment\n')
    rc, out = run(home, "--setup", "--dry-run")
    check("dry run writes nothing", rc == 0 and "c3-guide" not in open(md).read(), out)
    rc, out = run(home, "--setup")
    text = open(md).read()
    check("setup adds one block and keeps the user's text", rc == 0 and "keep this line" in text and text.count("c3-guide:begin") == 1, out)
    rules = open("integrations/AGENTS.md").read().strip()
    check("the block holds the rules of integrations/AGENTS.md", rules in text, text)
    check("only CLAUDE.md is touched", sorted(os.listdir(cfg)) == ["CLAUDE.md", "settings.json"] and open(st).read() == '{"theme": "dark"} // my comment\n', os.listdir(cfg))
    before = open(md).read()
    rc, out = run(home, "--setup")
    check("second run changes nothing", open(md).read() == before and out.count("already up to date") == 1, out)
    rc, out = run(home, "--doctor")
    check("doctor reports the rules installed and no hook", "rules:    installed" in out and "hook" not in out, out)
    os.remove(md)
    target = os.path.join(home, "elsewhere.md")
    open(target, "w").write("do not touch\n")
    os.symlink(target, md)
    rc, out = run(home, "--setup")
    check("a symlinked CLAUDE.md is not written through", open(target).read() == "do not touch\n" and "symbolic link" in out, out)

with tempfile.TemporaryDirectory() as home:
    rc, out = run(home, "--setup")
    cfg = os.path.join(home, ".claude")
    check("a missing config folder gets CLAUDE.md only", rc == 0 and os.listdir(cfg) == ["CLAUDE.md"], out)

with tempfile.TemporaryDirectory() as home:
    cfg = os.path.join(home, ".claude")
    os.makedirs(cfg)
    big = os.path.join(cfg, "CLAUDE.md")
    open(big, "w").write("my notes\n" * 200000)   # 1.8 MB: not ours to rewrite
    rc, out = run(home, "--setup")
    check("a CLAUDE.md that is too large is left alone", open(big).read().startswith("my notes") and "c3-guide:begin" not in open(big).read() and "left alone" in out, out)

with tempfile.TemporaryDirectory() as home:
    rc, out = run(home, "--setup", "--dryrun")   # a typo must not turn a dry run into a real one
    check("a mistyped --setup flag is refused and writes nothing", rc == 2 and not os.path.exists(os.path.join(home, ".claude")), out)
    rc, out = run(home, "--stdio")   # an editor's own flag: serve (here the input is already at its end)
    check("an unknown flag with piped input is ignored", rc == 0 and "ignoring" in out, out)
    cfg = os.path.join(home, "we ird\"dir")
    env = {"PATH": "/usr/bin:/bin", "HOME": home, "CLAUDE_CONFIG_DIR": cfg}
    r = subprocess.run([B, "--setup"], capture_output=True, text=True, env=env, timeout=30, stdin=subprocess.DEVNULL)
    check("a config path with a quote and a space works", r.returncode == 0 and os.path.isfile(os.path.join(cfg, "CLAUDE.md")), r.stdout)
    md = os.path.join(cfg, "CLAUDE.md")
    open(md, "w").write("keep\n<!-- c3-guide:begin (written by c3-guide-mcp --setup; edit outside this block) -->\nmore of mine\n")
    r = subprocess.run([B, "--setup"], capture_output=True, text=True, env=env, timeout=30, stdin=subprocess.DEVNULL)
    check("a begin marker without an end marker is not rewritten", open(md).read().endswith("more of mine\n") and "no end marker" in r.stdout and r.returncode == 1, r.stdout)

print("setup_test:", "all ok" if fails == 0 else f"{fails} failed")
sys.exit(1 if fails else 0)
