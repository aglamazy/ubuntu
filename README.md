# Ubuntu Dev CLIs

This repository hosts a collection of small, task‑focused CLIs and scripts for maintaining a productive Ubuntu development environment. It includes TypeScript/Node utilities, shell helpers, and workstation setup recipes.

## What’s Inside
- `utils/`: Handy Node/TS scripts (e.g., API key checks, small generators) and shell helpers.
- `services/`: System scripts like power/battery policies.
- `install/`: Local machine provisioning via `Makefile` targets (edit/read before running).
- `code-copilot-cli/`: TypeScript CLI scaffolding for experiments and tooling.
- `nodejs/`: Legacy Node scripts kept for reference.

## Quick Start
1) Clone and review folders you plan to use.
2) Install dependencies per tool:
   - `cd utils && npm install`
   - `cd code-copilot-cli && npm install`
3) Run scripts:
   - TypeScript (dev): `npx ts-node utils/gpt_test.ts`
   - Shell: `bash services/power.sh` (ensure `chmod +x`).
4) Optional workstation setup:
   - `cd install && make develop` (provisions local tooling for Ubuntu; requires sudo).

## Conventions
- Keep changes scoped per folder; avoid cross‑folder refactors without coordination.
- Don’t commit secrets. Use `.env.local` and `process.env`.
- Prefer small, composable CLIs with clear `--help` behavior and minimal dependencies.

See `AGENTS.md` for contributor guidelines and project practices.

