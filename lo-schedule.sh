#!/usr/bin/env bash
# lo-schedule.sh — recurring agent jobs, declared as Markdown files in the repo.
#
#   lo-schedule.sh due [--no-fetch]      {"due":[{name,slot}],"running":[…],"errors":[…]}; writes no state
#   lo-schedule.sh list [--no-fetch]     one line per job: schedule, next run, last run and its result
#   lo-schedule.sh report                Markdown lines for the weekly report; empty when no job ran
#   lo-schedule.sh check <file.md>       parse a local job file: errors, the next runs, the allowlist
#   lo-schedule.sh run <name> [--force] [--dry-run]
#                                        start one cca agent for the due run of <name>
#   lo-schedule.sh done <name> "<line>"  the agent's last command: it finished, and what it did
#
# Needs a cca with --allowlist (janwilmake/multiclaude); LO_CCA names another one.
#
# A job is `<LO_SCHEDULES>/<name>.md` on origin/<LO_BASE>, never the working
# tree: an edit nobody merged must not change what an agent may do. The file is
# YAML front matter and a prompt:
#
#   ---
#   schedule: "0 7 * * 1"          # cron: minute hour day-of-month month day-of-week
#   timezone: Europe/Amsterdam     # IANA name; default UTC
#   late: 6h                       # a run may start this long after its time; default 1h
#   model: opus                    # default opus
#   permissions:                   # Claude Code rule syntax; the agent gets these and no more
#     allow:
#       - Read
#       - Bash(git log:*)
#     deny:
#       - Bash(git push:*)
#   outputs:                       # what the job may produce, in words; the prompt names them
#     - Linear tickets labelled security
#   ---
#   The prompt.
#
# The front matter parser takes only the shapes above: `key: value`, block
# lists, and the two levels under `permissions`. Any other line makes the file
# invalid and the job does not run. A permission rule that is read wrong is a
# security bug, so a file that does not parse is never half used.
#
# State: ~/.claude/watchloop/<LO_PREFIX>-schedules.json, one entry per job: the
# run time it was started for (`slot`), the agent slot, and its result. `run`
# writes the slot before it calls cca, so the next check never starts the same
# run again, also when the agent dies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
[ -f "$here/.env" ] && set -a && . "$here/.env" && set +a
REPO="${LO_REPO:-$PWD}"
BASE="${LO_BASE:-dev}"
dir="$HOME/.claude/watchloop"
mkdir -p "$dir/schedules"
STATE="$dir/${LO_PREFIX:-LO}-schedules.json"
CCA="${LO_CCA:-cca}"
LOCK="$dir/schedules/.lock"

core() {
  python3 -I - "$here" "$REPO" "$BASE" "${LO_SCHEDULES:-.agents/schedules}" "$STATE" \
    "${LO_SCHEDULES_FETCH:-900}" "$@" <<'PY'
import datetime as dt, json, os, re, subprocess, sys, time
from zoneinfo import ZoneInfo

here, repo, base, sdir, state_path, fetch_every, mode, *args = sys.argv[1:]
UTC = dt.timezone.utc
now = dt.datetime.now(UTC).replace(second=0, microsecond=0)

def iso(t):
    return t.astimezone(UTC).strftime("%Y-%m-%dT%H:%MZ")

def load_state():
    try:
        return json.load(open(state_path))
    except (FileNotFoundError, ValueError):
        return {}

def save_state(s):
    with open(state_path + ".tmp", "w") as f:
        json.dump(s, f, indent=1, sort_keys=True)
    os.replace(state_path + ".tmp", state_path)

# --- front matter: a strict subset of YAML --------------------------------
KEYS = {"schedule", "timezone", "late", "model", "description", "permissions", "outputs"}

def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v

def scalar(v):
    # A trailing comment, only on a scalar: a rule such as `Bash(echo #1)` keeps its '#'.
    v = v.strip()
    m = re.match(r"""^(["'])(.*?)\1\s*(#.*)?$""", v)
    if m:
        return m.group(2)
    return re.sub(r"\s+#.*$", "", v)

def parse(text):
    errs = []
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return None, None, ["no front matter: the file must start with a --- line"]
    try:
        end = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return None, None, ["front matter has no closing --- line"]
    meta, key, sub = {}, None, None
    for n, raw in enumerate(lines[1:end], start=2):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        ind = len(raw) - len(raw.lstrip(" "))
        s = raw.strip()
        if "\t" in raw[:ind + 1]:
            errs.append(f"line {n}: a tab in the indent"); continue
        if ind == 0:
            m = re.match(r"^([a-z_]+):(.*)$", s)
            if not m or m.group(1) not in KEYS:
                errs.append(f"line {n}: unknown key or shape: {s}"); continue
            key, sub = m.group(1), None
            v = m.group(2).strip()
            if key == "permissions":
                if v and v != "{}":
                    errs.append(f"line {n}: permissions takes an indented block"); continue
                meta[key] = {"allow": [], "deny": []}
            elif key == "outputs":
                if v and v != "[]":
                    errs.append(f"line {n}: outputs takes a block list"); continue
                meta[key] = []
            else:
                meta[key] = scalar(v)
        elif key == "outputs" and s.startswith("- "):
            meta["outputs"].append(unquote(s[2:]))
        elif key == "permissions" and ind == 2 and re.match(r"^(allow|deny):\s*(\[\])?\s*$", s):
            sub = s.split(":")[0]
        elif key == "permissions" and sub and ind >= 4 and s.startswith("- "):
            rule = unquote(s[2:])
            if not rule:
                errs.append(f"line {n}: an empty rule"); continue
            meta["permissions"][sub].append(rule)
        else:
            errs.append(f"line {n}: not understood: {s}")
    body = "\n".join(lines[end + 1:]).strip()
    if "schedule" not in meta:
        errs.append("no schedule")
    if not body:
        errs.append("no prompt under the front matter")
    if not meta.get("permissions", {}).get("allow"):
        errs.append("no permissions.allow: an agent with no allowed tool can do nothing")
    tz = meta.get("timezone") or "UTC"
    try:
        meta["tz"] = ZoneInfo(tz)
    except Exception:
        errs.append(f"unknown timezone {tz}")
    late = meta.get("late") or "1h"
    m = re.match(r"^(\d+)([mhd])$", late)
    if m:
        meta["late_s"] = int(m.group(1)) * {"m": 60, "h": 3600, "d": 86400}[m.group(2)]
    else:
        errs.append(f"late must be like 30m, 6h or 2d, not {late}")
    if "schedule" in meta:
        try:
            meta["cron"] = Cron(meta["schedule"])
        except ValueError as e:
            errs.append(f"schedule: {e}")
    meta.setdefault("model", "opus")
    meta.setdefault("outputs", [])
    return meta, body, errs

# --- cron ------------------------------------------------------------------
DOW = {n: i for i, n in enumerate(["sun", "mon", "tue", "wed", "thu", "fri", "sat"])}
MON = {n: i + 1 for i, n in enumerate(["jan", "feb", "mar", "apr", "may", "jun",
                                       "jul", "aug", "sep", "oct", "nov", "dec"])}

class Cron:
    def __init__(self, spec):
        f = spec.split()
        if len(f) != 5:
            raise ValueError(f"needs 5 fields, has {len(f)}: {spec}")
        self.mins = self.field(f[0], 0, 59)
        self.hours = self.field(f[1], 0, 23)
        self.doms = self.field(f[2], 1, 31)
        self.mons = self.field(f[3], 1, 12, MON)
        self.dows = {d % 7 for d in self.field(f[4], 0, 7, DOW)}
        # Cron's own rule: when both day fields are restricted, a day matches either.
        self.either = not f[2].startswith("*") and not f[4].startswith("*")

    @staticmethod
    def field(spec, lo, hi, names=None):
        def tok(x):
            x = x.lower()
            if names and x in names:
                return names[x]
            if not x.isdigit():
                raise ValueError(f"bad value {x}")
            return int(x)
        out = set()
        for part in spec.split(","):
            step = 1
            if "/" in part:
                part, s = part.split("/", 1)
                if not s.isdigit() or int(s) == 0:
                    raise ValueError(f"bad step {s}")
                step = int(s)
            if part == "*":
                a, b = lo, hi
            elif "-" in part:
                a, b = (tok(x) for x in part.split("-", 1))
            else:
                a = tok(part)
                b = hi if step > 1 else a
            if not lo <= a <= b <= hi:
                raise ValueError(f"{part} is outside {lo}-{hi}")
            out.update(range(a, b + 1, step))
        return out

    def day(self, d):
        if d.month not in self.mons:
            return False
        dom, dow = d.day in self.doms, (d.weekday() + 1) % 7 in self.dows
        return (dom or dow) if self.either else (dom and dow)

    def times(self, d, tz, reverse=False):
        # The run times on one local day. A wall time that does not exist (the
        # spring DST gap) is skipped; an ambiguous one runs once, at its first.
        for h in sorted(self.hours, reverse=reverse):
            for m in sorted(self.mins, reverse=reverse):
                naive = dt.datetime(d.year, d.month, d.day, h, m)
                t = naive.replace(tzinfo=tz)
                if t.astimezone(UTC).astimezone(tz).replace(tzinfo=None) == naive:
                    yield t.astimezone(UTC)

    def prev(self, upto, since, tz):
        """The latest run time in (since, upto], or None."""
        d = upto.astimezone(tz).date()
        while d >= since.astimezone(tz).date():
            if self.day(d):
                for t in self.times(d, tz, reverse=True):
                    if since < t <= upto:
                        return t
            d -= dt.timedelta(days=1)
        return None

    def next(self, after, tz, n=1):
        out, d = [], after.astimezone(tz).date()
        for _ in range(4 * 366):
            if self.day(d):
                for t in self.times(d, tz):
                    if t > after:
                        out.append(t)
                        if len(out) == n:
                            return out
            d += dt.timedelta(days=1)
        return out

# --- the jobs, from origin/<base> -------------------------------------------
def git(*a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)

def fetch():
    stamp = state_path + ".fetched"
    try:
        if time.time() - os.path.getmtime(stamp) < int(fetch_every):
            return None
    except OSError:
        pass
    p = git("fetch", "--quiet", "origin", base)
    if p.returncode != 0:
        return f"git fetch origin {base} failed: {p.stderr.strip()[:120]}"
    open(stamp, "w").close()
    return None

def jobs():
    p = git("ls-tree", "--name-only", f"origin/{base}", f"{sdir.rstrip('/')}/")
    out = {}
    for path in p.stdout.split():
        name = os.path.basename(path)
        if not name.endswith(".md") or name.lower() == "readme.md":
            continue
        text = git("show", f"origin/{base}:{path}").stdout
        out[name[:-3]] = (path, text)
    return out

def alive(agent):
    try:
        pid = int(open(os.path.expanduser(f"~/.claude/agents/{agent}.lock")).read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False

def result(st):
    if not st:
        return "never ran"
    s = st.get("status")
    if s == "dispatched":
        s = "running" if alive(st.get("agent", "")) else "ended without a report"
    note = st.get("note")
    return f"{s}{': ' + note if note else ''}"

def due_slot(meta, st):
    """(slot, why-not). The run that is due now, or None and the reason."""
    prev = meta["cron"].prev(now, now - dt.timedelta(seconds=meta["late_s"]), meta["tz"])
    if prev is None:
        return None, "not due"
    if st and st.get("slot", "") >= iso(prev):
        return None, "already started for " + iso(prev)
    if st and st.get("status") == "dispatched" and alive(st.get("agent", "")):
        return None, "the last run is still going"
    return prev, None

def prompt(name, path, meta, body, slot):
    outs = "\n".join(f"- {o}" for o in meta["outputs"]) or "- nothing outside this run"
    return f"""Run the scheduled job **`{name}`** unattended, for its run of {iso(slot)}. The job is `{path}` on `origin/{base}`; its text is below, so do not read the file.

You run on an allowlist, not with skipped permissions: a tool call that the job's `permissions` do not allow is refused at once, and nobody can approve it. Do not ask for it and do not try a way around it. Do the job with what is allowed, and name what was refused in your report. Nobody is awake, so never stop to ask.

What this job may produce, and nothing else:
{outs}

Never leave a background process behind: keep each pid you start and kill it in a `trap ... EXIT`. Do not run `npm install`.

**Your last command**, also when the job failed: `{here}/lo-schedule.sh done {name} "<one line: what you did, with links>"`. It is allowed for you. It is how the loop knows this run finished.

---

{body}
"""

state = load_state()

if mode in ("due", "list"):
    errors = []
    if "--no-fetch" not in args:
        e = fetch()
        if e:
            errors.append(e)
    due, running, rows = [], [], []
    for name, (path, text) in sorted(jobs().items()):
        meta, body, errs = parse(text)
        if errs:
            errors.append(f"{name}: {errs[0]}")
            rows.append(f"{name:<24} INVALID: {'; '.join(errs)}")
            continue
        st = state.get(name)
        slot, why = due_slot(meta, st)
        if slot:
            due.append({"name": name, "slot": iso(slot)})
        elif why == "the last run is still going":
            running.append(name)
        nxt = meta["cron"].next(now, meta["tz"])
        rows.append(f"{name:<24} {meta['schedule']:<16} {meta['tz'].key:<18} "
                    f"next {iso(nxt[0]) if nxt else 'never'} · "
                    f"{'DUE ' + iso(slot) if slot else 'last ' + (st or {}).get('slot', '-')} · {result(st)}")
    if mode == "due":
        print(json.dumps({"due": due, "running": running, "errors": errors}, separators=(",", ":")))
    else:
        print("\n".join(rows) or f"no jobs in {sdir} on origin/{base}")
        for e in errors:
            print("error:", e)

elif mode == "report":
    week = now - dt.timedelta(days=7)
    for name, st in sorted(state.items()):
        if st.get("slot", "") >= iso(week):
            print(f"  - {name} · {st['slot']} · {result(st)}")

elif mode == "check":
    text = open(args[0]).read()
    meta, body, errs = parse(text)
    if errs:
        print("INVALID:\n  " + "\n  ".join(errs))
        sys.exit(1)
    print(f"schedule  {meta['schedule']} ({meta['tz'].key}), late {meta.get('late') or '1h'}, model {meta['model']}")
    print("next runs " + ", ".join(t.astimezone(meta["tz"]).strftime("%a %d %b %H:%M %Z")
                                   for t in meta["cron"].next(now, meta["tz"], 3)))
    print("allow     " + json.dumps(meta["permissions"]["allow"]))
    print("deny      " + json.dumps(meta["permissions"]["deny"]))
    print("outputs   " + json.dumps(meta["outputs"]))

elif mode == "prepare":
    # Validate one job, pick its slot and print what `run` needs. Writes nothing.
    name, force = args[0], "--force" in args[1:]
    found = jobs().get(name)
    if not found:
        sys.exit(f"lo-schedule: no job {name} in {sdir} on origin/{base}")
    path, text = found
    meta, body, errs = parse(text)
    if errs:
        sys.exit(f"lo-schedule: {name} is invalid: {'; '.join(errs)}")
    slot, why = due_slot(meta, state.get(name))
    if force:
        st = state.get(name)
        if st and st.get("status") == "dispatched" and alive(st.get("agent", "")):
            sys.exit(f"lo-schedule: {name}: the last run is still going")
        slot = now
    if slot is None:
        sys.exit(f"lo-schedule: {name}: {why}")
    print(json.dumps({"slot": iso(slot), "forced": force, "model": meta["model"],
                      "allow": meta["permissions"]["allow"], "deny": meta["permissions"]["deny"],
                      "prompt": prompt(name, path, meta, body, slot)}))

elif mode == "record":
    # record <name> <json>: merge fields into the job's entry; "null" removes it.
    name, patch = args[0], json.loads(args[1])
    if patch is None:
        state.pop(name, None)
    else:
        state[name] = {**state.get(name, {}), **patch}
    save_state(state)

elif mode == "get":
    print(json.dumps(state.get(args[0])))
PY
}

lock() {
  for _ in $(seq 1 100); do mkdir "$LOCK" 2>/dev/null && { trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT; return 0; }
    # A holder that died leaves the lock behind; the work it guards takes seconds.
    [ $(( $(date +%s) - $(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null || date +%s) )) -gt 60 ] && rmdir "$LOCK" 2>/dev/null
    sleep 0.1
  done
  echo "lo-schedule: cannot take $LOCK" >&2; exit 1
}

mode=${1:-list}; shift || true
case "$mode" in
  due|list|report|check) core "$mode" "$@" ;;
  done)
    [ $# -ge 2 ] || { echo 'usage: lo-schedule.sh done <name> "<line>"' >&2; exit 1; }
    lock
    [ "$(core get "$1")" != null ] || { echo "lo-schedule: no run of $1 on record" >&2; exit 1; }
    core record "$1" "$(jq -nc --arg n "$2" --arg t "$(date -u +%Y-%m-%dT%H:%MZ)" \
      '{status: "done", note: ($n | .[0:300]), finished: $t}')"
    echo "lo-schedule: $1 recorded as done" ;;
  run)
    [ $# -ge 1 ] || { echo "usage: lo-schedule.sh run <name> [--force] [--dry-run]" >&2; exit 1; }
    name=$1; shift
    dry=0; for a in "$@"; do [ "$a" = --dry-run ] && dry=1; done
    lock
    job=$(core prepare "$name" "$@")
    settings="$dir/schedules/${LO_PREFIX:-LO}-$name.settings.json"
    rules=()
    while IFS= read -r r; do rules+=(--allow "$r"); done < <(jq -r '.allow[]' <<<"$job")
    while IFS= read -r r; do rules+=(--deny "$r"); done < <(jq -r '.deny[]' <<<"$job")
    # The one rule the loop adds: the agent's report. Only this job's name.
    "$here/lo-allowlist.sh" "$settings" "${rules[@]}" --allow "Bash($here/lo-schedule.sh done $name:*)"
    slot=$(jq -r .slot <<<"$job")
    if [ "$dry" = 1 ]; then
      echo "slot $slot · model $(jq -r .model <<<"$job") · settings $settings"
      jq . "$settings"
      jq -r .prompt <<<"$job"
      exit 0
    fi
    # An older cca hands --allowlist to claude, which refuses it, and the run
    # would be spent on an agent that never started.
    { "$CCA" 2>&1 || true; } | grep -q -- --allowlist \
      || { echo "lo-schedule: $CCA has no --allowlist; update multiclaude" >&2; exit 1; }
    sid=$(uuidgen | tr A-Z a-z)
    before=$(core get "$name")
    # The claim comes first: once the slot is on record, no later check starts
    # this run again, whatever happens to the spawn.
    core record "$name" "$(jq -nc --arg s "$slot" --arg sid "$sid" --arg t "$(date -u +%Y-%m-%dT%H:%MZ)" \
      --argjson f "$(jq .forced <<<"$job")" \
      '{slot: $s, sid: $sid, dispatched: $t, forced: $f, status: "dispatched", agent: null, note: null, finished: null}')"
    "$here/lo-usage.sh" tag "$sid" - --kind 2r >/dev/null 2>&1 || true
    if ! out=$(cd "$REPO" && "$CCA" "$(jq -r .prompt <<<"$job")" --non-interactive \
                 --allowlist "$settings" --model "$(jq -r .model <<<"$job")" --session-id "$sid" 2>&1); then
      # Nothing started, so the run is not spent: put the old entry back.
      core record "$name" "$before"
      echo "lo-schedule: cca failed for $name: $out" >&2
      exit 1
    fi
    agent=$(printf '%s' "$out" | grep -oE '^agent-[0-9]+' | head -1)
    core record "$name" "$(jq -nc --arg a "$agent" '{agent: $a}')"
    echo "lo-schedule: $name started for $slot in ${agent:-an unknown slot}" ;;
  *) sed -n '2,12p' "$0" >&2; exit 1 ;;
esac
