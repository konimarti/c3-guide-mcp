#!/usr/bin/env python3
"""c3-guide-mcp --setup / --doctor on a throw-away HOME: idempotent, keeps the user's text, writes nothing on --dry-run,
never writes through a symlink, never rewrites an existing settings.json. Run from the repository root."""
import os, subprocess, sys, tempfile

B = os.path.abspath("build/c3-guide-mcp")
fails = 0

def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "\n" + str(detail)[:400]))
    fails += 0 if ok else 1

def run(home, *args):
    env = {"PATH": "/usr/bin:/bin", "HOME": home}
    r = subprocess.run([B, *args], capture_output=True, text=True, env=env, timeout=30)
    return r.returncode, r.stdout + r.stderr

with tempfile.TemporaryDirectory() as home:
    cfg = os.path.join(home, ".claude")
    os.makedirs(cfg)
    md = os.path.join(cfg, "CLAUDE.md")
    st = os.path.join(cfg, "settings.json")
    open(md, "w").write("# Mine\n\nkeep this line\n")
    open(st, "w").write('{"theme": "dark"} // my comment\n')
    rc, out = run(home, "--setup", "--dry-run")
    check("dry run writes nothing", rc == 0 and not os.path.exists(os.path.join(cfg, "hooks")) and "c3-guide" not in open(md).read(), out)
    rc, out = run(home, "--setup")
    text = open(md).read()
    check("setup adds one block and keeps the user's text", rc == 0 and "keep this line" in text and text.count("c3-guide:begin") == 1, out)
    hook = os.path.join(cfg, "hooks", "c3-guide-redirect.sh")
    check("hook is executable", os.access(hook, os.X_OK), out)
    check("existing settings.json is not rewritten", open(st).read() == '{"theme": "dark"} // my comment\n' and "hooks.PreToolUse" in out, out)
    before = open(md).read()
    rc, out = run(home, "--setup")
    check("second run changes nothing", open(md).read() == before and out.count("already up to date") == 2, out)
    rc, out = run(home, "--doctor")
    check("doctor reports rules and hook installed", "rules:    installed" in out and "hook:     installed" in out, out)
    os.remove(hook)
    target = os.path.join(home, "elsewhere.sh")
    open(target, "w").write("do not touch\n")
    os.symlink(target, hook)
    rc, out = run(home, "--setup")
    check("a symlinked hook is not written through", open(target).read() == "do not touch\n" and "symbolic link" in out, out)

with tempfile.TemporaryDirectory() as home:
    rc, out = run(home, "--setup")
    st = os.path.join(home, ".claude", "settings.json")
    check("a missing settings.json is created with the hook", rc == 0 and os.path.exists(st) and "c3-guide-redirect.sh" in open(st).read(), out)

with tempfile.TemporaryDirectory() as home:
    cfg = os.path.join(home, ".claude")
    os.makedirs(cfg)
    big = os.path.join(cfg, "CLAUDE.md")
    open(big, "w").write("my notes\n" * 200000)   # 1.8 MB: not ours to rewrite
    rc, out = run(home, "--setup")
    check("a CLAUDE.md that is too large is left alone", open(big).read().startswith("my notes") and "c3-guide:begin" not in open(big).read() and "left alone" in out, out)

rc, out = run("/nonexistent", "--bogus")
check("an unknown option is refused", rc == 2 and "--doctor" in out, out)
print("setup_test:", "all ok" if fails == 0 else f"{fails} failed")
sys.exit(1 if fails else 0)
