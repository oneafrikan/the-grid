# New user on a shared Linux box

[`scripts/bootstrap-user.sh`](../scripts/bootstrap-user.sh) sets up one unprivileged account for LLM work: uv and a data-science venv, Node via nvm, Claude Code, herdr, `gh`, the shared Claude rules, the openspec CLI, then this repo. Written for Ubuntu 24.04 headless with a bash login shell.

- It runs as the target user, needs no sudo, and refuses root.
- The machine operator installs the system packages first. Step 1 of the script prints the exact `sudo apt-get install -y ...` line if any are missing.
- It is idempotent: each step probes first, so a second run changes nothing.

Preview with a dry run (nothing is written):

```bash
bash -s -- --name "Full Name" --machine "Laptop" --channels "Telegram" --dry-run < scripts/bootstrap-user.sh
```

Drop `--dry-run` to run it for real. The real install paths are REAL-RUN-ONLY: the dry run and the bats stubs do not cover them.

`--name`, `--machine` and `--channels` seed `agent-factory/user.yaml` (`operator`, `machine`, `channels`) only when that file does not exist.

An operator can run it for another user from their own session, piping the file in so the user needs no read access to it:

```bash
sudo -iu USER bash -s -- --name "Full Name" --machine "Laptop" --channels "Telegram" < /path/to/bootstrap-user.sh
```

Afterwards the user opens a new shell, runs `claude` to log in, and runs `gh auth login`.
