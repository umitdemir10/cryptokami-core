# CryptoKami Core

Haskell cryptocurrency node forked from Cardano SL. Build with Stack (resolver `lts-9.1`, GHC 8.0) or Nix.

## Layout

Package dependency order (from `stack.yaml`):
`networking → [util, binary] → crypto → core → db → [lrc, infra] → [ssc, txp, update, delegation] → block → lib`,
then `client → generator → [auxx, explorer, wallet] → wallet-new` and `[node, tools]`.

## Commands

- Build: `stack build` (or `scripts/build/cryptokami-sl.sh`)
- Test: `stack test`
- Lint: `scripts/haskell/lint.sh` (HLint, config in `HLint.hs`)
- Format: `scripts/haskell/stylish.sh` (stylish-haskell ≥ 0.8.1.0, config in `.stylish-haskell.yaml`)

A full build is very slow; prefer building only the package you changed, e.g. `stack build cryptokami-sl-core`.

## Security

- `secrets/` holds key material (`*.sk`, `*.seed`). Never read, print, copy or modify it; Claude is denied access in `.claude/settings.json`.
- Never commit keys, wallet DBs (`node-db*`, `wallet-db/`) or `.env` files.
- Crypto, signing, transaction validation (`crypto/`, `txp/`, `core/`) changes need tests and a careful review; use the Blockchain Security Auditor or Code Reviewer agent.

## Claude setup

- `.claude/agents/`: 20 agency-agents subagents (see `.claude/AGENCY-AGENTS.md`).
- Plugins enabled in `.claude/settings.json`: Ponytail, Agent Skills, Anthropic code-review, and Trail of Bits differential-review, variant-analysis, sharp-edges, insecure-defaults, fp-check.
- `.claude/skills/graphify/`: Graphify skill (graphifyy 0.9.89). Run `/graphify .` to build a knowledge graph of the repo into `graphify-out/`; `.graphifyignore` keeps key material out of it.
