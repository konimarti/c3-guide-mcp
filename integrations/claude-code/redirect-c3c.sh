#!/bin/sh
# Claude Code PreToolUse hook (matcher: Bash). When the model runs `c3c test`, `c3c compile-run`, ... by hand,
# stop the call and tell it to use the c3-guide tools instead: they run the same compiler and add the
# stdlib signature or release note the bare error message lacks.
# `c3c build` and `c3c compile` are let through: producing a binary is a legitimate use.
# Exit code 2 blocks the call and shows stderr to the model.
#
# Only the command itself is looked at (not the rest of the JSON), and only where c3c is the program being
# run: `git commit -m "fix c3c test"` and `echo c3c test` pass. The subcommand is the first word of c3c's
# arguments that is not an option. To run c3c deliberately, put C3_GUIDE_ALLOW=1 in front of it:
#   C3_GUIDE_ALLOW=1 c3c test
payload=$(cat)
if command -v jq >/dev/null 2>&1; then
	cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)
elif command -v python3 >/dev/null 2>&1; then
	cmd=$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)
else
	cmd=$payload   # no JSON parser: look at everything, which can only over-block
fi
[ -n "$cmd" ] || exit 0

# one segment per line (; & | and newlines), tabs as spaces; then: skip VAR=value words and '(' / '{', find
# the program, and for c3c take the first non-option word as the subcommand.
blocked=$(printf '%s\n' "$cmd" | tr '\t' ' ' | tr ';&|(){}`' '\n\n\n\n\n\n\n\n' | awk '
{
	allow = 0; i = 1; n = split($0, w, " ")
	while (i <= n && w[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { if (w[i] == "C3_GUIDE_ALLOW=1") allow = 1; i++ }
	if (i > n || allow) next
	prog = w[i]; gsub(/^["\x27]+|["\x27]+$/, "", prog)
	if (prog !~ /(^|\/)c3c(\.exe)?$/ && prog !~ /^\$\{?C3C\}?$/) next
	for (i = i + 1; i <= n; i++) {
		if (w[i] ~ /^-/) continue
		sub_cmd = w[i]; gsub(/^["\x27]+|["\x27]+$/, "", sub_cmd)
		if (sub_cmd ~ /^(test|compile-run|compile-only|compile-test|run)$/) { print "yes"; exit }
		break
	}
}')

if [ "$blocked" = yes ]; then
	cat >&2 <<'MSG'
Do not run c3c by hand to check or run C3 code. Use the c3-guide MCP tools:
  mcp__c3-guide__c3_check   type-check a snippet (code) or a project/file (path), with hints
  mcp__c3-guide__c3_test    run the @test functions of a project or file, failures only
  mcp__c3-guide__c3_run     build and run a program (args, input)
MSG
	exit 2
fi
exit 0
