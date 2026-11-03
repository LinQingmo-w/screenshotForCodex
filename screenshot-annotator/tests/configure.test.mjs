import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, copyFile, readFile, stat, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { configure } from '../scripts/configure.mjs';

test('portable MCP uses a contained executable and starts from quoted source paths', async t => {
  const temporary = await mkdtemp(path.join(tmpdir(), 'annotator-config-'));
  t.after(() => rm(temporary, { recursive: true, force: true }));
  const root = path.join(temporary, "插件 ' quoted $(literal)");
  await mkdir(path.join(root, 'scripts'), { recursive: true });
  await mkdir(path.join(root, 'server'));
  await copyFile(new URL('../server/main.mjs', import.meta.url), path.join(root, 'server/main.mjs'));
  await configure(root);
  const { mcpServers } = JSON.parse(await readFile(path.join(root, 'mcp.json'), 'utf8'));
  const server = mcpServers['screenshot-annotator'];
  assert.match(server.command, /^\.\//);
  assert.equal(path.isAbsolute(server.command), false);
  assert.equal(server.command.split('/').includes('..'), false);
  const executable = path.join(root, server.command);
  assert.ok((await stat(executable)).mode & 0o111);
  // 从其他目录执行，验证中文、空格、shell 字符和插件安装目录不影响启动。
  const child = spawn(executable, server.args, { cwd: tmpdir(), stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  let errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  child.stdin.end(JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list' }) + '\n');
  const timer = setTimeout(() => child.kill(), 5000);
  const code = await new Promise((resolve, reject) => { child.on('close', resolve); child.on('error', reject); });
  clearTimeout(timer);
  assert.equal(code, 0, errors);
  assert.equal(errors, '');
  assert.ok(JSON.parse(output).result.tools.some(tool => tool.name === 'start_screenshot'));
});
