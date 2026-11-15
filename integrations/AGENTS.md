## C3

Use the c3-guide tools for C3 work: they run the real compiler and read your project, and their answers are short.

- **Names:** `c3_lookup` every name before you use it; one call covers your project, its libraries and the standard library. Never guess a signature.
- **Unknown name:** describe what you need (`c3_lookup "read a line from stdin"`); a missing name gets "did you mean" and where it moved.
- **Library source:** `c3_lookup` with `source=true` shows the implementation; do not read `lib/std` with `sed` or `cat`.
- **Project overview:** `c3_lookup` with only a `path` lists the project's declarations.
- **Check:** `c3_check` every snippet before you show or write it; `path` checks a file or a project. Old 0.7 syntax is rewritten for you.
- **Snippet against a project:** give `code` and `path=<project directory>`; nothing is written to the tree.
- **Other platforms:** `c3_check` with `platform=windows-x64` or `platform=macos-aarch64`.
- **Tests and runs:** `c3_test` and `c3_run` instead of `c3c test` and `c3c run`; `c3_run` takes `args` and `input`.
- **Shell:** use `c3c build` and the shell only for a binary, a new project or running the built app.
- **Renames:** `c3_refs` shows where a name is used; with `rename_to=NEW` it lists the exact edits. Use it instead of grep and `sed -i`.
- **Language questions:** `c3_search` (manual and examples); `scope=changes` when old syntax fails, `scope=syntax` for keywords, attributes and builtins.
- If anything disagrees with the compiler, trust the compiler.
