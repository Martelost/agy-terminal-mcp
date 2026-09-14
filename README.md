# AGY Terminal MCP

Use a user-opened AGY/Gemini terminal as a local MCP worker from Codex or another MCP client.

The bridge routes requests by project directory, shows the work in the visible terminal, and auto-approves only explicitly scoped file-edit confirmations. Shell commands, OAuth/login prompts, deletes, credentials, and writes outside the declared file scope are not auto-approved.

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

In the project that should receive the work:

```powershell
cd C:\path\to\your-project
agy
```

Keep that terminal open. The MCP client should call `agy_status` first and continue only when the result reports `ready: true`, `agyReady: true`, and a nonzero `agyPid` for the requested project directory.

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
node --check plugin/mcp/server.mjs
```

PowerShell syntax can be checked without changing execution policy permanently:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "& { $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path '.\\plugin\\mcp\\agy-terminal-bridge.ps1').Path, [ref]$null, [ref]$errors); if ($errors.Count) { $errors | Format-List; exit 1 } }"
```

## Troubleshooting

- `no_session`: open `agy` in the same project directory and keep it running.
- `bridge_only`: the bridge is alive but the real AGY process is not ready; restart `agy`.
- `agy_status` reports an old version: rerun the installer and restart the MCP client.
- PowerShell blocks `agy.ps1`: use the installer-created `agy` wrapper or run the launcher through `powershell.exe -ExecutionPolicy Bypass` as documented by your local AGY installation.

## Safety model

This is a local bridge, not a sandbox. Review the visible terminal and keep `editableFiles` limited to the files the worker is allowed to change. Never pass credentials, participant responses, production data, or private repository content to an external model.

## License

MIT. See [LICENSE](LICENSE).
