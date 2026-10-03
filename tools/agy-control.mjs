import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';
import process from 'node:process';

const names = { open: 'agy_open', read: 'agy_read', status: 'agy_status' };
const [operation, cwd] = process.argv.slice(2);
if (!names[operation] || !cwd) {
  console.error('Usage: node tools/agy-control.mjs <open|read|status> <absolute-project-directory>');
  process.exit(1);
}
const server = fileURLToPath(new URL('../plugin/mcp/server.mjs', import.meta.url));
const child = spawn(process.execPath, [server], { stdio: ['pipe', 'pipe', 'inherit'] });
const lines = readline.createInterface({ input: child.stdout });
const timeout = setTimeout(() => {
  console.error('AGY control request timed out. Check the visible window.');
  child.kill();
  process.exitCode = 1;
}, 30000);
lines.on('line', (line) => {
  const response = JSON.parse(line);
  if (response.id !== 1) return;
  clearTimeout(timeout);
  console.log(JSON.stringify(response.result?.structuredContent ?? response.error, null, 2));
  process.exitCode = response.error || response.result?.isError ? 1 : 0;
  lines.close();
  child.stdin.end();
  child.kill();
});
child.on('error', (error) => { clearTimeout(timeout); console.error(error.message); process.exitCode = 1; });
child.stdin.write(JSON.stringify({
  jsonrpc: '2.0', id: 1, method: 'tools/call',
  params: { name: names[operation], arguments: { cwd } }
}) + '\n');
