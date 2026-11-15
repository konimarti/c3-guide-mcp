# Maintaining c3-guide-mcp

For people who change or release the server. Users: see the [README](../README.md).

## How it works

- Modules import only earlier layers: `util`, `corpus`, `context`, `ts`, `sources` → `proc` → `compiler` → `guard`, `format` → `search`, `outline` → `hints` → `check` → `live` → `tools` → `doctor` → `main`.
- The docs are a snapshot of one c3c release in `data/corpus.dat`, embedded in the binary and built by `scripts/gen_corpus.py`.
- Search scans every entry with BM25 in a few milliseconds, so there is no index to keep in sync.
- `src/context.c3` remembers the last project and the modules the session uses, and ranks their names higher.
- When the installed c3c is another release, `src/live.c3` reads its standard library once (about 0.2 s) and replaces the snapshot's symbols.
- `src/live.c3` is a port of `symbols()` in `scripts/gen_corpus.py`: change one, change the other (`test/live_test.c3` compares them).
- Project lookups and `c3_refs` read source with the vendored tree-sitter grammar, so comments and strings are not uses.
- `src/doctor.c3` holds one table of where each client keeps its files (`SPECS`, with the source of each location and the unconfirmed ones marked); a new client is a row there. `--doctor` only reads.
- `src/compat.c3` maps old argument and tool names to the current ones; a renamed parameter needs an entry in `alias_of`.
- Every ranking rule must hold in general; `test/quality_test.c3`, `test/suggest_test.c3` and `test/sessions_test.c3` pin the cases.

## Updating for a new c3c release

| Piece | Where | Update |
|---|---|---|
| docs snapshot, synonyms | `data/` | `python3 scripts/gen_corpus.py /path/to/c3`, then `python3 scripts/update_synonyms.py` |
| C3 grammar | `vendor/tree-sitter-c3` (submodule) | `python3 scripts/update_treesitter.py grammar [TAG]`, commit the pointer |
| tree-sitter runtime | `vendor/tree-sitter` (submodule) | `python3 scripts/update_treesitter.py runtime [TAG]`, commit the pointer |

- Bump `C3C_VERSION` in `ci.yml` and `release.yml`; `sh test/version_check.sh` checks they agree.
- The version lives only in `project.json` (read as `env::PROJECT_VERSION`); change it only with the maintainer's OK.
- `C3_DIR=/path/to/c3 c3c test c3-guide-mcp` fails if the grammar cannot parse a file of that standard library.
- Files the grammar cannot parse yet are listed in `KNOWN_UNPARSED` in `test/outline_test.c3`; delete an entry when it parses.
- Manual examples the compiler contradicts are corrected by `ERRATA` in `scripts/gen_corpus.py`.

## Recipes

- `recipes/*.c3` are small complete programs: the first line is the title, `// expect:` lines are the exact output.
- After adding one, run the tests and `python3 scripts/update_recipes.py /path/to/c3`.

## Tests

```
C3_DIR=/path/to/c3 c3c test c3-guide-mcp   # all @test functions, about 80 s
python3 test/stdio_test.py                 # JSON-RPC over the built binary
python3 test/smoke.py [binary]             # one call per tool
python3 test/growth_test.py                # memory over 4,000 calls
python3 test/doctor_test.py                # --doctor (clients, paths; Windows and macOS paths in test/doctor_test.c3)
python3 scripts/verify_corpus.py           # code in the corpus compiles
python3 test/corpus_test.py /path/to/c3    # snapshot matches the c3c install
sh test/version_check.sh                   # version and CI pins
```

- Without `C3_DIR` the grammar and live-docs tests are skipped; CI sets it.

## Where the advice is written

- Each tool's `@Desc` is canonical; then update `INSTRUCTIONS` in `src/main.c3`, `integrations/AGENTS.md` and the README.
- The first line of `INSTRUCTIONS` is what an agent sees first; `test/stdio_test.py` pins it.

## Safety

- c3c and the programs it builds run in a fresh scratch directory with a reduced environment (`KEEP_ENV` in `src/proc.c3`).
- `c3_check` runs `c3c --trust=none --no-obj` and type-checks only, so nothing is emitted, linked or run.
- Snippets with `$embed`, `$include` or `$exec` are refused before they reach the compiler.
- `src/guard.c3` reads exactly the files c3c would compile and refuses any compile-time read that leaves the project.
- Source patterns expand as in c3c 0.8.6 (`sources::expand_pattern`): `dir/*` is one folder, `dir/**` and a plain folder name are the whole tree, dot names are skipped.
- A pattern the guard cannot expand like c3c makes it scan the whole tree and say so.
- `c3_test` and `c3_run` of a project are not guarded, because they run the project's own code anyway.
- Every c3c run has a deadline and capped output, and everything under the scratch directory is killed at the deadline.
