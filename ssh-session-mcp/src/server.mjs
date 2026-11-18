import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { loadProfiles } from './profiles.mjs';
import { SessionManager } from './sessions.mjs';

const manager = new SessionManager(await loadProfiles());
const server = new McpServer({ name: 'ssh-sessions', version: '1.0.0' }, {
  instructions: 'Use ssh_run with a configured host name; it opens or reuses that host\'s persistent shell. Cwd and environment persist between commands. Follow the user\'s authorization for remote actions. Do not replay commands after a disconnect. A running result is not a failure: poll ssh_read with operation_id and next_cursor. Only one command runs per host. Sessions last while this MCP process runs. No PTY; tools requiring an interactive terminal should use a separate terminal.'
});
const host = z.string().min(1).max(40).describe('Configured name from ssh_hosts.');
const waitMs = z.number().int().min(0).max(10000).default(1000).describe('Wait up to this many milliseconds; a longer command returns running and remains active.');
const maxChars = z.number().int().min(100).max(100000).default(16000);
const operationId = z.string().uuid();
const result = (value) => ({ content: [{ type: 'text', text: JSON.stringify(value) }], structuredContent: value,
  isError: value.status === 'disconnected' || (value.status === 'completed' && value.exit_code !== 0) });
const wrap = (handler) => async (args) => {
  try { return result(await handler(args)); }
  catch (error) { return { content: [{ type: 'text', text: error.message }], isError: true }; }
};

server.registerTool('ssh_hosts', {
  description: 'List the configured SSH hosts and the state of their persistent shell sessions. No connection is opened.',
  inputSchema: {}, annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, wrap(() => ({ hosts: manager.list() })));

server.registerTool('ssh_open', {
  description: 'Open a key-authenticated persistent shell for a configured host, or return its existing session. ssh_run also opens lazily. No password or arbitrary connection arguments are accepted.',
  inputSchema: { host }, annotations: { destructiveHint: false, idempotentHint: true, openWorldHint: true }
}, wrap(async ({ host }) => (await manager.open(host)).info()));

server.registerTool('ssh_run', {
  description: 'Execute a user-authorized command in a host\'s persistent POSIX or PowerShell shell. Automatically opens/reuses the connection. Cwd and variables persist. Commands can change remote files; this is not a read-only tool. One command per host; if still running use ssh_read, not ssh_run again. Session loss never triggers automatic command replay.',
  inputSchema: { host, command: z.string().min(1).max(131072), wait_ms: waitMs, max_output_chars: maxChars },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true }
}, wrap(({ host, command, wait_ms, max_output_chars }) => manager.run(host, command, wait_ms, max_output_chars)));

server.registerTool('ssh_read', {
  description: 'Read output/status of an existing operation. Use the previous next_cursor to avoid repeated output; output is capped at 1 MiB per operation and truncated flags discarded history. Does not execute commands or reconnect.',
  inputSchema: { host, operation_id: operationId, cursor: z.number().int().min(0).default(0), wait_ms: waitMs, max_output_chars: maxChars },
  annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false }
}, wrap(({ host, operation_id, cursor, wait_ms, max_output_chars }) => manager.read(host, operation_id, cursor, wait_ms, max_output_chars)));

server.registerTool('ssh_input', {
  description: 'Send stdin input to a running operation that is waiting for input. Use only within the authorized task. No PTY is allocated: terminal-only apps and Ctrl-C signaling are unsupported. Do not put passwords or secrets in tool arguments.',
  inputSchema: { host, operation_id: operationId, data: z.string().max(8192), newline: z.boolean().default(true) },
  annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true }
}, wrap(({ host, operation_id, data, newline }) => manager.input(host, operation_id, data, newline)));

server.registerTool('ssh_close', {
  description: 'Close the persistent SSH transport for a host. The next ssh_run creates a fresh shell. This may interrupt its active command; detached remote processes are not guaranteed to stop.',
  inputSchema: { host }, annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true }
}, wrap(({ host }) => manager.close(host)));

const transport = new StdioServerTransport();
server.server.onclose = () => manager.closeAll();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { manager.closeAll(); process.exit(0); });
process.stdin.on('end', () => manager.closeAll());
process.on('exit', () => manager.closeAll());
await server.connect(transport);
