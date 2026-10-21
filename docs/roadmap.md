# Roadmap

Shipped today: the **Claude Code** target is built and wired live.
`compose.py --target` also accepts `openclaw`, `openclaw-native`, `paperclip`,
`codex`, `gemini-cli`, `opencode` and `portable` (single-file personas, committed
under `dist/personas/`). Skills, subagents and rule packs reach Codex CLI, OpenCode
and Gemini CLI through opt-in `harness:<name>` manifest entries
([harnesses.md](harnesses.md)); Cursor gets rule packs only
(`scripts/rules.py emit --harness cursor`), not an agent target.

Not built, or not yet verified — tracked in [Issues](https://github.com/oneafrikan/the-grid/issues):

| Direction | Status |
|---|---|
| Real-install smoke tests of the Codex, OpenCode and Gemini CLI targets | Planned; the vendor docs were read, not exercised ([harnesses.md](harnesses.md)) |
| Amp | Blocked — custom-agent mechanism needs verifying first |
| OpenSpec **stores** (cross-repo planning) | Open decision, deliberately not adopted |

The compose model is a multi-target compiler: one source (the OpenClaw 5-file
identity model — SOUL/IDENTITY/AGENTS/USER/MEMORY + skills) emitting to
different runtimes. Adding a target means writing an emitter, not re-authoring
any agent.

Model routing across providers (OpenRouter and friends) is a live question, not
a built feature — see [model-selection.md](model-selection.md) for the
current price/capability picture and the open evidence gaps in it.
