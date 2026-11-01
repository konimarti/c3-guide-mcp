## C3

- Look up every C3 standard library call with `c3_symbol` (and `c3_examples` for how it is used) before using it.
- Check C3 with `c3_check` (`code` for a snippet, `path` for a project or file), never by running `c3c` yourself. If `c3_test` / `c3_run` are listed, use them instead of `c3c test` / `c3c compile-run`.
- When 0.7 syntax fails, run `c3_fix`, then `c3_changes`.
