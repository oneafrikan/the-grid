#!/usr/bin/env bash
# bootstrap-user.sh: per-user LLM workstation setup. Run AS the target user (no sudo).
#
# Brings a fresh Linux account (written for Ubuntu 24.04 headless, bash login shell)
# to a working LLM environment: uv + a data-science venv, nvm + Node, Claude Code,
# herdr, the gh CLI, shared Claude rules, the openspec CLI, and the-grid itself.
# Everything lands under $HOME. The one thing it cannot do is install system
# packages: the operator does that once per machine (step 1 prints the exact line).
#
# Works piped, so an operator can run it for a user without that user reading the file:
#   sudo -iu USER bash -s -- --name "Full Name" --machine Laptop --channels Telegram < scripts/bootstrap-user.sh
# For that reason it never relies on its own file location ($0 / BASH_SOURCE).
#
# Usage:
#   bash bootstrap-user.sh [--name NAME] [--machine NAME] [--channels TEXT] [--dry-run] [-h]
#
#   --name      operator name   -> agent-factory/user.yaml  "operator"
#   --machine   machine label   -> agent-factory/user.yaml  "machine"
#   --channels  contact channels-> agent-factory/user.yaml  "channels"
#               (user.yaml is seeded ONLY if it does not exist; never overwritten)
#   --dry-run   print what would happen (PLAN lines); change nothing
#   -h, --help  this text
#
# Env overrides (all optional):
#   GRID_DIR          the-grid clone location        (default: ~/.the-grid)
#   GRID_REPO_URL     the-grid clone URL             (default: public GitHub repo)
#   RULES_REPO_URL    claude-rules clone URL         (default: public GitHub repo)
#   NVM_VERSION       nvm tag to install             (default: pinned below)
#   GH_VERSION        gh release to install          (default: pinned below)
#
# Idempotent: every step probes first (command -v / dir exists / marker present) and
# logs SKIP when already done. A second run changes nothing.
# Each step logs one line:  [n/10] DONE|SKIP|PLAN|FAIL: message
#
# Whole script lives in main() and is invoked on the LAST line with stdin redirected
# from /dev/null: bash reads a piped script incrementally, so any child process
# (installer, git) reading stdin would otherwise swallow the rest of this file.

set -euo pipefail

# Download scratch dir. Script-level (not local to main) because the EXIT trap fires after
# main() returns, when a local would be gone and `set -u` would abort with "TMP: unbound".
TMP=""
cleanup() { [ -z "${TMP:-}" ] || rm -rf "$TMP"; }
trap cleanup EXIT

# ---- pins (verified 2026-11-11; see PR description) --------------------------------
# nvm v0.40.8: published 2026-09-21. v0.41.0 existed but was < 2 weeks old.
NVM_VERSION_DEFAULT="v0.40.8"
# gh 2.103.3: published 2026-10-26; linux_amd64 tarball + checksums file in the release.
GH_VERSION_DEFAULT="2.103.3"
NODE_MIN="20.19.0"   # the-grid's openspec skills need Node >= 20.19.0
APT_PKGS=(git curl python3 python3-venv build-essential mosh)
DS_PKGS=(pandas numpy scipy scikit-learn matplotlib jupyter duckdb polars)
MARK_BEGIN="# >>> the-grid bootstrap-user >>>"
MARK_END="# <<< the-grid bootstrap-user <<<"
TOTAL=10

usage() {
  cat <<'EOF'
usage: bootstrap-user.sh [--name NAME] [--machine NAME] [--channels TEXT] [--dry-run] [-h]

Per-user LLM workstation setup. Run as the target user (never root, no sudo).
  --name      operator name      (seeds agent-factory/user.yaml if absent)
  --machine   machine label      (same)
  --channels  contact channels   (same)
  --dry-run   print PLAN lines only; change nothing
  -h, --help  this text

Piped form (operator running it for another user):
  sudo -iu USER bash -s -- --name "Full Name" --machine Laptop --channels Telegram < bootstrap-user.sh
EOF
}

# ---- logging -----------------------------------------------------------------------
log()  { printf '[%s/%s] %s: %s\n' "$1" "$TOTAL" "$2" "$3"; }
die()  { printf 'bootstrap-user.sh: %s\n' "$*" >&2; exit 1; }

# vge A B: true if version A >= version B (GNU sort -V; present on Ubuntu).
vge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

# yaml_quote: emit a YAML double-quoted scalar (miniyaml reads JSON-style escapes).
yaml_quote() {
  local s="$1"
  case "$s" in *$'\n'*|*$'\r'*) die "newline in a --name/--machine/--channels value" ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

main() {
  local NAME="" MACHINE="" CHANNELS="" DRY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)     [ $# -ge 2 ] || die "--name needs a value";     NAME="$2"; shift 2 ;;
      --machine)  [ $# -ge 2 ] || die "--machine needs a value";  MACHINE="$2"; shift 2 ;;
      --channels) [ $# -ge 2 ] || die "--channels needs a value"; CHANNELS="$2"; shift 2 ;;
      --dry-run)  DRY=1; shift ;;
      -h|--help)  usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done

  # Refuse root: everything here is per-user, and the Claude installer itself refuses sudo.
  [ "$(id -u)" -ne 0 ] || die "refusing to run as root; run as the target user (sudo -iu USER ...)"
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME is unset or not a directory"
  [ "$(uname -s)" = Linux ] || die "Linux only (written for Ubuntu 24.04)"
  [ "$DRY" = 1 ] && echo "== DRY RUN: nothing will be changed =="

  local GRID="${GRID_DIR:-$HOME/.the-grid}"
  local GRID_URL="${GRID_REPO_URL:-https://github.com/oneafrikan/the-grid.git}"
  local RULES_URL="${RULES_REPO_URL:-https://github.com/oneafrikan/claude-rules.git}"
  local NVM_TAG="${NVM_VERSION:-$NVM_VERSION_DEFAULT}"
  local GHV="${GH_VERSION:-$GH_VERSION_DEFAULT}"
  local LOCAL_BIN="$HOME/.local/bin"
  local NVM_HOME="${NVM_DIR:-$HOME/.nvm}"
  local VENV="$HOME/.venvs/ds"
  local RULES="$HOME/.claude-rules"
  local STAMP_DIR="$HOME/.local/state"
  local STAMP="$STAMP_DIR/the-grid-bootstrap-user.head"
  local summary=() preflight_fail=0

  # Later steps need what earlier steps install, within this one process.
  export PATH="$LOCAL_BIN:$PATH"

  # Scratch dir for downloads: real runs only (a dry run must create nothing), removed on exit.
  # Created here, not lazily in a helper: $(...) would run a helper in a subshell and lose TMP.
  if [ "$DRY" = 0 ]; then TMP="$(mktemp -d)"; fi
  # fetch URL DEST: download over https; fail loudly.
  fetch() { curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"; }

  # ---- 1. preflight: system packages (operator installs these) ------------------------
  local missing=() p
  if command -v dpkg >/dev/null 2>&1; then
    for p in "${APT_PKGS[@]}"; do
      dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
  else
    # No dpkg (not Debian/Ubuntu): fall back to checking the commands we need.
    for p in git curl python3; do command -v "$p" >/dev/null 2>&1 || missing+=("$p"); done
  fi
  if [ "${#missing[@]}" -eq 0 ]; then
    log 1 SKIP "system packages present (${APT_PKGS[*]})"
  else
    log 1 FAIL "missing system packages: ${missing[*]}"
    echo "    Ask the machine operator to run:  sudo apt-get install -y ${missing[*]}"
    if [ "$DRY" = 1 ]; then preflight_fail=1; else exit 1; fi
  fi

  # ---- 2. uv + data-science venv ----------------------------------------------------
  if command -v uv >/dev/null 2>&1; then
    log 2 SKIP "uv already installed ($(uv --version 2>/dev/null || echo '?'))"
  elif [ "$DRY" = 1 ]; then
    log 2 PLAN "install uv: curl -fsSL https://astral.sh/uv/install.sh -> sh (UV_NO_MODIFY_PATH=1, into $LOCAL_BIN)"
  else
    fetch https://astral.sh/uv/install.sh "$TMP/uv-install.sh"
    # UV_NO_MODIFY_PATH=1: the installer must not edit rc files; step 10 owns that.
    UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$LOCAL_BIN" sh "$TMP/uv-install.sh"
    command -v uv >/dev/null 2>&1 || die "uv installed but not found on PATH"
    log 2 DONE "uv installed ($(uv --version))"; summary+=("uv")
  fi
  if [ -x "$VENV/bin/python" ]; then
    log 2 SKIP "data-science venv exists ($VENV)"
  elif [ "$DRY" = 1 ]; then
    log 2 PLAN "uv venv $VENV; uv pip install ${DS_PKGS[*]}"
  else
    mkdir -p "$HOME/.venvs"
    uv venv "$VENV"
    uv pip install --python "$VENV/bin/python" "${DS_PKGS[@]}"
    log 2 DONE "venv $VENV with ${DS_PKGS[*]}"; summary+=("venv ~/.venvs/ds")
  fi

  # ---- 3. nvm + Node LTS (>= NODE_MIN) ----------------------------------------------
  if [ -s "$NVM_HOME/nvm.sh" ]; then
    log 3 SKIP "nvm already installed ($NVM_HOME)"
  elif [ "$DRY" = 1 ]; then
    log 3 PLAN "install nvm $NVM_TAG from raw.githubusercontent.com/nvm-sh/nvm/$NVM_TAG/install.sh (PROFILE=/dev/null)"
  else
    fetch "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_TAG/install.sh" "$TMP/nvm-install.sh"
    # PROFILE=/dev/null: nvm's installer must not edit rc files; step 10 owns that.
    PROFILE=/dev/null bash "$TMP/nvm-install.sh"
    log 3 DONE "nvm $NVM_TAG installed"; summary+=("nvm $NVM_TAG")
  fi
  # best_node: newest nvm-managed node dir satisfying NODE_MIN (prints version like v22.1.0).
  best_node() {
    local d v best=""
    for d in "$NVM_HOME"/versions/node/v*; do
      [ -d "$d" ] || continue
      v="${d##*/v}"
      if vge "$v" "$NODE_MIN" && { [ -z "$best" ] || vge "$v" "${best#v}"; }; then best="v$v"; fi
    done
    printf '%s' "$best"
  }
  local node_v; node_v="$(best_node)"
  if [ -n "$node_v" ]; then
    log 3 SKIP "nvm-managed node $node_v >= $NODE_MIN present"
  elif [ "$DRY" = 1 ]; then
    log 3 PLAN "nvm install --lts; assert node >= $NODE_MIN"
  else
    # nvm.sh is not safe under set -eu; relax for the nvm calls only.
    set +eu; . "$NVM_HOME/nvm.sh"; nvm install --lts; local nrc=$?; set -eu
    [ "$nrc" -eq 0 ] || die "nvm install --lts failed"
    node_v="$(best_node)"
    [ -n "$node_v" ] || die "installed node is older than $NODE_MIN"
    log 3 DONE "node $node_v via nvm"; summary+=("node $node_v")
  fi
  # Put nvm's node on PATH for the npm step below (real runs only; a dry run may have no nvm).
  if [ "$DRY" = 0 ] && [ -n "$node_v" ]; then
    set +eu; . "$NVM_HOME/nvm.sh"; nvm use --silent "$node_v" >/dev/null; set -eu
    node --version >/dev/null 2>&1 || die "node not runnable after nvm use"
    vge "$(node --version | sed 's/^v//')" "$NODE_MIN" || die "active node is older than $NODE_MIN"
  fi

  # ---- 4. Claude Code: official native installer ------------------------------------
  # Official method per code.claude.com/docs/en/setup (checked 2026-11-11):
  #   curl -fsSL https://claude.ai/install.sh | bash
  # Binary lands as ~/.local/bin/claude (symlink into ~/.local/share/claude/versions/).
  if command -v claude >/dev/null 2>&1; then
    log 4 SKIP "claude already installed ($(claude --version 2>/dev/null | head -n1 || echo '?'))"
  elif [ "$DRY" = 1 ]; then
    log 4 PLAN "install Claude Code: curl -fsSL https://claude.ai/install.sh -> bash"
  else
    fetch https://claude.ai/install.sh "$TMP/claude-install.sh"
    bash "$TMP/claude-install.sh"
    command -v claude >/dev/null 2>&1 || die "claude installed but not found at $LOCAL_BIN/claude"
    log 4 DONE "claude installed"; summary+=("Claude Code")
  fi

  # ---- 5. herdr ---------------------------------------------------------------------
  # The installer (read 2026-11-11) takes the binary URL + sha256 from herdr.dev/latest.json,
  # so the checksum guards transport only, not a compromised herdr.dev. Installs to ~/.local/bin.
  if command -v herdr >/dev/null 2>&1; then
    log 5 SKIP "herdr already installed"
  elif [ "$DRY" = 1 ]; then
    log 5 PLAN "install herdr: curl -fsSL https://herdr.dev/install.sh -> sh"
  else
    fetch https://herdr.dev/install.sh "$TMP/herdr-install.sh"
    HERDR_INSTALL_DIR="$LOCAL_BIN" sh "$TMP/herdr-install.sh"
    command -v herdr >/dev/null 2>&1 || die "herdr installed but not found at $LOCAL_BIN/herdr"
    log 5 DONE "herdr installed"; summary+=("herdr")
  fi

  # ---- 6. gh CLI: release tarball, checksum-verified, no apt ------------------------
  if command -v gh >/dev/null 2>&1; then
    log 6 SKIP "gh already installed ($(gh --version 2>/dev/null | head -n1))"
  elif [ "$(uname -m)" != x86_64 ]; then
    log 6 FAIL "gh step only knows linux amd64 (this is $(uname -m)); install gh manually"
    [ "$DRY" = 1 ] || exit 1
  elif [ "$DRY" = 1 ]; then
    log 6 PLAN "gh v$GHV linux_amd64 tarball from github.com/cli/cli/releases, sha256 vs gh_${GHV}_checksums.txt, into $LOCAL_BIN"
  else
    local base="https://github.com/cli/cli/releases/download/v$GHV"
    local tb="gh_${GHV}_linux_amd64.tar.gz" d; d="$TMP/gh"; mkdir -p "$d"
    fetch "$base/$tb" "$d/$tb"
    fetch "$base/gh_${GHV}_checksums.txt" "$d/checksums.txt"
    # Keep only our tarball's line, then let sha256sum do the comparison.
    ( cd "$d" && grep " $tb\$" checksums.txt > want.sha && sha256sum -c want.sha ) \
      || die "gh checksum verification FAILED; nothing installed"
    tar -xzf "$d/$tb" -C "$d"
    mkdir -p "$LOCAL_BIN"
    install -m 0755 "$d/gh_${GHV}_linux_amd64/bin/gh" "$LOCAL_BIN/gh"
    log 6 DONE "gh $GHV installed (checksum OK)"; summary+=("gh $GHV")
  fi

  # ---- 7. shared Claude rules -------------------------------------------------------
  # deploy.sh with NO --import/--harnesses writes ~/.claude/CLAUDE.md as @-imports of
  # ~/.claude-rules/rules.md (and backs up a hand-written CLAUDE.md first).
  if [ -d "$RULES/.git" ]; then
    if [ "$DRY" = 1 ]; then
      log 7 PLAN "git -C $RULES pull --ff-only"
    else
      git -C "$RULES" fetch -q && git -C "$RULES" pull -q --ff-only \
        || die "cannot fast-forward $RULES; resolve by hand (never forced)"
    fi
  elif [ -e "$RULES" ]; then
    die "$RULES exists but is not a git clone; move it aside and re-run"
  elif [ "$DRY" = 1 ]; then
    log 7 PLAN "git clone $RULES_URL $RULES"
  else
    git clone -q "$RULES_URL" "$RULES"
  fi
  if grep -qs "^@~/.claude-rules/rules.md\$" "$HOME/.claude/CLAUDE.md"; then
    log 7 SKIP "$HOME/.claude/CLAUDE.md already imports claude-rules"
  elif [ "$DRY" = 1 ]; then
    log 7 PLAN "bash $RULES/deploy.sh (writes ~/.claude/CLAUDE.md; backs up a hand-written one)"
  else
    bash "$RULES/deploy.sh"
    log 7 DONE "claude-rules deployed"; summary+=("claude-rules")
  fi

  # ---- 8. openspec CLI --------------------------------------------------------------
  if command -v openspec >/dev/null 2>&1; then
    log 8 SKIP "openspec already installed ($(openspec --version 2>/dev/null | head -n1))"
  elif [ "$DRY" = 1 ]; then
    log 8 PLAN "npm install -g @fission-ai/openspec@latest (into the nvm node prefix; no sudo)"
  else
    command -v npm >/dev/null 2>&1 || die "npm not on PATH (nvm step incomplete)"
    npm install -g @fission-ai/openspec@latest
    command -v openspec >/dev/null 2>&1 || die "openspec installed but not on PATH"
    log 8 DONE "openspec installed"; summary+=("openspec")
  fi

  # ---- 9. the-grid: clone/update, seed user.yaml, bootstrap -------------------------
  local grid_ready=1
  if [ -d "$GRID/.git" ]; then
    if [ "$DRY" = 1 ]; then
      log 9 PLAN "git -C $GRID fetch && pull --ff-only"
    else
      # Never reset/force. A dirty tree or diverged branch stops here with a clear message.
      git -C "$GRID" fetch -q && git -C "$GRID" pull -q --ff-only \
        || die "cannot fast-forward $GRID (local changes or diverged branch). Fix by hand, then re-run. Nothing was reset."
    fi
  elif [ -e "$GRID" ]; then
    die "$GRID exists but is not a git clone; move it aside and re-run"
  elif [ "$DRY" = 1 ]; then
    log 9 PLAN "git clone --no-recurse-submodules $GRID_URL $GRID"; grid_ready=0
  else
    git clone -q --no-recurse-submodules "$GRID_URL" "$GRID"
  fi

  # user.yaml: seeded only when absent and at least one value was given.
  local ucfg="$GRID/agent-factory/user.yaml"
  if [ -f "$ucfg" ]; then
    log 9 SKIP "user.yaml exists, not touched"
  elif [ -z "$NAME$MACHINE$CHANNELS" ]; then
    log 9 SKIP "no --name/--machine/--channels given; user.yaml not seeded (see BOOTSTRAP.md step 5)"
  elif [ "$DRY" = 1 ]; then
    log 9 PLAN "write $ucfg (operator=$(yaml_quote "$NAME") machine=$(yaml_quote "$MACHINE") channels=$(yaml_quote "$CHANNELS"))"
  else
    {
      echo "# Seeded by scripts/bootstrap-user.sh; edit freely (it will not be overwritten)."
      echo "operator: $(yaml_quote "$NAME")"
      echo "machine: $(yaml_quote "$MACHINE")"
      echo "channels: $(yaml_quote "$CHANNELS")"
    } > "$ucfg"
    log 9 DONE "seeded $ucfg"; summary+=("user.yaml")
  fi

  # bootstrap.sh is itself idempotent but slow (submodules, venv, compose). Skip it when
  # the clone is at the commit we last bootstrapped and the agent venv exists.
  local head=""
  [ "$grid_ready" = 1 ] && head="$(git -C "$GRID" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$head" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$head" ] && [ -x "$GRID/agent-factory/.venv/bin/python" ]; then
    log 9 SKIP "the-grid already bootstrapped at ${head:0:12}"
  elif [ "$DRY" = 1 ]; then
    log 9 PLAN "bash $GRID/scripts/bootstrap.sh --with-agents"
  else
    bash "$GRID/scripts/bootstrap.sh" --with-agents
    mkdir -p "$STAMP_DIR"; printf '%s\n' "$head" > "$STAMP"
    log 9 DONE "the-grid bootstrapped (--with-agents)"; summary+=("the-grid")
  fi

  # ---- 10. ~/.bashrc marker block: PATH + nvm ---------------------------------------
  # Appended once, between markers. Present and identical = no-op; present but different
  # = report and stop (never rewritten silently).
  local rc="$HOME/.bashrc" block
  block="$(cat <<EOF
$MARK_BEGIN
# Managed by the-grid scripts/bootstrap-user.sh. Edit outside this block.
case ":\$PATH:" in *":\$HOME/.local/bin:"*) ;; *) export PATH="\$HOME/.local/bin:\$PATH" ;; esac
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
$MARK_END
EOF
)"
  if grep -qsF "$MARK_BEGIN" "$rc"; then
    local have
    have="$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{f=1} f{print} $0==e{f=0}' "$rc")"
    if [ "$have" = "$block" ]; then
      log 10 SKIP "$HOME/.bashrc block already present"
    else
      log 10 FAIL "$HOME/.bashrc has a bootstrap-user block that differs from the current one; not rewriting. Compare by hand."
      exit 1
    fi
  elif [ "$DRY" = 1 ]; then
    log 10 PLAN "append marked PATH + nvm block to ~/.bashrc"
  else
    # Leading blank line so we never glue onto a file that lacks a trailing newline.
    { echo; printf '%s\n' "$block"; } >> "$rc"
    log 10 DONE "$HOME/.bashrc updated (open a new shell)"; summary+=("bashrc block")
  fi

  # ---- summary ----------------------------------------------------------------------
  echo
  if [ "$DRY" = 1 ]; then
    echo "Dry run complete; nothing was changed."
    [ "$preflight_fail" = 0 ] || { echo "Step 1 reported missing system packages (see above)."; exit 1; }
    return 0
  fi
  if [ "${#summary[@]}" -gt 0 ]; then echo "Installed this run: ${summary[*]}"; else echo "Nothing to do: already set up."; fi
  cat <<'EOF'

Next steps (open a NEW shell first so PATH and nvm load):
  1. claude          # log in with your account when prompted
  2. gh auth login   # GitHub CLI login
  3. git config --global user.email "<id>+<login>@users.noreply.github.com"
     # GitHub rejects pushes that expose a private address
EOF
}

main "$@" </dev/null
