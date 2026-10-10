// Independent expected bytes come from the prepared candidate manifest.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
export const digest = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
export function runtimeBinding(app, executableHash) {
  const file = process.env.NEANTIK_PLATFORM_BINDING;
  assert(file && path.isAbsolute(file), 'Independent candidate binding required');
  const binding = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(binding.schemaVersion, 1);
  assert.equal(binding.runtimeExecutableSHA256, executableHash);
  assert(/^[0-9a-f]{64}$/.test(binding.runtimeFrameworkSHA256));
  const relative = binding.runtimeFrameworkRelativePath;
  assert(typeof relative === 'string' && relative.startsWith('Contents/Frameworks/') && !relative.split('/').includes('..'));
  const framework = path.join(app, relative);
  assert.equal(digest(framework), binding.runtimeFrameworkSHA256, 'Framework differs from candidate');
  return { binding, framework, bindingSHA256: digest(file) };
}
export function applyManagerLaunch(flags, env) {
  const file = process.env.NEANTIK_PLATFORM_LAUNCH_RECEIPT;
  assert(file && path.isAbsolute(file), 'Compiled manager launch receipt required');
  const receipt = JSON.parse(fs.readFileSync(file, 'utf8'));
  assert.equal(receipt.schemaVersion, 1);
  assert.equal(receipt.scope, 'synthetic-direct-profile-manager-policy');
  assert(Array.isArray(receipt.arguments));
  const allowed = new Set(['--no-first-run', '--no-default-browser-check', '--new-window',
    '--no-proxy-server', '--webrtc-ip-handling-policy=default_public_interface_only', '--disable-features=WebGPUService']);
  assert(receipt.arguments.length === allowed.size && receipt.arguments.every(v => allowed.has(v)) && new Set(receipt.arguments).size === allowed.size, 'Manager Direct policy drift');
  assert.deepEqual(receipt.environment, {NEANTIK_PROFILE_SEED:'21'});
  for (const flag of receipt.arguments) if (!flags.includes(flag)) flags.push(flag);
  Object.assign(env, receipt.environment);
  return digest(file);
}
