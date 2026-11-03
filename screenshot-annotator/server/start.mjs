import { createService } from './main.mjs';

// 快捷入口只发起一次会话，复用 MCP 的活动锁；不需要聊天消息或 AI 调用。
try {
  const result = await createService({ preferFocusedComposer: true }).call('start_screenshot');
  process.stdout.write(JSON.stringify(result) + '\n');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
