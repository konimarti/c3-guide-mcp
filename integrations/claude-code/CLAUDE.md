## C3

- Look up every name with `c3_lookup` before using it: your project, its libraries and the standard library in one call. It shows the signature and a working example; `source=true` shows the whole implementation, so never read `lib/std` files with `sed` or `cat`. Never guess a signature.
- Check all C3 code with `c3_check` before showing it: `code` for a snippet, `path` for a file or project, both (`code` and `path=<project directory>`) for a snippet that uses the project's own modules. Do not check, test or run code with `c3c` typed by hand; `c3c build` is fine when you need the binary or a step that needs a shell (creating a project, running the built app in its own directory).
- Old syntax or a name not found? `c3_check` rewrites 0.7 syntax, `c3_lookup` says where a name moved, `c3_search` with `scope=changes` has the release notes.
- `c3_lookup` with only a `path` lists what a project contains; `c3_refs` shows where a name is used, and with `rename_to` the exact edits of a rename (use it instead of grep and sed).
- Use `c3_test` and `c3_run` instead of `c3c test` and `c3c run` (`c3_run` takes `args` and `input`).
