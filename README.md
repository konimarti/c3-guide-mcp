# c3-guide-mcp

C3 changed a lot between 0.6/0.7 and 0.8, which is what most models were trained on. An assistant writing C3 from memory tends to use syntax and functions that no longer exist. c3-guide-mcp gives it the real thing instead: your compiler, the standard library, and the manual, through a small MCP server. Works with Claude Code, Claude Desktop, Cursor, VS Code, and other MCP clients.

## Six tools

| Tool | Use it for |
|---|---|
| `c3_lookup` | Look up a name, in your project, its libraries, or the standard library. |
| `c3_check` | Check a snippet, a file, or a whole project with the real compiler. |
| `c3_test` | Run the `@test` functions of a project or file; only the failures come back. |
| `c3_run` | Build and run a program, with arguments and stdin. |
| `c3_refs` | Find where a name is used, before you change or delete it. |
| `c3_search` | Find how to do something: the manual, example programs, release notes, the compiler's lists. |

Every call takes `query`, `code`, or `path`, with sensible defaults, and a missing argument gets a message naming what to give instead of a protocol error. A few older tool/argument names still work and are forwarded to the current ones.

A couple of things worth knowing:

- **`c3_check` runs the real compiler**, not a guess. For checking a snippet against your own code, give it `code` and `path=<project dir>` and it compiles the snippet with your project's sources and libraries in a scratch directory; nothing is written to your tree.
- **`c3_lookup` answers from your project, its libraries, and the standard library in one call.** A name that doesn't exist gets a short "did you mean" list and, where known, where it went. Library signatures and syntax lists come from your own installed `c3c`, so they match the version you actually build with; the manual and example programs are a snapshot (currently c3c 0.8.6) and say so when your compiler is a different release.

## Install

1. Download the binary for your platform from [Releases](https://github.com/konimarti/c3-guide-mcp/releases) (Linux x64, macOS arm64, or Windows x64) and unpack it. On macOS, allow it once: `xattr -d com.apple.quarantine ./c3-guide-mcp`. The Linux binary needs glibc 2.34+ (Ubuntu 22.04, Debian 12, or newer).
2. Install [c3c](https://github.com/c3lang/c3c/releases). Built and tested against **0.8.6**; a different installed version still works, since `c3_lookup` reads live signatures from your own `c3c` on first use.

The server looks for `c3c` on `PATH` and in the usual install locations. If your editor uses a restricted `PATH`, set `C3C=/path/to/c3c`.

## Add it to your editor

**Claude Code**

```
claude mcp add c3-guide -e C3C=/path/to/c3c -- /path/to/c3-guide-mcp
```

**Claude Desktop** (`claude_desktop_config.json`) and **Cursor** (`~/.cursor/mcp.json`)

```json
{ "mcpServers": { "c3-guide": { "command": "/path/to/c3-guide-mcp", "env": { "C3C": "/path/to/c3c" } } } }
```

**VS Code** (`.vscode/mcp.json`)

```json
{ "servers": { "c3-guide": { "type": "stdio", "command": "/path/to/c3-guide-mcp", "env": { "C3C": "/path/to/c3c" } } } }
```

Claude Code is the one tested in real sessions; the others follow each client's own documented MCP format.

### Getting the assistant to actually use it

```
c3-guide-mcp --setup --dry-run   # shows what it would do
c3-guide-mcp --setup             # adds a rules block to ~/.claude/CLAUDE.md, a hook script, settings.json if missing
c3-guide-mcp --doctor            # reports what is and isn't set up (also your c3c and docs versions)
```

Safe to re-run. It only touches a marked block in `CLAUDE.md` and its own hook file, and never overwrites an existing `settings.json` (it prints what to add instead). By hand: paste [these lines](integrations/claude-code/CLAUDE.md) into `CLAUDE.md`/`AGENTS.md`/Cursor rules/`.github/copilot-instructions.md`, and for the Claude Code hook see [integrations/claude-code](integrations/claude-code) (it redirects `c3c test`/`run`/`compile-*` to the matching tool; `c3c build` still runs directly).

## Good to know

- `c3_test` and `c3_run` actually execute the code they build, in a scratch directory with a reduced environment, under a time limit — but it's not a sandbox. Use them on your own code, not on untrusted input. `c3_check` never runs anything.
- Signatures come from your `c3c`; if something still disagrees with the compiler, trust the compiler.
- `c3_search` matches words, not meaning. For a single known function, `c3_lookup` is more direct.
- Tested by hand on Linux x64. CI builds and smoke-tests Linux, macOS, and Windows.

## Build from source

You need [c3c](https://github.com/c3lang/c3c) 0.8.6 and a C compiler. The C3 and C dependencies (the MCP SDK and the vendored tree-sitter grammar/runtime) are git submodules:

```
git clone --recurse-submodules https://github.com/konimarti/c3-guide-mcp
cd c3-guide-mcp
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

Already cloned without `--recurse-submodules`? Run `git submodule update --init` first.

## More

[Maintaining and releasing](docs/MAINTAINING.md) · [License](LICENSE) · [Third-party notices](NOTICE)
