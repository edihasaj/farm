#!/usr/bin/env python3
"""Regression tests for farm-resume's resurrect reconciliation.

The bug: a claude/codex session can sit ALIVE-but-idle in a farm pane for days.
Its log mtime goes stale, so after a reboot the recency-window scan drops it and
the pane never comes back. farm-resume must fold in whatever the last pre-reboot
tmux-resurrect snapshot says was running, regardless of log mtime.

Run: python3 tests/test-farm-resume.py   (exit 0 = pass)
"""
import json
import os
import sys
import tempfile
from importlib.machinery import SourceFileLoader

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "farm-resume")
fr = SourceFileLoader("farm_resume", BIN).load_module()

PASS = 0
FAIL = 0


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"ok   {name}")
    else:
        FAIL += 1
        print(f"FAIL {name}")


def pane_line(home, cwd_rel, cmd):
    cwd = os.path.join(home, cwd_rel)
    # mirror tmux-resurrect's tab layout: ...:<pane_current_path>...:<full command>
    return "\t".join(
        ["pane", "farm", "3", "1", "", "1", ": task", f":{cwd}", "1", "node", f":{cmd}"]
    ) + "\n"


OKTAPOD = "019eb6b2-f907-74f1-b497-135951dc1059"
WHISPER = "4fb52b58-78c6-4c26-8bb5-306e7ee2b133"


def write_save(path, lines, mtime):
    with open(path, "w") as f:
        f.write("\n".join(["state\tfarm"]) + "\n")
        f.writelines(lines)
    os.utime(path, (mtime, mtime))


def test_parse():
    with tempfile.TemporaryDirectory() as home:
        os.makedirs(os.path.join(home, "Projects", "oktapod"))
        save = os.path.join(home, "s.txt")
        line = pane_line(
            home, "Projects/oktapod",
            f"node /x/codex resume {OKTAPOD} -c model=gpt-5.5 -c model_reasoning_effort=high",
        )
        write_save(save, [line], 1000)
        old_home = fr.HOME
        fr.HOME = home
        try:
            recs = fr._parse_resume_lines(save)
        finally:
            fr.HOME = old_home
        check("parse: one codex session", len(recs) == 1)
        if recs:
            tool, cwd, sid = recs[0]
            check("parse: tool=codex", tool == "codex")
            check("parse: sid extracted", sid == OKTAPOD)
            check("parse: cwd is pane path not bin path",
                  cwd == os.path.join(home, "Projects", "oktapod"))


def test_parse_fresh_agent():
    """Bare `claude`/`codex` panes (no resume uuid) parse as (tool, cwd, None).

    These are the long-idle fresh agents that used to vanish on reboot: RESUME_RE
    can't match them, so the parser must still surface them with sid=None for the
    caller to resolve against the newest log for cwd.
    """
    with tempfile.TemporaryDirectory() as home:
        for d in ("Projects/chat-sql-nlp", "Projects/reachout", "Projects/idle-shell"):
            os.makedirs(os.path.join(home, d))
        save = os.path.join(home, "s.txt")
        lines = [
            pane_line(home, "Projects/chat-sql-nlp",
                      "claude --dangerously-skip-permissions --model claude-opus-4-8[1m]"),
            pane_line(home, "Projects/reachout",
                      "node /x/.nvm/bin/codex --yolo --model gpt-5.5"),
            pane_line(home, "Projects/idle-shell", "-zsh"),  # plain shell, not an agent
        ]
        write_save(save, lines, 1000)
        old_home = fr.HOME
        fr.HOME = home
        try:
            recs = fr._parse_resume_lines(save)
        finally:
            fr.HOME = old_home
        by_cwd = {os.path.basename(c): (t, s) for (t, c, s) in recs}
        check("fresh: shell pane ignored", "idle-shell" not in by_cwd)
        check("fresh: bare claude surfaced with sid=None",
              by_cwd.get("chat-sql-nlp") == ("claude", None))
        check("fresh: bare codex surfaced with sid=None",
              by_cwd.get("reachout") == ("codex", None))


def test_gap_recovers_idle():
    with tempfile.TemporaryDirectory() as home:
        os.makedirs(os.path.join(home, "Projects", "oktapod"))
        os.makedirs(os.path.join(home, "Projects", "whisper"))
        rdir = os.path.join(home, ".local/share/tmux/resurrect")
        os.makedirs(rdir)
        okta = pane_line(home, "Projects/oktapod", f"node /x/codex resume {OKTAPOD}")
        whis = pane_line(home, "Projects/whisper", f"claude --resume {WHISPER}")
        # pre-reboot save: BOTH panes live
        write_save(os.path.join(rdir, "tmux_resurrect_20260622T002849.txt"),
                   [okta, whis], 1000)
        # reboot gap (>300s), then post-reboot save with only whisper restored
        write_save(os.path.join(rdir, "tmux_resurrect_20260622T114134.txt"),
                   [whis], 1000 + 40000)

        old_home, old_dirs = fr.HOME, fr.RESURRECT_DIRS
        fr.HOME, fr.RESURRECT_DIRS = home, (rdir,)
        try:
            live = fr._resurrect_live()
        finally:
            fr.HOME, fr.RESURRECT_DIRS = old_home, old_dirs
        sids = {s for (_t, _c, s) in live}
        check("gap: idle oktapod recovered from pre-reboot save", OKTAPOD in sids)
        check("gap: whisper present", WHISPER in sids)
        check("gap: deduped across both saves", len(live) == 2)


def test_no_gap_uses_newest_only():
    with tempfile.TemporaryDirectory() as home:
        os.makedirs(os.path.join(home, "Projects", "whisper"))
        rdir = os.path.join(home, ".local/share/tmux/resurrect")
        os.makedirs(rdir)
        whis = pane_line(home, "Projects/whisper", f"claude --resume {WHISPER}")
        okta = pane_line(home, "Projects/whisper", f"node /x/codex resume {OKTAPOD}")
        # two consecutive saves 60s apart (no reboot): older has an extra session
        write_save(os.path.join(rdir, "tmux_resurrect_20260622T120000.txt"),
                   [whis, okta], 2000)
        write_save(os.path.join(rdir, "tmux_resurrect_20260622T120100.txt"),
                   [whis], 2060)
        old_home, old_dirs = fr.HOME, fr.RESURRECT_DIRS
        fr.HOME, fr.RESURRECT_DIRS = home, (rdir,)
        try:
            live = fr._resurrect_live()
        finally:
            fr.HOME, fr.RESURRECT_DIRS = old_home, old_dirs
        sids = {s for (_t, _c, s) in live}
        check("no-gap: only newest save used", sids == {WHISPER})


def test_account_resume_cmd():
    """resume_cmd re-adds the `--work` flag for work-account sessions."""
    cwd = os.path.join(fr.HOME, "Projects", "x")
    check("acct: codex --work placed after binary",
          fr.resume_cmd("codex", cwd, OKTAPOD, None, "work")
          == f"cd ~/Projects/x && codex --work resume {OKTAPOD}")
    check("acct: claude --work placed after binary",
          fr.resume_cmd("claude", cwd, WHISPER, None, "work")
          == f"cd ~/Projects/x && claude --work --resume {WHISPER}")
    check("acct: default account has no --work",
          "--work" not in fr.resume_cmd("codex", cwd, OKTAPOD, None, None))


def test_scan_tags_work_account():
    """A codex session whose log lives under ~/.codex-work is tagged 'work' and
    its resume command carries --work — the account that used to go missing."""
    with tempfile.TemporaryDirectory() as home:
        wdir = os.path.join(home, ".codex-work/sessions/2026/06/28")
        os.makedirs(wdir)
        proj = os.path.join(home, "Projects/secret")
        os.makedirs(proj)
        log = os.path.join(wdir, f"rollout-2026-06-28T00-00-00-{OKTAPOD}.jsonl")
        with open(log, "w") as f:
            f.write(json.dumps({"cwd": proj}) + "\n")
        saved = (fr.HOME, fr.CLAUDE_PROJECT_DIRS, fr.CODEX_SESSION_DIRS,
                 fr.RESURRECT_DIRS)
        fr.HOME = home
        fr.CLAUDE_PROJECT_DIRS = [(os.path.join(home, ".claude/projects"), None)]
        fr.CODEX_SESSION_DIRS = [
            (os.path.join(home, ".codex/sessions"), None),
            (os.path.join(home, ".codex-work/sessions"), "work"),
        ]
        fr.RESURRECT_DIRS = (os.path.join(home, "no-such-dir"),)
        try:
            sessions = fr.scan(72)
        finally:
            (fr.HOME, fr.CLAUDE_PROJECT_DIRS, fr.CODEX_SESSION_DIRS,
             fr.RESURRECT_DIRS) = saved
        rec = [r for r in sessions if r[3] == OKTAPOD]
        check("scan: work-account session found", len(rec) == 1)
        if rec:
            check("scan: tagged as work account", rec[0][6] == "work")
            check("scan: resume cmd carries --work",
                  "codex --work resume" in
                  fr.resume_cmd(rec[0][1], rec[0][2], rec[0][3], rec[0][5], rec[0][6]))


def test_scan_skips_trashed_project():
    """A session whose cwd was moved into the Trash is deliberately closed, so scan
    must not propose `cd ~/.Trash/<proj> && resume` after a reboot."""
    with tempfile.TemporaryDirectory() as home:
        cdir = os.path.join(home, ".codex/sessions/2026/07/07")
        os.makedirs(cdir)
        trashed = os.path.join(home, ".Trash/kiln")
        live = os.path.join(home, "Projects/live")
        os.makedirs(trashed)
        os.makedirs(live)
        for cwd, sid in ((trashed, OKTAPOD), (live, WHISPER)):
            log = os.path.join(cdir, f"rollout-2026-07-07T00-00-00-{sid}.jsonl")
            with open(log, "w") as f:
                f.write(json.dumps({"cwd": cwd}) + "\n")
        saved = (fr.HOME, fr.CLAUDE_PROJECT_DIRS, fr.CODEX_SESSION_DIRS,
                 fr.RESURRECT_DIRS, fr.TRASH)
        fr.HOME = home
        fr.TRASH = os.path.join(home, ".Trash")
        fr.CLAUDE_PROJECT_DIRS = [(os.path.join(home, ".claude/projects"), None)]
        fr.CODEX_SESSION_DIRS = [(os.path.join(home, ".codex/sessions"), None)]
        fr.RESURRECT_DIRS = (os.path.join(home, "no-such-dir"),)
        try:
            sessions = fr.scan(72)
        finally:
            (fr.HOME, fr.CLAUDE_PROJECT_DIRS, fr.CODEX_SESSION_DIRS,
             fr.RESURRECT_DIRS, fr.TRASH) = saved
        sids = {r[3] for r in sessions}
        check("trash: trashed-project session dropped", OKTAPOD not in sids)
        check("trash: live-project session kept", WHISPER in sids)


test_parse()
test_parse_fresh_agent()
test_account_resume_cmd()
test_scan_tags_work_account()
test_scan_skips_trashed_project()
test_gap_recovers_idle()
test_no_gap_uses_newest_only()

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
