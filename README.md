# c3-guide-mcp

An MCP server that teaches an LLM the C3 of today. It answers from the manual, the release notes and the standard library of the installed `c3c`, and checks code with the real compiler.

Most models learned C3 0.6/0.7. In 0.8 type properties became `int::size`, `if` with `else` needs braces, and more. Models write the old forms with confidence. This server gives them something better to look at than their memory.

```
model:  c3_symbol("file::open")  ->  fn File? open(String filename, String mode)
        c3_check(<its code>)     ->  <code>/snippet.c3:1:44: error: if-statements with an 'else'
                                     must use '{ }' even around a single statement.
        (fixes it, checks again) ->  OK: no errors
```

## Tools

| Tool | Answers |
|---|---|
| `c3_search(query)` | the language manual, best sections first |
| `c3_symbol(name)` | exact signature, doc and file:line of a stdlib function, macro, method or type; says so when it does not exist and suggests close names |
| `c3_changes(topic)` | the release-note lines about a topic, newest first |
| `c3_syntax(topic)` | the compiler's lists: attributes, builtins, keywords, type properties, operators |
| `c3_check(code)` | the compiler's diagnostics for a snippet (type-check only, nothing is linked or run) |

Replies of the four docs tools are capped at 3.2 KB, `c3_check` at 4 KB. A server that dumps pages into the context makes the model worse.

## Build and use

Needs [c3c](https://github.com/c3lang/c3c) 0.8.5 (the snapshot and the tests are built for exactly this version; `c3c` must be on `PATH`, or set `C3C`) and [mcp.c3l](https://github.com/konimarti/mcp.c3l) in `deps/mcp.c3l`.

```
git clone https://github.com/konimarti/mcp.c3l deps/mcp.c3l
c3c build c3-guide-mcp -O3          # -> build/c3-guide-mcp
```

Register it in your MCP client as a stdio server. Set `C3C` to the compiler if it is not on `PATH` (only `c3_check` needs it):

```json
{ "mcpServers": { "c3-guide": { "command": "/path/to/build/c3-guide-mcp", "env": { "C3C": "/path/to/c3c" } } } }
```

## How it works

The docs are a snapshot embedded in the binary (`$embed`, 1.8 MB, 7,283 entries). `scripts/gen_corpus.py` builds it from a `c3c` install: `MANUAL.md`, `releasenotes.md`, `c3c --list-*` and `c3c docgen lib/std --json`. Startup takes about 10 ms. A search scans every entry in about 10 ms (BM25), so there is no index to build or keep in sync.

The snapshot belongs to one `c3c` version (printed in its header). After a compiler update:

```
curl -o all.md https://c3-lang.org/all.md      # optional: adds the sections the manual lacks (22 in 0.8.5)
python3 scripts/gen_corpus.py /path/to/c3 all.md && c3c build c3-guide-mcp -O3
```

`c3_check` runs `c3c --trust=none --no-obj` on the snippet in a fresh temp directory, killed after 10 s, output capped at 4 KB. `$exec` does not run (tested, with a positive control). `--trust=none` still allows `$embed`, which with `$echo` can print any file the server can read, so snippets containing `$embed`, `$include` or `$exec` are rejected before they reach the compiler. The server is not a sandbox: run it as a user without secrets.

## Tests

```
C3C=/path/to/c3c python3 test/stdio_test.py   # every tool over stdio, protocol errors, $exec guard
python3 test/limits_test.py                   # hanging and flooding compilers
python3 test/quality_test.py                  # 20 questions, expected answer in the top 3
python3 test/growth_test.py                   # memory over 4,000 calls
python3 test/mutation_test.py                 # breaks the code 8 ways; every break must fail a test (slow)
```

## Limits

- The docs and the compiler do not always agree (the manual says `excuse`, other pages `faultdef`; the compiler accepts both). When they differ, `c3_check` is right.
- Search is keyword based: it finds "Macro vaargs" for "vararg", but not a paraphrase with different words.
- A killed server leaves its temp directory behind; the next `c3_check` removes `c3guide-*` directories older than an hour.
- Only Linux x64 was tested. `c3_check` needs the `timeout` program.
- Tested with `hermes mcp test` and tool calls from a Hermes session; no other client yet.
