# Taskbot

Unattended Claude agent that reads task docs, implements fixes, tests via MCP browser tools, commits, and pushes to dev. A separate promote step creates PRs and verifies on prod.

## Install

```bash
./install.sh
source ~/.bashrc
```

## Configure a project

```bash
taskbot.sh ~/develop/MyProject --configure
# or
./configure.sh ~/develop/MyProject
```

This creates:
- `docs/taskbot.json` — project config (port, branches, hosting, PR method)
- `docs/AGENT_INSTRUCTIONS.md` — generic agent instructions
- `docs/TASK_TEMPLATE.md` — template for writing tasks
- `docs/dev/` — staging for completed tasks
- `docs/done/` — archive for released tasks

## Write a task

Create `docs/1-my-task.md` using the template. Include:
- **Problem** — what's wrong
- **Fix** — what to change
- **Files** — which files
- **Verify** — MCP-testable steps

## Run

```bash
taskbot.sh <project-dir>              # next pending task
taskbot.sh <project-dir> 1            # specific task
taskbot.sh <project-dir> --all        # all tasks sequentially
taskbot.sh <project-dir> --dry-run    # list pending tasks
taskbot.sh <project-dir> --list       # show all tasks by status
taskbot.sh <project-dir> --configure  # (re)configure project
taskbot.sh <project-dir> --new        # create task via interview
taskbot.sh <project-dir> --promote 2  # promote task 2 to prod
```

## Phase 1 — Execute task (`taskbot.sh 1`)

1. Read `taskbot.json` config + project rules
2. Read task doc
3. Implement the fix (in isolated git worktree on feature branch)
4. Lint + typecheck
5. Test locally via MCP browser
6. Push feature branch + create PR → dev

Task moves from `docs/` → `docs/dev/`. User reviews and merges PR to dev.

## Phase 2 — Promote to prod (`taskbot.sh --promote 1`)

1. Read task doc from `docs/dev/`
2. Poll dev deployment, test on dev via MCP
3. Create PR (dev → prod) on git platform
4. Wait for PR to be merged (user reviews)
5. Poll prod deployment
6. Test on prod environment

Task moves from `docs/dev/` → `docs/done/`

## Project config (taskbot.json)

```json
{
  "project": "my-app",
  "dev_port": 3000,
  "dev_branch": "dev",
  "prod_branch": "main",
  "lint": "npx eslint",
  "typecheck": "npx tsc --noEmit",
  "hosting": "vercel | azure | none",
  "deploy": { "poll_status": "..." } | null,
  "pr": { "platform": "github", "repo": "owner/repo", "create_method": "gh_cli", "reviewer": "user" },
  "notes": ["project-specific rules"]
}
```

## Logs

Task execution logs go to `<project>/task-logs/{index}-{timestamp}.log` (filtered text) and `.log.raw` (full JSON stream).
