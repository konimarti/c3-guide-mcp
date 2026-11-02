## C3

- Look up every standard library call with `c3_symbol` before using it. `c3_examples` shows it in use. Never guess a signature.
- Check all C3 code with `c3_check` before showing it: `code` for a snippet, `path` for a file or project. Do not run `c3c` by hand.
- A name or syntax not found? `c3_symbol` says where it moved, `c3_changes` has the release notes, `c3_fix` converts 0.7 syntax.
- Use `c3_outline` to see what a project contains before reading its files.
- If `c3_test` and `c3_run` are listed, use them instead of `c3c test` and `c3c run`.
