import { constants } from 'node:fs';
import { access, mkdir, open, readFile, unlink, writeFile, stat, realpath } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

// 不依赖工作目录，避免 Codex 从其他项目启动时找不到原生 App。
const projectRoot = fileURLToPath(new URL('../', import.meta.url));
const execute = promisify(execFile);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const terminalStates = new Set(['attached', 'paste_requested', 'saved', 'cancelled', 'error']);
const emptySchema = { type: 'object', properties: {}, additionalProperties: false };
const sessionSchema = {
  type: 'object', properties: { session_id: { type: 'string', description: 'start_screenshot 返回的会话 UUID。' } },
  required: ['session_id'], additionalProperties: false,
};

/** 工具声明只暴露插件自己的会话，不接受文件路径或任意命令。 */
export const toolDefinitions = [
  { name: 'start_screenshot', description: '启动 macOS 截图与标注窗口，可在其他应用截图，完成后返回最近的 Codex 聊天。点击 ✓ 后尝试附图到当前输入框；不改文字、不发送消息。立即返回 session_id，请等待用户操作，勿循环查询。需要已构建原生 App。', inputSchema: emptySchema, annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false } },
  { name: 'get_screenshot_status', description: '查询一个截图会话。paste_requested 只表示已发出粘贴快捷键，不保证附件已显示；须用户确认。', inputSchema: sessionSchema, annotations: { readOnlyHint: true, openWorldHint: false } },
  { name: 'read_screenshot', description: '用户明确要求分析完成的标注图时读取 PNG。不会把图片附加到用户输入框，不要用它替代对勾的附图操作。', inputSchema: sessionSchema, annotations: { readOnlyHint: true, openWorldHint: false } },
];

/** 创建可注入启动器的业务服务；测试使用临时目录，绝不打开真实截图窗口。 */
export function createService({
  root = path.join(homedir(), 'Library/Application Support/ScreenshotAnnotator/sessions'),
  appPath = path.join(projectRoot, '.build/Screenshot Annotator.app'),
  preferFocusedComposer = false,
  launch = async (sessionID, sessionRoot) => {
    await access(path.join(appPath, 'Contents/MacOS/ScreenshotAnnotator'), constants.X_OK);
    // 后台启动保留原 Codex 前台状态，让原生进程先记录窗口和输入框再请求截图。
    const args = ['-g', '-n', appPath, '--args', '--session', sessionID, '--root', sessionRoot];
    if (preferFocusedComposer) args.push('--focused-composer');
    await execute('/usr/bin/open', args, { timeout: 10000 });
  },
} = {}) {
  /** 验证工具参数及 UUID，确保不能跳出插件自己的会话目录。 */
  function validateArguments(name, args) {
    if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('arguments 必须是对象。');
    const allowed = name === 'start_screenshot' ? [] : ['session_id'];
    if (Object.keys(args).some(key => !allowed.includes(key))) throw new Error('包含不支持的参数。');
    if (allowed.length && !uuidPattern.test(args.session_id ?? '')) throw new Error('session_id 必须是截图会话 UUID。');
  }

  /** 原生进程用原子写更新状态；只返回已知字段，不泄漏文件系统其他内容。 */
  async function readStatus(sessionID) {
    const data = JSON.parse(await readFile(path.join(root, sessionID, 'status.json'), 'utf8'));
    return { session_id: sessionID, state: data.state, message: data.message,
      image_path: data.image_path && terminalStates.has(data.state) ? path.join(root, sessionID, 'annotated.png') : undefined };
  }

  /** 串行执行旧锁清理和新锁创建，防止另一进程误删刚创建的活动锁。 */
  async function start() {
    await mkdir(root, { recursive: true, mode: 0o700 });
    const startingPath = path.join(root, 'starting.lock');
    let starting;
    try { starting = await open(startingPath, 'wx', 0o600); }
    catch (error) {
      if (error.code === 'EEXIST') throw new Error('已有截图会话正在启动，请稍后重试；如进程异常退出，请按 README 清理启动锁。');
      throw error;
    }
    try {
      await starting.writeFile(String(process.pid));
      return await startLocked();
    } finally {
      await starting.close();
      await unlink(startingPath);
    }
  }

  /** 持有 starting.lock 时创建唯一活动会话，防止多个窗口竞争剪贴板。 */
  async function startLocked() {
    const lockPath = path.join(root, 'active.lock');
    // 只在上一个会话已明确结束时释放锁；崩溃留下的锁交由用户核对后清理。
    try {
      const previous = (await readFile(lockPath, 'utf8')).trim();
      if (uuidPattern.test(previous) && terminalStates.has((await readStatus(previous)).state)) await unlink(lockPath);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    let lock;
    try { lock = await open(lockPath, 'wx', 0o600); }
    catch (error) {
      if (error.code === 'EEXIST') throw new Error('已有截图会话正在进行。请先完成或关闭标注窗口；如进程异常退出，请按 README 恢复步骤清理锁。');
      throw error;
    }
    const sessionID = randomUUID();
    try {
      await lock.writeFile(sessionID);
      await lock.close();
      const directory = path.join(root, sessionID);
      await mkdir(directory, { mode: 0o700 });
      await writeFile(path.join(directory, 'status.json'), JSON.stringify({ state: 'launching', message: '正在启动截图标注。' }), { mode: 0o600 });
      await launch(sessionID, root);
      return { session_id: sessionID, state: 'launching', message: '已发起截图。请操作截图标注窗口；点击 ✓ 尝试附图，不会自动发送。' };
    } catch (error) {
      await lock.close().catch(() => {});
      await writeFile(path.join(root, sessionID, 'status.json'), JSON.stringify({ state: 'error', message: String(error.message) })).catch(() => {});
      await unlink(lockPath).catch(() => {});
      throw new Error(`截图启动失败：${error.message}。请先执行 npm run build:native，并确认本地桌面环境可用。`);
    }
  }

  /** 调用已声明的工具；异常作为 MCP 工具错误返回，而不是使服务进程崩溃。 */
  async function call(name, args = {}) {
    if (!toolDefinitions.some(tool => tool.name === name)) throw new Error(`未知工具：${name}`);
    validateArguments(name, args);
    if (name === 'start_screenshot') return start();
    const status = await readStatus(args.session_id);
    if (name === 'get_screenshot_status') return status;
    if (!['attached', 'paste_requested', 'saved'].includes(status.state)) throw new Error('当前会话还没有完成的标注图。');
    const imagePath = path.join(root, args.session_id, 'annotated.png');
    const info = await stat(imagePath);
    if (info.size > 16 * 1024 * 1024) throw new Error('PNG 超过 16 MiB，请在本地查看。');
    return { content: [{ type: 'image', mimeType: 'image/png', data: (await readFile(imagePath)).toString('base64') }] };
  }
  return { call };
}

/** 最小 stdio JSON-RPC/MCP 路由；只声明实际实现的工具能力。 */
export async function dispatch(request, service) {
  if (!request || request.jsonrpc !== '2.0' || typeof request.method !== 'string') return { jsonrpc: '2.0', id: request?.id ?? null, error: { code: -32600, message: 'Invalid Request' } };
  if (request.id === undefined) return null;
  const response = { jsonrpc: '2.0', id: request.id };
  try {
    switch (request.method) {
      case 'initialize': {
        const supported = ['2024-11-05', '2025-03-26', '2025-06-18', '2025-11-25'];
        response.result = { protocolVersion: supported.includes(request.params?.protocolVersion) ? request.params.protocolVersion : '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'screenshot-annotator', version: '0.7.3' } };
        break;
      }
      case 'ping': response.result = {}; break;
      case 'tools/list': response.result = { tools: toolDefinitions }; break;
      case 'tools/call': {
        try {
          const result = await service.call(request.params?.name, request.params?.arguments ?? {});
          response.result = result.content ? result : { content: [{ type: 'text', text: JSON.stringify(result) }] };
        } catch (error) { response.result = { isError: true, content: [{ type: 'text', text: error.message }] }; }
        break;
      }
      default: response.error = { code: -32601, message: 'Method not found' };
    }
  } catch (error) { response.error = { code: -32603, message: error.message }; }
  return response;
}

/** 按行处理 MCP stdio；日志不写 stdout，EOF 后不保留后台循环。 */
async function main() {
  const service = createService();
  const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of input) {
    if (!line.trim()) continue;
    let response;
    try {
      if (Buffer.byteLength(line) > 1024 * 1024) throw new Error('Request too large');
      response = await dispatch(JSON.parse(line), service);
    } catch { response = { jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }; }
    if (response) process.stdout.write(JSON.stringify(response) + '\n');
  }
}
// Node 会解析模块符号链接，argv 可能仍含 /var 等别名；比较真实路径以免静默跳过服务启动。
if (process.argv[1] && await realpath(process.argv[1]).catch(() => '') === fileURLToPath(import.meta.url)) main().catch(error => { console.error(error.message); process.exitCode = 1; });
