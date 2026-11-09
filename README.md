# c3-guide-mcp

**Your AI writes C3 from memory. Its memory is two versions old.**

Models learned C3 0.6 and 0.7. C3 0.8 changed the language. So they write code that does not compile and call functions that do not exist.

c3-guide-mcp gives your assistant the real C3: your compiler, the standard library, the manual. One small binary. Any MCP client: Claude Code, Claude Desktop, Cursor, VS Code.

## Six tools

| Tool | Use it for |
|---|---|
| `c3_lookup` | Any name, wherever it lives: your project, its libraries, the standard library. |
| `c3_check` | Check a snippet, a file or a whole project with the real compiler. |
| `c3_test` | Run the `@test` functions of a project or file; only the failures come back. |
| `c3_run` | Build and run a program, with arguments and stdin. |
| `c3_refs` | Where a name is used, before you change or delete it. |
| `c3_search` | How to do something: the manual, tested example programs, release notes, the compiler's exact lists. |

All of them take `query`, `code` or `path`, and every argument has a default: a call with a missing argument gets a sentence that names the argument to give, not a protocol error. The argument names of earlier releases still work (`name` and `symbol` for `query`, `file` for `path`), a call to one of the old tools (`c3_symbol`, `c3_outline`, ...) is forwarded to its replacement, and an argument a tool does not take is answered with the ones it takes.

### 1. Code is checked by the real compiler

The assistant runs `c3_check` before it shows you code. It gets the compiler's own errors, plus a hint that names the fix.

To check a usage snippet against your own library, give `code` and `path=<project directory>` to `c3_check` or `c3_run`: the snippet is compiled with the project's sources and libraries (`import yourmodule;`), in a scratch directory, nothing is written to the tree. If the snippet has its own `main`, the project's source files that define one are left out.

```
fn void main() { int n = int.sizeof; isz x = 3; }

error: Expected a type here.
Hints:
  `isz` is `sz` since 0.8 (`usz` is unchanged). `c3_check` rewrites it.

0.7 syntax found: 2 mechanical rewrite(s) (.sizeof -> ::size, isz -> sz). The rewritten code:
fn void main() { int n = int::size; sz x = 3; }
--- c3_check of the rewritten code ---
OK: no errors
```

(Output shortened.)

It checks a snippet, a file or a whole project, for this platform or another (`platform: "windows-x64"`, no linking). A snippet can bring helper files along (`files`). Nothing is run. Nothing is written to your tree. Old 0.7 syntax is rewritten with the official C3 tree-sitter grammar, so `int.max` (the type) is told from your variable `x.max`.

`c3_test` and `c3_run` build in a scratch directory and return only what matters: the failing assertions with file and line, or the program's output. `c3_run` takes `args` (one per line), `input` for stdin, `files` for more sources and `opt` for the optimization level.

### 2. A name is looked up once, wherever it lives

`c3_lookup("allocator::free")` answers for the standard library, your project and its libraries in one call. For the standard library it returns the exact signature, source location, a working example, and with `source: true` the implementation:

```
c3_lookup("bits::ctz")

'bits::ctz' does not exist in the standard library of c3c 0.8.6.
'ctz' is a method, called on a value (`x.ctz(...)`), not a function of a module.
It exists on 20 types: char, char[<*>], ichar, ichar[<*>], int, ...
  macro int ctz(char self)  (lib/std/bits.c3:126:16)
```

A name that does not exist says so, and says where it went: another module, a method of a type, a compiler builtin, or a release-note line about the rename. Do not know the name? Describe it: `c3_lookup("get environment variable")`. A description that matches little says so, instead of returning the nearest unrelated names. A type or module (`List`, `std::io::path`) lists its methods or functions.

For your own code give `path` (or just call `c3_check` on the project first and the session remembers it):

```
c3_lookup("new_server", path="/work/app")

In /work/app (1 match):
  deps/mcp.c3l!/src/mcp/types.c3:59  fn Server new_server(String name, String version)
```

The project's `src`, its libraries (`dependency-search-paths`, else `deps`) and `.c3l` archives are read with the C3 grammar; nothing is compiled. The whole standard library (364 files) takes 0.3 seconds. A file the parser cannot fully read is marked incomplete. `c3_lookup(path="src")` with no query lists the declarations of a project, one line each with file and line.

`c3_refs("new_server")` finds every use, read with the grammar so comments and strings are not uses, with the declaration marked. `stdlib: true` searches the installed standard library: how the library itself calls `is_dir`.

### 3. Up to date with the compiler you run

Library signatures, source locations and the lists of attributes, builtins, keywords and type properties are read from your own `c3c`. The manual, the example programs and the release notes are a snapshot of c3c 0.8.5; when your compiler is another release, every manual or release-note reply says so, and the compiler has the last word.

## Install

1. Download the binary for your system from [Releases](https://github.com/konimarti/c3-guide-mcp/releases): Linux x64, macOS arm64 or Windows x64. Unpack it. On macOS, allow it once: `xattr -d com.apple.quarantine ./c3-guide-mcp`. The Linux binary needs glibc 2.34 or newer (Ubuntu 22.04, Debian 12 and later).
2. Install [c3c](https://github.com/c3lang/c3c/releases). Built and tested with **0.8.5**. If you run another version (a newer release or the pre-release), the server reads the standard library signatures from your own `c3c` on the first lookup (about 0.2 s, once), so `c3_lookup` matches the compiler you build with, and so do the syntax lists of `c3_search`. The manual and release notes stay at 0.8.5.

The server finds `c3c` on your `PATH` and in the usual install folders. If your editor uses a short `PATH`, set `C3C=/path/to/c3c`. The search tools work without it.

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

Claude Code and Hermes are tested in real sessions. The other entries follow each client's documented format.

### Make sure the assistant uses it

The server already asks. For Claude Code one command does the rest:

```
c3-guide-mcp --setup --dry-run   # shows what it would do
c3-guide-mcp --setup             # rules block in ~/.claude/CLAUDE.md, the hook script, settings.json if it does not exist
c3-guide-mcp --doctor            # what is in place and what is not (also: your c3c and docs versions)
```

It is safe to repeat. It edits only a marked block of `CLAUDE.md` and its own hook file, never writes through a symbolic link, and never rewrites an existing `settings.json` (it prints the lines to add, and the `claude mcp add` command). By hand, the same in two steps:

- **Rules.** Paste [these lines](integrations/claude-code/CLAUDE.md) into `CLAUDE.md`, or into `AGENTS.md`, Cursor rules or `.github/copilot-instructions.md`.
- **Hook (Claude Code).** When the assistant types `c3c test`, `c3c run`, `c3c compile-run`, `c3c compile-only` or `c3c compile-test`, the hook stops it and names the right tool. `c3c build` still works. It is a nudge, not a lock: wrappers like `time c3c test` get through. Setup steps: [integrations/claude-code](integrations/claude-code).

### What `c3_test` and `c3_run` execute

They run the code they build, in a scratch directory, with a reduced environment on Linux and macOS (`PATH`, `HOME`, the locale and what c3c reads; not your tokens or keys), with a time limit you can set (up to 120 s). This is not a sandbox: a program you run can touch anything your user can. Use it on your own code. `c3_check` never runs anything: it type-checks (a project is not compiled with `cc` or linked), and it refuses a file or project whose `$embed`/`$include` reaches outside the project.

## Good to know

- Signatures come from your `c3c`. If anything still disagrees with the compiler, trust the compiler.
- The tools are for checking, testing and running code. Anything that needs a shell (creating a project, `c3c build` for the binary, running the built app with its own input or working directory) is done with `c3c` directly, and the hook allows it.
- Search matches words, not meaning. `c3_search` also looks in the standard library, so "tcp server socket listen accept" finds `std::net::tcp`; for one function, ask `c3_lookup` by name.
- Tested by hand on Linux x64. CI builds and smoke-tests Linux, macOS and Windows.

## Build from source

You need [c3c](https://github.com/c3lang/c3c) 0.8.5, [c3l](https://github.com/konimarti/c3l) and a C compiler.

```
c3l sync --frozen
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

## More

[Maintaining and releasing](docs/MAINTAINING.md) · [License](LICENSE) · [Third-party notices](NOTICE)
