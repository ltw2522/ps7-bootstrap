/**
 * PowerShell 7 引导插件
 *
 * 把「把本机 PowerShell 升级到 7 并接入系统」这件事收成一个工具：
 * 检测、下载安装、写系统集成项、锁定 DSH 的执行器、实测校验。
 *
 * 真正干活的是同包的 scripts/ps7-bootstrap.ps1，本文件只负责
 * 参数校验、进程调度、超时与信号处理、结构化结果整形。
 * 拆成两层的原因：脚本可以脱离 DSH 单独跑（给别的机器用），
 * 插件层只负责把它接进模型可调用的接口。
 *
 * 不 import @deepseek-ai/dsh-tools：本包以目录形式安装时，
 * 模块解析从包的真实路径出发，找不到 harness 的 node_modules。
 * 工具定义直接按 registry 要求的形态手写 JSON Schema，零运行时依赖，
 * 这样同一份包在别的机器上也能直接装。
 *
 * @module ps7-bootstrap
 */

import { spawn } from 'node:child_process';
import { lstatSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const name = 'ps7-bootstrap';

/** 只依赖工具注册表；不需要 fs、shell 或网络服务。 */
const inject = ['tools'];

/** 本包所在目录，用于定位随包分发的脚本。 */
const HERE = dirname(fileURLToPath(import.meta.url));

/** 引导脚本的绝对路径。 */
const SCRIPT = join(HERE, 'scripts', 'ps7-bootstrap.ps1');

/**
 * 固定使用 Windows PowerShell 5.1 作为脚本宿主。
 *
 * 这不是笔误：本工具的首要任务就是在「还没装 7」的机器上装 7，
 * 所以启动器必须是系统自带的 5.1，不能依赖 pwsh。
 */
const PS51 = join(
  process.env.SystemRoot ?? 'C:\\Windows',
  'System32',
  'WindowsPowerShell',
  'v1.0',
  'powershell.exe',
);

/** 脚本用这个前缀把结构化结果单独打成一行。 */
const MARKER = '##PS7RESULT##';

/** 默认超时：安装要拉约 350 MB，给足 30 分钟。 */
const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

/** 可用动作集合，供 schema 与运行期双重校验共用。 */
const ACTIONS = ['detect', 'install', 'integrate', 'lock', 'verify', 'all', 'auto'];

/**
 * 调起引导脚本并收集输出。
 *
 * @param action 动作名，须属于 {@link ACTIONS}。
 * @param options 版本、镜像、强制重装与超时。
 * @param signal 调用方中断信号，触发时强杀子进程。
 * @returns 解析后的结构化结果，以及原始输出（供排障）。
 */
function runBootstrap(action, options, signal) {
  const { version, mirror, force, timeoutMs } = options;

  return new Promise((resolve, reject) => {
    // -ExecutionPolicy Bypass：目标机器可能仍是 Restricted，否则脚本直接被拒
    const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', SCRIPT, '-Action', action, '-Version', version];
    if (mirror !== undefined && mirror.length > 0) args.push('-Mirror', mirror);
    if (force === true) args.push('-Force');

    const child = spawn(PS51, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });

    let stdout = '';
    let stderr = '';
    let settled = false;
    let timer;

    /** 统一收尾：清定时器、摘监听，避免重复结算。 */
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (signal !== undefined) signal.removeEventListener('abort', onAbort);
      fn(value);
    };

    /** 用户中断：先礼后兵，超时未退再强杀。 */
    const onAbort = () => {
      child.kill();
      setTimeout(() => child.kill('SIGKILL'), 2000).unref?.();
      finish(reject, new Error('ps7_bootstrap: 调用被中断'));
    };

    if (signal !== undefined) {
      if (signal.aborted) {
        onAbort();
        return;
      }
      signal.addEventListener('abort', onAbort, { once: true });
    }

    timer = setTimeout(() => {
      child.kill();
      finish(reject, new Error(`ps7_bootstrap: 超过 ${Math.round(timeoutMs / 60000)} 分钟未完成，已终止`));
    }, timeoutMs);

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });

    child.on('error', (error) => {
      finish(reject, new Error(`ps7_bootstrap: 无法启动脚本宿主 ${PS51}：${error.message}`));
    });

    child.on('close', (code) => {
      // 结果行可能被缓冲拆开，所以从完整 stdout 里找最后一次出现
      const index = stdout.lastIndexOf(MARKER);
      if (index < 0) {
        const tail = (stdout + stderr).slice(-1200);
        finish(reject, new Error(`ps7_bootstrap: 脚本未输出结果行（退出码 ${code}）。输出尾部：\n${tail}`));
        return;
      }

      const line = stdout.slice(index + MARKER.length).split(/\r?\n/, 1)[0];
      let parsed;
      try {
        parsed = JSON.parse(line);
      } catch (error) {
        finish(reject, new Error(`ps7_bootstrap: 结果行不是合法 JSON：${error.message}`));
        return;
      }

      resolve({ result: parsed, log: stdout.slice(0, index).trim(), stderr: stderr.trim() });
    });
  });
}

/**
 * 把结构化结果渲染成一段人能直接读的报告。
 *
 * 步骤明细全部保留：失败时模型需要看到是哪一步断的，
 * 而不是只看一个 ok=false。
 */
function renderReport(result, log) {
  const lines = [];
  const head = result.ok === true ? '完成' : `有 ${result.failed} 步失败`;
  lines.push(`PowerShell 7 引导 · ${result.action} · ${head}`);
  lines.push('');

  for (const step of result.steps) {
    lines.push(`${step.ok === true ? '✓' : '✗'} \`${step.step}\` — ${step.detail}`);
  }

  if (result.ok !== true) {
    lines.push('');
    lines.push('失败步骤不撤销已成功的部分；修正原因后可只重跑对应 action，或直接跑 all 幂等补齐。');
  }

  if (log.length > 0) {
    lines.push('');
    lines.push('过程日志：');
    lines.push('```text');
    lines.push(log.length > 4000 ? `…（省略 ${log.length - 4000} 字符）\n${log.slice(-4000)}` : log);
    lines.push('```');
  }

  return lines.join('\n');
}

/** 工具定义：参数与输出都按 registry 支持的标准 JSON Schema 子集手写。 */
const ps7Tool = {
  name: 'ps7_bootstrap',
  description:
    '在 Windows 上把 PowerShell 7 落地到本机并接入系统：检测现状、下载安装、写系统集成项、'
    + '把 DSH 的 shell 执行器锁定到 7、实测校验。安装走 MSIX 用户级部署，不需要管理员权限；'
    + '系统集成只写当前用户（HKCU）与终端设置文件，改前自动留 .ps7bak 备份。'
    + 'install 需下载约 350 MB，耗时数分钟到十几分钟；detect 与 verify 只读。',
  parameters: {
    type: 'object',
    properties: {
      action: {
        type: 'string',
        enum: ACTIONS,
        description:
          'detect 只读检查现状；install 下载并安装；integrate 写系统集成（终端默认 profile、'
          + '系统默认终端委托、资源管理器右键、Win+R 的 powershell 解析、.ps1 关联）；'
          + 'lock 把 DSH 的 pwshPath 钉死到 7；verify 实跑校验；'
          + 'all 依次跑 install → integrate → lock → verify；'
          + 'auto 先做廉价判定，已就绪就一步不动、有缺口才补（插件加载时自动调用这个）。',
      },
      version: {
        type: 'string',
        description: '目标版本号，需与 GitHub release 的 tag 一致。默认 7.7.0。',
      },
      mirror: {
        type: 'string',
        description:
          '下载镜像前缀，例如 https://ghproxy.net/https://github.com。'
          + '留空时按内置镜像列表依次尝试，最后回退 GitHub 直连——国内直连常超时。',
      },
      force: {
        type: 'boolean',
        description: '已安装同版本时仍强制重新下载并覆盖安装。默认 false。',
      },
      timeoutMs: {
        type: 'number',
        description: '整体超时毫秒数，默认 1800000（30 分钟）。慢网络下可调高。',
      },
    },
    required: ['action'],
    additionalProperties: false,
  },
  output: {
    schema: {
      type: 'object',
      properties: {
        ok: { type: 'boolean' },
        action: { type: 'string' },
        failed: { type: 'integer' },
        summary: { type: 'string' },
        steps: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              step: { type: 'string' },
              ok: { type: 'boolean' },
              detail: { type: 'string' },
            },
            required: ['step', 'ok', 'detail'],
            additionalProperties: false,
          },
        },
      },
      required: ['ok', 'action', 'failed', 'summary', 'steps'],
      additionalProperties: false,
    },
    render: (_args, value) => [{ type: 'text', text: value.summary }],
  },
  async execute(args, exec) {
    if (!ACTIONS.includes(args.action)) {
      throw new Error(`ps7_bootstrap: 未知 action ${JSON.stringify(args.action)}，可用：${ACTIONS.join(' / ')}`);
    }

    const timeoutMs = typeof args.timeoutMs === 'number' && args.timeoutMs > 0 ? args.timeoutMs : DEFAULT_TIMEOUT_MS;
    const { result, log } = await runBootstrap(
      args.action,
      {
        version: typeof args.version === 'string' && args.version.length > 0 ? args.version : '7.7.0',
        mirror: args.mirror,
        force: args.force === true,
        timeoutMs,
      },
      exec.signal,
    );

    // 只有一步时 5.1 的 ConvertTo-Json 会把数组退化成对象，这里统一回数组
    const steps = Array.isArray(result.steps) ? result.steps : result.steps === undefined ? [] : [result.steps];

    return {
      ok: result.ok === true,
      action: typeof result.action === 'string' ? result.action : args.action,
      failed: typeof result.failed === 'number' ? result.failed : steps.filter((s) => s.ok !== true).length,
      steps,
      summary: renderReport({ ...result, steps }, log),
    };
  },
};

/**
 * 当前 profile 的 patch 里是否已有 pwsh-sandbox 条目。读不到就当没有。
 */
function patchAlreadyLocked() {
  const dir = process.env.DSH_PROFILE_DIR;
  if (dir === undefined) return false;
  try {
    return /id:\s*pwsh-sandbox/.test(readFileSync(join(dir, 'cordis.patch.yml'), 'utf8'));
  } catch {
    return false;
  }
}

/**
 * 判断路径是否存在，**不跟随符号链接**。
 *
 * WindowsApps 里的 pwsh.exe 是应用执行别名——一个指向受保护包目录的
 * reparse point。跟随它去 stat 目标会因 ACL 拒绝而抛 EACCES，
 * 于是 existsSync 一路返回 false，明明装了 7 却判成没装。
 * lstatSync 只读链接本身，不碰目标，正好避开这个坑。
 * （DSH 自己的 dsh-pwsh-local 用同一个办法认别名。）
 */
function pathExists(target) {
  try {
    lstatSync(target);
    return true;
  } catch {
    return false;
  }
}

/**
 * 本机是否「已经什么都不用做」。
 *
 * 只用两次文件系统探测就下结论，不启子进程：
 *   1. 执行别名 pwsh.exe 在不在（MSIX 装好后一定有）
 *   2. 当前 profile 的 patch 里有没有 pwsh-sandbox 条目
 *
 * 判为真时插件加载零开销；判为假就交给脚本——脚本的探测比这里细
 * （多 profile 兜底、DSH 版本护栏），宁可多跑一次也不要漏修。
 */
function looksReady() {
  const local = process.env.LOCALAPPDATA;
  if (local === undefined) return false;
  if (!pathExists(join(local, 'Microsoft', 'WindowsApps', 'pwsh.exe'))) return false;
  return patchAlreadyLocked();
}

/** 最近一次自动引导的结果；null 表示没跑过（配置 off，或判定已就绪）。 */
let lastAutoRun = null;

/**
 * 按配置安排一次自动引导，让「装上插件」和「配置到位」合并成一件事。
 *
 * 三个取舍：
 *   - 延迟 2 秒启动，把 IO 让给 DSH 自己的初始化；
 *   - 定时器 unref，不阻止进程退出；
 *   - 全程不阻塞、不抛异常。自动引导失败绝不能拖垮宿主启动，
 *     失败只记进 lastAutoRun，用户随时能手动跑 ps7_bootstrap 补。
 */
function scheduleAutoRun(ctx, config) {
  const mode = config?.autoRun ?? 'full';
  if (mode === 'off') return;

  // 已经配好的机器：连子进程都不起
  if (looksReady()) return;

  const action = mode === 'lock-only' ? 'lock' : 'auto';

  const timer = setTimeout(() => {
    runBootstrap(action, { version: '7.7.0', timeoutMs: DEFAULT_TIMEOUT_MS })
      .then(({ result }) => {
        const steps = Array.isArray(result.steps) ? result.steps : [result.steps];
        lastAutoRun = { at: new Date().toISOString(), action, ok: result.ok === true, steps };
      })
      .catch((error) => {
        lastAutoRun = {
          at: new Date().toISOString(),
          action,
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        };
      });
  }, 2000);

  timer.unref?.();

  // 插件卸载或重载时取消，避免重复排程
  if (typeof ctx.effect === 'function') {
    ctx.effect(() => () => clearTimeout(timer));
  }
}

/**
 * 插件入口：注册 ps7_bootstrap 工具，并按配置自动跑一次引导。
 *
 * @param ctx 携带工具注册表的插件上下文。
 * @param config 插件配置，来自 profile 的 cordis.patch.yml。
 */
function apply(ctx, config) {
  ctx.tools.register(ps7Tool);
  scheduleAutoRun(ctx, config);
}

export { apply, inject, lastAutoRun, looksReady, name, ps7Tool };
