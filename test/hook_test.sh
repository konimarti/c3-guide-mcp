#!/bin/sh
# The hook blocks hand-run c3c check/test/run commands and nothing else. Usage: sh test/hook_test.sh
hook="$(dirname "$0")/../integrations/claude-code/redirect-c3c.sh"
fail=0
check() {   # expected exit code, command
	json=$(jq -n --arg c "$2" '{tool_input:{command:$c}}')
	printf '%s' "$json" | sh "$hook" >/dev/null 2>&1
	got=$?
	if [ "$got" != "$1" ]; then echo "FAIL (want $1, got $got): $2"; fail=1; fi
}
# blocked
check 2 'c3c test'
check 2 'c3c compile-run a.c3'
check 2 'c3c -O3 run'
check 2 '/opt/c3/c3c test c3-guide-mcp'
check 2 "$(printf 'c3c\ttest')"
check 2 '$C3C test'
check 2 '"$C3C" test'
check 2 'C3C=/x/c3c c3c test'
check 2 'cd x && c3c compile-only a.c3'
check 2 'echo hi; c3c test'
check 2 'c3c.exe test'
# allowed
check 0 'git commit -m "fix c3c test"'
check 0 'echo c3c test'
check 0 'c3c compile a.c3 -o run'
check 0 'c3c build'
check 0 'c3c --version'
check 0 'ls'
check 0 'grep -r "c3c run" docs'
check 0 'C3_GUIDE_ALLOW=1 c3c test'
check 0 'C3C=/x/c3c C3_GUIDE_ALLOW=1 c3c test c3-guide-mcp'
[ "$fail" = 0 ] && echo "hook_test: all ok"
exit $fail
