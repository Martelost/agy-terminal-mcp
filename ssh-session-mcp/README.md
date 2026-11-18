# SSH Sessions MCP

An MCP server that keeps one SSH shell open per configured host. Models call
`ssh_run({host, command})` instead of constructing SSH commands. Working directory,
shell variables, and environment remain available for subsequent commands.

Uses the installed OpenSSH client, SSH keys, and existing known-host verification.
No passwords are stored. Host profiles belong in a local file outside the repository.

## Install

Requires Node.js 20+, OpenSSH, and the Codex CLI. Create
`%USERPROFILE%\.codex\ssh-sessions\hosts.json` using `hosts.example.json` as a template.
Keep real host details and credentials out of the repository.

Run `install.ps1`. It installs the server under `%USERPROFILE%\.codex\mcp\ssh-sessions`
and registers `ssh-sessions` with `codex mcp add`. Reload the MCP client once after
installation to load the tools.

## Tools

| Tool | Purpose |
| --- | --- |
| `ssh_hosts` | List host names and session state |
| `ssh_open` | Open or reuse a shell explicitly |
| `ssh_run` | Open lazily and execute a command in that shell |
| `ssh_read` | Poll a running operation or page output using `next_cursor` |
| `ssh_input` | Send stdin input to a running command |
| `ssh_close` | Close the host's transport and reset its shell state |

Commands run sequentially per host. A slow command returns `running` with an
`operation_id`; poll `ssh_read` until it completes. A busy host rejects another
command. Output retains the last 1 MiB per operation and reports truncation.

Sessions remain connected while the MCP process runs, with SSH keepalives. A
client restart resets them. After a disconnect the next command may open a new
connection; the interrupted command is never replayed automatically. Do not
retry a mutation without checking the remote result.

There is no PTY: use noninteractive commands (for example `sudo -n`) or a separate
terminal for terminal-only apps. `ssh_input` supports programs reading standard
input, but raw Ctrl-C bytes do not deliver a remote signal. Closing a connection
does not guarantee that detached remote jobs stop. Starting background jobs can
mix their output with later commands; use explicit output files for those jobs.

The server preserves the shell, not filesystem permissions or command policy.
`ssh_run` and `ssh_input` are marked as potentially destructive. The model must
follow the user's scope for remote changes. POSIX hosts require `sh`; Windows
hosts require `powershell.exe`. `exit`, `exec`, or closing standard input can end
the shell; the next run opens a fresh one.

Implementation uses the [official MCP SDK stdio API](https://ts.sdk.modelcontextprotocol.io/server).
