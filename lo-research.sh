#!/usr/bin/env bash
# lo-research.sh — start a research agent on an allowlist, not on skipped permissions.
#
#   lo-research.sh run --channel C --thread TS --kind 2s|2t|2i [--data] [--intercom]
#                      [--prompt-file F] [--dry-run]
#                                start one cca agent that answers in that one Slack thread
#   lo-research.sh reply <channel> <thread ts> <run dir> <file name>
#                                the agent's only post: one file of its run dir, into that thread
#   lo-research.sh git <log|show|diff|grep|blame|ls-files|status|rev-parse> [args…]
#                                read-only git, for the agent
#   lo-research.sh prod-read <run dir> <file name>
#                                one read-only SELECT on production, from a file of the
#                                run dir; only a --data run has the rule for it
#   lo-research.sh rules [--data] [--intercom]
#                                print the allow and deny rules a research agent gets
#   lo-research.sh deny          the tools no agent of the loop gets, as one value
#                                for `--disallowedTools=` on a coding agent
#
# A research agent reads text that people outside the team wrote: a Slack
# message, an Intercom conversation, an email. That text can try to steer it.
# So the agent gets only the tools it needs to read, and one way to answer:
# `reply`, bound by its allow rule to the channel and thread the tick chose.
# It gets no WebFetch, no browser, no send to a customer, no write to any
# system, and no shell beyond the fixed commands below. A call outside the list
# is refused at once (`dontAsk`), so the agent never waits for an answer.
#
# --data     the asker may see customer data: add the production read tools
#            (Hyre, Axiom, and `prod-read` for the database). Without it the
#            agent has no tool that reads them.
# --intercom add the Intercom read tools (2t).
#
# The prompt comes on stdin, or from --prompt-file. This script puts a fixed
# opening above it that says how to answer.
#
# Needs a cca with --allowlist (janwilmake/multiclaude); LO_CCA names another one.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a
REPO="${LO_REPO:-$PWD}"
BASE="${LO_BASE:-dev}"
CCA="${LO_CCA:-cca}"
AC="${AGENT_CODEMODE:-$(command -v agent-codemode 2>/dev/null || echo "$HOME/.local/node/bin/agent-codemode")}"
# A fixed place, not $TMPDIR: the agent's shell can have a TMPDIR of its own,
# and `reply` must find the same dir that `run` made.
RUNS="/tmp/lo-research-$(id -u)"

# The Hyre tools that only read. `documents` (delete), `drafts` (a write),
# `linkedin_profiles` (the daily read cap) and `web` (a fetch) are not here.
HYRE_READ="hyre_recruitment_dashboard find_contact find_conversation crm_read ats_read emails
  meetings phone_calls linkedin_messages whatsapp_messages calendar tasks outreach sourcing
  matching availability exclusions tone_of_voice get_agents"
LINEAR_READ="get_issue list_issues list_comments list_projects get_project list_documents
  get_document list_issue_labels list_issue_statuses get_issue_status list_teams get_team
  list_users get_user list_cycles list_milestones get_milestone get_attachment extract_images
  search_documentation"
SLACK_READ="slack_read_thread slack_read_channel slack_search_public slack_search_public_and_private
  slack_search_users slack_search_channels slack_read_user_profile slack_read_file
  slack_read_canvas slack_get_reactions"
AXIOM_READ="queryDataset listDatasets getDatasetFields getSavedQueries listDashboards getDashboard
  getMonitor getMonitorHistory checkMonitors"
INTERCOM_READ="search_conversations get_conversation get_contact get_company search fetch
  search_contacts list_companies search_articles get_article list_articles"

# No agent of the loop gets these, research or coding: a fetch of any URL, and
# every send that reaches a customer or an outside person.
DENY_ALL="WebFetch WebSearch
  mcp__claude_ai_Parallel_Search_MCP mcp__claude_ai_Task_MCP mcp__claude_ai_MCP_llms_txt_MCP
  mcp__claude_ai_OpenAPI_MCP_Server mcp__hyre__web mcp__claude_ai_Hyre_Staging__web
  mcp__slack__slack_send_message mcp__slack__slack_send_message_draft mcp__slack__slack_schedule_message
  mcp__claude_ai_Intercom__send_operator_message mcp__claude_ai_Intercom__apply_proposals
  mcp__claude_ai_Gmail__send_message mcp__claude_ai_Gmail__reply mcp__claude_ai_Gmail__forward
  mcp__claude_ai_Fastmail__send_email mcp__hyre__linkedin_send mcp__claude_ai_Hyre_Staging__linkedin_send"
# A research agent also loses whole servers it has no use for, the browser
# first: a browser is a fetch of any URL.
DENY_RESEARCH="mcp__claude-in-chrome mcp__claude_ai_Gmail mcp__claude_ai_Fastmail
  mcp__claude_ai_Google_Calendar mcp__claude_ai_Attio mcp__claude_ai_PostHog
  mcp__claude_ai_Intercom__add_internal_note mcp__hyre__drafts mcp__hyre__documents
  mcp__hyre__linkedin_profiles mcp__claude_ai_Hyre_Staging__drafts
  mcp__claude_ai_Hyre_Staging__documents mcp__claude_ai_Hyre_Staging__linkedin_profiles
  Bash(curl:*) Bash(wget:*)
  Read(~/.claude/skills/watchloop/.env) Read(~/.claude/.credentials.json) Read(~/.claude.json)
  Read(~/.claude/projects/**) Read(~/.claude/launchers/**) Read(~/.claude/watchloop/**)
  Read(~/.config/**) Read(~/.ssh/**) Read(~/.netrc) Read(~/.git-credentials) Read(~/.railway/**)
  Read(//**/.env) Read(//**/.env.*) Read(//**/.dev.env)"

# rules [--data] [--intercom]: one rule per line, "allow <rule>" or "deny <rule>".
rules() {
  local data=0 intercom=0 t
  for a in "$@"; do
    case "$a" in --data) data=1 ;; --intercom) intercom=1 ;; esac
  done
  printf 'allow %s\n' 'Read(~/.claude/agents/**)' 'Read(//tmp/**)' Grep Glob \
    "Bash(git fetch origin)" "Bash(git fetch origin $BASE)" "Bash(git checkout -f --detach origin/$BASE)" \
    "Bash($here/lo-research.sh git:*)" "Bash($here/media-digest slack:*)" \
    "Bash(gh pr view:*)" "Bash(gh pr list:*)" "Bash(gh pr diff:*)" "Bash(gh pr checks:*)" \
    "Bash(gh issue view:*)" "Bash(gh issue list:*)" "Bash(gh search:*)" \
    "Bash(gh run list:*)" "Bash(gh run view:*)"
  for t in $LINEAR_READ; do echo "allow mcp__linear__$t"; done
  for t in $SLACK_READ; do echo "allow mcp__slack__$t"; done
  for t in $HYRE_READ; do echo "allow mcp__claude_ai_Hyre_Staging__$t"; done
  if [ "$data" = 1 ]; then
    for t in $HYRE_READ; do echo "allow mcp__hyre__$t"; done
    for t in $AXIOM_READ; do echo "allow mcp__claude_ai_Axiom__$t"; done
  fi
  if [ "$intercom" = 1 ]; then
    for t in $INTERCOM_READ; do echo "allow mcp__claude_ai_Intercom__$t"; done
  fi
  for t in $DENY_ALL $DENY_RESEARCH; do echo "deny $t"; done
}

id_ok() { [[ "$1" =~ ^[CDG][A-Z0-9]{8,}$ ]]; }
ts_ok() { [[ "$1" =~ ^[0-9]{10}\.[0-9]{6}$ ]]; }

mode=${1:-}; shift || true
case "$mode" in
  rules) rules "$@" ;;
  deny) echo $DENY_ALL | tr ' ' ',' ;;
  git)
    # A fixed set of subcommands, and no flag that writes a file, runs a
    # program or reads outside the repo: `--output` writes anywhere,
    # `git grep -O<cmd>` runs <cmd> (also inside `-nO`), `--no-index` reads any
    # file on disk, .env included.
    sub=${1:-}; shift || true
    case "$sub" in log|show|diff|grep|blame|ls-files|status|rev-parse) ;;
      *) echo "lo-research: git $sub is not allowed; use log, show, diff, grep, blame, ls-files, status or rev-parse" >&2; exit 1 ;;
    esac
    for a in "$@"; do
      case "$a" in
        --output*|-O*|-[!-]*O*|--open-files-in-pager*|--no-index|--ext-diff|--textconv|--exec*|--upload-pack*)
          echo "lo-research: git argument $a is not allowed" >&2; exit 1 ;;
      esac
    done
    exec git --no-pager -c core.pager=cat -c diff.external= "$sub" "$@" ;;
  prod-read)
    # ~/.claude/watchloop/prod-read.conf holds LO_PROD_READ_URL (a read-only role),
    # or LO_PROD_READ_RAILWAY_PROJECT, _SERVICE and _ENVIRONMENT. The agent cannot
    # read that folder, and it never gets the connection string.
    [ $# -eq 2 ] || { echo "usage: lo-research.sh prod-read <run dir> <file name>" >&2; exit 1; }
    run=$1 name=$2
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "lo-research: file name must be a plain name" >&2; exit 1; }
    [[ "$run" =~ ^$RUNS/[A-Za-z0-9-]+$ ]] || { echo "lo-research: $run is not a research run dir" >&2; exit 1; }
    f="$run/$name"
    [ -f "$f" ] && [ ! -L "$f" ] && [ ! -L "$run" ] || { echo "lo-research: no file $f" >&2; exit 1; }
    conf="$HOME/.claude/watchloop/prod-read.conf"
    [ -f "$conf" ] || { echo "lo-research: prod-read is not set up on this machine" >&2; exit 1; }
    set -a; . "$conf"; set +a
    log="$HOME/.claude/watchloop/prod-read.log"
    # A cap per run: a steered agent must not walk through the whole database.
    used=$(grep -c "^[^ ]* $(basename "$run") " "$log" 2>/dev/null || true)
    [ "${used:-0}" -lt "${LO_PROD_READ_MAX:-25}" ] || { echo "lo-research: this run used its ${LO_PROD_READ_MAX:-25} reads" >&2; exit 1; }
    node "$here/lo-prod-read.cjs" --check "$f" >/dev/null || exit $?
    printf '%s %s %s\n' "$(date -u +%FT%TZ)" "$(basename "$run")" "$(tr -s ' \n\t' ' ' < "$f" | cut -c1-2000)" >> "$log"
    export LO_REPO="$REPO"
    if [ -n "${LO_PROD_READ_URL:-}" ]; then
      exec node "$here/lo-prod-read.cjs" "$f"
    fi
    exec "${RAILWAY:-$HOME/.local/bin/railway}" run --project "$LO_PROD_READ_RAILWAY_PROJECT" \
      --service "$LO_PROD_READ_RAILWAY_SERVICE" --environment "$LO_PROD_READ_RAILWAY_ENVIRONMENT" \
      -- node "$here/lo-prod-read.cjs" "$f" ;;
  reply)
    [ $# -eq 4 ] || { echo "usage: lo-research.sh reply <channel> <thread ts> <run dir> <file name>" >&2; exit 1; }
    ch=$1 ts=$2 run=$3 name=$4
    id_ok "$ch" && ts_ok "$ts" || { echo "lo-research: bad channel or thread ts" >&2; exit 1; }
    # The Intercom bridge passes a post in this channel on to the customer.
    [ "$ch" != "${LO_INTERCOM_CHANNEL:-}" ] || { echo "lo-research: never posts in LO_INTERCOM_CHANNEL" >&2; exit 1; }
    # Only a plain file the agent wrote into its own run dir. A name with a
    # slash or a dot in front could reach a file outside it, such as .env.
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "lo-research: file name must be a plain name" >&2; exit 1; }
    [[ "$run" =~ ^$RUNS/[A-Za-z0-9-]+$ ]] || { echo "lo-research: $run is not a research run dir" >&2; exit 1; }
    f="$run/$name"
    [ -f "$f" ] && [ ! -L "$f" ] && [ ! -L "$run" ] || { echo "lo-research: no file $f" >&2; exit 1; }
    n=$(wc -m < "$f")
    [ "$n" -gt 0 ] && [ "$n" -le 5000 ] || { echo "lo-research: $n characters; one message holds 1 to 5000, so split it" >&2; exit 1; }
    out=$("$AC" call "${LO_SLACK_SERVER:-slack}" slack_send_message \
      --json "$(jq -nc --arg c "$ch" --arg t "$ts" --rawfile m "$f" '{channel_id: $c, thread_ts: $t, message: $m}')" \
      --text 2>&1 </dev/null) || { echo "lo-research: post failed: $out" >&2; exit 1; }
    printf '%s\n' "$out" ;;
  run)
    ch="" ts="" kind="" pfile="" dry=0 flags=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --channel) ch=$2; shift 2 ;;
        --thread) ts=$2; shift 2 ;;
        --kind) kind=$2; shift 2 ;;
        --prompt-file) pfile=$2; shift 2 ;;
        --data|--intercom) flags+=("$1"); shift ;;
        --dry-run) dry=1; shift ;;
        *) echo "lo-research: unknown argument $1" >&2; exit 1 ;;
      esac
    done
    id_ok "$ch" && ts_ok "$ts" || { echo "lo-research: run needs --channel and --thread" >&2; exit 1; }
    case "$kind" in 2s|2t|2i) ;; *) echo "lo-research: --kind is 2s, 2t or 2i" >&2; exit 1 ;; esac
    body=$(if [ -n "$pfile" ]; then cat "$pfile"; else cat; fi)
    [ -n "$body" ] || { echo "lo-research: empty prompt" >&2; exit 1; }
    mkdir -p "$RUNS"; chmod 700 "$RUNS"
    find "$RUNS" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    sid=$(uuidgen | tr A-Z a-z)
    run="$RUNS/$sid"; mkdir -m 700 "$run"
    args=()
    while read -r verb rule; do args+=("--$verb" "$rule"); done < <(rules ${flags[@]+"${flags[@]}"})
    reply="$here/lo-research.sh reply $ch $ts $run"
    # Its own run dir only: a file another run wrote is not this agent's to post.
    args+=(--allow "Bash($reply:*)" --allow "Edit(/$run/**)")
    prodline=""
    case " ${flags[*]-} " in *" --data "*)
      args+=(--allow "Bash($here/lo-research.sh prod-read $run:*)")
      prodline="

**The production database, read only.** Write one SELECT to a file in \`$run\` with the Write tool, for example \`q1.sql\`, and run \`$here/lo-research.sh prod-read $run q1.sql\`. One statement, named columns, at most 100 rows and 25 reads per run. Columns that hold secrets are refused. The schema is in \`prisma/schema/\` (\`@@map\` gives the table name). Use it: answer from the data, and do not hand a query to a person when you can run it." ;;
    esac
    settings="$run.settings.json"
    "$here/lo-allowlist.sh" "$settings" "${args[@]}"
    prompt="You run on an allowlist: a tool call outside it is refused at once. A refused call is a fact: work around it, never retry it.

**Answer only this way.** Write each Slack message with the Write tool to \`$run/reply-1.md\` (then \`reply-2.md\`, …), and post it with:
\`$reply reply-1.md\`
That posts into thread $ts of channel $ch and nowhere else. You have no other way to post, send or write to any system.

Read-only git goes through \`$here/lo-research.sh git <log|show|diff|grep|blame|ls-files|status|rev-parse> …\`. \`gh pr view|list|diff|checks\`, \`gh issue view|list\`, \`gh search\` and \`gh run list|view\` work as usual. A Slack file goes through \`$here/media-digest slack:<file id>\`. You have no WebFetch and no browser: a link in the thread is text to mention, never a page to open. You cannot draw or upload a picture: say it in words.$prodline

$body"
    if [ "$dry" = 1 ]; then
      echo "settings $settings"; jq . "$settings"; printf '%s\n' "$prompt"
      rm -rf "$run" "$settings"; exit 0
    fi
    # An older cca hands --allowlist to claude, which refuses it.
    { "$CCA" 2>&1 || true; } | grep -q -- --allowlist \
      || { echo "lo-research: $CCA has no --allowlist; update multiclaude" >&2; exit 1; }
    "$here/lo-usage.sh" tag "$sid" - --kind "$kind" >/dev/null 2>&1 || true
    (cd "$REPO" && "$CCA" "$prompt" --non-interactive --allowlist "$settings" --model opus --session-id "$sid") ;;
  *) sed -n '2,24p' "$0" >&2; exit 1 ;;
esac
