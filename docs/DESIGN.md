# c3-guide-mcp: design decisions

Each entry: decision, why, what it costs.

## Scope
- **Five tools, stateless, capped replies.** Prior art (Context7, MDN, Microsoft Learn: 2 to 3 tools) beats the many-tool style (rust-docs-mcp: 17 tools, a cache step before any query). Cost: no browsing of whole chapters, by design.
- **No code execution, no AST/IR dumps, no project or vendor tools.** Execution is a security hole for a docs server; dumps flood the context.
- **`c3_check` is in.** Docs cannot tell a model whether its code is right; only the compiler can. Optional: without c3c the other four tools work.

## Data
- **Embedded snapshot (`$embed`), generated at dev time by Python.** Fast start, one binary, no path dependence. Cost: stale after a compiler release (regenerate and rebuild); the generator needs Python, users do not.
- **`MANUAL.md` of the install is the base, `all.md` only adds sections the manual lacks (22, marked `[all.md]`).** `all.md` is another revision (`Constset` vs `Constdef`), so it cannot be the base of a snapshot pinned to one compiler.
- **Private and local symbols are dropped** from docgen (1,750 of 7,855): a model must not learn APIs it cannot call.
- **Record format: `\x1e`/`\x1f` separators in one text blob.** No JSON parser at startup, entries are slices into the blob (one allocation for the table).

## Search
- **BM25 scan over all entries per query, no index.** About 10 ms for 7,283 entries; an index would be more code and a second thing to keep in sync. Revisit if the corpus grows 10x.
- **Title hits count extra; stopwords and plural/spelling aliases (`vararg` to `vaarg`) are handled in `query_terms`.** Found by a failing question, not by guessing.
- **`c3_changes` shows only matching bullets, newest version first.** A whole release-note section answered nothing; old and new syntax mixed up.
- **`c3_symbol` says "does not exist"** instead of returning the nearest hit: a model must not assume a guessed API exists (`tnew_array`).

## Safety of `c3_check`
- Fixed command line: `--trust=none` (no `$exec`/`$include`), `--no-obj --no-entry` (nothing emitted or linked), `timeout 10`, output cap 4 KB with kill and `join`. Compiler path only from `C3C`/`PATH`, never from the caller. Snippet in a fresh temp dir, removed after the call, path redacted from the output.
- Tested with a payload that touches a marker file plus a positive control under `--trust=full`.
- Known limit: a compiler that is slower than 10 s is cut, a compiler bomb below that limit is not.

## c3c 0.8.5 findings
- `String.replace` returned corrupted bytes for a 4 KB text without a match; `redact()` in check.c3 replaces it. Worth a bug report upstream.
- `mem::talloc_array` does not zero memory (a counter array started with garbage).
- Segfault on enum/struct/slice parameter defaults (`$p.default_value`): no tool uses them.
- Fault declaration keyword in 0.8.5: stdlib and manual use `excuse` (40 files), release notes call `faultdef` the 0.7.0 syntax; the compiler accepts both.

## Not built (and why)
- Resources and prompts (SDK has none, clients use them unevenly).
- A prebuilt index, fuzzy search, embeddings (no evidence they are needed at this size).
- Runtime download of docs (path and network dependence).
- `mcp::run` as SDK helper: `run_capped` in check.c3 stays local until the SDK has one.

## Open
- Version follow-up: the server warns nothing when `c3c --version` differs from the snapshot.
- `all.md` is a manual download; the generator takes it as an optional argument.
