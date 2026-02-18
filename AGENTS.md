# Repository Guidelines

## Project Structure & Module Organization
- `code-copilot-cli/`: TypeScript CLI scaffolding (`src/`, `tsconfig.json`).
- `utils/`: Small Node/TS utilities and shell helpers (e.g., `gpt_test.ts`, `git_*.sh`).
- `services/`: System scripts and service helpers (e.g., `power.sh`).
- `install/`: Local workstation setup (`Makefile`, installers).
- `nodejs/`: Legacy Node scripts.
- `iSavta/`: One-off data scripts and a local `.env` (keep secrets local).

## Build, Test, and Development Commands
- Install deps per folder: `cd utils && npm install` or `cd code-copilot-cli && npm install`.
- Run TypeScript directly (dev): `npx ts-node utils/gpt_test.ts` (or compile with `npx tsc` then `node`).
- Compile TS project: `cd code-copilot-cli && npx tsc --noEmit false`.
- Shell scripts: `bash services/power.sh` (ensure `chmod +x`).
- Installer targets: `cd install && make develop` (provisions local tools; read Makefile first).

## Coding Style & Naming Conventions
- Indentation: 2 spaces for TS/JS; POSIX shell for scripts.
- Names: files `kebab-case`, variables/functions `camelCase`, constants `UPPER_SNAKE_CASE`.
- TypeScript: prefer explicit types on public APIs; avoid `any`.
- Shell: add shebang, `set -euo pipefail`, and minimal external deps.
- Formatting: no formatter is enforced; match nearby style and keep diffs focused.

## Testing Guidelines
- No formal suite today. When adding modules, co-locate tests as `name.test.ts` and run with Jest or `ts-node` smoke tests.
- Prefer pure functions and small CLIs to ease manual verification.
- For scripts touching external services, gate with env flags (e.g., `DRY_RUN=1`).

## Commit & Pull Request Guidelines
- Commits: concise, imperative subject (e.g., `add disk monitor`, `fix power policy`).
- PRs: include purpose, key changes, run/verify steps, and any screenshots/logs. Link issues when relevant.
- Keep changes scoped per folder; avoid cross-folder refactors unless coordinated.

## Security & Configuration Tips
- Secrets: do not commit `.env` files. Use `.env.local` and `process.env` loading.
- Example: `OPENAI_API_KEY` required by `utils/gpt_test.ts`; keep it in `.env.local` and out of VCS.
- Review `.gitignore` before adding new config or generated files.

