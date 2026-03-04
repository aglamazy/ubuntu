# Review Instructions

You are an unattended agent (taskbot review). Follow these steps exactly.

## Step 1 — Read project config

Read `taskbot.json` in the project's `docs/` directory. It contains:
- `dev_branch` — the base branch
- `lint` / `typecheck` — commands to run
- `notes` — project-specific rules

Read any AGENTS.md or AGENT.md in the project root for additional project rules.

## Step 2 — Read the task

Read the task document you were given. Understand what was implemented so you can
verify correctness and completeness.

## Step 3 — Read the diff

Run: `git diff origin/{dev_branch}...HEAD`

Review all changes made since the feature branch diverged from dev.

## Step 4 — Check task requirements

Verify that all subtasks described in the task's Fix section are implemented.
If any subtask is missing, implement it now.

## Step 5 — Check code quality

Review the diff for:
- **Correctness**: Does the implementation match the task specification?
- **Error handling**: Are error cases handled appropriately?
- **Edge cases**: Are obvious edge cases covered?
- **Naming**: Are variables and functions named clearly?
- **Dead code**: No commented-out code, unused imports, or debug artifacts.
- **TypeScript types**: No unnecessary `any`, types match usage.
- **Secrets**: No hardcoded credentials, tokens, or environment-specific values.

## Step 6 — Run lint and typecheck

Run the `lint` and `typecheck` commands from taskbot.json.
Fix any errors before proceeding.

## Step 7 — Fix and push

If any issues were found in Steps 4–6:
- Fix them directly in the worktree.
- Commit the fixes with a descriptive message (e.g. "review: fix edge case in X").
- Push the branch to origin.

If no issues were found, no commit needed (but still push if you made any changes).

End with: `RESULT: SUCCESS — review complete, N issues fixed: <brief list>`

Only end with `RESULT: FAILURE` for things requiring human judgment:
- Ambiguous requirements where you cannot determine the correct behavior
- Architectural decisions outside the task scope

## Progress reporting

Print a short status line before and after each step:

```
[STEP 1] Reading config... (project: finance)
[STEP 2] Task: 3 - Add export button
[STEP 3] Reading diff... 4 files changed
[STEP 4] Requirements check — all 3 subtasks implemented
[STEP 5] Code quality — 2 issues found (unused import, missing null check)
[STEP 6] Lint + tsc... Pass.
[STEP 7] Fixed 2 issues, committed + pushed
RESULT: SUCCESS — review complete, 2 issues fixed: removed unused import, added null check for empty list
```

## Rules

- Do NOT add features beyond the task scope.
- Do NOT modify tests unless they are directly related to the task.
- You are UNATTENDED. Do NOT ask for user confirmation.
- If requirements are ambiguous, use your best judgment and document it in the result.
