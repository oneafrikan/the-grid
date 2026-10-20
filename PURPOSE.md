# Purpose
<!-- DRAFT: wording derived from the README and CLAUDE.md intro; pending the operator's review. -->

## Problem

Skills, agents and rules for AI assistants are scattered across repos and machines. They drift apart between machines and between tools, and nobody can audit what is actually active.

## Intended solution

One repo that wires a curated set of skills, agents and rules identically onto every machine and every supported harness, generated from a single source and checked for drift.

## Outcome

- A fresh machine reaches the same wired set with one command.
- `bash scripts/gate.sh` passes.
- The drift detectors exit 0.

Must-nots: see [GUARDRAILS.md](GUARDRAILS.md).
