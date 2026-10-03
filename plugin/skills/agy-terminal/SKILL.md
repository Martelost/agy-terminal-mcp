---
name: agy-terminal
description: >
  Open and read a visible AGY/Gemini terminal shared with the user.
  Delegate bounded tasks and resume observation after the user handles prompts.
  Human confirmations are manual by default.
metadata:
  short-description: Shared visible AGY terminal (v0.5.0)
---

# AGY Terminal (v0.5.0)

Use this skill for authorized AGY/Gemini review or bounded implementation in the
current project. Codex can open the console itself; the user can see and type in
the same console.

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
supports both current and legacy plugin caches and can diagnose conflicting
unsigned launcher shims.

No session: use agy_open for the correct project. Capture failure: keep the
visible window open, inspect the reported error, and do not submit a task until
the screen can be read. Waiting for user: let the user handle the prompt, then
read again or wait for the pending task. Wrong project: check cwd and sessionId.

## Boundaries

Do not delegate credentials, deployments, production data, participant responses,
or other external effects. Keep worker file scope small and verify all edits.
Omit the legacy target parameter; the visible terminal is always the target.
