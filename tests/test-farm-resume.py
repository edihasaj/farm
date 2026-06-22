#!/usr/bin/env python3
"""Regression tests for farm-resume's resurrect reconciliation.

The bug: a claude/codex session can sit ALIVE-but-idle in a farm pane for days.
Its log mtime goes stale, so after a reboot the recency-window scan drops it and
the pane never comes back. farm-resume must fold in whatever the last pre-reboot
tmux-resurrect snapshot says was running, regardless of log mtime.

Run: python3 tests/test-farm-resume.py   (exit 0 = pass)
"""
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


test_parse()
test_gap_recovers_idle()
test_no_gap_uses_newest_only()

print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
