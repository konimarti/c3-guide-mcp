#!/bin/sh
# One version everywhere: project.json, the version the server reports, the c3c pin in both workflows, the
# mcp.c3l commit (c3l.lock and the release workflow), and (on a tag build) the tag. Usage: sh test/version_check.sh [tag]
cd "$(dirname "$0")/.." || exit 1
fail=0
pj=$(jq -r .version project.json)
grep -q '^const String VERSION = env::PROJECT_VERSION;' src/main.c3 || { echo "src/main.c3 must take VERSION from env::PROJECT_VERSION (project.json is the one place the version is written)"; fail=1; }
[ -n "$pj" ] && [ "$pj" != null ] || { echo "project.json has no version"; fail=1; }
ci=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/ci.yml)
rel=$(sed -n 's/^  C3C_VERSION: \([^ ]*\).*/\1/p' .github/workflows/release.yml)
[ -n "$ci" ] && [ "$ci" = "$rel" ] || { echo "C3C_VERSION differs: ci '$ci', release '$rel'"; fail=1; }
mcp_lock=$(awk -F'\t' '$1=="mcp" {print $7}' c3l.lock | sed 's/^commit://')
mcp_rel=$(sed -n 's/^  MCP_REF: \([0-9a-f]*\).*/\1/p' .github/workflows/release.yml)
[ -n "$mcp_lock" ] && [ "$mcp_lock" = "$mcp_rel" ] || { echo "mcp.c3l differs: c3l.lock '$mcp_lock', release.yml '$mcp_rel'"; fail=1; }
if [ -n "$1" ] && [ "$1" != "v$pj" ]; then echo "tag $1 does not match project.json version $pj"; fail=1; fi
[ "$fail" = 0 ] && echo "versions ok: $pj, c3c $ci"
exit $fail
