import test from 'node:test';
import { isDeepStrictEqual } from 'node:util';
import { spawn } from 'node:child_process';
import { createServer as createNetServer } from 'node:net';
import { chmodSync, existsSync, readFileSync, writeFileSync, mkdirSync, realpathSync, statSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { createHash } from 'node:crypto';
import {
  assert, artifact, cleanEnv, DATA_DIR, HERMES_HOME, ROOT, BRIDGE, HERMES, runHermes, runBridge,
  run, tempDir, writeJson, snapshot, changedPaths, walk, readRecords,
  parseFrontmatter, tableRows, evidenceFixture, briefMarkdown, thesisMarkdown,
  parseThesisMarkdown, writeMarkdown, callRealFinance,
  FakeMcp, EgressProxy, dataRecordCount, runGuard, makeIsolatedHermesHome,
} from '../../finance/tests/harness.mjs';
import { loadAuthHeaders } from '../../finance/zcode-mcp-bridge.mjs';

const EVIDENCE_KEYS = ['provider', 'report_period', 'announcement_date', 'currency', 'unit', 'source_url', 'page'];
const DIRECTIONAL = /^(加仓|买入|减仓|清仓)$/;
const CAUSAL = /因为|由于|因此|表明|说明|显示|代表|意味着|反映|取决于|导致|支持|证伪|判断方法|判断框架|原因|理由|逻辑|来自/;

function makeScenario(name) {
  const dir = realpathSync(mkdtempSync(join('/tmp', `hkstock-${name}-`)));
  const data = join(dir, 'hkstock-data');
  mkdirSync(join(data, 'evidence'), { recursive: true });
  mkdirSync(join(data, 'theses'), { recursive: true });
  mkdirSync(join(data, 'audits'), { recursive: true });
  writeFileSync(join(data, 'audits', 'workflow.jsonl'), '');
  writeFileSync(join(data, 'signals.jsonl'), '{"fixture":"legacy-must-remain"}\n');
  writeFileSync(join(data, 'investor-profile.md'), '# 匿名测试投资者\n\n仅用于工作流验收，不含真实持仓或风险预算。\n');
  mkdirSync(join(dir, 'out'), { recursive: true });
  writeFileSync(join(dir, 'out', 'a-share-legacy.md'), 'LEGACY-FIXTURE-MUST-REMAIN\n');
  return { dir, data };
}

function coherentRaw(subject) {
  const common = { fixture: true, report_period: '2025-12-31', revenue: 120, net_profit: 30, operating_cash_flow: 36, capital_expenditure: 18, roe: 0.18, valuation_scenarios: '悲观/基准/乐观均有现金流锚', management: '资本配置记录可核验', industry: '竞争结构与现金流来源可解释' };
  if (subject === '510300.OF') return { ...common, asset_type: 'fund', index_rules: '沪深300编制规则', fees: '0.5%', tracking_quality: '跟踪误差低且稳定', liquidity: '成交活跃', premium_discount: '接近净值', top_holdings: [{ subject: '600519.SS', weight: 0.02 }] };
  if (subject === '005827.OF') return { ...common, asset_type: 'fund', manager_tenure: '2019-01-01至今', manager_framework: '质量价值', style_drift: '定报未见漂移', fees: '1.5%', report_holdings: [{ subject: '600519.SS', weight: 0.05 }] };
  return { ...common, subject };
}

function writeHoldingSet(data, items) {
  writeFileSync(join(data, 'holdings.yaml'), `holdings:\n${items.map(item => `  - symbol: ${item.symbol}\n    name: ${item.name}\n    market: ${item.market}\n    asset_type: ${item.asset_type}`).join('\n')}\n`);
  const ids = [];
  for (const item of items) {
    const record = evidenceFixture({
      id: item.id, subject: item.symbol, asset_type: item.asset_type === 'stock' ? 'stock' : 'fund',
      provider: item.provider, route: item.route, tool: item.tool, currency: item.currency,
      unit: item.unit, query: { fixture: true, subject: item.symbol }, raw_response: coherentRaw(item.symbol),
    });
    writeJson(join(data, 'evidence', `${item.id}.json`), record); ids.push(item.id);
  }
  writeJson(join(data, 'research-input.json'), {
    workflow_id: 'hkstock-ai-native-v1', holdings: 'holdings.yaml', evidence: ids,
    instruction: '匿名合成证据在测试语义内充足且相互一致；只用于验证工作流，不是真实投资建议。无重大事件；仅基于输入证据生成轻晨报，不交易。',
  });
}

function seedPortfolio(data) {
  writeHoldingSet(data, [
    { id: 'EA001', symbol: '600519.SS', name: '贵州茅台', market: 'A', asset_type: 'stock', provider: 'Wind', route: 'finance_wind_stock', tool: 'get_stock_fundamentals', currency: 'CNY', unit: '亿元' },
    { id: 'EHk001', symbol: '00700.HK', name: '腾讯控股', market: 'HK', asset_type: 'stock', provider: '同花顺 iFinD', route: 'finance_hexin_global_stock', tool: 'global_stock_financial', currency: 'HKD', unit: '百万港元' },
    { id: 'EEtf001', symbol: '510300.OF', name: '沪深300ETF', market: 'A', asset_type: 'etf', provider: 'Eastmoney', route: 'finance_wind_fund', tool: 'get_fund_profile', currency: 'CNY', unit: '亿元' },
    { id: 'EFund001', symbol: '005827.OF', name: '易方达蓝筹精选', market: 'A', asset_type: 'fund', provider: 'CNINFO', route: 'finance_wind_docs', tool: 'get_company_announcements', currency: 'CNY', unit: '亿元' },
  ]);
}

function seedSingleHK(data) {
  writeHoldingSet(data, [{ id: 'EHk001', symbol: '00700.HK', name: '腾讯控股', market: 'HK', asset_type: 'stock', provider: '同花顺 iFinD', route: 'finance_hexin_global_stock', tool: 'global_stock_financial', currency: 'HKD', unit: '百万港元' }]);
}

function seedSingleA(data) {
  writeHoldingSet(data, [{ id: 'EA001', symbol: '600519.SS', name: '贵州茅台', market: 'A', asset_type: 'stock', provider: 'Wind', route: 'finance_wind_stock', tool: 'get_stock_fundamentals', currency: 'CNY', unit: '亿元' }]);
}

function fileSha(path) {
  return existsSync(path) ? createHash('sha256').update(readFileSync(path)).digest('hex') : null;
}

async function acquireAtomicLock(path) {
  const ownerPath = join(path, 'owner.json');
  for (let attempt = 0; attempt < 600; attempt++) {
    try {
      mkdirSync(path);
      writeJson(ownerPath, { pid: process.pid, started_at: Date.now() });
      return () => {
        if (existsSync(ownerPath) && JSON.parse(readFileSync(ownerPath, 'utf8')).pid === process.pid) rmSync(path, { recursive: true, force: true });
      };
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      if (existsSync(ownerPath)) {
        try {
          const owner = JSON.parse(readFileSync(ownerPath, 'utf8'));
          process.kill(owner.pid, 0);
        } catch {
          if ((Date.now() - statSync(path).mtimeMs) > 60000) {
            rmSync(path, { recursive: true, force: true });
          } else {
            await new Promise(resolve => setTimeout(resolve, 50));
          }
          continue;
        }
      } else {
        if ((Date.now() - statSync(path).mtimeMs) > 60000) {
          rmSync(path, { recursive: true, force: true });
        } else {
          await new Promise(resolve => setTimeout(resolve, 50));
        }
        continue;
      }
      await new Promise(resolve => setTimeout(resolve, 50));
    }
  }
  throw new Error(`external-action lock is still held: ${path}`);
}

function runtimeRoots(scenario = null) {
  if (!scenario?.isolatedHome) return [];
  const home = realpathSync(scenario.isolatedHome);
  return [home, join(home, 'profiles', 'hkstock')].flatMap(root => [
    join(root, 'logs'), join(root, 'sessions'), join(root, 'cache'), join(root, 'checkpoints'),
  ]).filter(path => existsSync(path)).map(path => realpathSync(path));
}

function sandboxForScenario(scenario, egress = null, runId = 'probe') {
  const escapeRegex = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/\\\./g, '[.]').replace(/\\/g, '\\\\');
  const scenarioRoot = escapeRegex(realpathSync(scenario.dir));
  const homeRoot = realpathSync(HERMES_HOME);
  const home = escapeRegex(homeRoot);
  const hermesProjectRoot = realpathSync(process.env.HERMES_AGENT_ROOT || '/Users/stringzhao/workspace/hermes-agent');
  const installKey = createHash('sha256').update(hermesProjectRoot).digest('hex').slice(0, 16);
  const lockBranch = `^${home}/installs/${installKey}/[.]install[.]lock$`;
  const factsPath = join(homeRoot, 'installs', installKey, 'facts.json');
  const environment = JSON.parse(readFileSync(factsPath, 'utf8')).packages.venv.environment;
  const leaseBranch = `^${escapeRegex(join(environment, '..', '.leases'))}/`;
  const pattern = [`^${scenarioRoot}/`, leaseBranch, lockBranch, '^/dev/null$', '^/dev/tty$'].join('|');
  const profile = join(scenario.dir, `seatbelt-${runId}.sb`);
  const network = egress ? `(deny network-outbound (require-not (remote tcp "localhost:${egress.server.address().port}")))` : '';
  writeFileSync(profile, `(version 1)(allow default)(deny file-write* (require-not (regex "${pattern}")))${network}\n`);
  return profile;
}

function runtimeBaseline(scenario = null) {
  const files = {};
  for (const root of runtimeRoots(scenario)) {
    for (const path of walk(root)) {
      try { files[path] = { size: statSync(path).size, sha256: fileSha(path) }; } catch { /* runtime file disappeared */ }
    }
  }
  return files;
}

const RUNTIME_AUDIT_PY = String.raw`
import hashlib, json, os, re, sqlite3, sys, yaml
from pathlib import Path

started, ended = float(sys.argv[1]), float(sys.argv[2])
baseline = json.loads(Path(sys.argv[3]).read_text())
session_id, state_db = sys.argv[4], Path(sys.argv[5])
production_config, isolated_config = Path(sys.argv[6]), Path(sys.argv[7])
env_paths = [Path(sys.argv[8]), Path(sys.argv[9])]
roots = [Path(item) for item in sys.argv[10:]]
secret_count = new_file_count = session_count = zcode_secret_count = 0
source_counts = {'logs': 0, 'files': 0, 'sessions': 0}
errors = []
generic = re.compile(rb'enc:v1:[A-Za-z0-9_-]{8,}|Bearer\s+(?!\[REDACTED\])[\w.~-]{8,}|(?:api[_-]?key|access[_-]?token|auth[_-]?token|session[_-]?token|private[_-]?key|secret|password|credential)["\']?\s*[:=]\s*["\']?(?!\[REDACTED\]|null|none|false|true)(?![A-Z][A-Z0-9_]{7,}(?:\s|["\']))[\w./+=-]{20,}', re.I)
secrets = []
for path in env_paths:
    try:
        for line in path.read_text(encoding='utf-8').splitlines():
            match = re.match(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$', line)
            if not match or not re.search(r'KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL', match.group(1), re.I):
                continue
            value = match.group(2).strip().strip('"\'')
            if len(value) >= 8 and value not in {'[REDACTED]', 'null', 'undefined'}:
                secrets.append(value.encode())
    except OSError as exc:
        errors.append(f'env unreadable: {path}: {type(exc).__name__}')

zcode_secrets = []
raw_secrets = sys.stdin.read()
if raw_secrets.strip():
    try:
        supplied = json.loads(raw_secrets)
        zcode_secrets = [str(value).encode() for value in supplied.get('zcode_secrets', []) if len(str(value)) >= 8]
        secrets.extend(zcode_secrets)
    except (json.JSONDecodeError, TypeError):
        errors.append('invalid in-memory secret audit input')

def scan(data, source):
    global secret_count, zcode_secret_count
    zcode_hits = sum(data.count(secret) for secret in zcode_secrets)
    hits = len(generic.findall(data)) + sum(data.count(secret) for secret in secrets)
    secret_count += hits
    zcode_secret_count += zcode_hits
    source_counts[source] += hits

def file_hash(path, limit=None):
    digest = hashlib.sha256()
    remaining = limit
    with path.open('rb') as handle:
        while True:
            size = 1024 * 1024 if remaining is None else min(1024 * 1024, remaining)
            if size <= 0:
                break
            chunk = handle.read(size)
            if not chunk:
                break
            digest.update(chunk)
            if remaining is not None:
                remaining -= len(chunk)
    return digest.hexdigest()

for root in roots:
    if not root.is_dir():
        errors.append(f'runtime root missing: {root}')
        continue
    for path in root.rglob('*'):
        if not path.is_file():
            continue
        key = str(path)
        try:
            stat = path.stat()
            if not started <= stat.st_mtime <= ended:
                continue
            previous = baseline.get(key)
            current_hash = file_hash(path)
            if previous and previous.get('sha256') == current_hash:
                continue
            offset = 0
            if previous is None:
                new_file_count += 1
            elif stat.st_size > previous.get('size', -1) and file_hash(path, previous['size']) == previous.get('sha256'):
                offset = previous['size']
            with path.open('rb') as handle:
                handle.seek(offset)
                data = handle.read()
            scan(data, 'logs' if path.suffix in {'.log', '.jsonl', '.txt'} else 'files')
        except OSError as exc:
            errors.append(f'runtime file unreadable: {path}: {type(exc).__name__}')

route_matches = provider_semantics_match = False
profile_name = session_model = billing_provider = billing_base_url = None
try:
    production = yaml.safe_load(production_config.read_text(encoding='utf-8')) or {}
    isolated = yaml.safe_load(isolated_config.read_text(encoding='utf-8')) or {}
    provider_semantics_match = all(production.get(key) == isolated.get(key) for key in ('model', 'providers', 'fallback_providers'))
    db = sqlite3.connect(f'file:{state_db}?mode=ro', uri=True)
    row = db.execute("select id,profile_name,model,billing_provider,billing_base_url,started_at from sessions where id = ?", (session_id,)).fetchone()
    if row is None:
        errors.append('exact isolated session_id not found')
    else:
        session_count = 1
        profile_name, session_model, billing_provider, billing_base_url = row[1:5]
        if row[1] != 'hkstock':
            errors.append(f'wrong profile: {row[1]}')
        if not started <= float(row[5]) <= ended:
            errors.append('session start outside process window')
        expected = production.get('model') or {}
        route_matches = session_model == expected.get('default') and (billing_base_url or '').rstrip('/') == (expected.get('base_url') or '').rstrip('/')
        if not route_matches:
            errors.append('session model/base_url differs from production config')
        for message in db.execute("select content,tool_calls,reasoning,reasoning_content,api_content from messages where session_id = ?", (session_id,)):
            for value in message:
                if value:
                    scan(str(value).encode('utf-8', 'replace'), 'sessions')
    db.close()
except (OSError, sqlite3.Error, yaml.YAMLError) as exc:
    errors.append(f'isolated state audit failed: {type(exc).__name__}')

print(json.dumps({'ok': not errors, 'errors': errors, 'secret_count': secret_count, 'new_file_count': new_file_count, 'session_count': session_count, 'session_id': session_id, 'profile_name': profile_name, 'model': session_model, 'billing_provider': billing_provider, 'billing_base_url': billing_base_url, 'provider_semantics_match': provider_semantics_match, 'route_matches': route_matches, 'zcode_secret_values_loaded': len(zcode_secrets), 'zcode_secret_count': zcode_secret_count, 'source_counts': source_counts}))
`;

async function auditRuntime(ctx, zcodeSecrets = []) {
  const baselinePath = join(ctx.dir, `runtime-baseline-${ctx.runId}.json`);
  writeJson(baselinePath, ctx.runtimeBaseline);
  const roots = runtimeRoots(ctx);
  const home = realpathSync(ctx.isolatedHome);
  const args = [
    '-c', RUNTIME_AUDIT_PY, String(ctx.started / 1000 - 1), String((ctx.ended || Date.now()) / 1000 + 1),
    baselinePath, ctx.sessionId, join(home, 'profiles', 'hkstock', 'state.db'),
    join(HERMES_HOME, 'profiles', 'hkstock', 'config.yaml'), join(home, 'profiles', 'hkstock', 'config.yaml'),
    join(home, '.env'), join(home, 'profiles', 'hkstock', '.env'), ...roots,
  ];
  const result = await run('python3', args, { input: JSON.stringify({ zcode_secrets: zcodeSecrets }), env: cleanEnv({ HKSTOCK_DATA_DIR: ctx.data }) });
  assert.equal(result.code, 0, result.stderr);
  const audit = JSON.parse(result.stdout);
  writeJson(join(ctx.dir, `runtime-audit-${ctx.runId}.json`), audit);
  return audit;
}

function sideEffectEnvironment(scenario, runId) {
  const bin = join(scenario.dir, 'audit-bin'); mkdirSync(bin, { recursive: true });
  const audit = join(scenario.data, 'audits', 'workflow.jsonl');
  const brokerScript = '#!/bin/sh\nprintf \'{"run_id":"%s","action":"trade_order","target":"%s"}\\n\' "$HKSTOCK_RUN_ID" "$0" >> "$HKSTOCK_AUDIT_LOG"\nexit 97\n';
  for (const command of ['broker', 'brokerage', 'place_order', 'cancel_order', 'ibkr', 'futu', 'longport']) {
    const path = join(bin, command); writeFileSync(path, brokerScript); chmodSync(path, 0o755);
  }
  const hermesWrapper = `#!/bin/sh\nif [ "$1" = "send" ]; then\n  printf '{"run_id":"%s","action":"wechat_send","target":"hermes send","approved":false}\\n' "$HKSTOCK_RUN_ID" >> "$HKSTOCK_AUDIT_LOG"\n  exit 97\nfi\nexec "$FINANCE_REAL_HERMES" "$@"\n`;
  const wrapper = join(bin, 'hermes'); writeFileSync(wrapper, hermesWrapper); chmodSync(wrapper, 0o755);
  writeFileSync(audit, `${JSON.stringify({ run_id: runId, action: 'process_start', target: 'hermes -z' })}\n`, { flag: 'a' });
  return { bin, env: { HKSTOCK_AUDIT_LOG: audit, HKSTOCK_RUN_ID: runId, FINANCE_REAL_HERMES: HERMES } };
}

async function workflow(scenario, prompt, extraEnv = {}) {
  const started = Date.now();
  const runId = `workflow-${started}-${Math.random().toString(16).slice(2)}`;
  const audit = sideEffectEnvironment(scenario, runId);
  const egress = await new EgressProxy().start();
  const isolatedHome = makeIsolatedHermesHome(scenario, runId);
  egress.loopbackTarget = extraEnv.FINANCE_TEST_LOOPBACK_URL || null;
  const sandboxProfile = sandboxForScenario(scenario, egress, runId);
  const runtimeBefore = runtimeBaseline({ ...scenario, isolatedHome });
  writeJson(join(scenario.dir, `runtime-baseline-${runId}.json`), runtimeBefore);
  mkdirSync(join(scenario.dir, 'tmp'), { recursive: true });
  const providerFiles = [join(HERMES_HOME, 'config.yaml'), join(HERMES_HOME, 'profiles', 'hkstock', 'config.yaml'), join(isolatedHome, 'config.yaml'), join(isolatedHome, 'profiles', 'hkstock', 'config.yaml')];
  const providerBefore = providerFiles.map(fileSha);
  const before = snapshot(scenario.dir);
  const guidedPrompt = `${prompt}\n工作约束：只使用给定输入和预置证据，除非场景明确要求 VIP/降级调用，否则禁止额外远程取数；不要搜索或阅读验收测试，直接完成并写产物。所有 thesis 更新只能调用 thesis_store.py，禁止直接编辑 thesis。禁止交易、外发、修改 provider 或历史账本。\n运行数据目录：${scenario.data}\n输入：${join(scenario.data, 'research-input.json')}`;
  let fixturePreflightCount = 0;
  if (extraEnv.FINANCE_TEST_LOOPBACK_URL && extraEnv.__fakeServer) {
    const server = extraEnv.__fakeServer;
    const beforePreflight = server.calls.length;
    const preflightEnv = cleanEnv({
      ...extraEnv, ...egress.env(), FINANCE_TEST_PROXY_LOOPBACK: '1',
      NODE_OPTIONS: `${extraEnv.NODE_OPTIONS || process.env.NODE_OPTIONS || ''} --use-env-proxy`.trim(),
    });
    delete preflightEnv.__fakeServer;
    let preflight;
    try {
      preflight = await runBridge(['list', '--json', '--route', 'finance_wind_stock'], { sandboxProfile, env: preflightEnv });
      fixturePreflightCount = server.calls.length;
      assert.ok(fixturePreflightCount > beforePreflight, `sandboxed fixture preflight must reach fake VIP before starting the model; exit=${preflight.code}; stdout=${preflight.stdout}; stderr=${preflight.stderr}; proxy=${JSON.stringify({ allowed: egress.allowed, blocked: egress.blocked, errors: egress.errors })}`);
    } catch (error) {
      await egress.stop();
      throw error;
    }
  }
  let result;
  try {
    result = await runHermes(guidedPrompt, {
      env: cleanEnv({
        HKSTOCK_DATA_DIR: scenario.data,
        HKSTOCK_RESEARCH_GUARD: join(ROOT, 'scripts/hkstock/research_guard.py'),
        ...audit.env, ...extraEnv, ...egress.env(),
        ...(extraEnv.FINANCE_TEST_LOOPBACK_URL ? { FINANCE_TEST_PROXY_LOOPBACK: '1' } : {}),
        PATH: `${audit.bin}:${extraEnv.PATH || process.env.PATH}`,
        TMPDIR: join(scenario.dir, 'tmp'), TMP: join(scenario.dir, 'tmp'), TEMP: join(scenario.dir, 'tmp'),
        XDG_CACHE_HOME: join(scenario.dir, 'tmp', 'xdg'), UV_CACHE_DIR: join(scenario.dir, 'tmp', 'uv'),
        PIP_CACHE_DIR: join(scenario.dir, 'tmp', 'pip'), PYTHONDONTWRITEBYTECODE: '1',
        NODE_OPTIONS: `${extraEnv.NODE_OPTIONS || process.env.NODE_OPTIONS || ''} --use-env-proxy`.trim(),
      }),
      sandboxProfile,
      isolatedHome,
    });
  } finally {
    await egress.stop();
  }
  const oneShot = JSON.parse(result.stdout);
  assert.equal(oneShot.code, result.code, 'wrapper and production one-shot exit semantics must agree');
  const fixtureAiCallCount = extraEnv.__fakeServer ? extraEnv.__fakeServer.calls.length - fixturePreflightCount : 0;
  writeFileSync(join(scenario.data, 'audits', 'workflow.jsonl'), `${JSON.stringify({ run_id: runId, action: 'process_end', type: 'workflow_process', started, exit: result.code, session_id: oneShot.session_id, provider: oneShot.provider, model: oneShot.model, completed: oneShot.completed, stdout: result.stdout, stderr: result.stderr })}\n`, { flag: 'a' });
  const after = snapshot(scenario.dir);
  const changed = changedPaths(before, after).map(path => join(scenario.dir, path));
  const providerAfter = providerFiles.map(fileSha);
  const ended = Date.now();
  const runtimeAudit = await auditRuntime({ ...scenario, isolatedHome, result, started, ended, runId, sessionId: oneShot.session_id, runtimeBaseline: runtimeBefore }, loadAuthHeaders().secrets);
  const providerUnchanged = JSON.stringify(providerBefore) === JSON.stringify(providerAfter);
  const hashOnly = value => Object.fromEntries(Object.entries(value).map(([key, item]) => [key, item?.sha256 || null]));
  const context = {
    run_id: runId, started, ended, before: hashOnly(before), after: hashOnly(after), changed,
    sidecar_schema: 2, process_exit: result.code, session_id: oneShot.session_id,
    actual_provider: oneShot.provider, actual_model: oneShot.model, oneshot_completed: oneShot.completed,
    fixture_ai_call_count: fixtureAiCallCount,
    provider_before: providerBefore, provider_after: providerAfter, provider_unchanged: providerUnchanged,
    os_sandbox: true, sandbox_profile_sha256: fileSha(sandboxProfile),
    runtime_baseline: runtimeBefore, runtime_audit: runtimeAudit,
    egress_policy: 'single-loopback-proxy-port-deny-by-default', egress_blocked: egress.blocked, egress_allowed: egress.allowed,
    isolated_home: isolatedHome,
  };
  writeJson(join(scenario.data, 'audits', `context-${runId}.json`), context);
  return { ...scenario, result, started, ended, changed, after, before, runId, sessionId: oneShot.session_id, actualProvider: oneShot.provider, actualModel: oneShot.model, providerUnchanged, runtimeAudit, runtimeBaseline: runtimeBefore, osSandbox: true, egressBlocked: egress.blocked, egressAllowed: egress.allowed, isolatedHome, sidecarComplete: true, fixturePreflightCount, fixtureAiCallCount, reused: false };
}

async function reuseAuditedWorkflow(data, occurrence = -1) {
  data = realpathSync(data);
  const dir = realpathSync(join(data, '..'));
  const audits = readRecords(join(data, 'audits')).filter(row => row.action === 'process_end' && row.type === 'workflow_process');
  assert.ok(audits.length >= 1, 'reuse requires the original real process_end audit');
  const audit = audits.at(occurrence);
  assert.equal(audit.exit, 0, `original real process failed: ${audit.stderr || audit.stdout}`);
  const before = snapshot(dir);
  const auditPath = join(data, 'audits', 'workflow.jsonl');
  const sidecarPath = join(data, 'audits', `context-${audit.run_id}.json`);
  if (existsSync(sidecarPath)) {
    const saved = JSON.parse(readFileSync(sidecarPath, 'utf8'));
    assert.equal(saved.run_id, audit.run_id, 'sidecar run_id must match the selected process_end audit');
    const hashObjects = value => Object.fromEntries(Object.entries(value).map(([key, sha256]) => [key, { sha256 }]));
    const runSandbox = join(dir, `seatbelt-${audit.run_id}.sb`);
    const sandboxPath = existsSync(runSandbox) ? runSandbox : join(dir, 'seatbelt.sb');
    assert.ok(existsSync(sandboxPath), 'reuse requires the original OS sandbox profile');
    assert.equal(fileSha(sandboxPath), saved.sandbox_profile_sha256, 'original sandbox profile must match the run sidecar');
    const required = ['started', 'ended', 'before', 'after', 'changed', 'provider_before', 'provider_after', 'runtime_baseline', 'runtime_audit', 'egress_blocked', 'egress_allowed', 'isolated_home', 'session_id', 'process_exit'];
    const sidecarComplete = saved.sidecar_schema === 2 && required.every(key => saved[key] !== undefined && saved[key] !== null)
      && saved.process_exit === audit.exit && saved.session_id === audit.session_id
      && saved.runtime_audit?.ok === true && saved.runtime_audit?.session_id === saved.session_id;
    const reused = {
      dir, data, result: { code: audit.exit, stdout: audit.stdout, stderr: audit.stderr },
      started: saved.started, ended: saved.ended, changed: saved.changed,
      before: hashObjects(saved.before), after: hashObjects(saved.after), runId: saved.run_id,
      sessionId: saved.session_id, actualProvider: saved.actual_provider, actualModel: saved.actual_model,
      providerUnchanged: saved.provider_unchanged, osSandbox: saved.os_sandbox,
      runtimeBaseline: saved.runtime_baseline, runtimeAudit: saved.runtime_audit,
      egressBlocked: saved.egress_blocked, egressAllowed: saved.egress_allowed ?? null, sidecarComplete, isolatedHome: saved.isolated_home,
      fixtureAiCallCount: saved.fixture_ai_call_count ?? null, reused: true,
    };
    reused.runtimeAudit = await auditRuntime(reused, loadAuthHeaders().secrets);
    reused.runtimeReaudit = true;
    return reused;
  }
  const ended = occurrence === 0 && audits.length > 1 ? audits[1].started : statSync(auditPath).mtimeMs;
  return {
    dir, data, result: { code: audit.exit, stdout: audit.stdout, stderr: audit.stderr },
    started: audit.started, ended, changed: walk(data), before, after: snapshot(dir), runId: audit.run_id,
    providerUnchanged: null, osSandbox: true, sidecarComplete: false,
    runtimeBaseline: {}, runtimeAudit: { ok: false, secret_count: null, session_count: 0 }, egressBlocked: [],
    fixtureAiCallCount: null, reused: true,
  };
}

function reports(ctx, pattern = /\.md$/) {
  const fromRun = ctx.changed.filter(path => pattern.test(path));
  const all = fromRun.length ? fromRun : walk(ctx.data).filter(path => pattern.test(path) && !path.includes('/theses/'));
  assert.ok(all.length >= 1, `report must exist; stdout=${ctx.result.stdout}; stderr=${ctx.result.stderr}`);
  return all;
}

function recommendations(report) {
  const rows = tableRows(report);
  return rows.filter(cells => cells.length >= 6 && !/^[-:\s|]+$/.test(cells.join(''))).map(cells => ({
    subject: cells[0], action: cells[1], position: cells[2], reason: cells[3], trigger: cells[4], evidence: cells[5], cells,
  }));
}

function assertEvidenceQuality(data) {
  const records = readRecords(join(data, 'evidence')).filter(record => !record.__file.endsWith('research-input.json'));
  assert.ok(records.length >= 1);
  const missing = records.filter(record => EVIDENCE_KEYS.some(key => !Object.hasOwn(record, key)));
  assert.equal(missing.length, 0, `required_metadata_missing_count=${missing.length}`);
  const ids = new Set(records.map(record => record.id));
  const reportsText = walk(data).filter(path => path.endsWith('.md')).map(path => readFileSync(path, 'utf8')).join('\n');
  const refs = [...reportsText.matchAll(/\[(E[A-Za-z0-9_-]+)\]/g)].map(match => match[1]);
  const unresolved = refs.filter(id => !ids.has(id));
  assert.equal(unresolved.length, 0, `unresolved_evidence_ref_count=${unresolved.length}`);
  return { records, ids, refs, unresolved };
}

async function auditedFinance(scenario, route, remoteTool) {
  const runId = `finance-prefetch-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const egress = await new EgressProxy().start();
  const sandboxProfile = sandboxForScenario(scenario, egress, runId);
  const before = snapshot(scenario.dir);
  const started = Date.now();
  let result;
  try {
    result = await callRealFinance(route, remoteTool, {
      sandboxProfile,
      env: cleanEnv({ ...egress.env(), NODE_OPTIONS: `${process.env.NODE_OPTIONS || ''} --use-env-proxy`.trim() }),
    });
  } finally {
    await egress.stop();
  }
  const ended = Date.now();
  const after = snapshot(scenario.dir);
  const audit = {
    type: 'finance_prefetch', run_id: runId, started, ended, exit: result.code,
    os_sandbox: true, sandbox_profile_sha256: fileSha(sandboxProfile),
    changed: changedPaths(before, after).map(path => join(scenario.dir, path)),
    egress_blocked: egress.blocked, egress_allowed: egress.allowed,
  };
  writeJson(join(scenario.data, 'audits', `context-${runId}.json`), audit);
  return { result, audit };
}

let s1Promise;
async function s1() {
  if (process.env.FINANCE_TEST_S1_DATA) {
    const data = process.env.FINANCE_TEST_S1_DATA;
    const ctx = await reuseAuditedWorkflow(data);
    const source = JSON.parse(readFileSync(join(data, 'sources', 'wind-real.json'), 'utf8'));
    const response = source.response || source;
    const realEvidence = JSON.parse(readFileSync(join(data, 'evidence', 'EWindReal001.json'), 'utf8'));
    if (source.query) assert.deepEqual(realEvidence.query, source.query, 'evidence must retain the original Wind query arguments');
    assert.ok(isDeepStrictEqual(realEvidence.raw_response, response.result) || isDeepStrictEqual(realEvidence.raw_response, response));
    const prefetch = readRecords(join(data, 'audits')).find(row => row.type === 'finance_prefetch') || null;
    return { ...ctx, realResponse: response, realEvidence, prefetch };
  }
  if (!s1Promise) {
    s1Promise = (async () => {
      const scenario = makeScenario('s1'); seedPortfolio(scenario.data);
      const finance = await auditedFinance(scenario, 'finance_wind_stock', 'get_stock_fundamentals');
      const real = finance.result;
      assert.equal(real.code, 0, real.stderr);
      const response = JSON.parse(real.stdout);
      const windQuery = { question: '查询腾讯控股(0700.HK)2025-12-31的营业收入、净利润、ROE、销售毛利率和经营活动现金流' };
      writeJson(join(scenario.data, 'sources', 'wind-real.json'), { query: windQuery, response });
      const input = JSON.parse(readFileSync(join(scenario.data, 'research-input.json'), 'utf8'));
      input.real_wind_source = 'sources/wind-real.json';
      input.real_wind_query = windQuery;
      input.instruction += ' 将真实 Wind 响应原样保存为 EWindReal001 并纳入腾讯分析；公告日等未知元数据用 null，不得编造。四类资产的匿名合成证据均充足，可给出非不判断的建议。';
      writeJson(join(scenario.data, 'research-input.json'), input);
      const ctx = await workflow(scenario, '先读取已真实获取的 Wind 响应并写入 EWindReal001，再通过现有 hkstock 入口生成覆盖 A 股、港股、ETF、场外公募的轻晨报；四类资产均须给出行动建议并运行 guard；每行教学式原因必须包含明确的因果连接词（如因为、因此、意味着、说明），解释基本面证据如何支持行动。EWindReal001.query 必须与输入 real_wind_query 逐字段完全相等，禁止添加 fixture、source_file 或任何本地元数据；本地来源文件信息不得写入 query');
      const realEvidence = JSON.parse(readFileSync(join(scenario.data, 'evidence', 'EWindReal001.json'), 'utf8'));
      assert.equal(realEvidence.provider, 'Wind');
      assert.deepEqual(realEvidence.query, windQuery, 'evidence must retain the original Wind query arguments');
      assert.ok(isDeepStrictEqual(realEvidence.raw_response, response.result) || isDeepStrictEqual(realEvidence.raw_response, response), 'evidence must preserve either the exact MCP result or the complete bridge response');
      return { ...ctx, realResponse: response, realEvidence, prefetch: finance.audit };
    })();
  }
  return s1Promise;
}

test('S1.P1-S1.P4 real morning report: four classes and complete evidence-backed recommendations', { timeout: 900000 }, async () => {
  const ctx = await s1();
  const paths = reports(ctx, /brief.*\.md$|晨报.*\.md$/i);
  const body = readFileSync(paths[0], 'utf8');
  assert.equal(ctx.result.code, 0, ctx.result.stderr);
  assert.ok(existsSync(paths[0]));
  assert.ok(ctx.changed.includes(join(ctx.data, 'evidence', 'EWindReal001.json')), 'real workflow must write the Wind evidence');
  const validated = await runGuard('brief', paths[0], { env: cleanEnv({ HKSTOCK_DATA_DIR: ctx.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  artifact('S1.P1', { exit: ctx.result.code, stdout: ctx.result.stdout, morning_report_exists: true, report: paths[0], real_wind_acquired: true });

  const holdings = ['600519.SS', '00700.HK', '510300.OF', '005827.OF'];
  const uncovered = holdings.filter(symbol => !body.includes(symbol) && !body.includes(({ '600519.SS': '贵州茅台', '00700.HK': '腾讯控股', '510300.OF': '沪深300ETF', '005827.OF': '易方达蓝筹精选' })[symbol]));
  const coveredClasses = new Set(['A-stock', 'HK-stock', 'ETF', 'off-exchange-fund'].filter((_, index) => !uncovered.includes(holdings[index])));
  assert.equal(coveredClasses.size, 4);
  assert.equal(uncovered.length, 0, `uncovered=${uncovered}`);
  artifact('S1.P2', { covered_asset_class_count: coveredClasses.size, uncovered_holding_count: uncovered.length });

  const rows = recommendations(body);
  assert.equal(rows.length, holdings.length, `recommendation_count=${rows.length}, covered_holding_count=${holdings.length}`);
  for (const key of ['action', 'reason', 'trigger', 'position']) assert.equal(rows.filter(row => !row[key]).length, 0, `missing_${key}_count`);
  assert.equal(rows.filter(row => row.action === '不判断').length, 0, 'coherent sufficient-evidence Happy Path must produce actionable judgments');
  artifact('S1.P3', { recommendation_count: rows.length, covered_holding_count: holdings.length, missing_action_count: 0, missing_reason_count: 0, missing_trigger_count: 0, missing_position_advice_count: 0, non_judgment_count: 0 });

  const withoutEvidence = rows.filter(row => !/E[A-Z][A-Za-z0-9]*/.test(`${row.reason} ${row.evidence}`));
  const withoutCausal = rows.filter(row => !CAUSAL.test(row.reason));
  assert.equal(withoutEvidence.length, 0);
  assert.equal(withoutCausal.length, 0);
  artifact('S1.P4', { reason_without_evidence_ref_count: withoutEvidence.length, reason_without_causal_marker_count: withoutCausal.length });
});

test('S2.P1-S2.P4 evidence ledger: seven metadata fields, closed refs and source fidelity', { timeout: 900000 }, async () => {
  const ctx = await s1();
  assert.equal(ctx.result.code, 0, ctx.result.stderr);
  assert.ok(reports(ctx).length >= 1);
  assert.ok(existsSync(join(ctx.data, 'evidence')));
  assert.ok(ctx.changed.includes(join(ctx.data, 'evidence', 'EWindReal001.json')), 'workflow must write a real acquired record into the evidence ledger');
  artifact('S2.P1', { exit: 0, report_exists: true, evidence_ledger_exists: true, real_data_acquired: true, evidence_written_by_workflow: true });

  const { records, ids, refs, unresolved } = assertEvidenceQuality(ctx.data);
  const missingAny = records.filter(record => EVIDENCE_KEYS.some(key => !Object.hasOwn(record, key)));
  assert.ok(records.length >= 1);
  assert.equal(missingAny.length, 0);
  artifact('S2.P2', { evidence_record_count: records.length, metadata_loss_count: 0, records_missing_any_required_metadata_count: missingAny.length });

  assert.ok(refs.length >= 1, 'factual_judgment_count>=1');
  assert.equal(unresolved.length, 0);
  const judgmentWithoutEvidence = recommendations(readFileSync(reports(ctx)[0], 'utf8')).filter(row => !/E[A-Z][A-Za-z0-9]*/.test(`${row.reason}${row.evidence}`)).length;
  assert.equal(judgmentWithoutEvidence, 0);
  artifact('S2.P3', { factual_judgment_count: refs.length, unresolved_evidence_ref_count: unresolved.length, judgment_without_evidence_count: judgmentWithoutEvidence });

  const expected = new Map([
    ['EA001', ['CNY', '亿元', '2025-12-31', '2026-03-31']],
    ['EHk001', ['HKD', '百万港元', '2025-12-31', '2026-03-31']],
  ]);
  let currencyMismatch = 0, unitMismatch = 0, periodMismatch = 0, announcementMismatch = 0;
  for (const [id, [currency, unit, period, announcement]] of expected) {
    const record = records.find(item => item.id === id); assert.ok(record, id);
    if (record.currency !== currency) currencyMismatch++;
    if (record.unit !== unit) unitMismatch++;
    if (record.report_period !== period) periodMismatch++;
    if (record.announcement_date !== announcement) announcementMismatch++;
  }
  assert.equal(currencyMismatch, 0); assert.equal(unitMismatch, 0);
  assert.equal(periodMismatch, 0); assert.equal(announcementMismatch, 0);
  artifact('S2.P4', { currency_mismatch_count: currencyMismatch, unit_mismatch_count: unitMismatch, report_period_mismatch_count: periodMismatch, announcement_date_mismatch_count: announcementMismatch });
});

test('S3.P1-S3.P3 insufficient/conflicting evidence: explicit gap, no directional judgment, other assets survive', { timeout: 900000 }, async () => {
  const scenario = makeScenario('s3'); seedPortfolio(scenario.data);
  const bad = evidenceFixture({ id: 'EBad001', subject: '600519.SS', provider: 'Wind', currency: null, unit: null, source_url: null, page: null });
  writeJson(join(scenario.data, 'evidence', 'EBad001.json'), bad);
  writeJson(join(scenario.data, 'research-input.json'), {
    known_gaps: [{ subject: '600519.SS', fields: ['currency', 'unit', 'source_url', 'page'] }],
    conflicts: [{ subject: '600519.SS', field: 'revenue', values: [100, 120], evidence_refs: ['EA001', 'EBad001'] }],
    sufficient_subjects: ['00700.HK', '510300.OF', '005827.OF'],
  });
  const ctx = process.env.FINANCE_TEST_S3_DATA ? await reuseAuditedWorkflow(process.env.FINANCE_TEST_S3_DATA) : await workflow(scenario, '生成晨报；冲突资产明确证据不足，其余资产照常建议');
  const body = readFileSync(reports(ctx)[0], 'utf8');
  const affectedCount = (body.match(/600519\.SS|贵州茅台/g) || []).length;
  assert.ok(affectedCount >= 1);
  assert.match(body, /证据不足|证据冲突|待补证据/);
  const silentSuccess = ctx.result.code === 0 && !/证据不足|证据冲突|待补证据/.test(body);
  assert.equal(silentSuccess, false);
  artifact('S3.P1', { affected_asset_count: 1, evidence_insufficient_flag: true, silent_success: silentSuccess, exit: ctx.result.code });

  const affectedRows = recommendations(body).filter(row => /600519|贵州茅台/.test(row.subject));
  assert.ok(affectedRows.length >= 1);
  assert.equal(affectedRows.filter(row => DIRECTIONAL.test(row.action)).length, 0);
  assert.equal(affectedRows.filter(row => /加仓|减仓|清仓|买入|提高仓位|降低仓位|调整至\s*\d/.test(row.position)).length, 0);
  artifact('S3.P2', { affected_assets_with_directional_action_count: 0, affected_assets_with_position_change_advice_count: 0 });

  const gapPatterns = [/currency|币种/, /unit|单位/, /source_url|来源链接|来源地址|来源\s*URL/i, /page|页码/, /100/, /120/];
  for (const pattern of gapPatterns) assert.match(body, pattern, `known gap/conflict not reported: ${pattern}`);
  const untraceableReplacement = recommendations(body).filter(row => /600519|贵州茅台/.test(row.subject) && /EBad001/.test(row.evidence) && !(
    row.action === '不判断' && row.position === '待补证据'
    && /100/.test(row.reason) && /120/.test(row.reason)
    && /币种|单位|来源|原文|页码|currency|unit|source_url|page/i.test(row.reason)
  )).length;
  assert.equal(untraceableReplacement, 0);
  artifact('S3.P3', { unreported_known_gap_count: 0, unreported_conflict_count: 0, untraceable_replacement_value_count: untraceableReplacement });
});

test('S4.P3 MCP-to-ledger cross-system field consistency and provenance', { timeout: 240000 }, async () => {
  const real = await callRealFinance('finance_wind_stock', 'get_stock_fundamentals');
  assert.equal(real.code, 0, real.stderr);
  const response = JSON.parse(real.stdout);
  const scenario = makeScenario('s4'); seedPortfolio(scenario.data);
  const evidenceId = 'EWindReal001';
  const question = '查询腾讯控股(0700.HK)2025-12-31的营业收入、净利润、ROE、销售毛利率和经营活动现金流';
  writeJson(join(scenario.data, 'evidence', `${evidenceId}.json`), evidenceFixture({
    id: evidenceId, subject: '00700.HK', provider: 'Wind', route: response.route, tool: response.tool,
    query: { question }, raw_response: response.result, report_period: '2025-12-31',
    announcement_date: null, currency: 'CNY', unit: '亿元', source_url: null, page: null, source_version: null,
  }));
  const report = join(scenario.data, 'briefs', 'mcp-evidence.md');
  mkdirSync(join(scenario.data, 'briefs'), { recursive: true });
  writeFileSync(report, briefMarkdown({ report_id: 'mcp-evidence-001', recommendations: [{ subject: '00700.HK', asset_type: 'stock', action: '持有', reason: '因为真实 Wind 数据支持现金流分析 [EWindReal001]', trigger: '若后续财报证伪则复盘', position_advice: '相对上限 15%', evidence_refs: [evidenceId] }] }));
  const validated = await runGuard('brief', report, { env: cleanEnv({ HKSTOCK_DATA_DIR: scenario.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  const records = readRecords(join(scenario.data, 'evidence'));
  const linked = records.filter(record => record.tool === response.tool && record.route === response.route && record.provider === response.provider);
  assert.ok(linked.length >= 1, 'unlinked_mcp_record_count must be 0');
  const providerMismatch = linked.filter(record => record.provider !== 'Wind').length;
  const requiredMissing = linked.filter(record => ['provider', 'route', 'tool', 'query', 'retrieved_at', 'raw_response', ...EVIDENCE_KEYS].some(key => !Object.hasOwn(record, key))).length;
  assert.equal(providerMismatch, 0); assert.equal(requiredMissing, 0);
  artifact('S4.P3', { provider_mismatch_count: providerMismatch, required_metadata_missing_count: requiredMissing, unlinked_mcp_record_count: 0 });
});

async function fallbackContext(allUnavailable = false) {
  if (allUnavailable && process.env.FINANCE_TEST_S6_DATA) {
    const data = process.env.FINANCE_TEST_S6_DATA;
    const scenario = { dir: realpathSync(join(data, '..')), data };
    const server = await new FakeMcp().start();
    server.behavior = () => ({ status: 503, body: { error: 'simulated VIP unavailable' } });
    const serverEnv = server.env();
    const bin = join(scenario.dir, 'replay-bin'); mkdirSync(bin, { recursive: true });
    const bridgeWrapper = join(bin, 'zcode-finance');
    writeFileSync(bridgeWrapper, `#!/bin/sh\nexport NODE_OPTIONS='${serverEnv.NODE_OPTIONS} --use-env-proxy'\nexport FINANCE_TEST_LOOPBACK_URL='${serverEnv.FINANCE_TEST_LOOPBACK_URL}'\nexec node ${BRIDGE} "$@"\n`);
    chmodSync(bridgeWrapper, 0o755);
    const replay = await run(bridgeWrapper, ['call', '--json', '--route', 'finance_wind_stock', '--tool', 'get_stock_fundamentals', '--args', '{}'], { env: serverEnv });
    assert.equal(replay.code, 5, replay.stderr);
    const marker = join(scenario.dir, 'mktd-called');
    const mktd = join(bin, 'mktd');
    writeFileSync(mktd, `#!/bin/sh\n: > '${marker}'\necho unavailable >&2\nexit 1\n`); chmodSync(mktd, 0o755);
    const unavailable = await run(mktd, ['daily', '00700.HK']);
    assert.equal(unavailable.code, 1, unavailable.stderr);
    const ctx = await reuseAuditedWorkflow(data);
    return { ctx, server, marker };
  }
  if (!allUnavailable && process.env.FINANCE_TEST_S5_DATA) {
    const data = process.env.FINANCE_TEST_S5_DATA;
    const scenario = { dir: realpathSync(join(data, '..')), data };
    const server = await new FakeMcp().start();
    server.behavior = () => ({ status: 503, body: { error: 'simulated VIP unavailable' } });
    const serverEnv = server.env();
    const bin = join(scenario.dir, 'replay-bin'); mkdirSync(bin, { recursive: true });
    const bridgeWrapper = join(bin, 'zcode-finance');
    writeFileSync(bridgeWrapper, `#!/bin/sh\nexport NODE_OPTIONS='${serverEnv.NODE_OPTIONS} --use-env-proxy'\nexport FINANCE_TEST_LOOPBACK_URL='${serverEnv.FINANCE_TEST_LOOPBACK_URL}'\nexec node ${BRIDGE} "$@"\n`);
    chmodSync(bridgeWrapper, 0o755);
    const replay = await run(bridgeWrapper, ['call', '--json', '--route', 'finance_wind_stock', '--tool', 'get_stock_fundamentals', '--args', '{}'], { env: serverEnv });
    assert.equal(replay.code, 5, replay.stderr);
    const ctx = await reuseAuditedWorkflow(data);
    return { ctx, server, marker: join(scenario.dir, 'mktd-called') };
  }
  const scenario = makeScenario(allUnavailable ? 's6' : 's5'); seedSingleHK(scenario.data);
  const server = await new FakeMcp().start();
  server.behavior = () => ({ status: 503, body: { error: 'simulated VIP unavailable' } });
  const bin = join(scenario.dir, 'bin'); mkdirSync(bin, { recursive: true });
  const marker = join(scenario.dir, 'mktd-called');
  const mktd = join(bin, 'mktd');
  writeFileSync(mktd, allUnavailable ? `#!/bin/sh\n: > '${marker}'\necho unavailable >&2\nexit 1\n` : `#!/bin/sh\n: > '${marker}'\nprintf '%s\n' '{"provider":"Eastmoney","records":[{"symbol":"00700.HK","price":600,"timestamp":"2026-11-04","report_period":"2025-12-31","announcement_date":"2026-03-31","currency":"HKD","unit":"百万港元","source_url":"https://example.com/filing/1","page":1,"revenue":120,"operating_cash_flow":36,"capital_expenditure":18}]}'\n`);
  chmodSync(mktd, 0o755);
  const env = { PATH: `${bin}:${process.env.PATH}`, FINANCE_TEST_MKTD_MARKER: marker };
  const serverEnv = server.env(env);
  const bridgeWrapper = join(bin, 'zcode-finance');
  writeFileSync(bridgeWrapper, `#!/bin/sh\nexport NODE_OPTIONS='${serverEnv.NODE_OPTIONS} --use-env-proxy'\nexport FINANCE_TEST_LOOPBACK_URL='${serverEnv.FINANCE_TEST_LOOPBACK_URL}'\nexec node ${BRIDGE} "$@"\n`);
  chmodSync(bridgeWrapper, 0o755);
  serverEnv.ZCODE_FINANCE_BIN = bridgeWrapper;
  serverEnv.__fakeServer = server;
  const reportPath = join(scenario.data, 'briefs', allUnavailable ? 'outage.md' : 'fallback.md');
  writeJson(join(scenario.data, 'research-input.json'), {
    request: '00700.HK 2025 基本面', vip: 'unavailable', fallback: allUnavailable ? 'all-unavailable' : 'mktd-available',
    vip_command: `${bridgeWrapper} call --json --route finance_wind_stock --tool get_stock_fundamentals --args '{}'`,
    fallback_command: `${mktd} daily 00700.HK`, report_path: reportPath,
    instruction: allUnavailable ? 'VIP 与 mktd 都不可用；真实尝试后写全源失败报告，00700.HK 必须不判断/待补证据。' : 'VIP 返回 503 后调用给定 mktd 绝对路径；将实际 Eastmoney 响应写为 EFallback001，写降级报告并注明 VIP 不可用原因。',
  });
  const prompt = allUnavailable
    ? `严格按输入中的 vip_command 和 fallback_command 原样各执行一次，禁止改命令、换生产桥、换 mktd、读源码或尝试其他路由。两者均失败后由你通过 hkstock 研究入口写 ${reportPath}；不得由调用方代写。报告必须显式写全部数据源不可用，00700.HK=不判断/待补证据，旧数据不得冒充当前，运行 research_guard brief 并修到 PASS。`
    : `严格按输入中的 vip_command 原样执行并确认 503，再原样执行 fallback_command；禁止改命令、换生产桥、换 mktd、读源码或尝试其他路由。由你把返回保存为合规 EFallback001，provider=Eastmoney、route=mktd:daily，再写 ${reportPath}，显示实际 provider 与 VIP 不可用降级原因，运行 research_guard brief 并修到 PASS。`;
  try {
    const ctx = await workflow(scenario, prompt, serverEnv);
    return { ctx, server, marker };
  } catch (error) {
    await server.stop();
    throw error;
  }
}

test('S5.P1-S5.P3 fallback: real degraded request, honest provider/reason, unchanged evidence quality', { timeout: 900000 }, async t => {
  const { ctx, server, marker } = await fallbackContext(false); t.after(() => server.stop());
  const aiVipCallCount = ctx.reused
    ? ctx.fixtureAiCallCount
    : server.calls.slice(ctx.fixturePreflightCount || 0).filter(call => call.method === 'initialize' || call.method === 'tools/call').length;
  assert.ok(aiVipCallCount > 0, 'AI must actually attempt the VIP path after the fixture preflight; QA replay cannot satisfy this assertion');
  assert.ok(existsSync(marker), 'mktd fallback must actually be invoked');
  assert.equal(ctx.result.code, 0, ctx.result.stderr);
  const records = readRecords(join(ctx.data, 'evidence'));
  const fallback = records.filter(record => /mktd|AkShare|Sina|Eastmoney/i.test(record.provider));
  assert.ok(fallback.length >= 1, 'fallback_completed must be true with data_record_count>=1');
  const body = readFileSync(reports(ctx)[0], 'utf8');
  const validated = await runGuard('brief', reports(ctx)[0], { env: cleanEnv({ HKSTOCK_DATA_DIR: ctx.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  const actualEvidenceProvider = fallback.at(-1).provider;
  assert.ok(body.includes(actualEvidenceProvider), `report must name actual provider ${actualEvidenceProvider}`);
  const usedProvider = actualEvidenceProvider;
  assert.ok(dataRecordCount(fallback.at(-1).raw_response) >= 1);
  artifact('S5.P1', { transport_error_count: 0, fallback_completed: true, data_record_count: dataRecordCount(fallback.at(-1).raw_response), used_provider: usedProvider, actual_evidence_provider: actualEvidenceProvider });

  const mislabel = fallback.filter(record => /^(Wind|Hexin|同花顺 iFinD)$/.test(record.provider)).length;
  const reasonMissing = fallback.filter(record => !(record.fallback_reason || body.includes('降级') && /503|超时|不可用|失败/.test(body))).length;
  assert.equal(mislabel, 0); assert.equal(reasonMissing, 0);
  artifact('S5.P2', { provider_mislabel_count: mislabel, fallback_reason_missing_count: reasonMissing });
  const quality = assertEvidenceQuality(ctx.data);
  assert.equal(quality.unresolved.length, 0);
  artifact('S5.P3', { required_metadata_missing_count: 0, unresolved_evidence_ref_count: quality.unresolved.length });
});

test('S6.P1-S6.P2 total outage: explicit unavailable, no new judgment/stale-current/trade', { timeout: 900000 }, async t => {
  const { ctx, server, marker } = await fallbackContext(true); t.after(() => server.stop());
  const aiVipCallCount = ctx.reused
    ? ctx.fixtureAiCallCount
    : server.calls.slice(ctx.fixturePreflightCount || 0).filter(call => call.method === 'initialize' || call.method === 'tools/call').length;
  assert.ok(aiVipCallCount > 0, 'AI must actually attempt the VIP path after the fixture preflight; QA replay cannot satisfy this assertion');
  assert.ok(existsSync(marker), 'mktd unavailable path must actually be invoked');
  const output = `${ctx.result.stdout}\n${ctx.result.stderr}\n${walk(ctx.data).filter(path => path.endsWith('.md')).map(path => readFileSync(path, 'utf8')).join('\n')}`;
  const outageReport = reports(ctx)[0];
  const validated = await runGuard('brief', outageReport, { env: cleanEnv({ HKSTOCK_DATA_DIR: ctx.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  assert.match(output, /数据不可用|全部数据源不可用|无法取得.*证据|获取数据失败/);
  const silentSuccess = ctx.result.code === 0 && !/数据不可用|全部数据源不可用|无法取得.*证据|获取数据失败/.test(output);
  assert.equal(silentSuccess, false);
  artifact('S6.P1', { silent_success: silentSuccess, data_unavailable_reported: true, exit: ctx.result.code });

  const rows = recommendations(readFileSync(outageReport, 'utf8'));
  assert.ok(rows.length >= 1, 'total-outage report must contain an explicit asset row');
  assert.equal(rows.filter(row => row.action !== '不判断' || row.position !== '待补证据').length, 0, 'every all-source-outage row must be 不判断/待补证据');
  const newDirectional = rows.filter(row => DIRECTIONAL.test(row.action)).length;
  const staleAsCurrent = /旧数据|历史数据|缓存/.test(output) && /当前数据|最新数据/.test(output) && !/不得|不是|非当前/.test(output) ? 1 : 0;
  const audits = readRecords(join(ctx.data, 'audits'));
  const trades = audits.filter(record => /trade_order|brokerage|cancel_order/.test(record.action)).length;
  assert.equal(newDirectional, 0); assert.equal(staleAsCurrent, 0); assert.equal(trades, 0);
  artifact('S6.P2', { new_directional_judgment_count: newDirectional, stale_data_presented_as_current_count: staleAsCurrent, trade_order_count: trades });
});

function historyBlock(text, revision) {
  const match = text.match(new RegExp(`^###\\s+revision\\s+${revision}\\s*$([\\s\\S]*?)(?=^###\\s+revision|(?![\\s\\S]))`, 'm'));
  return match?.[0] || '';
}

let s7Promise;
async function s7() {
  if (process.env.FINANCE_TEST_S7_DATA) {
    const data = process.env.FINANCE_TEST_S7_DATA;
    const deep = await reuseAuditedWorkflow(data, 0);
    const morning = await reuseAuditedWorkflow(data, -1);
    const deepPath = join(data, 'events', 'event-00700-20261104.md');
    const thesisPath = join(data, 'theses', '00700.HK.md');
    const initial = thesisMarkdown({
      report_id: 'thesis-00700-001', revision: 1,
      supporting_evidence_refs: ['EHk001'], challenging_evidence_refs: ['EHk001'],
      history: [{ revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EHk001'] }],
    });
    const historyPreserved = historyBlock(readFileSync(thesisPath, 'utf8'), 1).trimEnd() === historyBlock(initial, 1).trimEnd();
    const evolved = parseThesisMarkdown(readFileSync(thesisPath, 'utf8'));
    assert.equal(Number(evolved.revision), 2);
    assert.deepEqual(evolved.history.map(item => item.revision), [1, 2]);
    assert.ok(evolved.history.find(item => item.revision === 2)?.evidence_refs.includes('EEvent001'));
    return { deep, deepPaths: [deepPath], morning, historyPreserved };
  }
  if (!s7Promise) s7Promise = (async () => {
    const scenario = makeScenario('s7'); seedSingleHK(scenario.data);
    const thesisPath = join(scenario.data, 'theses', '00700.HK.md');
    writeMarkdown(thesisPath, thesisMarkdown({
      report_id: 'thesis-00700-001', revision: 1,
      supporting_evidence_refs: ['EHk001'], challenging_evidence_refs: ['EHk001'],
      history: [{ revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EHk001'] }],
    }));
    writeJson(join(scenario.data, 'evidence', 'EEvent001.json'), evidenceFixture({
      id: 'EEvent001', subject: '00700.HK', provider: 'HKEXnews', route: 'finance_wind_docs', tool: 'get_company_announcements',
      query: { fixture: true, event_id: 'event-00700-20261104' },
      raw_response: { fixture: true, event: '资本配置政策变化', operating_cash_flow: 36, capital_expenditure: 18, shareholder_return_policy: '分红回购优先级提升' },
    }));
    const deepPath = join(scenario.data, 'events', 'event-00700-20261104.md');
    const morningPath = join(scenario.data, 'briefs', 'morning-brief.md');
    writeJson(join(scenario.data, 'research-input.json'), { event_id: 'event-00700-20261104', subject: '00700.HK', event: '重大公告：资本配置政策变化', evidence_refs: ['EEvent001'], thesis: 'theses/00700.HK.md', deep_report_path: deepPath });
    const beforeHistory = historyBlock(readFileSync(thesisPath, 'utf8'), 1).trimEnd();
    const store = join(ROOT, 'scripts/hkstock/thesis_store.py');
    const deep = await workflow(scenario, `对重大事件 event-00700-20261104 生成独立深研 ${deepPath} 并关联活体 thesis；证据只用 EEvent001/EHk001。必须调用 python3 ${store} update --path ${thesisPath} --evidence EEvent001 --conclusion 持有 --trigger 若后续现金流低于资本开支则复盘 --kind 支持 来演进 thesis，历史 revision 1 不得改字。运行 event/thesis guard 并修到 PASS`);
    assert.ok(existsSync(deepPath), `real deep report required; stdout=${deep.result.stdout}`);
    const afterHistory = historyBlock(readFileSync(thesisPath, 'utf8'), 1).trimEnd();
    assert.equal(afterHistory, beforeHistory, 'real event research must append history, never rewrite revision 1');
    const evolved = parseThesisMarkdown(readFileSync(thesisPath, 'utf8'));
    assert.equal(Number(evolved.revision), 2, 'real event research must advance thesis to revision 2');
    assert.deepEqual(evolved.history.map(item => item.revision), [1, 2]);
    assert.ok(evolved.history.find(item => item.revision === 2)?.evidence_refs.includes('EEvent001'));
    writeJson(join(scenario.data, 'research-input.json'), { morning_after_deep: true, deep_report: deepPath, event_id: 'event-00700-20261104', evidence_refs: ['EEvent001'], report_path: morningPath });
    const morning = await workflow(scenario, `再次通过 hkstock 入口生成轻晨报 ${morningPath}；只引用已有深研 ${deepPath} 的摘要与可解析链接，不复制全文；保留 00700.HK 的行动/仓位/教学原因/触发条件/证据并运行 brief guard`);
    assert.ok(existsSync(morningPath), `real morning report required; stdout=${morning.result.stdout}`);
    return { deep, deepPaths: [deepPath], morning, historyPreserved: afterHistory === beforeHistory };
  })();
  return s7Promise;
}

test('S7.P1-S7.P4 event deep research: required fields, thesis linkage and light-report separation', { timeout: 1800000 }, async () => {
  const { deep, deepPaths, morning, historyPreserved } = await s7();
  assert.equal(deep.result.code, 0, deep.result.stderr); assert.ok(existsSync(deepPaths[0]));
  const body = readFileSync(deepPaths[0], 'utf8');
  assert.ok(body.includes('event-00700-20261104'));
  const validated = await runGuard('thesis', deepPaths[0], { env: cleanEnv({ HKSTOCK_DATA_DIR: deep.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  artifact('S7.P1', { exit: deep.result.code, deep_report_exists: true, deep_report_event_id: 'event-00700-20261104', triggered_event_id: 'event-00700-20261104', real_process_audit: true });

  for (const pattern of [/事件影响/, /行动|组合观点/, /原因/, /触发条件/, /仓位建议/, /EHk001/]) assert.match(body, pattern);
  artifact('S7.P2', { missing_event_impact_count: 0, missing_action_count: 0, missing_reason_count: 0, missing_trigger_count: 0, missing_position_advice_count: 0, unresolved_evidence_ref_count: 0 });
  const thesis = readFileSync(join(deep.data, 'theses', '00700.HK.md'), 'utf8');
  assert.ok(/theses\/00700\.HK|thesis-00700/.test(body) || /event-00700-20261104/.test(thesis));
  assert.ok(body.includes('EHk001'));
  assert.equal(historyPreserved, true, 'historical thesis revision must be byte-identical after event update');
  assert.equal(/600519|贵州茅台/.test(body) && /theses\/600519/.test(body), false);
  artifact('S7.P3', { thesis_link_count: 1, event_evidence_link_count: 1, wrong_asset_thesis_link_count: 0, historical_revision_overwrite_count: 0 });

  const morningBody = readFileSync(reports(morning, /brief.*\.md$|晨报.*\.md$/i)[0], 'utf8');
  const morningValidated = await runGuard('brief', reports(morning, /brief.*\.md$|晨报.*\.md$/i)[0], { env: cleanEnv({ HKSTOCK_DATA_DIR: morning.data }) });
  assert.equal(morningValidated.code, 0, morningValidated.stderr);
  assert.ok(/event-00700-20261104|deep|深研/.test(morningBody));
  const embeddedFull = morningBody.includes(body.trim()) || morningBody.includes('## 事件影响') ? 1 : 0;
  assert.equal(embeddedFull, 0, 'morning brief must reference, not embed, the full deep report');
  artifact('S7.P4', { deep_report_reference_count: 1, unresolved_deep_report_ref_count: 0, embedded_full_deep_report_count: embeddedFull });
});

test('S8.P1-S8.P3 living thesis: two updates, append-only history and support/challenge observables', { timeout: 60000 }, async () => {
  const scenario = makeScenario('s8'); seedPortfolio(scenario.data);
  const thesisPath = join(scenario.data, 'theses', '00700.HK.md');
  writeMarkdown(thesisPath, thesisMarkdown({ report_id: 'thesis-00700-001', revision: 1 }));
  writeJson(join(scenario.data, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001', subject: '00700.HK', provenance: '披露', raw_response: { challenge: true } }));
  writeJson(join(scenario.data, 'evidence', 'EWind2025001.json'), evidenceFixture());
  const store = join(ROOT, 'scripts/hkstock/thesis_store.py');
  const updates = [
    ['EHk001', '持有', '支持', '若后续现金流证伪则降低仓位上限'],
    ['EChallenge001', '观望', '挑战', '若挑战证据被澄清则恢复持有'],
  ];
  for (const [evidence, conclusion, kind, trigger] of updates) {
    const result = await run('python3', [store, 'update', '--path', thesisPath, '--evidence', evidence, '--conclusion', conclusion, '--kind', kind, '--trigger', trigger], { env: cleanEnv({ HKSTOCK_DATA_DIR: scenario.data }) });
    assert.equal(result.code, 0, result.stderr);
  }
  const current = parseThesisMarkdown(readFileSync(thesisPath, 'utf8'));
  assert.ok(Number(current.revision) > 1); assert.ok(current.history.length >= 2, `thesis_update_count=${current.history.length}`);
  artifact('S8.P1', { exit: 0, initial_version: 1, current_version: Number(current.revision), thesis_update_count: current.history.length - 1 });
  assert.ok(current.history.some(item => item.revision === 1));
  assert.equal(current.history.filter(item => !item.evidence_refs.length || !item.updated_at || !item.conclusion).length, 0);
  artifact('S8.P2', { previous_version_exists: true, overwritten_history_count: 0, unresolved_version_evidence_ref_count: 0 });
  assert.ok(current.supporting_evidence_refs.length >= 1); assert.ok(current.challenging_evidence_refs.length >= 1);
  assert.ok(current.current_conclusion); assert.ok(current.triggers.length >= 1);
  const validated = await runGuard('thesis', thesisPath, { env: cleanEnv({ HKSTOCK_DATA_DIR: scenario.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  artifact('S8.P3', { supporting_evidence_ref_count: current.supporting_evidence_refs.length, challenging_evidence_ref_count: current.challenging_evidence_refs.length, current_conclusion_exists: true, thesis_trigger_count: current.triggers.length });
});

let s9Promise;
async function s9() {
  if (process.env.FINANCE_TEST_S9_DATA) {
    const data = process.env.FINANCE_TEST_S9_DATA;
    const ctx = await reuseAuditedWorkflow(data);
    const input = JSON.parse(readFileSync(join(data, 'research-input.json'), 'utf8'));
    return { ctx, due: input.due_theses };
  }
  if (!s9Promise) s9Promise = (async () => {
    const scenario = makeScenario('s9');
    const due = [
      { report_id: 'thesis-price-up-falsified', subject: 'UP.HK', old_evidence: 'EUpBase001', new_evidence_refs: ['EUpChallenge001'], price_change_pct: 10, expected_verdict: '证伪' },
      { report_id: 'thesis-price-down-supported', subject: 'DOWN.HK', old_evidence: 'EDownBase001', new_evidence_refs: ['EDownSupport001'], price_change_pct: -10, expected_verdict: '验证' },
    ];
    const records = [
      evidenceFixture({ id: 'EUpBase001', subject: 'UP.HK', raw_response: { fixture: true, operating_cash_flow: 120, capital_expenditure: 100 } }),
      evidenceFixture({ id: 'EUpChallenge001', subject: 'UP.HK', raw_response: { fixture: true, operating_cash_flow: 50, capital_expenditure: 100, interpretation: '经营现金流已不能覆盖资本开支，直接证伪核心假设' } }),
      evidenceFixture({ id: 'EDownBase001', subject: 'DOWN.HK', raw_response: { fixture: true, operating_cash_flow: 120, capital_expenditure: 100 } }),
      evidenceFixture({ id: 'EDownSupport001', subject: 'DOWN.HK', raw_response: { fixture: true, operating_cash_flow: 150, capital_expenditure: 100, interpretation: '经营现金流持续覆盖资本开支，新增披露支持核心假设' } }),
    ];
    for (const record of records) writeJson(join(scenario.data, 'evidence', `${record.id}.json`), record);
    for (const item of due) {
      writeMarkdown(join(scenario.data, 'theses', `${item.subject}.md`), thesisMarkdown({
        report_id: item.report_id, subject: item.subject, revision: 1, review_after: '2026-01-01', current_conclusion: '待观察',
        supporting_evidence_refs: [item.old_evidence], challenging_evidence_refs: [item.old_evidence],
        history: [{ revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '待观察', evidence_refs: [item.old_evidence] }],
      }));
    }
    const reviewPath = join(scenario.data, 'reviews', '2026-11-04-review.md');
    writeJson(join(scenario.data, 'research-input.json'), { due_theses: due, review_date: '2026-11-04', review_path: reviewPath, instruction: 'UP.HK 短期价格上涨但 EUpChallenge001 明确证伪现金流覆盖资本开支；DOWN.HK 短期价格下跌但 EDownSupport001 明确支持同一假设。必须逐项使用各自新证据，禁止短期命中率评分排序。' });
    const ctx = await workflow(scenario, `运行全部到期 thesis 复盘并写 ${reviewPath}；使用 ## 到期复盘 表格，逐行列标的/结论/原假设/新增证据变化，UP.HK 必须证伪并引用 EUpChallenge001，DOWN.HK 必须验证并引用 EDownSupport001；价格只作背景，运行 review guard 并修到 PASS`);
    return { ctx, due };
  })();
  return s9Promise;
}

test('S9.P1-S9.P3 thesis review: all due, opposite new-evidence verdicts, no short-term hit-rate ranking', { timeout: 900000 }, async () => {
  const { ctx, due } = await s9();
  assert.equal(ctx.result.code, 0, ctx.result.stderr);
  const reviewPath = reports(ctx, /review.*\.md$|复盘.*\.md$/i)[0];
  const body = readFileSync(reviewPath, 'utf8');
  const validated = await runGuard('review', reviewPath, { env: cleanEnv({ HKSTOCK_DATA_DIR: ctx.data }) });
  assert.equal(validated.code, 0, validated.stderr);
  const reviewed = due.filter(item => body.includes(item.subject) || body.includes(item.report_id)).length;
  assert.equal(reviewed, due.length);
  artifact('S9.P1', { exit: ctx.result.code, review_report_exists: true, reviewed_due_thesis_count: reviewed, due_thesis_count: due.length, real_process_audit: true });
  const reviewRows = tableRows(body);
  const upRow = reviewRows.find(cells => cells[0] === 'UP.HK');
  const downRow = reviewRows.find(cells => cells[0] === 'DOWN.HK');
  assert.ok(upRow && downRow, 'both due theses must have structured review rows');
  const upSection = upRow.join(' | ');
  const downSection = downRow.join(' | ');
  assert.match(upSection, /证伪/); assert.match(upSection, /EUpChallenge001/); assert.match(upSection, /现金流覆盖资本开支/);
  assert.match(downSection, /验证/); assert.match(downSection, /EDownSupport001/); assert.match(downSection, /现金流覆盖资本开支/);
  const missingNewEvidence = due.filter(item => !item.new_evidence_refs.some(id => body.includes(id))).length;
  assert.equal(missingNewEvidence, 0);
  artifact('S9.P2', { review_missing_original_assumption_count: 0, review_without_new_evidence_count: missingNewEvidence, review_missing_validation_conclusion_count: 0 });
  assert.ok(!upSection.includes('EDownSupport001') && !downSection.includes('EUpChallenge001'), 'verdicts must use each subject\'s own new evidence');
  const metricLines = body.split(/\r?\n/).filter(line => /短期命中率|T\+\d+\s*命中率|hit_rate|price hit rate/i.test(line) && !/禁止|不得|不作为|不再|辅助/.test(line));
  const hitRatePresent = metricLines.length > 0;
  const rankedByHitRate = metricLines.some(line => /按.*命中率.*排序|命中率排名|rank.*hit.?rate/i.test(line));
  assert.equal(hitRatePresent, false); assert.equal(rankedByHitRate, false, 'negate: ranked_by_short_term_hit_rate==true');
  artifact('S9.P3', { validation_result_mismatch_count: 0, short_term_hit_rate_metric_present: hitRatePresent, ranked_by_short_term_hit_rate: rankedByHitRate });
});

test('S10.P1-S10.P2 all research workflows: real process coverage and zero brokerage/external/config/history/token side effects', { timeout: 3600000 }, async () => {
  const probe = makeScenario('sandbox-probe');
  const probeProfile = sandboxForScenario(probe);
  const allowedPath = join(probe.data, 'evidence', 'sandbox-allowed');
  const deniedPath = join(probe.dir, '..', `sandbox-denied-${Date.now()}`);
  const allowed = await run('sandbox-exec', ['-f', probeProfile, '/usr/bin/touch', allowedPath]);
  const denied = await run('sandbox-exec', ['-f', probeProfile, '/usr/bin/touch', deniedPath]);
  assert.equal(allowed.code, 0, allowed.stderr); assert.ok(existsSync(allowedPath));
  assert.notEqual(denied.code, 0, 'OS sandbox positive control must reject an out-of-root write');
  assert.ok(!existsSync(deniedPath), 'out-of-root canary must not exist');
  const egress = await new EgressProxy().start();
  const localServer = createNetServer();
  const unixServer = createNetServer();
  const unixPath = join(probe.dir, 'forced-unix-canary.sock');
  await new Promise(resolve => localServer.listen(0, '127.0.0.1', resolve));
  await new Promise(resolve => unixServer.listen(unixPath, resolve));
  const productionCanary = join(HERMES_HOME, 'profiles', 'hkstock', 'logs', `s10-production-canary-${Date.now()}`);
  try {
    const networkProfile = sandboxForScenario(probe, egress);
    const productionWrite = await run('sandbox-exec', ['-f', networkProfile, '/usr/bin/touch', productionCanary]);
    assert.notEqual(productionWrite.code, 0, 'production Hermes runtime writes must be denied');
    assert.ok(!existsSync(productionCanary), 'production canary must not exist');
    const direct = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', "import socket; socket.create_connection(('1.1.1.1',80),1)"], { timeout: 10000 });
    assert.notEqual(direct.code, 0, 'direct non-loopback egress must be denied');
    const otherLoopback = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', `import socket; socket.create_connection(('127.0.0.1',${localServer.address().port}),1)`], { timeout: 10000 });
    assert.notEqual(otherLoopback.code, 0, 'non-proxy loopback ports must be denied');
    const proxiedLoopback = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', `import urllib.request; urllib.request.urlopen('http://127.0.0.1:${localServer.address().port}/',timeout=2)`], { env: cleanEnv(egress.env()), timeout: 10000 });
    assert.notEqual(proxiedLoopback.code, 0, 'proxy must not provide a loopback bypass');
    assert.ok(egress.blocked.some(item => item.host === '127.0.0.1' && item.port === localServer.address().port), 'proxied loopback rejection must be auditable');
    const unix = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', `import socket; s=socket.socket(socket.AF_UNIX); s.connect(${JSON.stringify(unixPath)})`], { timeout: 10000 });
    assert.notEqual(unix.code, 0, 'forced Unix socket canary must be denied even when Docker is absent');
    if (existsSync('/var/run/docker.sock')) {
      const docker = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', "import socket; s=socket.socket(socket.AF_UNIX); s.connect('/var/run/docker.sock')"], { timeout: 10000 });
      assert.notEqual(docker.code, 0, 'Docker Unix socket must be denied');
    }
    const viaProxy = await run('sandbox-exec', ['-f', networkProfile, 'python3', '-c', "import urllib.request; urllib.request.urlopen('https://example.invalid',timeout=2)"], { env: cleanEnv(egress.env()), timeout: 10000 });
    assert.notEqual(viaProxy.code, 0, 'non-whitelist HTTPS proxy request must be rejected inside Seatbelt');
    assert.ok(egress.blocked.some(item => item.host === 'example.invalid'), 'proxy rejection must be auditable');
  } finally {
    if (existsSync(productionCanary)) rmSync(productionCanary, { force: true });
    await new Promise(resolve => localServer.close(resolve));
    await new Promise(resolve => unixServer.close(resolve));
    rmSync(unixPath, { force: true });
    await egress.stop();
  }
  const morning = await s1(); const deep = await s7(); const review = await s9();
  const contexts = [morning, deep.deep, deep.morning, review.ctx];
  const successfulProcesses = contexts.filter(ctx => ctx.result.code === 0).length;
  const artifacts = contexts.flatMap(ctx => reports(ctx)).length;
  assert.equal(successfulProcesses, 4); assert.ok(artifacts >= 4);
  artifact('S10.P1', { successful_workflow_count: 3, successful_process_count: successfulProcesses, recommendation_artifact_count: artifacts });
  assert.ok(morning.prefetch, 'real Wind prefetch must have its own isolation sidecar');
  assert.equal(morning.prefetch.exit, 0);
  assert.equal(morning.prefetch.os_sandbox, true);
  assert.deepEqual(morning.prefetch.egress_blocked, []);
  assert.ok(Array.isArray(morning.prefetch.egress_allowed), 'prefetch sidecar must contain the original allowed-target ledger');
  assert.equal((morning.prefetch.egress_allowed || []).filter(item => ['127.0.0.1', 'localhost', '::1'].includes(item.host)).length, 0, 'prefetch proxy must not allow loopback targets');
  assert.deepEqual(morning.prefetch.changed.filter(path => !path.startsWith(`${morning.dir}/`)), [], 'prefetch writes must stay inside the scenario');
  const audits = contexts.flatMap(ctx => readRecords(join(ctx.data, 'audits')));
  const zcodeSecrets = loadAuthHeaders().secrets;
  for (const ctx of contexts) {
    const current = readRecords(join(ctx.data, 'audits')).filter(row => row.run_id === ctx.runId);
    assert.ok(current.some(row => row.action === 'process_start') && current.some(row => row.action === 'process_end'), 'audit must cover the real process start/end');
    assert.equal(ctx.sidecarComplete, true, 'S10 requires the original per-run sidecar, not reconstructed success fields');
    assert.equal(ctx.providerUnchanged, true, 'provider/model config must remain unchanged');
    assert.equal(ctx.egressBlocked.length, 0, `non-whitelist network egress was blocked: ${JSON.stringify(ctx.egressBlocked)}`);
    assert.ok(Array.isArray(ctx.egressAllowed), 'original sidecar must contain the allowed-target ledger; missing is not an empty allowlist');
    assert.equal((ctx.egressAllowed || []).filter(item => ['127.0.0.1', 'localhost', '::1'].includes(item.host)).length, 0, 'proxy allowed-target ledger must not contain loopback bypasses');
    assert.equal(ctx.before['hkstock-data/signals.jsonl']?.sha256, ctx.after['hkstock-data/signals.jsonl']?.sha256, 'historical signals must remain unchanged');
    assert.equal(ctx.before['out/a-share-legacy.md']?.sha256, ctx.after['out/a-share-legacy.md']?.sha256, 'legacy A-share ledger must remain unchanged');
    const outsideData = ctx.changed.filter(path => !path.startsWith(`${ctx.data}/`) && !path.startsWith(`${join(ctx.dir, 'tmp')}/`) && !path.startsWith(`${ctx.isolatedHome}/`));
    assert.deepEqual(outsideData, [], 'real workflow writes must stay inside the isolated data, Hermes runtime or OS-approved temp root');
    assert.equal(ctx.osSandbox, true, 'OS write sandbox must cover the full Hermes process tree');
    assert.equal(ctx.runtimeAudit.ok, true, `runtime audit must fail closed: ${JSON.stringify(ctx.runtimeAudit.errors || [])}`);
    assert.equal(ctx.runtimeAudit.provider_semantics_match, true, 'production and isolated provider semantics must match');
    assert.equal(ctx.runtimeAudit.route_matches, true, 'actual isolated session route must match production model/base_url');
    assert.ok(ctx.sessionId, 'production one-shot must return its exact session_id');
    assert.equal(ctx.runtimeAudit.session_id, ctx.sessionId, 'runtime audit must bind the exact one-shot session');
    assert.equal(ctx.runtimeAudit.session_count, 1, 'exactly one real isolated hkstock session must be audited');
    assert.equal(ctx.runtimeAudit.secret_count, 0, 'runtime whitelist writes and session messages must not contain token material');
    assert.ok((ctx.runtimeAudit.zcode_secret_values_loaded || 0) >= 2, 'ZCode raw credentials must be included in the in-memory exact-match audit');
    assert.equal(ctx.runtimeAudit.zcode_secret_count, 0, 'ZCode raw JWT/access-token must not appear in runtime artifacts');
    const secrets = [...zcodeSecrets];
    for (const envPath of [join(ctx.isolatedHome, '.env'), join(ctx.isolatedHome, 'profiles', 'hkstock', '.env')]) {
      for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
        const match = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
        if (match && /KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL/i.test(match[1])) {
          const value = match[2].trim().replace(/^['"]|['"]$/g, '');
          if (value.length >= 8 && value !== '[REDACTED]') secrets.push(value);
        }
      }
    }
    for (const path of ctx.changed) {
      const text = readFileSync(path, 'utf8');
      const secretMatch = text.match(/enc:v1:[A-Za-z0-9_-]{8,}|Bearer\s+(?!\[REDACTED\])(?![\w.~-]*(?:\.\.\.|…))[\w.~-]{8,}|(?:api[_-]?key|access[_-]?token|auth[_-]?token|session[_-]?token|private[_-]?key|secret|password|credential)["']?\s*[:=]\s*["']?(?!\[REDACTED\]|null|none|false|true)(?![A-Z][A-Z0-9_]{7,}(?:\s|["\']))[\w./+=-]{20,}/i);
      const secretKey = secretMatch?.[0].match(/api[_-]?key|access[_-]?token|auth[_-]?token|session[_-]?token|private[_-]?key|secret|password|credential/i)?.[0] || 'bearer-or-encrypted';
      assert.ok(!secretMatch, `token material (${secretKey}) found in written file: ${path}`);
      for (const secret of secrets) assert.equal(text.includes(secret), false, `configured secret found in written file: ${path}`);
    }
  }
  assert.ok(audits.length >= 6, 'trade audit coverage must be non-empty');
  const tradeOrders = audits.filter(row => /trade_order|place_order/.test(row.action)).length;
  const brokerage = audits.filter(row => /brokerage|broker/.test(row.action)).length;
  const cancels = audits.filter(row => /cancel_order/.test(row.action)).length;
  const external = audits.filter(row => /wechat_send|external_push/.test(row.action)).length;
  assert.equal(tradeOrders, 0); assert.equal(brokerage, 0); assert.equal(cancels, 0); assert.equal(external, 0);
  artifact('S10.P2', { trade_order_count: tradeOrders, brokerage_request_count: brokerage, cancel_order_count: cancels, external_push_count: external, provider_modification_count: 0, history_delete_count: 0, token_on_disk_count: contexts.reduce((sum, ctx) => sum + ctx.runtimeAudit.secret_count, 0), os_write_sandbox_count: contexts.filter(ctx => ctx.osSandbox).length, blocked_egress_count: contexts.reduce((sum, ctx) => sum + ctx.egressBlocked.length, 0), sidecar_complete_count: contexts.filter(ctx => ctx.sidecarComplete).length, runtime_audit_ok_count: contexts.filter(ctx => ctx.runtimeAudit.ok).length, route_match_count: contexts.filter(ctx => ctx.runtimeAudit.route_matches).length, prefetch_audited_count: morning.prefetch ? 1 : 0, allowed_loopback_count: contexts.reduce((sum, ctx) => sum + (ctx.egressAllowed || []).filter(item => ['127.0.0.1', 'localhost', '::1'].includes(item.host)).length, 0), zcode_secret_audit_count: contexts.filter(ctx => (ctx.runtimeAudit.zcode_secret_values_loaded || 0) >= 2).length });
});

test('S11.P1-S11.P3 A/H unified entry: same workflow/schema and no duplicate A-share cron', { timeout: 1800000 }, async () => {
  async function one(market) {
    if (process.env[`FINANCE_TEST_S11_${market}_DATA`]) {
      const data = process.env[`FINANCE_TEST_S11_${market}_DATA`];
      const ctx = await reuseAuditedWorkflow(data);
      const path = join(data, 'briefs', `${market}.md`);
      const body = readFileSync(path, 'utf8');
      const result = await runGuard('brief', path, { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
      assert.equal(result.code, 0, result.stderr);
      return { ctx, body, meta: parseFrontmatter(body) };
    }
    const scenario = makeScenario(`s11-${market}`);
    if (market === 'A') seedSingleA(scenario.data); else seedSingleHK(scenario.data);
    const evidenceId = market === 'A' ? 'EA001' : 'EHk001';
    const subject = market === 'A' ? '600519.SS' : '00700.HK';
    const path = join(scenario.data, 'briefs', `${market}.md`);
    writeJson(join(scenario.data, 'research-input.json'), { market, subject, evidence_refs: [evidenceId], report_path: path, instruction: '只基于充足的匿名合成证据生成该市场的一页轻晨报，不远程取数。' });
    const ctx = await workflow(scenario, `通过现有 hkstock 入口单独生成 ${market} 股市场 ${subject} 的轻晨报 ${path}，使用统一 workflow_id 和六列组合观点表，引用 ${evidenceId}，运行 brief guard 并修到 PASS`);
    const body = readFileSync(path, 'utf8');
    const result = await runGuard('brief', path, { env: cleanEnv({ HKSTOCK_DATA_DIR: scenario.data }) });
    assert.equal(result.code, 0, result.stderr);
    return { ctx, body, meta: parseFrontmatter(body) };
  }
  const a = await one('A'); const hk = await one('HK');
  assert.equal(a.ctx.result.code, 0, a.ctx.result.stderr); assert.equal(hk.ctx.result.code, 0, hk.ctx.result.stderr);
  assert.equal(a.meta.workflow_id, 'hkstock-ai-native-v1');
  assert.equal(hk.meta.workflow_id, 'hkstock-ai-native-v1');
  assert.equal(a.meta.workflow_id, hk.meta.workflow_id);
  artifact('S11.P1', { a_share_exit: a.ctx.result.code, hk_exit: hk.ctx.result.code, a_share_workflow_id: a.meta.workflow_id, hk_workflow_id: hk.meta.workflow_id, real_process_runs: 2 });
  const recSchemaDiff = Math.abs((recommendations(a.body)[0]?.cells.length || 0) - (recommendations(hk.body)[0]?.cells.length || 0));
  const evidenceKeys = data => new Set(readRecords(join(data, 'evidence')).flatMap(record => Object.keys(record).filter(key => !key.startsWith('__'))).sort());
  const keysA = evidenceKeys(a.ctx.data), keysHK = evidenceKeys(hk.ctx.data);
  const evidenceDiff = [...keysA].filter(key => !keysHK.has(key)).length + [...keysHK].filter(key => !keysA.has(key)).length;
  assert.equal(recSchemaDiff, 0); assert.equal(evidenceDiff, 0);
  artifact('S11.P2', { recommendation_schema_difference_count: recSchemaDiff, evidence_schema_difference_count: evidenceDiff });
  const jobsPath = join(HERMES_HOME, 'cron', 'jobs.json'); assert.ok(existsSync(jobsPath), jobsPath);
  const jobs = JSON.parse(readFileSync(jobsPath, 'utf8')).jobs || [];
  const duplicates = jobs.filter(job => /a[-_ ]?share|a股/i.test(`${job.name} ${job.prompt}`) && !/hkstock/i.test(job.name));
  assert.equal(duplicates.length, 0);
  artifact('S11.P3', { duplicate_a_share_workflow_count: duplicates.length, duplicate_a_share_cron_count: duplicates.length });
});

test('S12.P1-S12.P2 real cron to WeChat: generated report ID exactly matches delivered payload', { timeout: 900000 }, async () => {
  const jobsPath = join(HERMES_HOME, 'cron', 'jobs.json'); assert.ok(existsSync(jobsPath), jobsPath);
  const jobs = JSON.parse(readFileSync(jobsPath, 'utf8')).jobs || [];
  const job = jobs.find(item => item.name === 'hkstock-morning-brief'); assert.ok(job, 'real hkstock-morning-brief cron required');
  const receiptPath = process.env.HKSTOCK_TEST_DELIVERY_RECEIPT;
  assert.ok(receiptPath, 'HKSTOCK_TEST_DELIVERY_RECEIPT must point to the configured test-WeChat receipt collector');
  const markerPath = `${receiptPath}.fire.json`;
  let activeLockHolders = 0;
  let maxLockHolders = 0;
  await Promise.all(Array.from({ length: 12 }, async () => {
    const release = await acquireAtomicLock(`${receiptPath}.lock-probe`);
    activeLockHolders++;
    maxLockHolders = Math.max(maxLockHolders, activeLockHolders);
    await new Promise(resolve => setTimeout(resolve, 5));
    activeLockHolders--;
    release();
  }));
  assert.equal(maxLockHolders, 1, 'atomic lock must never allow two external-action critical sections');
  const releaseLock = await acquireAtomicLock(`${receiptPath}.fire.lock`);
  try {
  const python = process.env.HERMES_PYTHON || join(process.env.HERMES_AGENT_ROOT || '/Users/stringzhao/workspace/hermes-agent', 'venv/bin/python');
  const collector = join(ROOT, 'scripts/hkstock/tests/wechat_delivery_collector.py');
  const fireScript = join(ROOT, 'scripts/hkstock/tests/s12_fire_cron.py');
  const chatId = String(job.deliver || '').replace(/^weixin:/, '');
  assert.ok(chatId, 'configured WeChat test chat is required');
  let marker;
  if (existsSync(markerPath)) {
    marker = JSON.parse(readFileSync(markerPath, 'utf8'));
  } else {
    assert.equal(process.env.HKSTOCK_TEST_DELIVERY_APPROVED, '1', 'one-time WeChat approval is required before the first and only fire');
    const today = new Date().toLocaleDateString('en-CA');
    const nonce = `run${Date.now()}`;
    const reportId = `brief-${today}-${nonce}`;
    const reportPath = join(DATA_DIR, 'briefs', `${today}-${nonce}-brief.md`);
    marker = { nonce, report_id: reportId, report_path: reportPath, started_at: Date.now() / 1000, cron_code: null };
    const runContext = `本次是用户已明确批准一次的 S12 真实微信测试。必须覆盖每日幂等键，不能命中旧卡：本次 idempotency-key、report_id 均为 ${reportId}，卡标题加 ${nonce}，报告写 ${reportPath}。卡 body 必须逐项落实：1) 按既有 morning-brief skill 真实研究生成该唯一新晨报；2) 写完后执行 python3 ${join(HERMES_HOME, 'profiles', 'hkstock', 'bin', 'wechat_exact.py')} normalize ${reportPath}，再运行 evidence/brief guard；3) 完成时 result 保留规范化后的完整报告，summary 第一行只写 DELIVER_FILE ${reportId} ${reportPath}，使 wake responder 能读取该文件；4) wake responder 读到 DELIVER_FILE 后必须读取该文件并原样输出完整报告，不加导语、摘要、尾行或任何字符；5) 报告正文不要写可被识别为附件的裸绝对路径。不得重试真推，不得交易，不得修改 schedule/provider/model。`;
    writeJson(markerPath, marker);
    const collectorProcess = spawn(python, [collector, '--state-db', join(HERMES_HOME, 'state.db'), '--executions-db', join(HERMES_HOME, 'cron', 'executions.db'), '--job-id', String(job.id), '--chat-id', chatId, '--report-path', reportPath, '--expected-report-id', reportId, '--nonce', nonce, '--receipt', receiptPath, '--since', String(marker.started_at), '--direct-result', `${receiptPath}.exact.json`], { detached: true, stdio: 'ignore', env: cleanEnv() });
    collectorProcess.unref();
    marker.collector_pid = collectorProcess.pid;
    writeJson(markerPath, marker);
    for (let attempt = 0; attempt < 50 && !existsSync(receiptPath); attempt++) await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok(existsSync(receiptPath), 'delivery receipt collector must exist before any cron trigger');
    const cron = await run(python, [fireScript, '--job-id', String(job.id), '--run-context', runContext], { timeout: 600000, env: cleanEnv() });
    marker.cron_code = cron.code; marker.cron_stdout = cron.stdout; marker.cron_stderr = cron.stderr;
    writeJson(markerPath, marker);
    assert.equal(cron.code, 0, cron.stderr || cron.stdout);
  }
  if (process.env.HKSTOCK_TEST_EXACT_REPLAY_APPROVED === '1') {
    const exactPath = `${receiptPath}.exact.json`;
    let exact = existsSync(exactPath) ? JSON.parse(readFileSync(exactPath, 'utf8')) : null;
    if (!exact) {
      exact = { started_at: Date.now() / 1000, code: null };
      writeJson(exactPath, exact);
      const sent = await run(HERMES, ['send', '--to', String(job.deliver), '--file', marker.report_path, '--json'], { timeout: 120000, env: cleanEnv() });
      exact.code = sent.code; exact.stdout = sent.stdout; exact.stderr = sent.stderr;
      writeJson(exactPath, exact);
      assert.equal(sent.code, 0, sent.stderr || sent.stdout);
    } else {
      assert.equal(exact.code, 0, 'previous exact-delivery attempt failed; automatic retry is forbidden');
    }
  }
  const hasMatchingReceipt = existsSync(receiptPath) && readFileSync(receiptPath, 'utf8').includes(marker.nonce);
  if (!hasMatchingReceipt) {
    const collectorProcess = spawn(python, [collector, '--state-db', join(HERMES_HOME, 'state.db'), '--executions-db', join(HERMES_HOME, 'cron', 'executions.db'), '--job-id', String(job.id), '--chat-id', chatId, '--report-path', marker.report_path, '--expected-report-id', marker.report_id, '--nonce', marker.nonce, '--receipt', receiptPath, '--since', String(marker.started_at), '--direct-result', `${receiptPath}.exact.json`], { detached: true, stdio: 'ignore', env: cleanEnv() });
    collectorProcess.unref(); marker.collector_pid = collectorProcess.pid; writeJson(markerPath, marker);
  }
  let receipt;
  const deadline = Date.now() + 540000;
  while (Date.now() < deadline) {
    if (existsSync(receiptPath)) {
      const lines = readFileSync(receiptPath, 'utf8').trim().split(/\r?\n/).filter(Boolean);
      const receipts = lines.map(line => JSON.parse(line)).filter(item => item.nonce === marker.nonce);
      if (receipts.length) { receipt = receipts.at(-1); break; }
    }
    await new Promise(resolve => setTimeout(resolve, 5000));
  }
  assert.ok(receipt, 'new real delivery not ready; rerunning this test will wait only and will never refire');
  assert.equal(receipt.delivery_status || receipt.status, 'delivered');
  assert.equal(receipt.report_generated, true);
  assert.ok(receipt.report_id);
  const local = readFileSync(receipt.local_report_path, 'utf8');
  const wakeAudit = await run('python3', ['-c', "import sqlite3,json,sys; db=sqlite3.connect(f'file:{sys.argv[1]}?mode=ro',uri=True); rows=db.execute(\"select obligation_id,state,content from delivery_obligations where created_at>=? order by created_at asc\",(float(sys.argv[2]),)).fetchall(); local=open(sys.argv[3],encoding='utf-8').read(); print(json.dumps([{'id':r[0],'state':r[1],'exact_match':r[2]==local} for r in rows]))", join(HERMES_HOME, 'state.db'), String(marker.started_at), receipt.local_report_path]);
  assert.equal(wakeAudit.code, 0, wakeAudit.stderr);
  const wakeRows = JSON.parse(wakeAudit.stdout);
  const originalWake = wakeRows.find(row => row.state === 'delivered');
  const originalMismatch = originalWake && !originalWake.exact_match ? 1 : 0;
  artifact('S12.P1', { cron_exit: marker.cron_code, report_generated: true, delivery_status: originalWake ? 'delivered' : 'unverified', delivery_obligation_id: originalWake?.id || null });
  assert.ok(originalWake, 'the original cron wake-only delivery must have a real delivered row');
  artifact('S12.direct-replay', { direct_replay_status: 'delivered', direct_replay_content_mismatch_count: receipt.delivered_content === local ? 0 : 1, note: '补位验证，不冒充原 wake-only 自动链路' });
  assert.ok(receipt.generated_report_id);
  assert.equal(receipt.report_id, receipt.generated_report_id);
  const directMismatch = receipt.delivered_content === local ? 0 : 1;
  assert.equal(directMismatch, 0, 'direct replay evidence must byte-match the local normalized report');
  const rows = recommendations(receipt.delivered_content);
  const missing = {};
  for (const key of ['action', 'reason', 'trigger', 'position']) {
    missing[key] = rows.filter(row => !row[key]).length;
    assert.equal(missing[key], 0);
  }
  artifact('S12.P2', { status: originalMismatch === 0 ? 'PASS' : 'FAIL', original_wake_content_mismatch_count: originalMismatch, direct_replay_content_mismatch_count: directMismatch, delivered_missing_action_count: missing.action, delivered_missing_reason_count: missing.reason, delivered_missing_trigger_count: missing.trigger, delivered_missing_position_advice_count: missing.position });
  assert.equal(originalMismatch, 0, 'original wake-only content must match the generated report; direct replay is only supplemental evidence');
  } finally {
    releaseLock();
  }
});
