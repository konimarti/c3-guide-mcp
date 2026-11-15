# c3-guide-mcp

**A C3 coding companion for your AI assistant.**

It checks code with your compiler, runs your tests and looks up any name in your project, its libraries and the standard library. A model with a shell could grep the stdlib and run `c3c` itself; this does it in one step and with less noise: the exact signature instead of grep hits, only the failing tests instead of the whole log, a hint that names the fix. Signatures come from your `c3c`, the manual and release notes are those of 0.8.6.

One small binary. Any MCP client: Claude Code, Claude Desktop, Cursor, VS Code.

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

Download the binary for your system from [Releases](https://github.com/konimarti/c3-guide-mcp/releases) (on macOS, allow it once: `xattr -d com.apple.quarantine ./c3-guide-mcp`), install [c3c](https://github.com/c3lang/c3c/releases) 0.8.6, and add the server to your client:

```
claude mcp add c3-guide -e C3C=/path/to/c3c -- /path/to/c3-guide-mcp
c3-guide-mcp --setup    # Claude Code: rules in CLAUDE.md and a hook that points c3c test/run to the tools
```

Other clients (Claude Desktop, Cursor) take the usual entry; VS Code uses `"servers"` with `"type": "stdio"`:

```json
{ "mcpServers": { "c3-guide": { "command": "/path/to/c3-guide-mcp", "env": { "C3C": "/path/to/c3c" } } } }
```

Setting it up by hand, and the rules for other assistants: [integrations/claude-code](integrations/claude-code). `c3-guide-mcp --doctor` shows what is in place.

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
