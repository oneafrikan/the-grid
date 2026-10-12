#!/usr/bin/env python3
"""instincts capture hook (openspec change `instincts`, group 2).

Reads ONE Claude Code hook payload (JSON) on stdin and appends at most one
observation line to

    <state>/instincts/<project-id>/obs-<YYYY>-W<ww>.jsonl     (file 0600, dirs 0700)

Run as `python3 -I capture.py` via `scripts/instincts.sh capture`, on every
PostToolUse / PostToolUseFailure / UserPromptSubmit event of an opted-in project.

Hard guarantees:
  * ALWAYS exits 0 and prints NOTHING on stdout: a hook must never break or slow
    the session. Every failure (bad JSON, unwritable dir, git missing...) is
    swallowed and simply records nothing.
  * Records only what the design allows: a scrubbed Bash command, a project-relative
    file path (never content), or a scrubbed prompt prefix. Tool OUTPUT is never read
    (that is where injection and secrets live).
  * Everything stays in the private state dir outside the repo (lib.py refuses
    paths inside the checkout).

Stdlib only; no network. One process: the only subprocesses are the two or three
`git` calls needed to find the project root and its remote.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# `python3 -I` drops the script directory from sys.path, so add it by hand to import
# the shared lib. Never write bytecode: the import must not drop a __pycache__ into
# the repo tree.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import lib  # noqa: E402  (must follow the sys.path edit above)

# Tools whose calls are recorded; Read/Grep/Glob are noise for habit detection.
TOOLS = frozenset(["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit"])
# Hook events handled, and the `ev` each maps to. PreToolUse is deliberately absent
# (one line per call, from the post event).
EVENTS = {"PostToolUse": "tool", "PostToolUseFailure": "tool", "UserPromptSubmit": "prompt"}

MAX_BASH = 300          # chars of scrubbed command kept
MAX_PROMPT = 240        # chars of scrubbed prompt kept
MAX_RAW = 4000          # raw chars scrubbed per field; bounds work on huge pastes
MAX_FILE_BYTES = 2 * 1024 * 1024   # a week file over this stops growing

# Unattended sessions (loop worker, headless handoff child, cron) are not the
# operator's habits and their prompts are machine-written (SEC11a).
UNATTENDED_ENV = ("GRID_LOOP_HEADLESS", "GRID_AUTOHANDOFF_CHILD", "GRID_CRON")

# A path or command touching one of these drops the whole observation: redaction
# alone is not enough for key material and credential files.
SENSITIVE_RE = re.compile(
    r"\.env(?![A-Za-z0-9])|\.envrc|id_rsa|id_ed25519|id_ecdsa|id_dsa|\.pem(?![A-Za-z0-9])"
    r"|credentials|\.netrc|\.pgpass|\.npmrc|\.pypirc|\.kube(?![A-Za-z0-9])|\.docker/config"
    r"|\.p12(?![A-Za-z0-9])|\.pfx(?![A-Za-z0-9])|\.key(?![A-Za-z0-9])|\.tfstate|secrets?\.ya?ml"
    r"|\.ssh/|\.aws/|\.gnupg|\.git-credentials|\.htpasswd",
    re.I)

# An absolute path that survived the root/HOME rewrite lies outside both. It is kept
# as `(outside)/<last component>` (same rule as relative_path): the habit ("cat /etc/x")
# is data, the directory layout and user names are not. The lookbehind skips URL paths
# (`https://h/a`), `~/x`, `./x`, `a/b` and an already rewritten `(outside)/x`.
_ABS_PATH = re.compile(r"(?<![\w.~$/)@%+-])/(?=[\w.])[^\s'\"`;|&<>()=:]*")


def skip_by_env() -> bool:
    """True when an environment kill switch or unattended-session marker is set."""
    env = os.environ
    if env.get("GRID_INSTINCTS") == "0" or env.get("GRID_INSTINCTS_SKIP") == "1":
        return True
    return any(env.get(name) for name in UNATTENDED_ENV)


def rewrite_paths(text: str, root: str) -> str:
    """Project root -> `.` and $HOME -> `~`, so no absolute path or user name is stored.

    Root goes first (it normally lies under $HOME). The lookahead keeps `/a/repo`
    from eating the front of `/a/repo2`.
    """
    for prefix, repl in ((root, "."), (str(Path.home()), "~")):
        if len(prefix) > 1:
            text = re.sub(re.escape(prefix) + r"(?![\w.-])", repl, text)
    return _ABS_PATH.sub(lambda m: "(outside)/" + m.group(0).rstrip("/").rsplit("/", 1)[-1], text)


def clean(text: str, root: str, limit: int, paths: bool = True) -> str:
    """Rewrite paths, drop sensitive lines, scrub secrets, flatten to one line, cap at `limit`.

    "" means nothing is left to record (every line held a secret keyword with a value,
    a long token-like run, an email, a host, an IP...): the caller records no observation.
    Dropping happens BEFORE redaction because redaction leaks the shape of a secret.
    """
    text = text[:MAX_RAW]
    kept = lib.drop_sensitive_lines(rewrite_paths(text, root) if paths else text)
    return lib.sanitize(lib.scrub(kept), limit) if kept.strip() else ""


def tool_target(tool: str, tool_input: dict) -> str | None:
    """The raw (unscrubbed) command or file path of a tool call, or None if absent."""
    key = {"Bash": "command", "NotebookEdit": "notebook_path"}.get(tool, "file_path")
    value = tool_input.get(key)
    return value if isinstance(value, str) and value else None


def relative_path(path: str, root: str) -> str:
    """Project-relative path; outside the project only the file name is kept."""
    if not os.path.isabs(path):
        return path
    try:
        if Path(path).resolve().is_relative_to(Path(root).resolve()):
            return os.path.relpath(Path(path).resolve(), Path(root).resolve())
    except (OSError, ValueError):
        pass
    return "(outside)/" + os.path.basename(path)


def build_observation(payload: dict, root: str) -> dict | None:
    """Turn a payload into an observation dict, or None when it must not be recorded."""
    event = EVENTS.get(payload.get("hook_event_name"))
    if event is None:
        return None
    obs = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sid": lib.sanitize(str(payload.get("session_id") or ""), 8) or "unknown",
        "ev": event,
    }
    if event == "prompt":
        prompt = payload.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            return None
        prompt = prompt.lstrip()
        # A slash command records only the command word: its arguments are free text.
        if prompt.startswith("/"):
            # `/handoff` is a slash command, not a filesystem path: no path rewrite.
            word = prompt.split()[0]
            obs["in"] = clean(word, root, MAX_PROMPT, paths=not re.fullmatch(r"/[\w:.-]+", word))
        else:
            obs["in"] = clean(prompt, root, MAX_PROMPT)
        return obs if obs["in"] else None

    tool = payload.get("tool_name")
    tool_input = payload.get("tool_input")
    if tool not in TOOLS or not isinstance(tool_input, dict):
        return None
    target = tool_target(tool, tool_input)
    if target is None or SENSITIVE_RE.search(target):
        return None
    # File tools: the relative path only, never the content. Only is_error is read
    # from tool_response; its output is never touched.
    text = target if tool == "Bash" else relative_path(target, root)
    response = payload.get("tool_response")
    cleaned = clean(text, root, MAX_BASH)
    if not cleaned:
        return None
    obs.update({
        "tool": tool,
        "in": cleaned,
        "err": payload["hook_event_name"] == "PostToolUseFailure"
               or (isinstance(response, dict) and bool(response.get("is_error"))),
    })
    return obs


def append_line(project: str, line: str) -> None:
    """Append one line to this ISO week's file (dir 0700, file 0600); skip an over-size file."""
    year, week, _ = datetime.now(timezone.utc).isocalendar()
    base = lib.instincts_state_dir()
    directory = base / project
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    for d in (base, directory):                  # mkdir's mode is masked by umask (and
        os.chmod(d, 0o700)                       # parents get the default), so set it explicitly
    path = directory / f"obs-{year}-W{week:02d}.jsonl"
    data = (line + "\n").encode("utf-8")
    try:
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            return
    except FileNotFoundError:
        # A new week file: this is the moment to age out old ones, so retention does not
        # depend on the analyser ever running.
        size = 0
        lib.prune_old_obs(directory, datetime.now(timezone.utc))
    if size:
        # A full disk can leave an unterminated last line; start on a fresh line so this
        # record is not glued to the fragment (the fragment alone is invalid JSON and is skipped).
        try:
            with open(path, "rb") as fh:
                fh.seek(-1, os.SEEK_END)
                if fh.read(1) != b"\n":
                    data = b"\n" + data
        except OSError:
            pass
    # One O_APPEND write of a short line: concurrent hooks cannot interleave it.
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if os.write(fd, data) < len(data):      # short write (disk full, file-size limit)
            try:
                os.write(fd, b"\n")             # terminate the fragment if there is still room
            except OSError:
                pass
    finally:
        os.close(fd)


def run() -> None:
    raw = sys.stdin.buffer.read()            # always drain stdin, even when skipping
    if skip_by_env():
        return
    payload = json.loads(raw.decode("utf-8", errors="replace"))
    if not isinstance(payload, dict) or payload.get("agent_id"):    # subagent: skip
        return
    cwd = payload.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        return
    root = lib._git(cwd, "rev-parse", "--show-toplevel")
    if not root:
        return
    project = lib.git_project_id(root)       # None without a remote: nothing recorded
    # Repo flag AND the machine-local marker (see lib.learning_enabled).
    if not project or not lib.learning_enabled(root, project):
        return
    obs = build_observation(payload, root)
    if obs is not None:
        append_line(project, json.dumps(obs, ensure_ascii=False, separators=(",", ":")))


def main() -> int:
    try:
        run()
    except Exception:                        # a hook must never fail the session
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
