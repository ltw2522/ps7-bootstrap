/**
 * 自动引导自测：验证「装上插件就自动干活」这条路径真的通。
 *
 * 关键难点在于 ctx 是个假对象：
 *   - effect(fn) 只登记 fn，绝不能调用它。cordis 的约定是 effect 传入的是
 *     清理器工厂，调用点由框架安排在卸载时。这里如果立刻调用，
 *     定时器还没到期就被 clearTimeout，测试会永远等不到 lastAutoRun。
 *   - tools.register 只记录注册了什么，不做校验。
 *
 * profile 用一个临时目录顶替：里面的 cordis.patch.yml 不含 pwsh-sandbox，
 * 这样 looksReady() 必然为假，才能触发自动排程这条分支。
 * 跑完删掉临时目录，不碰真实 profile。
 *
 * 用法：node test/autotest.mjs
 */

import { mkdirSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/** 临时的假 profile 目录，避免污染真实的 ~/.dsh/profiles */
const FAKE_PROFILE = join(tmpdir(), 'ps7-autotest-profile');

// 造一个「还没锁定」的干净 patch：只有无关条目
rmSync(FAKE_PROFILE, { recursive: true, force: true });
mkdirSync(FAKE_PROFILE, { recursive: true });
writeFileSync(
  join(FAKE_PROFILE, 'cordis.patch.yml'),
  '- id: some-other-plugin\n  name: some-other-plugin\n',
  'utf8',
);

// 让插件把这里当成当前 profile
process.env.DSH_PROFILE_DIR = FAKE_PROFILE;

const entry = await import(pathToFileURL(join(HERE, '..', 'index.js')).href);

/** 只登记不调用，模拟 cordis 的 effect 语义 */
const disposers = [];
const registered = [];
const ctx = {
  effect(fn) {
    disposers.push(fn);
  },
  tools: {
    register(tool) {
      registered.push(tool);
      return () => {};
    },
  },
};

let failures = 0;
const check = (label, actual, expected) => {
  const ok = actual === expected;
  console.log(`  ${ok ? '✓' : '✗'} ${label} = ${JSON.stringify(actual)}${ok ? '' : `（期望 ${JSON.stringify(expected)}）`}`);
  if (!ok) failures += 1;
};

console.log('\n──── 自动引导自测 ────');

// 1) 干净 patch 上必须判为「没就绪」
check('looksReady() 未就绪', entry.looksReady(), false);

// 2) 走 apply：应注册工具并排一次定时器
entry.apply(ctx, { autoRun: 'lock-only' });
check('注册的工具名', registered[0]?.name, 'ps7_bootstrap');
check('排程的 disposer 数量', disposers.length, 1);

// 3) 等自动跑完。lock 动作只写 YAML，通常 1~3 秒
process.stdout.write('  等待自动引导完成');
const deadline = Date.now() + 60000;
while (entry.lastAutoRun === null && Date.now() < deadline) {
  process.stdout.write('.');
  await new Promise((resolve) => setTimeout(resolve, 500));
}
console.log('');

if (entry.lastAutoRun === null) {
  console.log('  ✗ lastAutoRun 仍为 null：自动引导未在 60 秒内结束');
  failures += 1;
} else {
  check('lastAutoRun.ok', entry.lastAutoRun.ok, true);
  console.log(`    detail: ${entry.lastAutoRun.steps?.[0]?.detail ?? '(无)'}`);
}

// 4) 副作用核对：临时 patch 上应该真的多了 pwsh-sandbox 条目
const patched = readFileSync(join(FAKE_PROFILE, 'cordis.patch.yml'), 'utf8');
check('临时 profile 已补上锁定', /id:\s*pwsh-sandbox/.test(patched), true);

// 5) 清理 disposer 再删目录，模拟插件卸载
for (const dispose of disposers) {
  if (typeof dispose === 'function') dispose();
}
rmSync(FAKE_PROFILE, { recursive: true, force: true });
check('临时 profile 已清理', existsSync(FAKE_PROFILE), false);

console.log(`\n==== ${failures === 0 ? '全部通过' : `${failures} 项失败`} ====\n`);

// 定时器虽 unref，但子进程句柄可能残留，显式退出
process.exit(failures === 0 ? 0 : 1);
