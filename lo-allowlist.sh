#!/usr/bin/env bash
# lo-allowlist.sh — write a Claude Code settings file that holds an allowlist.
#
#   lo-allowlist.sh <out.json> [--allow RULE]... [--deny RULE]...
#
# A RULE is in Claude Code permission rule syntax: `Read`, `Bash(git log:*)`,
# `mcp__linear__list_issues`. The file sets `defaultMode` to `dontAsk`: a tool
# call that no allow rule covers is refused at once, never asked. Nobody is
# awake to answer a prompt, and a refused call is a fact the agent can work
# around, where a prompt is a stall.
#
# Hand the file to `cca --allowlist <out.json>` in place of
# `--dangerously-skip-permissions`. cca adds its own Stop hook to a copy of it.
# Deny rules win over allow rules, in Claude Code itself.
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: lo-allowlist.sh <out.json> [--allow RULE]... [--deny RULE]..." >&2; exit 1; }
out=$1; shift
allow='[]'; deny='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --allow) allow=$(jq -c --arg r "$2" '. + [$r]' <<<"$allow"); shift 2 ;;
    --deny)  deny=$(jq -c --arg r "$2" '. + [$r]' <<<"$deny"); shift 2 ;;
    *) echo "lo-allowlist.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done
jq -n --argjson a "$allow" --argjson d "$deny" \
  '{permissions: {defaultMode: "dontAsk", allow: ($a | unique), deny: ($d | unique)}}' > "$out.tmp"
mv "$out.tmp" "$out"
