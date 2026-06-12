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
| `bin/farm-resume` | after a reboot/crash, find recently-active claude/codex sessions and `list`/`stage`/`go` to resume each in its pane |
| `bin/farm-risk-snapshot` | throttled safety snapshot before copy-mode entry, keeping mouse copy UX while making tmux crashes recoverable |
| `bin/farm-queue` | file-based task queue (`queue/pending→running→done\|failed`); tasks carry their repo, so one queue feeds many projects |
| `bin/farm-loop` | agent loop: drains the queue through `shipyard -p`; run one per pane for parallel workers |
| `tests/test-farm-loop.sh` | queue + loop test suite (stubbed shipyard; covers claims, failure, retry, concurrency, interrupt) |
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

Tests: `tests/test-farm-loop.sh` (no real agents; `shipyard` is stubbed).

## Push policy (the safety rail)

- restricted repos → `push: manual` — **never** pushes. Stops PR-ready, hands back.
- full-control repos → `push: ask` (or `pr` to fully automate).

## Roadmap (one at a time)

1. Hook: security scan on every diff (wire `hooks/security-scan.sh`).
2. ✅ Queue + agent loop: `farm-queue` backlog drained by `farm-loop` workers.
3. Scheduled farm: cron runs `farm-loop --drain` to empty the backlog unattended.
4. Graph DB of tasks/PRs/agents ("grafiti graph").
