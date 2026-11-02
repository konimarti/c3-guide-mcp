#!/bin/sh
# One version everywhere: project.json, the version the server reports, the c3c pin in both workflows, and
# (on a tag build) the tag. Usage: sh test/version_check.sh [tag]
cd "$(dirname "$0")/.." || exit 1
fail=0
pj=$(jq -r .version project.json)
main=$(sed -n 's/.*new_server("c3-guide-mcp", "\([^"]*\)").*/\1/p' src/main.c3)
[ "$pj" = "$main" ] || { echo "project.json says $pj, src/main.c3 says $main"; fail=1; }
ci=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/ci.yml)
rel=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/release.yml)
[ -n "$ci" ] && [ "$ci" = "$rel" ] || { echo "C3C_VERSION differs: ci '$ci', release '$rel'"; fail=1; }
if [ -n "$1" ] && [ "$1" != "v$pj" ]; then echo "tag $1 does not match project.json version $pj"; fail=1; fi
[ "$fail" = 0 ] && echo "versions ok: $pj, c3c $ci"
exit $fail
