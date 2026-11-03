import { chmod, realpath, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

/** 将本机路径编码为单个 shell 字面量，支持空格、单引号及美元符号。 */
function shellQuote(value) { return "'" + value.replaceAll("'", "'\\''") + "'"; }

/** 生成插件内部的可执行入口；绝对路径只存在脚本内，不能作为 portable MCP command。 */
export async function configure(root) {
  const launcher = path.join(root, 'scripts/launch-server.sh');
  await writeFile(launcher, '#!/bin/sh\nset -eu\nexec ' + shellQuote(process.execPath) + ' ' + shellQuote(path.join(root, 'server/main.mjs')) + '\n', { mode: 0o755 });
  await chmod(launcher, 0o755);
  const quickLauncher = path.join(root, 'scripts/quick-start.sh');
  await writeFile(quickLauncher, '#!/bin/sh\nset -eu\nexec ' + shellQuote(process.execPath) + ' ' + shellQuote(path.join(root, 'server/start.mjs')) + '\n', { mode: 0o755 });
  await chmod(quickLauncher, 0o755);
  const server = { type: 'stdio', command: './scripts/launch-server.sh', args: [] };
  await writeFile(path.join(root, 'mcp.json'), JSON.stringify({
    $schema: 'https://agent-plugins.org/schemas/1.0.0/mcp.schema.json',
    mcpServers: { 'screenshot-annotator': server },
  }, null, 2) + '\n');
}

if (process.argv[1] && await realpath(process.argv[1]).catch(() => '') === fileURLToPath(import.meta.url)) {
  await configure(fileURLToPath(new URL('../', import.meta.url)));
  console.log('已生成插件内部启动入口及 mcp.json；源码移动或换机器后请重新 configure 并刷新安装。');
}
