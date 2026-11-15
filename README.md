# c3-guide-mcp

**A C3 coding companion for your AI assistant.**

- Checks code with your compiler and adds a hint that names the fix.
- Runs your tests and returns only the failures.
- Looks up any name in your project, its libraries and the standard library.
- Signatures come from your `c3c`; the manual and release notes are those of 0.8.6.

A model with a shell could grep the stdlib and run `c3c` itself. This does it in one step, with less noise.

One small binary for any MCP client: Claude Code, Claude Desktop, Cursor, VS Code.

## Tools

| Tool | Use it for |
|---|---|
| `c3_lookup` | A name: signature, location, source. |
| `c3_check` | Compile a snippet, file or project. |
| `c3_test` | Run `@test` functions; failures only. |
| `c3_run` | Build and run with arguments and stdin. |
| `c3_refs` | Where a name is used. |
| `c3_search` | Manual, examples, release notes. |

- `c3_check` with `code` and `path=<project>` compiles a snippet against your project, without touching it.
- A missing name gets "did you mean" and, if known, where it went.

## Install

Download the binary from [Releases](https://github.com/konimarti/c3-guide-mcp/releases), install [c3c](https://github.com/c3lang/c3c/releases) 0.8.6, and add the server to your client:

```
claude mcp add c3-guide -e C3C=/path/to/c3c -- /path/to/c3-guide-mcp
c3-guide-mcp --setup    # Claude Code: rules in CLAUDE.md and a hook that points c3c test/run to the tools
```

Other clients take the usual entry; VS Code uses `"servers"` with `"type": "stdio"`:

```json
{ "mcpServers": { "c3-guide": { "command": "/path/to/c3-guide-mcp", "env": { "C3C": "/path/to/c3c" } } } }
```

Setting it up by hand, and the rules for other assistants: [integrations/claude-code](integrations/claude-code). `c3-guide-mcp --doctor` shows what is in place.

## Good to know

- `c3_test` and `c3_run` execute what they build; this is not a sandbox, so use them on your own code.
- `c3_check` never runs anything.
- If anything disagrees with the compiler, trust the compiler.

## Build from source

You need [c3c](https://github.com/c3lang/c3c) 0.8.6 and a C compiler:

```
git clone --recurse-submodules https://github.com/konimarti/c3-guide-mcp
cd c3-guide-mcp
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

## More

[Maintaining and releasing](docs/MAINTAINING.md) · [License](LICENSE) · [Third-party notices](NOTICE)
