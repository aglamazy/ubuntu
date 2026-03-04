# Promote Instructions

You are an unattended agent (taskbot promote). Follow these steps exactly.

## Step 1 — Read project config

Read `taskbot.json` in the same `docs/` directory as this file. It contains:
- `dev_branch` / `prod_branch` — git branches
- `hosting` — where the project is deployed (`vercel`, `azure`, or `none`)
- `deploy` — how to poll deployment status
- `pr` — how to create pull requests
- `notes` — project-specific rules

## Step 2 — Read the task

Read the task document you were given (from `docs/dev/`). Understand what was implemented
so you can write the PR description and verify on dev and prod.

## Step 2.5 — Create PR feature→dev (if not already done)

Check the state context provided at startup. If `pr_url` is non-null, skip this step.

If `pr_url` is null, create the PR now:
- Build PR title from the task's Problem/Fix sections (short summary, under 72 chars).
- Build PR description with sections: What, Why, Changes, Verify.

If `pr.create_method` is `gh_cli`:
```bash
gh pr create --repo {pr.repo} --base {merge_into} --head {feature_branch} \
  --title "Descriptive title from task" \
  --body "## What\n...\n\n## Why\n...\n\n## Changes\n...\n\n## Verify\n..." \
  --reviewer {pr.reviewer}
```

If `pr.create_method` is `mcp_browser`:
- Navigate to the PR creation URL from taskbot.json.
- Change `dest` to `merge_into` and `source` to the feature branch.
- Fill in title and description. Submit the PR.

Print: `[STEP 2.5] PR created: <url>`

## Step 2.6 — Wait for feature→dev PR to be merged

Poll the PR status until it is merged:

If `pr.create_method` is `gh_cli`:
```bash
gh pr view --repo {pr.repo} --json state --jq '.state'
```
Wait for state `MERGED`. Poll every 60 seconds, up to 30 minutes.

If `pr.create_method` is `mcp_browser`:
- Check the PR page via MCP browser to see if it was merged.
- Poll every 60 seconds, up to 30 minutes.

If not merged after 30 minutes, end with: `RESULT: TIMEOUT — feature PR not merged`

## Step 3 — Wait for dev deployment (skip if `deploy` is null)

Wait for the feature→dev PR to be merged (Step 2.6), then wait for dev to deploy.

If `hosting` is `vercel`:
- Poll using the `deploy.poll_status` command from taskbot.json.
- Wait for state `success`. Poll every 30 seconds, up to 10 minutes.

If `hosting` is `azure`:
- Poll using `deploy.poll_server` and/or `deploy.poll_frontend` from taskbot.json.
- Wait until the deployed version is newer than before. Poll every 30 seconds, up to 10 minutes.

If `hosting` is `none`:
- Skip this step.

If deployment times out, end with: `RESULT: FAILURE — dev deployment timed out`

## Step 4 — Test on dev (skip if `deploy` is null)

Re-run the task's **Verify** steps against the dev environment URL.
- For Vercel: get the preview URL from GitHub deployment status.
- For Azure: use the `deploy.dev_url` from taskbot.json.
- Navigate using MCP browser tools. Check the same **Expect** conditions.
- Take screenshots as evidence.

If verification fails, end with: `RESULT: FAILURE — dev verification failed`

## Step 5 — Create PR to prod

Build the PR title and description from the task doc:

- **Title**: Short summary from the task's Problem/Fix sections (e.g. "Deduplicate port invoices on import")
- **Description**: Include these sections:
  - **What**: 1-2 sentence summary of what was changed
  - **Why**: The problem this solves (from the task's Problem section)
  - **Changes**: Bullet list of files modified and what was done in each
  - **Verify**: The test steps from the task's Verify section

If `pr.create_method` is `gh_cli`:
```bash
gh pr create --repo {pr.repo} --base {prod_branch} --head {dev_branch} \
  --title "Descriptive title from task" \
  --body "## What\n...\n\n## Why\n...\n\n## Changes\n...\n\n## Verify\n..." \
  --reviewer {pr.reviewer}
```

If `pr.create_method` is `mcp_browser`:
- Navigate to the PR creation URL from taskbot.json via MCP browser tools.
- Fill in the title and description as described above.
- Submit the PR.

End with: `[STEP 5] PR created — waiting for merge`

## Step 6 — Wait for PR to be merged

Poll the PR status until it is merged:

If `pr.create_method` is `gh_cli`:
```bash
gh pr view --repo {pr.repo} --json state --jq '.state'
```
Wait for state `MERGED`. Poll every 60 seconds, up to 30 minutes.

If `pr.create_method` is `mcp_browser`:
- Check the PR page via MCP browser to see if it was merged.
- Poll every 60 seconds, up to 30 minutes.

If not merged after 30 minutes, end with: `RESULT: TIMEOUT — PR not merged`

## Step 7 — Wait for prod deployment (skip if `deploy` is null)

If `hosting` is `vercel`:
- Poll using a prod-equivalent status check. Wait for `success`.

If `hosting` is `azure`:
- Poll using `deploy.poll_server` and/or `deploy.poll_frontend` but against the PROD URL (not dev).
- If there is a `deploy.prod_url` in config, use it. Otherwise derive from `deploy.dev_url` by removing the `dev.` prefix.
- Wait until the version matches the one pushed. Poll every 30 seconds, up to 10 minutes.

If `hosting` is `none`:
- Skip this step.

If deployment times out, end with: `RESULT: FAILURE — prod deployment timed out`

## Step 8 — Test on prod (skip if `deploy` is null)

Re-run the task's **Verify** steps against the PROD URL.
- Navigate using MCP browser tools. Check the same **Expect** conditions.
- Take screenshots as evidence.

If verification fails, end with: `RESULT: FAILURE — prod verification failed`

If all passes, end with: `RESULT: SUCCESS — verified on prod`

## Progress reporting

Print a short status line before and after each step:

```
[STEP 1] Reading config... (project: importa-server, hosting: azure)
[STEP 2] Task: 2 - Dedup port invoices
[STEP 2.5] PR created: https://github.com/org/repo/pull/42
[STEP 2.6] Waiting for feature PR merge... merged after 3m
[STEP 3] Polling dev deployment... deployed after 60s
[STEP 4] Verify on dev — PASS
[STEP 5] Creating PR to prod... PR created
[STEP 6] Waiting for PR merge... merged after 5m
[STEP 7] Polling prod deployment... deployed after 90s
[STEP 8] Verify on prod — PASS
RESULT: SUCCESS — verified on prod
```

## Rules

- Do NOT modify any code. This is a promote/verify phase only.
- Do NOT push to any branch. The merge happens through the PR.
- You are UNATTENDED. Do NOT ask for user confirmation.
