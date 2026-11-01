#!/bin/sh
# Claude Code PreToolUse hook (matcher: Bash). When the model runs `c3c test`, `c3c compile-run`, ... by hand,
# stop the call and tell it to use the c3-guide tools instead: they run the same compiler and add the
# stdlib signature or release note the bare error message lacks.
# `c3c build` and `c3c compile` are let through: producing a binary is a legitimate use.
# Exit code 2 blocks the call and shows stderr to the model.
cmd=$(cat)
if printf '%s' "$cmd" | grep -Eq '(^|[^[:alnum:]_.-])c3c[^|;&]* (test|compile-run|compile-only|compile-test|run)( |"|\\|$)'; then
	cat >&2 <<'MSG'
Do not run c3c by hand to check or run C3 code. Use the c3-guide MCP tools:
  mcp__c3-guide__c3_check   type-check a snippet (code) or a project/file (path), with hints
  mcp__c3-guide__c3_test    run `c3c test` (if listed; needs C3_GUIDE_ALLOW_RUN=1 on the server)
  mcp__c3-guide__c3_run     build and run a program (same switch)
Use `c3c build` / `c3c compile` through Bash only to produce a binary.
MSG
	exit 2
fi
exit 0
