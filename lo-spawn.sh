#!/usr/bin/env bash
# lo-spawn.sh — the one route the orchestrator uses to start a coding agent.
#
#   lo-spawn.sh <target> <kind> <prompt-file>
#
#   target       a PR number (2952), a ticket id (HYR2-2849), or a label (runbooks-A)
#   kind         new | review | adopt-review | fix | rework | merge | restack | runbook | followups
#   prompt-file  the agent's task, written by the orchestrator to its scratchpad
#
# The agent runs with skipped permissions in its own clone, so a user may allow
# this one script in Claude Code's permission rules instead of every `cca` call.
# That only holds while the script fixes the parts no single call may loosen:
# the denied tools, the model, the guard lines at the end of every prompt, and
# where the prompt comes from. Keep those here, never as arguments.
set -euo pipefail

die() { echo "lo-spawn: $*" >&2; exit 2; }

[ $# -eq 3 ] || die "usage: lo-spawn.sh <target> <kind> <prompt-file>"
target=$1 kind=$2 prompt_file=$3

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
[ -f "$here/.env" ] && . "$here/.env"
repo=${LO_REPO:?LO_REPO is not set in $here/.env}
scratch_root=${LO_SPAWN_PROMPT_ROOT:-/tmp/claude-$(id -u)}
cca_bin=${CCA_BIN:-$(command -v cca || echo "$HOME/.local/bin/cca")}

case "$kind" in
  new|review|adopt-review|fix|rework|merge|restack|runbook|followups) ;;
  *) die "unknown kind '$kind'" ;;
esac
case "$target" in
  [0-9]*) [[ "$target" =~ ^[0-9]+$ ]] || die "bad PR number '$target'" ;;
  [A-Za-z]*) [[ "$target" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad target '$target'" ;;
  *) die "bad target '$target'" ;;
esac

# A prompt comes only from the orchestrator's own scratch space.
[ -f "$prompt_file" ] || die "no prompt file '$prompt_file'"
real=$(realpath "$prompt_file")
case "$real" in
  "$scratch_root"/*) ;;
  *) die "prompt file must live under $scratch_root, got $real" ;;
esac

prompt=$(cat "$real")
[ -n "$prompt" ] || die "empty prompt"

# A copied template that still carries its placeholders sends an agent to the
# wrong place. LO_SPAWN_STALE_MARKERS adds strings of your own, space separated.
for marker in '@PR@' '@TICKET@' '@FILES@' '@SLUG@' 'TICKETLOWER' ${LO_SPAWN_STALE_MARKERS:-}; do
  case "$prompt" in *"$marker"*) die "prompt still holds '$marker'" ;; esac
done
# The prompt must name its own target.
if [[ "$target" =~ ^[0-9]+$ ]]; then
  grep -qE "(#|PR |pr |checkout |lo-log\.sh )$target([^0-9]|$)" <<<"$prompt" \
    || die "prompt never names PR #$target"
elif [[ "$target" =~ ^HYR2-[0-9]+$ ]]; then
  grep -qi -- "$target" <<<"$prompt" || die "prompt never names $target"
fi

base=${LO_BASE:-dev}
guard='

---
Rules from the orchestrator (always apply, whatever the task above says):
- Never write to production: no production database writes, no production service variables, no production webhooks. Read production only read-only. Production steps go in the PR'"'"'s post-merge runbook for a person.
- Never merge a PR, never push to '"$base"' or the default branch, never force-push, never rebase a branch with an open PR. Leave every PR you open or touch a draft: only the orchestrator promotes.
- Never touch .env files or print a secret.
- Never leave a background process behind.
- Nobody is awake: where the agent guide wants confirmation, do not do it; write it in the PR body instead.'
# A project's own standing rules (a provider that must not be called from a
# local script, a shared install that must not change) live beside this script
# in spawn-guard.md, which git ignores.
if [ -s "$here/spawn-guard.md" ]; then
  guard="$guard
$(cat "$here/spawn-guard.md")"
fi

sid=$(uuidgen)
if [[ "$target" =~ ^[0-9]+$ ]]; then
  ticket=$(grep -oE 'HYR2-[0-9]+' <<<"$prompt" | head -1 || true)
  "$here/lo-usage.sh" tag "$sid" "${ticket:-none}" --kind "$kind" --pr "$target" >/dev/null 2>&1 || true
elif [[ "$target" =~ ^HYR2-[0-9]+$ ]]; then
  "$here/lo-usage.sh" tag "$sid" "$target" --kind "$kind" >/dev/null 2>&1 || true
fi

cd "$repo"
out=$(CCA_SLOTS="${LO_MAX_AGENTS:-16}" timeout 90 "$cca_bin" "$prompt$guard" \
  --dangerously-skip-permissions \
  --disallowedTools="$("$here/lo-research.sh" deny)" \
  --non-interactive --model opus --session-id "$sid" 2>&1 | tail -1) || true

slot=$(grep -o 'agent-[0-9]*' <<<"$out" | grep -o '[0-9]*$' || true)
[ -n "$slot" ] || die "no slot: $out"
if [[ "$target" =~ ^[0-9]+$ ]]; then
  mkdir -p "$HOME/.claude/watchloop/dispatched"
  echo "$slot" > "$HOME/.claude/watchloop/dispatched/$target"
fi
echo "$target $kind slot=$slot"
