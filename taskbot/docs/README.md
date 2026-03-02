# Taskbot

Unattended Claude agent that reads task docs, implements fixes, tests via MCP browser tools, commits, pushes, and creates PRs.

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
taskbot.sh <project-dir> --configure  # (re)configure project
```

## Agent execution flow

1. Read `taskbot.json` config + project rules
2. Read task doc
3. Implement the fix
4. Lint + typecheck
5. Test locally via MCP browser
6. Commit + push to dev branch
7. Poll deployment (if configured)
8. Test on deployed environment (if configured)
9. Create PR

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
