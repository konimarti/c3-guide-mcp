# c3-guide-mcp

**Your AI writes C3 from memory. Its memory is two versions old.**

Models learned C3 0.6 and 0.7. C3 0.8 changed the language. So they write code that does not compile and call functions that do not exist.

c3-guide-mcp gives your assistant the real C3: your compiler, the standard library, the manual. One small binary. Any MCP client: Claude Code, Claude Desktop, Cursor, VS Code.

## Three things that change the result

### 1. Code is checked by the real compiler

The assistant runs `c3_check` before it shows you code. It gets the compiler's own errors, plus a hint that names the fix.

```
fn void main() { int n = int.sizeof; }

error: 'int' does not have a member or method 'sizeof'.
Hints:
  Type properties are written with `::` since 0.8 (`int::size`, `Foo::name`, `int::max`),
  not `.sizeof`. `c3_fix` rewrites this.
```

(Output shortened.)

It checks a snippet, a file or a whole project. Nothing is run. Nothing is written to your tree.

Old code? `c3_fix` converts 0.7 syntax to 0.8 and compiles the result. It reads code with the official C3 tree-sitter grammar, so it tells the type `int.max` from your variable `x.max`.

### 2. The standard library, exactly

`c3_symbol` returns the exact signature and source location. No guessing.

Ask for something that does not exist, and it says so. Then it says where it went:

```
c3_symbol("allocator::free")

'allocator::free' does not exist in the standard library of c3c 0.8.5_1.
Similar names:
  std::core::mem::alloc::free
  libc::free
  ...
```

(Output shortened. When a release renamed the name, the release-note line is shown too.)

Do not know the name? Describe it: `c3_symbol("get environment variable")`.

Also: `c3_examples` (working code for a function), `c3_search` (the manual and tested example programs), `c3_changes` (what changed between releases).

### 3. A whole project in one call

`c3_outline` lists every function, type, macro and constant in a project, with file and line. The assistant sees what is there before it reads a single file. Third-party libraries are not a blind spot.

```
c3_outline("lib/std/collections/hashmap.c3")

  21   struct Entry
  29   struct HashMap (Printable)
  48   fn HashMap* HashMap.init(&self, Allocator allocator, sz capacity = ..., float load_factor = ...)
  166  fn bool HashMap.is_empty(&map) @inline
  171  fn sz HashMap.len(&map) @inline
  176  fn Value*? HashMap.get_ref(&map, Key key)
```

It reads your dependencies too. Point it at `deps` and filter with `match`:

```
c3_outline("deps", match="new_server")

mcp.c3l!/src/mcp/types.c3
  59   fn Server new_server(String name, String version)
```

It uses the official C3 tree-sitter grammar and compiles nothing. The whole standard library (364 files) takes 0.3 seconds. A file the parser cannot fully read is marked incomplete.

Two more tools are off until you enable them (below): `c3_test` runs your `@test` functions and returns only the failures. `c3_run` builds and runs a program, at any optimization level, with a time limit.

## Install

1. Download the binary for your system from [Releases](https://github.com/konimarti/c3-guide-mcp/releases): Linux x64, macOS arm64 or Windows x64. Unpack it. On macOS, allow it once: `xattr -d com.apple.quarantine ./c3-guide-mcp`. The Linux binary needs glibc 2.34 or newer (Ubuntu 22.04, Debian 12 and later).
2. Install [c3c](https://github.com/c3lang/c3c/releases). Built and tested with **0.8.5**. If you run another version (a newer release or the pre-release), the server reads the standard library signatures from your own `c3c` on the first lookup (about 0.2 s, once), so `c3_symbol` matches the compiler you build with. The manual and release notes stay at 0.8.5.

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

The server already asks. Two steps make it reliable:

- **Rules.** Paste [these lines](integrations/claude-code/CLAUDE.md) into `CLAUDE.md`, or into `AGENTS.md`, Cursor rules or `.github/copilot-instructions.md`.
- **Hook (Claude Code).** When the assistant types `c3c test`, `c3c run`, `c3c compile-run`, `c3c compile-only` or `c3c compile-test`, the hook stops it and names the right tool. `c3c build` still works. It is a nudge, not a lock: wrappers like `time c3c test` get through. Setup steps: [integrations/claude-code](integrations/claude-code).

### Switch on `c3_test` and `c3_run`

They run the code they build, so they are off by default. Start the server with `C3_GUIDE_ALLOW_RUN=1`:

```
claude mcp add c3-guide -e C3C=/path/to/c3c -e C3_GUIDE_ALLOW_RUN=1 -- /path/to/c3-guide-mcp
```

A run is stopped after the time limit you set (up to 120 s). This is not a sandbox: a program you run can touch anything your user can. Use it on your own code. `c3_check` never runs anything.

## Good to know

- Signatures come from your `c3c`. If anything still disagrees with the compiler, trust the compiler.
- Search matches words, not meaning. For a standard library function, ask by name.
- Tested by hand on Linux x64. CI builds and smoke-tests Linux, macOS and Windows.

## Build from source

You need [c3c](https://github.com/c3lang/c3c) 0.8.5, [c3l](https://github.com/konimarti/c3l) and a C compiler.

```
c3l sync --frozen
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

## More

[Maintaining and releasing](docs/MAINTAINING.md) · [License](LICENSE) · [Third-party notices](NOTICE)
