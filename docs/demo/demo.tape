# Demo tape for the README: bootstrap, then /tron. This is the script, not the GIF.
#
# How to record (the operator does this by hand; it needs a real terminal and Claude auth):
#   1. Install vhs: `brew install vhs`, or see the vhs docs for other platforms.
#   2. Use a clean OS user with Claude Code logged in. `claude` auth is per OS user, so a
#      throwaway $HOME cannot work. Accept the one-off "trust this folder" prompt in
#      `claude` once before recording.
#   3. Run from the repo root:  vhs docs/demo/demo.tape
#   4. The GIF lands at docs/demo/bootstrap-to-tron.gif and must stay at or under 3 MB
#      (tests/test_demo_tape.bats checks it).
#
# Why the clone is hidden: the real clone plus first bootstrap takes minutes, which would
# blow the 20 s on-screen budget. The Hide block does it off-camera; the visible part then
# re-runs the idempotent bootstrap, so the README caption says the demo starts after the clone.
#
# The hidden Type line must begin with the README quickstart command (clone through
# --with-agents); tests/test_demo_tape.bats pins that. Keep visible Sleep values at 20 s
# in total or less. Wait gives up after 15 s unless given an explicit @timeout, hence the
# @ timeouts below. The Wait regexes are tuned by the operator during the render.

Output docs/demo/bootstrap-to-tron.gif
Require git
Require claude

Set Shell "bash"
Set FontSize 16
Set Width 1200
Set Height 675
Set TypingSpeed 40ms
Set Theme "Dracula"

# Off-camera: clone and first bootstrap, then wait for the prompt to come back.
Hide
Type "git clone https://github.com/oneafrikan/the-grid.git ~/.the-grid && bash ~/.the-grid/scripts/bootstrap.sh --with-agents > /dev/null && clear" Enter
Wait+Screen@15m /\$ $/
Show

# On-camera: the idempotent re-run, a skill count, then /tron in Claude Code.
Type "bash ~/.the-grid/scripts/bootstrap.sh --with-agents" Enter
Wait@120s /Bootstrap complete/
Sleep 1s
Type "ls ~/.claude/skills | wc -l" Enter
Sleep 2s
Type "claude" Enter
Sleep 4s
Type "/tron" Enter
Sleep 8s
