// Bounded QA-only CDP: set a private download destination, navigate two fixed
// owned fixtures, observe completion/cancellation. No arbitrary JS/evaluation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { OwnedDownloadObserver, verifyDownloads } from '../runtime-platform/fixtures/vector-semantics/download-observer.mjs';

const root = fs.realpathSync(process.argv[2]);
assert(path.dirname(root) === '/private/tmp' && path.basename(root).startsWith('neantik-relay-owner-qualification-'));
assert((fs.statSync(root).mode & 0o777) === 0o700 && fs.statSync(root).uid === process.getuid());
const state = JSON.parse(fs.readFileSync(path.join(root, 'background-control.json'), 'utf8'));
const data = fs.realpathSync(state.browserDataPath);
assert(data.startsWith(root + '/Profiles/') && path.basename(data) === 'BrowserData');
const lines = fs.readFileSync(path.join(data, 'DevToolsActivePort'), 'utf8').trim().split('\n');
const port = Number(lines[0]);
assert(lines.length === 2 && Number.isInteger(port) && port > 0 && port < 65536);
assert(/^\/devtools\/browser\/[0-9a-f-]+$/.test(lines[1]));
const socket = new WebSocket(`ws://127.0.0.1:${port}${lines[1]}`);
await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error('CDP-open-timeout')), 5000);
    socket.addEventListener('open', () => { clearTimeout(timer); resolve(); }, { once: true });
    socket.addEventListener('error', () => { clearTimeout(timer); reject(Error('CDP-open-refused')); }, { once: true });
});
let sequence = 0;
const origin = 'http://relay-qualification.test';
const commands = new Set(['Browser.setDownloadBehavior', 'Browser.cancelDownload', 'Target.createTarget', 'Target.closeTarget']);
async function command(ws, method, params) {
    assert(commands.has(method));
    if (method === 'Target.createTarget') assert([`${origin}/own-download?case=complete`, `${origin}/own-download?case=cancel`].includes(params.url));
    const id = ++sequence;
    return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { ws.removeEventListener('message', listener); reject(Error('CDP-ack-timeout')); }, 5000);
        const listener = event => {
            const message = JSON.parse(event.data);
            if (message.id !== id) return;
            clearTimeout(timer); ws.removeEventListener('message', listener);
            message.error ? reject(Error('CDP-command-refused')) : resolve(message.result);
        };
        ws.addEventListener('message', listener);
        ws.send(JSON.stringify({ id, method, params }));
    });
}
const observer = new OwnedDownloadObserver(socket, command, origin, root);
const targets = [];
try {
    await observer.start(); // ACK is required BEFORE attachments become available.
    fs.writeFileSync(path.join(root, 'download-destination-ack'), 'owned-download-destination-ack', { flag: 'wx', mode: 0o600 });
    const result = { kind: 'actual-browser-download-operations', errors: [] };
    for (const name of ['complete', 'cancel']) {
        const target = await command(socket, 'Target.createTarget', { url: `${origin}/own-download?case=${name}`, background: true });
        targets.push(target.targetId);
        const deadline = Date.now() + 8000;
        while (Date.now() < deadline) {
            const receipt = await observer.receipt(name);
            if (!receipt.pending) { result[name] = receipt; break; }
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        assert(result[name], 'download-terminal-observation-missing');
    }
    result.errors = [...observer.errors];
    assert.deepEqual(verifyDownloads(result), []);
    fs.writeFileSync(path.join(root, 'background-download-receipt.json'), JSON.stringify(result), { flag: 'wx', mode: 0o600 });
    console.log(JSON.stringify({ downloadComplete: true, cancellationVerified: true, privateDestinationAcknowledged: true }));
} finally {
    for (const targetId of targets) await command(socket, 'Target.closeTarget', { targetId }).catch(() => {});
    observer.dispose(); socket.close();
}
