/**
 * 插件自测：把真实入口 import 进来，逐个动作跑一遍引导脚本。
 *
 * 为什么这么测而不是直接跑 .ps1：
 *   插件层要保证的不只是「脚本能跑」，还有「结果行能被解析、
 *   步骤数组能被整形、失败能被渲染成报告」。这些只有走 index.js 才覆盖得到。
 *
 * 除 install / all 之外的动作都是幂等的、只读或只补缺失项，
 * 所以可以在已经配好的机器上重复跑，不会污染环境。
 *
 * 用法：node test/selftest.mjs [动作列表...]
 *   缺省跑 detect verify integrate lock
 */

import { pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

// 动态 import：本文件在 test/ 下，入口在上一级
const entry = await import(pathToFileURL(join(HERE, '..', 'index.js')).href);

/** 缺省动作集：全是幂等动作，重复跑安全 */
const DEFAULT_ACTIONS = ['detect', 'verify', 'integrate', 'lock'];

const actions = process.argv.slice(2).length > 0 ? process.argv.slice(2) : DEFAULT_ACTIONS;

let failed = 0;

for (const action of actions) {
  const started = Date.now();
  process.stdout.write(`\n──── ${action} ────\n`);

  try {
    const result = await entry.ps7Tool.execute({ action }, { signal: undefined });
    const elapsed = Date.now() - started;

    // 逐条打印步骤，失败时能直接看到断在哪一步
    for (const step of result.steps) {
      console.log(`  ${step.ok === true ? '✓' : '✗'} ${step.step} — ${step.detail}`);
    }
    console.log(`  结果 ok=${result.ok} failed=${result.failed} 耗时 ${elapsed} ms`);

    if (result.ok !== true) failed += 1;
  } catch (error) {
    // 抛异常说明不是「某步失败」，而是脚本没起来或结果行坏掉，必须单独标红
    console.log(`  ✗ 抛异常：${error instanceof Error ? error.message : String(error)}`);
    failed += 1;
  }
}

console.log(`\n==== 合计：${actions.length - failed}/${actions.length} 个动作通过 ====\n`);

// 子进程的 stdio 句柄在 Windows 上不会立刻回收，不显式退出会挂住
process.exit(failed === 0 ? 0 : 1);
