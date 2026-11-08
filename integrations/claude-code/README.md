# Claude Code integration

Two optional files that make Claude Code reliably use the c3-guide tools.

## One command

`c3-guide-mcp --setup` does the steps below for Claude Code (`--dry-run` shows the plan, `--doctor` the state). The hook also stops `sed -i` on `.c3` files: renames go through `c3_refs` with `rename_to`.

## Rules for the assistant: `CLAUDE.md`

Copy the lines of [CLAUDE.md](CLAUDE.md) into your project's `CLAUDE.md` (or `~/.claude/CLAUDE.md` for all projects). Other editors take the same text in `AGENTS.md`, Cursor rules or `.github/copilot-instructions.md`.

## Hook: `redirect-c3c.sh`

When the assistant types `c3c test`, `c3c run`, `c3c compile-run`, `c3c compile-only` or `c3c compile-test` into the shell, the hook stops the command and tells it which c3-guide tool to use instead. `c3c build` and `c3c compile` are allowed.

1. Make sure `jq` or `python3` is installed.
2. Put the hook in your Claude Code `settings.json` (`~/.claude/settings.json`, or `.claude/settings.json` in a project), using the full path to `redirect-c3c.sh`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "/full/path/to/c3-guide-mcp/integrations/claude-code/redirect-c3c.sh" }
        ]
      }
    ]
  }
}
```

3. Restart Claude Code.

To run c3c yourself on purpose, put `C3_GUIDE_ALLOW=1` in front: `C3_GUIDE_ALLOW=1 c3c test`.

The hook is a nudge, not a lock. It recognizes the command typed directly. A wrapper such as `time c3c test`, `env c3c test` or `bash -c "c3c test"` goes through. `sh test/hook_test.sh` shows exactly what it matches.
