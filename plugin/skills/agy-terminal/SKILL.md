---
name: agy-terminal
description: >
  Delegate bounded implementation or review tasks to the user-opened AGY/Gemini terminal.
  Auto-approves only file-edit confirmations within the explicit editableFiles scope.
  Requires the user to run `agy` in the project terminal first.
metadata:
  short-description: Delegate bounded work to local AGY/Gemini (v0.4.1)
---

# AGY Terminal (v0.4.1)

Use this skill when the user asks to run Gemini, AGY, or a second-model pass for review
or bounded implementation in the current workspace.

## Prerequisites

The user must have a running **AGY process** in the project directory:

```powershell
# In a project terminal (not the bridge window)
agy
```

The launcher starts a per-project bridge and registers the AGY process automatically.
The bridge window may be separate; keep it open, but do not mistake the bridge alone
for a ready AGY session. Call `agy_status` first and require both `ready: true` and
`agyReady: true` with a non-zero `agyPid`.

## Normal workflow

```
1. User opens a terminal in their project and runs: agy
2. Codex calls agy_status({ cwd: "<project path>" }) to verify readiness
3. Codex calls agy_run({ task: "...", mode: "worker", editableFiles: [...] })
4. AGY edits the files — user sees every step in their terminal
5. File-edit confirmations within editableFiles are auto-approved (no manual clicks)
6. Codex inspects the diff and runs validation
```

## Tool reference

### `agy_status({ cwd? })`

Check whether an AGY terminal is ready for a given directory.
Returns: `ready`, `agyReady`, `cwd`, `sessionId`, `pipeName`, `serverVersion`,
`pluginVersion`, `bridgePid`, `agyPid`, and `reason`.

**Always call this first** when troubleshooting a `no_session` error.

### `agy_run({ task, mode?, cwd?, editableFiles?, timeoutSeconds?, maxOutputChars? })`

Send a bounded task to the AGY terminal the user opened.

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `task` | string | ✅ | The bounded task description |
| `mode` | `"review"` \| `"worker"` | — | Default `"review"` |
| `cwd` | string | — | Absolute path; used to select the right session |
| `editableFiles` | string[] | worker only ✅ | Absolute paths AGY may edit |
| `timeoutSeconds` | integer | — | Default 900 (15 min) |
| `maxOutputChars` | integer | — | Default 30 000 |

**Auto-approve rules** (worker mode only):

| Approved ✅ | Blocked ❌ |
|------------|----------|
| `allow file creation` in scope | Any shell / bash / PowerShell command |
| `allow file edit` in scope | OAuth / authorization code / login |
| `allow file write` in scope | `delete` operations |
| `allow modification` in scope | Files outside `editableFiles` or `cwd` |
| AGY survey skip | `.env`, secrets, credentials outside scope |
| | Workspace trust prompts |

> [!IMPORTANT]
> Do not pass a `target` parameter. The visible terminal is always the default;
> `target="auto"` returns `unsupported_target`.

### `terminal_run({ command, cwd? })`

Run an **explicit** PowerShell command in the bridge terminal.
**Use only when the user directly requests a shell command.**
Never call this automatically from `agy_run`.

## Invocation examples

```javascript
// Check session
await agy_status({ cwd: "C:\\Users\\me\\project" });

// Read-only review
await agy_run({
  task: "Review the risk engine for off-by-one errors.",
  mode: "review",
  cwd: "C:\\Users\\me\\project"
});

// Bounded implementation
await agy_run({
  task: "Add input validation to the transfer form.",
  mode: "worker",
  cwd: "C:\\Users\\me\\project",
  editableFiles: [
    "C:\\Users\\me\\project\\app.js",
    "C:\\Users\\me\\project\\styles.css"
  ]
});
```

## After plugin update

After installing a new plugin version, **restart Claude / Codex once** to reload
the MCP process. Verify with:

```powershell
# Check which server version Codex is using
# (look for serverVersion in any agy_status or agy_run response)
```

## Verified behavior

- The installed MCP and plugin report `0.4.1`.
- Sessions use a per-cwd pipe, so separate project terminals are routed independently.
- A live worker test created one scoped file with `autoApprovals: 1` and `blocked: 0`.
- The test file content was verified and then removed; no other file was changed.
- If `ready: true` but `agyReady: false` or `agyPid: 0`, only the bridge is running.
  Run `agy` in the project terminal and wait for the real AGY prompt before retrying.
- If `agy` fails with an empty `ArgumentList` error, update the global launcher using
  the repository installer, then retry; do not manually pass a dummy argument.

## Boundaries

- Do not delegate credentials, deployment, production data, participant responses, or external side effects.
- Review every changed file and run relevant tests after a worker pass.
- The first AGY invocation may require interactive OAuth. Stop at that prompt and let the user authenticate — never handle authorization codes, never attempt to automate OAuth, and never claim login or terminal restarts are unnecessary.
- Never attempt to bypass AGY permissions, add command(*), or use dangerously-skip-permissions. Auto-approval is strictly scoped to file-edits within explicit editableFiles.
- A nonzero agyPid is strictly required before sending tasks via agy_run. The target parameter must be omitted.
- This plugin works from any project — no `tools/agy.ps1` required.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `no_session` error | Run `agy` in the project terminal, then retry |
| `agyReady: false` or `agyPid: 0` | The bridge is alive but AGY is not; run `agy` in the project terminal |
| `auth_required` error | Interactive Google OAuth/login is needed; complete authentication in the visible AGY terminal |
| Wrong project gets the task | Check `cwd` param; call `agy_status` for both dirs |
| Stale MCP after install | Restart Claude/Codex once to reload the MCP process |
| Auto-approve not triggering | Verify `editableFiles` contains absolute paths inside `cwd` |
| `unsupported_target` error | Remove `target` parameter from the call |
