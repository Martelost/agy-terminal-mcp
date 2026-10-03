# AGY Terminal MCP

Use a visible AGY/Gemini terminal shared by Codex and the user as a local MCP worker.

Codex can open the terminal itself, read the same screen the user sees, and send
bounded tasks. The user can type and press Enter in that window. Confirmations are
manual by default. Scoped file-edit auto-approval is optional and never permits
shell commands, authentication, surveys, trust, deletes, or sensitive files.

This project is an independent community tool. It is not affiliated with Google, OpenAI, Anthropic, or the AGY/Gemini maintainers.

## Requirements

- Windows PowerShell 5.1 or newer
- Node.js 18 or newer
- The `agy` CLI installed and authenticated
- An MCP client that can launch a local Node server

## Install

From the repository root, run:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\agy-terminal-install.ps1
```

Restart the MCP client after installation so it reloads the server. The installer copies the plugin to the user-level Codex plugin cache and installs the `agy` launcher wrapper in `%USERPROFILE%\.codex\bin`.

## Use

Ask Codex to open AGY for your project. Version 0.5.0 provides:

| Tool | Behavior |
|------|----------|
| agy_open | Open or reuse one visible, interactive AGY console per project |
| agy_read | Read the actual screen without typing or pressing Enter |
| agy_run | Submit a bounded task only at a ready input prompt |
| agy_wait | Resume observing that task after the user handles a prompt |

When the window needs a confirmation, Codex reports manualInputRequired. Handle
the prompt yourself in that window. Authentication screens are hidden from the
model. Codex then reads again, or waits for the pending task, without submitting
the task twice.

You can test opening and reading directly from the repository:

~~~powershell
node tools/agy-control.mjs open C:\path\to\your-project
node tools/agy-control.mjs read C:\path\to\your-project
~~~

This diagnostic client starts the repository MCP server for a single request.
Restart Codex once after installation to load the new MCP tools in the app.

To check the installation without changing any files, run this from the repository:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\agy-terminal-install.ps1 -Check
~~~

The doctor checks the real AGY executable separately from the bridge wrapper, reports
its signing status, checks Node.js and launcher files, lists command precedence,
and finds bridge installations in both the current and legacy plugin caches.

You do not need to start AGY manually: Codex can call agy_open. If you prefer to
open it yourself, use the project that should receive the work:

```powershell
cd C:\path\to\your-project
agy
```

Keep that terminal open. The MCP client should inspect agy_read or agy_status and
continue only when inputReady is true and agyPid is nonzero for this project.

Use `agy_run` with an explicit task, mode, project directory, and `editableFiles` list. Keep the file scope as small as possible. The terminal remains visible so the user can review the worker's activity.

## Project layout

```text
plugin/                         MCP plugin source
  .codex-plugin/plugin.json     Plugin metadata
  .mcp.json                     MCP server entry point
  mcp/                          Node server and PowerShell bridge
  skills/agy-terminal/          Client usage instructions
tools/                          Installer and `agy` launcher
tests/agy-terminal/             Parser and named-pipe integration tests
```

## Validation

Run the built-in tests from the repository root:

```powershell
node tests/agy-terminal/prompt-parser.test.mjs
node tests/agy-terminal/pipe-integration.test.mjs
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\agy-terminal\launcher.test.ps1
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tests\agy-terminal\manual-input.test.ps1
node --test tests/agy-terminal/session-control.test.mjs tests/agy-terminal/mcp-tools.test.mjs
node --check plugin/mcp/server.mjs
```

## GitHub security automation

The public repository uses GitHub's free security features: secret scanning and push protection are enabled, CodeQL runs on pushes and pull requests through `.github/workflows/codeql.yml`, and Dependabot checks the GitHub Actions used by the workflow.

PowerShell syntax can be checked without changing execution policy permanently:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& { $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\\plugin\\mcp\\agy-terminal-bridge.ps1').Path, [ref]$null, [ref]$errors); if ($errors.Count) { $errors | Format-List; exit 1 } }"
```

## Troubleshooting

If Windows says that `.codex\bin\agy.exe` was blocked by Device Guard, check for
an old unsigned launcher that takes precedence over `agy.cmd`. The installer can
back up that unsigned file and refresh the launcher:

~~~powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\tools\agy-terminal-install.ps1 -RepairLauncher
~~~

The backup is named `agy.exe.disabled` (with a unique suffix if needed), so it
can be restored. Signed or unverifiable executables are left for manual review.
This option does not change Windows application-control policy. If the actual
AGY executable is blocked, ask the policy administrator to approve it.

After installation, open a new project terminal and run `agy`. To select the
wrapper explicitly in Command Prompt:

~~~cmd
"%USERPROFILE%\.codex\bin\agy.cmd"
~~~

In PowerShell:

~~~powershell
& "$env:USERPROFILE\.codex\bin\agy.cmd"
~~~

- `no_session`: ask Codex to call agy_open for the project, or open `agy` yourself.
- `bridge_only`: the bridge is alive but the real AGY process is not ready; restart `agy`.
- `agy_status` reports an old version: rerun the installer and restart the MCP client.
- PowerShell blocks `agy.ps1`: use the installer-created `agy` wrapper or run the launcher through `powershell.exe -ExecutionPolicy Bypass` as documented by your local AGY installation.

## Safety model

This is a local bridge, not a sandbox. Review the visible terminal and keep `editableFiles` limited to the files the worker is allowed to change. Never pass credentials, participant responses, production data, or private repository content to an external model.

## License

MIT. See [LICENSE](LICENSE).
