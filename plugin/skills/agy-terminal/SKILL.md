---
name: agy-terminal
description: >
  Open and operate AGY/Gemini in a visible, interactive terminal shared with the user.
  Use when asked to open AGY or delegate review or implementation to AGY in any project.
  Do not substitute a headless backend unless the user explicitly requests headless mode.
metadata:
  short-description: Shared visible AGY terminal (v0.5.3)
---

# AGY Terminal (v0.5.3)

This skill applies in any authorized project, not a particular repository or
marketplace. Use the absolute directory supplied by the user or the current
workspace. Ask only when the target project is unclear.

AGY in this workflow means a visible, interactive console shared with the user.
Codex opens it and sends ordinary task input itself; the user can see and type in
the same console. If the user explicitly requests headless mode, use the appropriate
headless workflow instead; do not pretend it is this shared terminal.

## Capability check and fallback

- Require agy_open and agy_read before starting this workflow. If they are missing,
  the client has an old or incomplete plugin: report that and request a reload or
  installation update. Do not silently call agy_ask, a headless MCP server,
  non-interactive CLI flags, or redirect AGY's stdin/stdout as a substitute.
- A no_session result means open the shared console with agy_open, not switch
  backends. If opening or capture fails, report the error and stop the AGY handoff.
- agy_open must produce or reuse a visible console, and agy_read must return actual
  screen text from the same sessionId and agyPid. A hidden bridge or a live PID alone
  is not proof of a usable shared terminal.

## Workflow

1. Call agy_open with the absolute project directory. Reuse the existing session.
2. Call agy_read to inspect the real screen. It types nothing and never presses Enter.
3. If manualInputRequired is true, tell the user what the terminal is waiting for
   and let them handle it in that window. Read again after they have done so.
4. Send agy_run only when inputReady is true and the exact session has a nonzero agyPid.
5. If a submitted task pauses for the user, use agy_wait after they handle the
   prompt. Do not resubmit the same task.
6. Review any changed files and run validation after a worker task.

The visible AGY window is interactive. The pipe bridge runs in the background;
a bridge without an AGY process is not a ready session.

## Tools

- agy_open({ cwd, maxOutputChars? }): open or reuse a visible console. Concurrent
  requests for one project do not create duplicate windows.
- agy_read({ cwd, maxOutputChars? }): capture the same console screen the user sees
  without writing input. Returns state, inputReady, manualInputRequired, output,
  exact process/session IDs, and an action when needed.
- agy_status({ cwd }): report bridge/process and input readiness. A live process
  may still be starting, busy, awaiting_user, or auth_required.
- agy_run({ task, mode?, cwd, editableFiles?, autoApprove?, timeoutSeconds?,
  maxOutputChars? }): submit a bounded task at an idle prompt. Review is read-only;
  worker requires absolute editableFiles inside cwd.
- agy_wait({ cwd, timeoutSeconds?, maxOutputChars? }): continue observing the
  pending task without typing or sending it again. Pending task markers belong
  to the running MCP process; after an MCP restart use agy_read to inspect an
  existing task instead of blindly resubmitting it.
- terminal_run({ command, cwd? }): a raw PowerShell command in the bridge, only
  when the user explicitly requests that command. Never use it automatically.

## Human input

Confirmations are manual by default, including file edits, surveys, workspace
trust, shell commands, and login. Never press Enter on those prompts for the user.
Authentication screens are hidden from the model; the user completes login
directly in the visible terminal. Never collect, paste, or automate credentials,
OAuth codes, or verification codes.

Only explicitly requested autoApprove:true in worker mode can approve file-edit
confirmations within editableFiles and cwd. It never permits shell commands,
deletes, sensitive files, surveys, trust, or authentication. Do not enable
dangerously-skip-permissions or command(*) permissions.

## Examples

~~~javascript
await agy_open({ cwd: "C:\\Users\\me\\project" });
const screen = await agy_read({ cwd: "C:\\Users\\me\\project" });
// If a human prompt is shown, the user handles it in the visible window.
await agy_run({
  task: "Review the risk engine for off-by-one errors.",
  mode: "review",
  cwd: "C:\\Users\\me\\project"
});
// After a pending task pauses for a confirmation and the user handles it:
await agy_wait({ cwd: "C:\\Users\\me\\project" });
~~~

## Installation and troubleshooting

Restart Codex once after an MCP update so the new tool definitions are loaded.
agy_open requires the installer-provided launcher in .codex\bin. The installer
registers a standalone, user-level marketplace so every chat uses the same plugin
without relying on a project checkout. Reinstall when the loaded tools still lack
agy_open or agy_read; restarting alone cannot upgrade an outdated plugin source.

No session: use agy_open for the correct project. Capture failure: keep the
visible window open, inspect the reported error, and do not submit a task until
the screen can be read. Waiting for user: let the user handle the prompt, then
read again or wait for the pending task. Wrong project: check cwd and sessionId.

## Boundaries

Do not delegate credentials, deployments, production data, participant responses,
or other external effects. Keep worker file scope small and verify all edits.
Omit the legacy target parameter; the visible terminal is always the target.
