# farm — agentic task pipeline + agent orchestration

Tmux farm orchestration for long-running agent panes and queued shipyard work.
Point it at a repo + task; it ships.

> **The ship pipeline is the public OSS tool [shipyard](https://github.com/edihasaj/shipyard)**.
> Shipyard repo configs/profiles live outside farm. Run
> `shipyard list` / `shipyard <repo> <task>`. farm owns tmux tooling
> (`bin/farm*`, `config/tmux.conf`) and queue/loop wrappers only.

## Core idea

Shipyard owns repo profiles and the task pipeline. farm keeps tmux/queue
wrappers around that pipeline and does not store repo configs.

```
shipyard <repo> <task>
  → load shipyard's repo profile
  → resolve task (Jira via atlassian MCP | GitHub issue | free text)
  → plan → branch (repo convention) → implement
  → gates (lint/typecheck/test) → /security-review → /code-review (pass 2)
  → write PR body to /tmp → optional local smoke
  → done gate: stop PR-ready (enterprise) | push+PR (full control) | ask
```

## Layout

| Path | What |
|---|---|
| `bin/farm` | open or attach the 32-pane tmux farm grid for parallel agents |
| `bin/farm-view` | dashboard of repos: branch / dirty / last commit |
| `bin/farm-tabname` | zsh snippet: name iTerm tabs by git repo |
| `bin/farm-reflow` | reshape the grid to the client width (client-resized hook) |
| `bin/farm-inspect` | blow up the focused pane into a fullscreen, scrollable, read-only overlay capped at recent history (`FARM_INSPECT_LINES`, default 10000) — `prefix + i`, `Esc`/`q` to close |
| `bin/farm-resume` | after a reboot/crash, find recently-active claude/codex sessions and `list`/`stage`/`go` to resume each in its pane. Resumes carry forward what each session was using: codex gets its model + reasoning effort (from the rollout's `turn_context`, so no drop to default medium); claude gets its last permission mode (`bypassPermissions` → `--dangerously-skip-permissions`, else `--permission-mode <mode>`), which claude otherwise won't re-apply on `--resume` |
| `bin/farm-risk-snapshot` | throttled safety snapshot before copy-mode entry, keeping mouse copy UX while making tmux crashes recoverable |
| `bin/farm-queue` | file-based task queue (`queue/pending→running→done\|failed`); tasks carry their repo, so one queue feeds many projects |
| `bin/farm-loop` | agent loop: drains the queue through `shipyard -p`; run one per pane for parallel workers |
| `bin/farm-control` | supervisor for one project run: enqueue run-tagged tasks, run ordered pipeline phases, spawn bounded workers into free tmux panes, then `status` / `pause` / `resume` / `stop` from one command |
| `bin/farm-status` | low-latency status for terminal/agents (`--json`) and a phone-friendly local web dashboard (`serve`) |
| `bin/farm-schedule` | cron wrapper: runs `farm-loop --drain` on an interval so the backlog empties unattended (overlap-locked, logged) |
| `tests/test-farm-loop.sh` | queue + loop test suite (stubbed shipyard; covers claims, failure, retry, concurrency, interrupt) |
| `tests/test-farm-control.sh` | controller test suite (run-scoped claims, pause/resume state, scratch tmux worker launch) |
| `tests/test-farm-schedule.sh` | scheduler test suite (line generation, drain, overlap lock — never touches the real crontab) |
| `config/tmux.conf` | tmux config for the farm (Ghostty-tuned: native mouse copy, kitty keys, even grids) |
| `hooks/` | optional always-on checks (e.g. security scan on diff) |

Farm keeps tmux pane scrollback to the most recent 10000 lines for smoother
copy-mode and grid redraws. Mouse drag and `prefix + [` keep the current tmux
copy behavior, and run a throttled `farm-risk-snapshot` first so copy-mode
crashes have a near-current recovery point. `prefix + C` clears the focused
pane's retained history. `Alt+arrow` moves between panes;
`Ctrl+Shift+Left/Right` moves between farm tabs, leaving `Shift+Left/Right`
available to agent composers. Older agent transcripts live in the agent logs;
use `bin/farm-transcripts` instead of tmux scrollback when you need full run
history.

## Install

```sh
# put bin on PATH (or symlink into an existing PATH dir)
export PATH="$HOME/Projects/farm/bin:$PATH"

# use the farm tmux config (symlink so `git pull` keeps it current)
ln -sfn ~/Projects/farm/config/tmux.conf ~/.tmux.conf
```

`bin/farm*` previously lived in `~/Projects/agent-scripts/bin`; they now live
here. Symlinks left behind there so existing PATH/muscle-memory still works.

## Usage

```sh
shipyard list                                      # configured repos
shipyard app-repo ISSUE-123                        # tracker key -> branch -> PR-ready
shipyard api-repo "#86 user profile CRUD"          # GitHub issue -> ask before PR
shipyard web-repo "add webhook retry backoff"      # free-text feature

# paste a link — repo inferred from a GitHub URL:
shipyard https://github.com/example/app/issues/86
shipyard https://github.com/example/api/pull/3483
# Jira URL (repo still given since the key prefix maps to it):
shipyard app-repo https://your.atlassian.net/browse/ISSUE-123
```

## Queue + agent loop

Feed small things in from anywhere; workers drain them through the shipyard
pipeline. State is just files under `queue/` (machine-local, gitignored).

```sh
farm-queue add app-repo ISSUE-123                  # queue a tracker task
farm-queue add api-repo "add retry backoff" focus on perf   # free text + notes
farm-queue add https://github.com/example/app/issues/86     # URL; repo inferred
farm-queue                                         # status summary
farm-queue retry <id> | rm <id> | show <id>

farm-loop --drain     # work until empty, exit (cron-friendly)
farm-loop             # watch mode: keep polling (run inside a farm pane)
farm-loop --once      # single task

# safe end-to-end smoke (scratch repo in sandbox/, gitignored):
farm-queue add sandbox-repo "create NOTES.md with one line" && farm-loop --drain
```

Claims are atomic renames (`pending/ → running/`), so several `farm-loop`
panes can share one queue with no locks and no double-claims. Each task logs
to `queue/logs/<id>.log`; failures land in `failed/` for `retry`. Ctrl-C
mid-task requeues the in-flight task. The loop prepends `farm/bin` and
`~/Projects/agent-scripts/bin` to PATH so headless agents keep full tooling.

`farm-loop` calls `shipyard -p` by default. Override with `FARM_LOOP_SHIP` only
for tests or temporary experiments. Agent/model selection lives in shipyard.

### Unattended (scheduled drain)

Let cron empty the backlog for you — queue all day, ship on a timer:

```sh
farm-schedule install --interval 30   # cron: farm-loop --drain every 30 min
farm-schedule status                  # show the entry + recent run log
farm-schedule remove                  # unschedule
farm-schedule run                     # one drain now (what cron calls)
```

`run` takes an atomic lock so a slow drain never overlaps the next tick, and
sets a sane PATH (cron's is bare) so `shipyard`/`farm-loop` resolve. Output
appends to `queue/logs/scheduler.log`. The crontab entry is tagged with a
`# farm-schedule` marker, so install/remove are idempotent and leave your other
cron lines untouched.

Tests: `tests/test-farm-loop.sh` + `tests/test-farm-schedule.sh` (no real
agents; `shipyard` is stubbed, the real crontab is never touched).

## Supervisor runs

Use `farm-control` when a project needs one visible control point instead of
manually supervising many panes. It creates a run id, tags queued tasks with
that run, and launches either a supervisor or `farm-loop` workers into free
shell panes with `FARM_LOOP_RUN=<id>`, so they only claim work for that project.

```sh
farm-control ship app-repo "ship account deletion end to end"
farm-control status <run-id>
farm-control pause <run-id>     # supervisor/workers stop claiming new work
farm-control resume <run-id>
farm-control stop <run-id>      # set stop flag + Ctrl-C supervisor/workers
farm-control retry <run-id>     # requeue failed/running work for current phase
farm-control logs <run-id> --lines 80
farm-control inspect <run-id> --lines 40
farm-control pane <run-id> all 60
farm-status                         # fastest manual status
farm-status --json                  # agent-friendly status
farm-status serve --host 0.0.0.0 --port 8765   # phone: http://<mac-ip>:8765

# manual fanout: each non-comment line becomes one run-tagged task
farm-control start --agents 4 --task-file /tmp/subtasks.txt app-repo
```

`ship` is the high-level path for "take this project task end to end". It turns
one task into ordered phases:

1. plan
2. implement
3. security review/remediation
4. code review/remediation
5. final gate / PR-ready handoff

The planning phase is asked to write implementation subtasks to
`control/runs/<run-id>.subtasks`, one non-comment line per task. Phase 2 reads
that manifest and fans those subtasks out as run/phase-tagged queue items; if
the planner writes one line, the run stays single-agent. Later phases are not
claimable until earlier phases finish.

When `--agents > 1`, the supervisor tries to launch phase workers into free
tmux shell panes and waits until that phase drains. If no spare pane is
available, it falls back to draining inline. Existing busy panes are left alone.
`pause` is a run-state file honored by the supervisor and workers; in-flight
agent work can finish, but no new queue item is claimed until `resume`. `stop`
sets a stop file and sends Ctrl-C to the recorded supervisor/worker panes.
`retry` clears pause/stop state, requeues failed/running tasks for the current
phase (or `--phase N` / `--all`), and resets stale pane assignments so the run
can be supervised again. `status` shows the supervisor pane, worker panes,
current phase, and queue counts. `logs` tails run task logs from `queue/logs/`;
`pane` captures recent tmux scrollback from the recorded supervisor/workers;
`inspect` combines status, task list, manifest, logs, and pane tails into one
run view. `--agents` is bounded to 1..32. Run state lives under `control/runs/`
(machine-local, gitignored); task logs still live in `queue/logs/`.

Tests: `tests/test-farm-control.sh` + the queue/loop/scheduler tests.

For the lowest-latency check path, use `farm-status`. It reads the farm state
files directly, so agents can run `farm-status --json` without attaching to
tmux, and a phone can open the tiny local dashboard from `farm-status serve`.
The web view auto-refreshes and exposes `/api/runs` for scripted checks.

## Push policy (the safety rail)

- restricted repos → `push: manual` — **never** pushes. Stops PR-ready, hands back.
- full-control repos → `push: ask` (or `pr` to fully automate).

## Roadmap (one at a time)

1. Hook: security scan on every diff (wire `hooks/security-scan.sh`).
2. ✅ Queue + agent loop: `farm-queue` backlog drained by `farm-loop` workers.
3. ✅ Scheduled farm: `farm-schedule` cron-drains the backlog unattended.
4. Graph DB of tasks/PRs/agents ("grafiti graph").
