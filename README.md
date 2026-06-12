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
| `bin/farm-schedule` | cron wrapper: runs `farm-loop --drain` on an interval so the backlog empties unattended (overlap-locked, logged) |
| `tests/test-farm-loop.sh` | queue + loop test suite (stubbed shipyard; covers claims, failure, retry, concurrency, interrupt) |
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

## Push policy (the safety rail)

- restricted repos → `push: manual` — **never** pushes. Stops PR-ready, hands back.
- full-control repos → `push: ask` (or `pr` to fully automate).

## Roadmap (one at a time)

1. Hook: security scan on every diff (wire `hooks/security-scan.sh`).
2. ✅ Queue + agent loop: `farm-queue` backlog drained by `farm-loop` workers.
3. ✅ Scheduled farm: `farm-schedule` cron-drains the backlog unattended.
4. Graph DB of tasks/PRs/agents ("grafiti graph").
