#!/bin/sh
# One version everywhere: project.json, the version the server reports, the c3c pin in both workflows, and
# (on a tag build) the tag. mcp.c3l's version is the deps/mcp.c3l submodule pointer, which git itself pins.
# Usage: sh test/version_check.sh [tag]
cd "$(dirname "$0")/.." || exit 1
fail=0
pj=$(jq -r .version project.json)
grep -q '^const String VERSION = env::PROJECT_VERSION;' src/main.c3 || { echo "src/main.c3 must take VERSION from env::PROJECT_VERSION (project.json is the one place the version is written)"; fail=1; }
[ -n "$pj" ] && [ "$pj" != null ] || { echo "project.json has no version"; fail=1; }
ci=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/ci.yml)
rel=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/release.yml)
[ -n "$ci" ] && [ "$ci" = "$rel" ] || { echo "C3C_VERSION differs: ci '$ci', release '$rel'"; fail=1; }
if [ -n "$1" ] && [ "$1" != "v$pj" ]; then echo "tag $1 does not match project.json version $pj"; fail=1; fi
[ "$fail" = 0 ] && echo "versions ok: $pj, c3c $ci"
exit $fail
