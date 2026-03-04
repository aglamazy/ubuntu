# {index} - {Task Title}

## Workflow
preset: standard
operations: code, pr
branch_from: dev
merge_into: dev

## Problem
What's wrong or what's needed. Be specific — include examples, error messages, screenshots if relevant.

## Fix
What to change and where. Reference specific files and functions.

## Files
| File | What changes |
|------|-------------|
| `src/path/to/file.ts` | `functionName()` — description of change |

## Verify

Steps the agent executes after implementing the fix to confirm it actually worked.
Each step is an action + expected result. Mix verification types as needed:

**UI verification** (via MCP browser tools):
- [ ] Navigate to `{url}`
- [ ] {action — click, fill, wait for element}
- [ ] **Expect**: {what should be visible/not visible/in console}
- [ ] Take screenshot

**Data verification** (via DB query or API call):
- [ ] Run: `{db query or curl command}`
- [ ] **Expect**: {specific result — e.g. "0 rows", "count < 10", "no duplicates"}

**Important**: Verify the *outcome*, not just that the code ran. For migrations, query the data.
For bug fixes, reproduce the original bug scenario and confirm it's gone.
For new features, test the actual user flow end-to-end.
