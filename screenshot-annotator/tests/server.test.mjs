import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createService, dispatch } from '../server/main.mjs';

/** 每个测试使用隔离临时会话；不写用户截图目录，不启动 App。 */
async function fixture(t, launch = async () => {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'annotator-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, service: createService({ root, launch }) };
}

test('MCP handshake, notifications and tool listing expose only implemented capabilities', async t => {
  const { service } = await fixture(t);
  const initialized = await dispatch({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }, service);
  assert.equal(initialized.result.protocolVersion, '2025-06-18');
  assert.deepEqual(initialized.result.capabilities, { tools: {} });
  assert.equal(await dispatch({ jsonrpc: '2.0', method: 'notifications/initialized' }, service), null);
  const listed = await dispatch({ jsonrpc: '2.0', id: 2, method: 'tools/list' }, service);
  assert.deepEqual(listed.result.tools.map(tool => tool.name), ['start_screenshot', 'get_screenshot_status', 'read_screenshot']);
});

test('new session is persisted and passed to launcher without accepting arbitrary paths', async t => {
  let invocation;
  const { root, service } = await fixture(t, async (...args) => { invocation = args; });
  const result = await service.call('start_screenshot', {});
  assert.match(result.session_id, /^[0-9a-f-]{36}$/);
  assert.deepEqual(invocation, [result.session_id, root]);
  assert.equal(JSON.parse(await readFile(path.join(root, result.session_id, 'status.json'), 'utf8')).state, 'launching');
  await assert.rejects(service.call('get_screenshot_status', { session_id: '../../etc/passwd' }), /UUID/);
  await assert.rejects(service.call('start_screenshot', { command: 'anything' }), /不支持/);
  await assert.rejects(service.call('read_screenshot', { session_id: result.session_id }), /还没有完成/);
});

test('one active session prevents overlapping clipboard workflows, completed session permits next', async t => {
  const { root, service } = await fixture(t);
  const first = await service.call('start_screenshot');
  await assert.rejects(service.call('start_screenshot'), /已有截图会话/);
  const secondServer = createService({ root, launch: async () => {} });
  await assert.rejects(secondServer.call('start_screenshot'), /已有截图会话/);
  await writeFile(path.join(root, first.session_id, 'status.json'), JSON.stringify({ state: 'cancelled', message: 'Cancelled' }));
  const second = await service.call('start_screenshot');
  assert.notEqual(first.session_id, second.session_id);
});

test('launcher failure is returned as tool error and releases the lock for retry', async t => {
  const { root, service } = await fixture(t, async () => { throw new Error('native app missing'); });
  const result = await dispatch({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'start_screenshot', arguments: {} } }, service);
  assert.equal(result.result.isError, true);
  assert.match(result.result.content[0].text, /native app missing/);
  const recovered = createService({ root, launch: async () => {} });
  assert.equal((await recovered.call('start_screenshot')).state, 'launching');
});

test('status never promotes a paste request to confirmed upload, image tool reads only its fixed file', async t => {
  const { root, service } = await fixture(t);
  const started = await service.call('start_screenshot');
  const directory = path.join(root, started.session_id);
  await writeFile(path.join(directory, 'status.json'), JSON.stringify({ state: 'paste_requested', message: 'Await user verification', image_path: '/outside-file', secret: 'must not return' }));
  // 内容固定为测试 PNG 片段；关注服务读取路径，不启动或验证原生绘图。
  const data = Buffer.from('89504e470d0a1a0a', 'hex');
  await writeFile(path.join(directory, 'annotated.png'), data);
  const status = await service.call('get_screenshot_status', { session_id: started.session_id });
  assert.equal(status.state, 'paste_requested');
  assert.equal(status.secret, undefined);
  assert.equal(status.image_path, path.join(directory, 'annotated.png'));
  const image = await service.call('read_screenshot', { session_id: started.session_id });
  assert.equal(image.content[0].data, data.toString('base64'));
});

test('unknown tools and malformed parameters remain actionable MCP errors', async t => {
  const { service } = await fixture(t);
  for (const args of [null, [], 'bad', { session_id: 'x' }]) {
    await assert.rejects(service.call('get_screenshot_status', args));
  }
  const result = await dispatch({ jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'shell_exec' } }, service);
  assert.equal(result.result.isError, true);
  assert.match(result.result.content[0].text, /未知工具/);
});

test('real stdio transport emits parse error, handshake and tool list without logging contamination', async () => {
  const file = fileURLToPath(new URL('../server/main.mjs', import.meta.url));
  const child = spawn(process.execPath, [file], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  let errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  child.stdin.end('invalid\n' + JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18' } }) + '\n' + JSON.stringify({ jsonrpc: '2.0', id: 2, method: 'tools/list' }) + '\n');
  const timer = setTimeout(() => child.kill(), 5000);
  const code = await new Promise(resolve => child.on('close', resolve));
  clearTimeout(timer);
  assert.equal(code, 0);
  assert.equal(errors, '');
  const messages = output.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(messages.length, 3);
  assert.equal(messages[0].error.code, -32700);
  assert.equal(messages[1].result.serverInfo.name, 'screenshot-annotator');
  assert.equal(messages[2].result.tools.length, 3);
});

test('oversize output is refused before reading image contents', async t => {
  const { root, service } = await fixture(t);
  const { session_id } = await service.call('start_screenshot');
  const directory = path.join(root, session_id);
  await writeFile(path.join(directory, 'status.json'), JSON.stringify({ state: 'saved' }));
  await writeFile(path.join(directory, 'annotated.png'), Buffer.alloc(16 * 1024 * 1024 + 1));
  await assert.rejects(service.call('read_screenshot', { session_id }), /超过/);
});

test('simultaneous servers reclaiming a finished session launch at most one new window', async t => {
  const { root, service } = await fixture(t);
  const first = await service.call('start_screenshot');
  await writeFile(path.join(root, first.session_id, 'status.json'), JSON.stringify({ state: 'cancelled' }));
  let launched = 0;
  const servers = Array.from({ length: 8 }, () => createService({ root, launch: async () => { launched += 1; } }));
  const results = await Promise.allSettled(servers.map(server => server.call('start_screenshot')));
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(launched, 1, 'concurrent cleanup must not delete a newly acquired active lock');
});

test('startup ownership prevents a second server from entering lock cleanup', async t => {
  let launched = false;
  const { root, service } = await fixture(t, async () => { launched = true; });
  // 模拟另一个进程持有“清理旧锁到创建新锁”这段启动事务的所有权。
  await writeFile(path.join(root, 'starting.lock'), String(process.pid));
  await assert.rejects(service.call('start_screenshot'), /已有截图会话/);
  assert.equal(launched, false);
});
