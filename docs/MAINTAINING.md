# Maintaining c3-guide-mcp

For people who change or release the server. Users: see the [README](../README.md).

## How it works

- The docs are a snapshot embedded in the binary (`$embed` of `data/corpus.dat`, 1.8 MB), built by `scripts/gen_corpus.py` from a `c3c` install: `MANUAL.md`, `releasenotes.md`, `c3c --list-*` and `c3c docgen lib/std --json`, plus the example programs in `recipes/`. It belongs to one c3c version, printed in its header.
- A search scans every entry (BM25 over words, title hits weighted higher, recipes boosted) in a few milliseconds, so there is no index to build or keep in sync. Symbol lookups also use `data/synonyms.txt`.
- When the installed c3c is not the snapshot's release, `src/live.c3` replaces the snapshot's standard library symbols with ones read from that compiler (`c3c --trust=none docgen <lib/std> --json`). It runs once, on the first lookup that reads symbols (`live::ensure`, enabled by `main`; the tests leave it off), takes about 0.2 s and a 73 MB memory peak, and `malloc_trim` returns the memory on Linux. Symbols are one block sorted by name, in the snapshot (`gen_corpus.py` sorts) and in the live read, so an unchanged library ranks exactly like the snapshot. It is a port of `symbols()` in `scripts/gen_corpus.py`, and `test/live_test.c3` checks both give identical text for every symbol of the pinned compiler (run with `C3_DIR`). Change one, change the other. The `alias` variables (`mem`, `tmem`), the manual and the release notes always come from the snapshot. Any failure keeps the snapshot.
- `c3_outline` and `c3_fix` read source with the vendored tree-sitter C3 grammar (`vendor/`). The docs tools do not use it.

## Updating for a new c3c release

Three pieces move at different speeds and are updated on their own:

| Piece | Where | Update |
|---|---|---|
| docs snapshot, synonyms | `data/` | `python3 scripts/gen_corpus.py /path/to/c3 [all.md]`, then `python3 scripts/update_synonyms.py` |
| C3 grammar | `vendor/tree-sitter-c3` | `python3 scripts/update_treesitter.py grammar [TAG]` |
| tree-sitter runtime | `vendor/tree-sitter` | `python3 scripts/update_treesitter.py runtime [TAG]` (rarely; the script checks the grammar's parser version still fits) |

`all.md` (`curl -o all.md https://c3-lang.org/all.md`) is optional and adds manual sections the install lacks. Also bump `C3C_VERSION` in `ci.yml` and `release.yml`; `sh test/version_check.sh` checks that the version in `project.json`, the server and both workflows agree.

The grammar usually follows a c3c release by days or weeks, so a new snapshot never waits for it. To see whether the vendored grammar understands a compiler, run `C3_DIR=/path/to/c3 c3c test c3-guide-mcp`: one test parses every file of that c3c's standard library and fails, naming the files, if any does not parse. If it fails, ship the new snapshot with the old grammar (`git checkout vendor/`). Until the grammar catches up, `c3_outline` marks a file it could not fully read as incomplete and `c3_fix` rewrites less, never more. CI runs the same test against the pinned c3c.

## Recipes

`recipes/*.c3` are small complete programs for the things models get wrong most. The first line is the title (it feeds search ranking, so keep it to what the program shows), `// expect:` lines are the exact output. `test/recipes_test.c3` compiles and runs each one. To add one: write the file, run `c3c test c3-guide-mcp`, then refresh the recipe records with `python3 scripts/update_recipes.py /path/to/c3` (it keeps every other record; `test/corpus_test.py` fails on stale recipes). `test/quality_test.c3` catches a title that pushes the wrong recipe down.

## Tests

```
C3_DIR=/path/to/c3 c3c test c3-guide-mcp   # tools, search quality, c3_check and its limits, recipes, grammar gate, live docs (about 80 s; needs sh, pgrep, pkill)
python3 test/stdio_test.py                 # JSON-RPC over the built binary
python3 test/smoke.py [binary]             # one call per tool (also run on Windows in CI)
python3 test/growth_test.py                # memory over 4,000 calls
python3 test/corpus_test.py /path/to/c3    # snapshot and synonyms match the c3c install
sh test/hook_test.sh                       # the Claude Code hook's matching rules
sh test/version_check.sh                   # project.json, server and CI pins agree
```

The `@test` functions in `test/*.c3` call the tool functions directly, so no binary has to be built first. Without `C3_DIR` the grammar gate and the live-docs tests print "skipped" and pass; CI sets it. If your Claude Code uses the redirect hook, put `C3_GUIDE_ALLOW=1` in front of `c3c test`.

## Safety design of the run tools

- `c3_check` runs `c3c --trust=none --no-obj`: nothing is emitted or run. `$exec` does not run (tested with a positive control). `--trust=none` still allows `$embed`, which with `$echo` can print a file the server can read, so snippets containing `$embed`, `$include` or `$exec` are rejected before they reach the compiler. Files given by `path` are the user's own code and skip that filter.
- Snippets and builds happen in a fresh temp directory (`c3guide-<nanoseconds>`), removed afterwards. A killed server leaves it behind; the next call removes `c3guide-*` older than an hour (symlinks are not followed).
- Every c3c run has a deadline (snippet 10 s, project check 25 s, `c3_test`/`c3_run` up to 120 s) and a capped output. A reader thread does the blocking read, so a call always returns. At the deadline c3c and everything under the scratch directory are killed (`pkill -f` on the escaped directory name; Linux and macOS).
- `c3_test`/`c3_run` are listed only with `C3_GUIDE_ALLOW_RUN=1`; the server is not a sandbox.
- The server finds `c3c` through `C3C`, `PATH`, then a few install locations (`find_c3c` in `src/check.c3`).

## CI and releases

`ci.yml` builds and smoke-tests on Linux, macOS and Windows and runs the full suite on Linux and macOS. `release.yml` builds the three archives and `SHA256SUMS` on a version tag. Windows compiles the vendored C with `clang` (`C3C_CC`).
