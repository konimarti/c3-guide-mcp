# c3-guide-mcp

An MCP server that gives an AI assistant accurate knowledge of the C3 language. It answers from the C3 manual, the release notes and the standard library, and checks code with the real `c3c` compiler.

Most models learned C3 0.6/0.7, and C3 0.8 changed a lot (`int::size`, `faultdef`, braces around `if`/`else`, ...). They write the old forms with confidence, and guess standard library functions that do not exist. This server lets them look things up and check their code instead.

```
model:  c3_symbol("read line")  ->  std::io::readline: macro String? readline(Allocator allocator, ...)
        c3_check(<its code>)    ->  <code>/snippet.c3:1:44: error: if-statements with an 'else' must use '{ }' ...
        (fixes it, checks again) -> OK: no errors
```

## What it can do

| Tool | Use |
|---|---|
| `c3_check` | Compile a snippet, a `.c3` file or a whole project and get the compiler's errors, with hints that name the right standard library function or the 0.8 spelling |
| `c3_symbol` | Exact signature and source location of a standard library function, macro or type. Also takes a description (`get environment variable`). Says so when a name does not exist, and suggests the module it moved to or the release that renamed it |
| `c3_search` | Search the manual and a set of tested example programs (files, HashMap, sorting, threads, generics, ...) |
| `c3_examples` | Working code that uses a given standard library function or type |
| `c3_changes` | What changed or was renamed between C3 releases (release notes, newest first) |
| `c3_syntax` | The compiler's own lists of attributes, builtins, keywords, type properties, operators |
| `c3_fix` | Rewrite C3 0.7 syntax to 0.8 where it is mechanical (`int.sizeof` to `int::size`, `isz` to `sz`, ...) and compile the result |
| `c3_outline` | List what a project contains: every top-level function, type, macro and constant with file and line |
| `c3_test` | *Optional.* Run a project's `@test` functions and get the failures without the noise |
| `c3_run` | *Optional.* Build and run a program, at any optimization level `O0`..`O5`, `Os`, `Oz`, with a time limit |

`c3_check` and `c3_run` take code or a `path`; `c3_test` and `c3_outline` take a `path`: a project directory containing `project.json`, or one `.c3` file. Nothing is written into your project.

Replies are kept short on purpose: a few KB each, so they do not flood the model's context.

## Install

1. Download the archive for your system from [Releases](https://github.com/konimarti/c3-guide-mcp/releases) (Linux x64, macOS arm64, Windows x64), check it against `SHA256SUMS`, and unpack it. On macOS, allow the unsigned binary once: `xattr -d com.apple.quarantine ./c3-guide-mcp`. For other platforms see [Build from source](#build-from-source).
2. Install [c3c](https://github.com/c3lang/c3c/releases) **0.8.5**. The documentation inside the server belongs to that release. It is needed for `c3_check`, `c3_fix`, `c3_test` and `c3_run`; the search tools work without it.

The server finds `c3c` on your `PATH`, then in the usual places (`/usr/local/bin`, `/opt/homebrew/bin`, `~/.local/bin`, `~/bin`, `~/c3`, `%LOCALAPPDATA%\c3`). Editors often start tools with a short `PATH`; if it is not found, set `C3C=/path/to/c3c` in the server's environment. If your `c3c` is a different release than the documentation, `c3_symbol` says so.

## Use it in your editor

The server speaks MCP over stdio. Register the binary in your client:

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

Any other MCP client works the same way: command = the binary, optional environment `C3C`. Claude Code and Hermes have been used in real sessions; the other entries follow each client's documented format.

### Make Claude Code use it

The server tells the model to use its tools, and models mostly do. Two things make it reliable:

- **Add a line to your `CLAUDE.md`** (or `AGENTS.md`): [integrations/claude-code/CLAUDE.md](integrations/claude-code/CLAUDE.md).
- **Add the hook** from [integrations/claude-code](integrations/claude-code) to your Claude Code `settings.json` (point it at `redirect-c3c.sh`; it needs `jq` or `python3`). When the model types `c3c test`, `c3c run`, `c3c compile-run` or `c3c compile-only` into the shell, the hook stops it and says which tool to call instead. `c3c build` and `c3c compile` still work. To run c3c yourself, put `C3_GUIDE_ALLOW=1` in front of it.

### Turn on `c3_test` and `c3_run`

These two *run* the code they build, so they are off by default. Start the server with `C3_GUIDE_ALLOW_RUN=1` to enable them:

```
claude mcp add c3-guide -e C3C=/path/to/c3c -e C3_GUIDE_ALLOW_RUN=1 -- /path/to/c3-guide-mcp
```

(or add `"C3_GUIDE_ALLOW_RUN": "1"` to `env` in the JSON above). A program that runs too long is stopped; the limit is set per call (`timeout_s`, at most 120 s). This is not a sandbox: a program you run can read and write whatever your user can, so enable it for your own code, not for untrusted input. `c3_check` never runs anything.

## Good to know

- When the documentation and the compiler disagree, the compiler is right. The tools say so.
- Search matches words, not meaning. It finds "vararg" for "vaargs", but a paraphrase with different words may miss. For a standard library function, asking by name (`c3_symbol readline`) is the most reliable.
- Only Linux x64 has been tested by hand. CI builds and smoke-tests Linux, macOS and Windows.

## Build from source

Needs [c3c](https://github.com/c3lang/c3c) 0.8.5, [c3l](https://github.com/konimarti/c3l), and a C compiler (the C3 grammar parser is C code).

```
c3l sync --frozen                   # fetches the pinned dependency
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

## More

- Updating for a new C3 release, running the tests, adding example programs: [docs/MAINTAINING.md](docs/MAINTAINING.md)
- License: [LICENSE](LICENSE). Third-party material: [NOTICE](NOTICE).
