# shellcheck shell=bash
# aliases.sh - context-mode aliases for Claude Code: claude-dev, claude-research,
# claude-review. Each starts `claude` with one of contexts/{dev,research,review}.md
# added to the system prompt, so a session begins in that working mode.
#
# Opt-in install: add this exact line to ~/.zshrc or ~/.bashrc, then open a new shell:
#
#   source "$HOME/.the-grid/contexts/aliases.sh"
#
# Extra arguments pass straight through:  claude-dev "fix the failing test"
#
# This file is meant to be SOURCED, not executed. It writes no files and only
# defines aliases (a mode whose context file is missing is simply not defined).
#
# Why --append-system-prompt-file and not --system-prompt-file: the latter
# REPLACES Claude Code's own system prompt and drops its built-in guidance;
# the former adds the mode text on top of it.

# --- Resolve the contexts directory (first match wins) -----------------------
# 1. $GRID_DIR/contexts when GRID_DIR is set (same override the-grid scripts use).
# 2. The directory of this file: bash BASH_SOURCE, or zsh's %x prompt escape.
# 3. $HOME/.the-grid/contexts.
# Variables are prefixed _grid_ctx_ and unset at the end so sourcing leaves
# nothing behind in the user's shell.
_grid_ctx_dir=""
if [ -n "${GRID_DIR:-}" ]; then
  _grid_ctx_dir="$GRID_DIR/contexts"
else
  _grid_ctx_src=""
  if [ -n "${BASH_VERSION:-}" ]; then
    _grid_ctx_src="${BASH_SOURCE[0]:-}"
  elif [ -n "${ZSH_VERSION:-}" ]; then
    # shellcheck disable=SC2296  # zsh-only %x escape (path of the file being sourced); bash cannot parse it
    _grid_ctx_src="${(%):-%x}"
  fi
  if [ -n "$_grid_ctx_src" ] && [ -f "$_grid_ctx_src" ]; then
    # cd + pwd makes the path absolute, so the aliases work from any cwd.
    _grid_ctx_dir="$(cd "$(dirname "$_grid_ctx_src")" 2>/dev/null && pwd)"
  fi
  [ -n "$_grid_ctx_dir" ] || _grid_ctx_dir="$HOME/.the-grid/contexts"
fi

# --- Define one alias per context file that exists ---------------------------
# shellcheck disable=SC2139  # the directory is expanded at definition time on purpose (aliases must not depend on cwd or on _grid_ctx_dir surviving)
[ -f "$_grid_ctx_dir/dev.md" ] && alias claude-dev="claude --append-system-prompt-file \"$_grid_ctx_dir/dev.md\""
# shellcheck disable=SC2139  # see above
[ -f "$_grid_ctx_dir/research.md" ] && alias claude-research="claude --append-system-prompt-file \"$_grid_ctx_dir/research.md\""
# shellcheck disable=SC2139  # see above
[ -f "$_grid_ctx_dir/review.md" ] && alias claude-review="claude --append-system-prompt-file \"$_grid_ctx_dir/review.md\""

unset _grid_ctx_dir _grid_ctx_src
