#!/usr/bin/env python3
"""Call every compose.py writer directly with unsafe project names; each must refuse.

usage: writer_guard_probe.py <agent-factory dir> <compose config> <out dir> [<absolute victim dir>]

load_config() already rejects a bad `project`, so the writers are only reachable with one
through a direct call (another script importing compose, a future caller). This probe is
that direct call: it proves the writers' own containment check holds when validation is
bypassed. Exit 0 when every (writer, name) pair raised SystemExit (a clean refusal);
non-zero, naming the pair, when a writer returned or died with any other exception.

Test helper for tests/test_harness_formats.bats; not part of the product.
"""
import sys
from pathlib import Path

af, cfg, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
sys.path.insert(0, str(af))
import compose  # noqa: E402  (needs the sys.path entry above)

config = compose.load_config(cfg)

# Names that would resolve outside <out>/<name>/, onto <out> itself, or are not one component.
BAD = ["../victim", "..", ".", "a/b", "", "x\n"]
# An absolute name replaces <out> entirely under pathlib's join; the caller passes a victim dir
# (never a system path) so an unguarded writer can only damage the test's own temp tree.
if len(sys.argv) > 4:
    BAD.append(sys.argv[4])

WRITERS = {
    "claude-code": lambda n: compose.write_claude_code(n, config, out),
    "codex": lambda n: compose.write_harness_agents("codex", n, config, out),
    "opencode": lambda n: compose.write_harness_agents("opencode", n, config, out),
    "gemini-cli": lambda n: compose.write_harness_agents("gemini-cli", n, config, out),
    "portable": lambda n: compose.write_portable(n, config, out),
    "paperclip": lambda n: compose.write_paperclip(n, config, out),
    "openclaw-native": lambda n: compose.write_openclaw(n, config, out),
    "openclaw": lambda n: compose.write_project(n, config, out),
}

failed = []
for wname, fn in WRITERS.items():
    for bad in BAD:
        try:
            fn(bad)
        except SystemExit as e:
            if e.code in (0, None):
                failed.append(f"{wname} {bad!r}: exited 0")
        except BaseException as e:  # a traceback is not a refusal
            failed.append(f"{wname} {bad!r}: raised {type(e).__name__}: {e}")
        else:
            failed.append(f"{wname} {bad!r}: returned without refusing")

for line in failed:
    print(line)
sys.exit(1 if failed else 0)
