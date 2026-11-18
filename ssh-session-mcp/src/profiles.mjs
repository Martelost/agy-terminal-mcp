import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

export const defaultHostsFile = path.join(os.homedir(), '.codex', 'ssh-sessions', 'hosts.json');

export function validateProfiles(config) {
  if (!Array.isArray(config?.hosts) || config.hosts.length === 0) {
    throw new Error('hosts.json must contain a nonempty hosts array.');
  }
  const profiles = new Map();
  for (const host of config.hosts) {
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(host.name ?? '') || profiles.has(host.name)) {
      throw new Error('Host names must be unique lowercase names with digits or hyphens.');
    }
    if (!/^[a-zA-Z0-9][a-zA-Z0-9._:-]*$/.test(host.hostname ?? '') ||
        !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(host.username ?? '')) {
      throw new Error(`Invalid hostname or username for ${host.name}.`);
    }
    if (!['posix', 'powershell'].includes(host.shell)) {
      throw new Error(`Host ${host.name} needs shell: posix or powershell.`);
    }
    if (typeof host.identityFile !== 'string' || !path.isAbsolute(host.identityFile)) {
      throw new Error(`Host ${host.name} needs an absolute identityFile path.`);
    }
    const port = host.port ?? 22;
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid SSH port.');
    if ('password' in host || 'passphrase' in host) throw new Error('Use SSH keys, not saved passwords.');
    profiles.set(host.name, { name: host.name, hostname: host.hostname, username: host.username,
      shell: host.shell, identityFile: host.identityFile, port });
  }
  return profiles;
}

export async function loadProfiles(file = process.env.SSH_SESSION_HOSTS || defaultHostsFile) {
  return validateProfiles(JSON.parse((await fs.readFile(file, 'utf8')).replace(/^\uFEFF/, '')));
}
