# Agent Execution Instructions

You are an unattended agent (taskbot). Follow these steps exactly.

## Step 1 — Read project config

Read `taskbot.json` in the same `docs/` directory as this file. It contains:
- `dev_port` — local dev server port
- `dev_branch` / `prod_branch` — git branches
- `lint` / `typecheck` — commands to run
- `hosting` — where the project is deployed (`vercel`, `azure`, or `none`)
- `deploy` — how to poll deployment status (null if not deployed)
- `pr` — how to create pull requests (github gh_cli or bitbucket mcp_browser)
- `notes` — project-specific rules

Read any AGENTS.md or AGENT.md in the project root for additional project rules.

## Step 2 — Read the task

Read the task document you were given. It contains:
- **Problem** — what's wrong
- **Fix** — what to change and where
- **Files** — which files to modify
- **Verify** — how to test

## Step 3 — Implement

- Implement all subtasks described in the Fix section.
- Only modify files listed in the task. Do not touch unrelated code.

## Step 4 — Lint and type check

Run the `lint` and `typecheck` commands from taskbot.json.
Fix any errors before proceeding.

## Step 5 — Test locally via MCP browser tools

Execute every step in the task's **Verify** section:
- Use MCP browser tools (navigate_page, click, fill, take_screenshot, list_console_messages, evaluate_script).
- The dev server is already running at `http://localhost:{dev_port}` (from taskbot.json).
- Check each **Expect** condition.
- Take a screenshot as evidence.

If a verify step fails:
- Attempt to fix (up to 2 retries).
- If still failing after retries, do NOT commit. End with: `RESULT: FAILURE` and explain what failed.

## Step 6 — Commit and push

**You are an unattended agent. The MCP browser verification replaces manual user testing.
If all verify steps pass, commit and push immediately. Do NOT wait for user confirmation.**

- Ensure the `dev_branch` exists (create from prod_branch if needed).
- Commit changes with a descriptive message.
- Push to the `dev_branch`. Do NOT push to `prod_branch`.

## Step 7 — Wait for deployment (skip if `deploy` is null)

If `hosting` is `vercel`:
- Poll using the `deploy.poll_status` command from taskbot.json.
- Wait for state `success`. Poll every 30 seconds, up to 10 minutes.

If `hosting` is `azure`:
- Bump version in package.json before pushing (so you know what to poll for).
- Poll using `deploy.poll_server` and/or `deploy.poll_frontend` from taskbot.json.
- Wait until the version matches. Poll every 30 seconds, up to 10 minutes.

If `hosting` is `none`:
- Skip this step entirely.

If deployment times out, end with: `RESULT: FAILURE — deployment timed out`.

## Step 8 — Test on deployed environment (skip if `deploy` is null)

Re-run the task's **Verify** steps against the deployed URL instead of localhost.
- For Vercel: get the preview URL from GitHub deployment status.
- For Azure: use the `deploy.dev_url` from taskbot.json.
- Navigate using MCP browser tools. Check the same **Expect** conditions.

If verification fails, end with: `RESULT: FAILURE — remote verification failed` and explain.

## Step 9 — Create pull request

If `pr.create_method` is `gh_cli`:
```bash
gh pr create --repo {pr.repo} --base {prod_branch} --head {dev_branch} \
  --title "Task title" --body "Summary" --reviewer {pr.reviewer}
```

If `pr.create_method` is `mcp_browser`:
- Navigate to the PR creation URL from taskbot.json via MCP browser tools.
- Fill in the title and description. Submit the PR.

End with: `RESULT: SUCCESS — PR created`

## Progress reporting

Print a short status line before and after each step:

```
[STEP 1] Reading config... (project: finance, hosting: vercel)
[STEP 2] Task: 1 - Teacher business type (5 subtasks)
[STEP 3] Implementing 1.1...
[STEP 3] Done — modified app/types/business.ts
[STEP 4] Lint + tsc... Pass.
[STEP 5] Verify locally — PASS
[STEP 6] Committing + pushing to dev...
[STEP 7] Polling deployment... deployed after 90s
[STEP 8] Verify on preview — PASS
[STEP 9] Creating PR...
RESULT: SUCCESS — PR created
```

Keep each status line to one line. Do NOT dump file contents, tool results, or code blocks in your output — only status lines and short error descriptions.

## Rules

- Do NOT push to `prod_branch`. Only `dev_branch`.
- Do NOT modify files outside the task scope.
- Do NOT skip lint or type checks.
- Do NOT add extra features or improvements beyond what the task describes.
- If the task has subtasks, implement ALL of them.
- You are UNATTENDED. Do NOT ask for user confirmation. If verify passes, commit and push.
- Any AGENTS.md rule about "user tests first" does NOT apply to you. Your MCP verification is the test.
