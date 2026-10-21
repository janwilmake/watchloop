# How it works

Two mechanisms carry the whole loop. Neither is something you have to know to run
it — read this when a run looks wrong, or when you want to change it.

## The gate — one `bash` call, no model

```
$ /watchloop
waiting for work - probe every 60s, give up after 40m
17:22Z NO - slots=1, nothing to take; no drafts; linear ready column empty
17:41Z NO - no slot: ram 2.2gb free, 2.5gb per agent, busy=1; 1 draft(s) waiting
load1=1.80 freegb=2.5 diskgb=855 busy=0 slots=1
FEEDBACK: [{"pr":768,"id":5327779919,"who":"a-teammate","state":"MERGED"}]
DRAFTS: [772]
--- woke after 26m ---
```

`gate.sh` answers "is there anything to do?" in one shot and prints either a `NO`
line **with its reason** or a compact context block. It covers capacity, reaps
leaked dev servers, re-checks the PRs it already promoted, finds comments nobody
has answered, and — the part that used to be impossible from a shell — **reads the
Linear ready column directly**, through the
[`agent-codemode`](https://github.com/janwilmake/agent-codemode) CLI.

`agent-codemode` inherits Claude Code's [Linear MCP](https://linear.app/docs/mcp)
OAuth from the Keychain, so the gate queries Linear with **no token, no model and
no cost**.

Run it as `gate.sh --wait` and it blocks until work exists, then exits — and that
exit is what wakes the model. A night with nothing to do costs zero turns instead
of one every five minutes.

## How it tells your comments from its own

Every agent posts through your own `gh`, so every comment on every PR carries
**your** GitHub login. The author field can never separate a person from a
machine. So the loop marks its own instead:

- The loop writes **one comment per PR, its log**, marked `<!-- 🌙 log -->`.
  Every action — a review, a fix pass, a merge of the base, an answer to you — is
  one collapsed entry with a one-line summary, oldest at the top and newest at
  the bottom. `lo-log.sh` is its only writer. Promoting and re-drafting write
  nothing: the draft state is the record.
- An unmarked comment on a PR the loop opened is a person talking to it.
- Its answer is one `human` entry in the log that quotes your comment and names
  its id — `ack:<comment-id>` in the entry's hidden marker — so "already handled"
  is a fact recorded on GitHub, not in a cache that a `/clear` can lose. Nothing
  is answered twice, and nothing is answered never.
- Every comment gets an answer, including the ones that need no work. Silence is
  the one wrong reply.

Set `LO_FEEDBACK_SINCE` to the day you install this. Comments older than it were
written before marking began, so they carry no marker and would all read as
instructions.

## Scheduled jobs — a file in the repo, an allowlist per job

```
$ lo-schedule.sh list
security-weekly   0 7 * * mon   Europe/Amsterdam   next 2026-10-26T06:00Z · last 2026-10-19T06:00Z · done: 3 tickets, #2601
```

A job is `.agents/schedules/<name>.md` in your repo: YAML front matter
(`schedule`, `timezone`, `late`, `model`, `permissions`, `outputs`) and the
prompt as the body. The shape follows GitHub Agentic Workflows. There is no
timer and no cron daemon: the gate already probes every minute, so it asks
`lo-schedule.sh due` on each probe. That is shell and a short Python, no
model.

Three rules keep it safe to leave running:

- **The job is read from `origin/<base>`, never the working tree.** An edit
  nobody merged cannot change what an agent may do.
- **The run is written down before the agent starts.** The state file records
  the run time it was started for, so the next probe never starts it again,
  also when the agent dies. A run that found no free slot inside its `late`
  window is skipped, not caught up.
- **The agent gets an allowlist, not skipped permissions.** `lo-allowlist.sh`
  turns the job's `permissions` into a settings file, and
  `cca --allowlist` runs the agent with it in `dontAsk` mode: a tool call
  outside the list is refused at once and never waits for an answer. The front
  matter parser takes only a small, strict part of YAML; a file it does not
  understand does not run at all, because a deny rule read wrong is a hole.

The agent's last command is `lo-schedule.sh done <name> "<one line>"`, and the
weekly report lists each job's last run with that line.

## When a run looks wrong

[`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) carries the failure modes seen on
real runs — a tick that spawns nothing, `slots` stuck at 0, `mergeable: UNKNOWN`,
a screenshot committed as a file.
