#!/usr/bin/env python3
"""c3-guide-mcp --doctor on throw-away homes: reports each client found (config file, c3-guide entry, rules), the others
in one line, honours CLAUDE_CONFIG_DIR and CODEX_HOME, never writes, refuses a stray argument. Windows and macOS locations
are unit-tested in test/doctor_test.c3. Run from the repository root."""
import hashlib, os, subprocess, sys, tempfile

B = os.path.abspath("build/c3-guide-mcp")
fails = 0

def check(name, ok, detail=""):
    global fails
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "\n" + str(detail)[:600]))
    fails += 0 if ok else 1

def run(home, *args, **extra):
    env = {"PATH": "/usr/bin:/bin", "HOME": home}
    env.update(extra)
    r = subprocess.run([B, *args], capture_output=True, text=True, env=env, timeout=30, stdin=subprocess.DEVNULL)
    return r.returncode, r.stdout + r.stderr

def tree_hash(root):
    h = hashlib.sha256()
    for d, dirs, files in sorted(os.walk(root)):
        dirs.sort()
        h.update(d.encode())
        for f in sorted(files):
            p = os.path.join(d, f)
            h.update(p.encode())
            h.update(os.readlink(p).encode() if os.path.islink(p) else open(p, "rb").read())
    return h.hexdigest()

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(text)

def block(out, title):
    """The lines of one client's block."""
    lines = out.splitlines()
    for i, l in enumerate(lines):
        if l.startswith(title + "  ("):
            j = i + 1
            while j < len(lines) and lines[j].startswith("  "):
                j += 1
            return "\n".join(lines[i:j])
    return ""

ENTRY = '{"mcpServers": {"c3-guide": {"command": "x"}}}\n'
NO_ENTRY = '{"mcpServers": {}}\n'
TOOLS = "Use c3_lookup before every name.\n"

# ---- nothing found ----
with tempfile.TemporaryDirectory() as home:
    rc, out = run(home, "--doctor")
    check("no client found: one 'not found' line with all six", rc == 0 and "not found: Claude Code, Codex, Antigravity, Cursor, VS Code (Copilot), Claude Desktop" in out and "c3-guide-mcp " in out, out)
    check("nothing is created", os.listdir(home) == [], os.listdir(home))

# ---- every client, server present or missing, rules with or without the tools ----
with tempfile.TemporaryDirectory() as home:
    j = lambda *p: os.path.join(home, *p)
    put(j(".claude.json"), ENTRY)                     # Claude Code keeps its servers in ~/.claude.json
    put(j(".claude", "CLAUDE.md"), "notes\n" + TOOLS)
    put(j(".codex", "config.toml"), 'model = "x"\n')  # no server, and AGENTS.md without the tools
    put(j(".codex", "AGENTS.md"), "my notes\n")
    put(j(".gemini", "config", "mcp_config.json"), ENTRY)
    put(j(".gemini", "config", "GEMINI.md"), "check with c3_check\n")
    put(j(".cursor", "mcp.json"), NO_ENTRY)
    put(j(".config", "Code", "User", "mcp.json"), '{"servers": {"c3-guide": {"type": "stdio", "command": "x"}}}\n')
    os.makedirs(j(".config", "Claude"))               # Claude Desktop: folder but no config file
    before = tree_hash(home)
    rc, out = run(home, "--doctor")
    check("doctor exits 0 and writes nothing", rc == 0 and tree_hash(home) == before, out)
    b = block(out, "Claude Code")
    check("claude: server present in ~/.claude.json, rules mention the tools", j(".claude.json") + ": c3-guide server present" in b and "rules mention the c3 tools" in b, out)
    b = block(out, "Codex")
    check("codex: server MISSING, no c3 rules", "config.toml: c3-guide server MISSING" in b and "AGENTS.md: no c3 rules" in b, out)
    b = block(out, "Antigravity")
    check("antigravity: present, rules with c3_check", "mcp_config.json: c3-guide server present" in b and "GEMINI.md: rules mention the c3 tools" in b, out)
    b = block(out, "Cursor")
    check("cursor: missing, project rules", "mcp.json: c3-guide server MISSING" in b and "rules:    project file (see README)" in b, out)
    b = block(out, "VS Code (Copilot)")
    check("vscode: a servers entry is present", "mcp.json: c3-guide server present" in b and "project file (see README)" in b, out)
    b = block(out, "Claude Desktop")
    check("desktop: folder found, no config file", "claude_desktop_config.json: no such file" in b, out)
    check("no 'not found' line when all are found", "not found" not in out, out)
    check("no --setup anywhere", "--setup" not in out, out)

# ---- a toml server table counts; only some clients found ----
with tempfile.TemporaryDirectory() as home:
    put(os.path.join(home, ".codex", "config.toml"), '[mcp_servers.c3-guide]\ncommand = "x"\n')
    rc, out = run(home, "--doctor")
    check("codex: a [mcp_servers.c3-guide] table is present", "c3-guide server present" in block(out, "Codex"), out)
    check("the rest are listed as not found", "not found: Claude Code, Antigravity, Cursor, VS Code (Copilot), Claude Desktop" in out, out)

# ---- env overrides ----
with tempfile.TemporaryDirectory() as home:
    cfg = os.path.join(home, "moved claude")
    put(os.path.join(cfg, ".claude.json"), ENTRY)
    put(os.path.join(cfg, "CLAUDE.md"), TOOLS)
    rc, out = run(home, "--doctor", CLAUDE_CONFIG_DIR=cfg)
    b = block(out, "Claude Code")
    check("CLAUDE_CONFIG_DIR: folder, .claude.json and CLAUDE.md inside it", cfg in b and os.path.join(cfg, ".claude.json") + ": c3-guide server present" in b and "rules mention" in b, out)
    cx = os.path.join(home, "cx")
    put(os.path.join(cx, "config.toml"), '[mcp_servers.c3-guide]\n')
    rc, out = run(home, "--doctor", CODEX_HOME=cx)
    check("CODEX_HOME is honoured", cx in block(out, "Codex") and "server present" in block(out, "Codex"), out)
    rc, out = run(home, "--doctor", CODEX_HOME=os.path.join(home, "nowhere"))
    check("an override that does not exist is 'not found'", "Codex" in out.split("not found:")[-1], out)

# ---- stray arguments ----
with tempfile.TemporaryDirectory() as home:
    os.makedirs(os.path.join(home, ".claude"))
    before = tree_hash(home)
    for args in (["--doctor", "claude"], ["--doctor", "--dry-run"], ["--doctor", "--rules", "f"]):
        rc, out = run(home, *args)
        check("usage and exit 2: " + " ".join(args), rc == 2 and "--doctor" in out and tree_hash(home) == before, out)
    rc, out = run(home, "--help")
    check("--setup is gone from the usage", rc == 0 and "--doctor" in out and "--setup" not in out, out)
    rc, out = run(home, "--stdio")
    check("an unknown flag with piped input is ignored", rc == 0 and "ignoring" in out, out)

print("doctor_test:", "all ok" if fails == 0 else f"{fails} failed")
sys.exit(1 if fails else 0)
