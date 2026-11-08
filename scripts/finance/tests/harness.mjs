import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { connect as netConnect, createServer as createNetServer } from 'node:net';
import { mkdtempSync, mkdirSync, existsSync, readFileSync, writeFileSync, readdirSync, statSync, cpSync, symlinkSync, copyFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve, relative, extname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export { assert };
export const HERE = dirname(fileURLToPath(import.meta.url));
export const ROOT = process.env.MARTIN_ROOT || resolve(HERE, '../../..');
export const BRIDGE = join(ROOT, 'scripts/finance/zcode-mcp-bridge.mjs');
export const GUARD = join(ROOT, 'scripts/hkstock/research_guard.py');
export const DATA_DIR = process.env.HKSTOCK_DATA_DIR || join(ROOT, 'hkstock-data');
export const HERMES_HOME = process.env.HERMES_HOME || join(process.env.HOME || '', '.hermes');
export const HERMES = process.env.HERMES_BIN || join(process.env.HOME || '', '.local/bin/hermes');
export const ISOLATED_HERMES = join(HERE, 'isolated_hermes.py');

export function activeHermesPython() {
  const projectRoot = process.env.HERMES_AGENT_ROOT || '/Users/stringzhao/workspace/hermes-agent';
  const installKey = createHash('sha256').update(projectRoot).digest('hex').slice(0, 16);
  const facts = JSON.parse(readFileSync(join(HERMES_HOME, 'installs', installKey, 'facts.json'), 'utf8'));
  return join(facts.packages.venv.environment, 'bin', 'python');
}

function writeOfflineConfig(source, target) {
  let text = readFileSync(source, 'utf8');
  const setScalar = (section, key, value) => {
    const lines = text.split(/\r?\n/);
    const start = lines.findIndex(line => line === `${section}:`);
    if (start < 0) {
      lines.push(section, `  ${key}: ${value}`);
    } else {
      let end = lines.length;
      for (let index = start + 1; index < lines.length; index++) {
        if (/^[^\s#][^:\n]*:/.test(lines[index])) { end = index; break; }
      }
      const keyIndex = lines.findIndex((line, index) => index > start && index < end && line.startsWith(`  ${key}:`));
      if (keyIndex >= 0) lines[keyIndex] = `  ${key}: ${value}`;
      else lines.splice(start + 1, 0, `  ${key}: ${value}`);
    }
    text = lines.join('\n');
  };
  setScalar('model_catalog', 'enabled', 'false');
  setScalar('plugins', 'auto_update_check_hours', '0');
  setScalar('memory', 'provider', 'builtin');
  writeFileSync(target, text, { mode: 0o600 });
}

export function makeIsolatedHermesHome(scenario, runId = 'home') {
  const source = HERMES_HOME;
  const home = join(scenario.dir, `hermes-home-${runId}`);
  mkdirSync(join(home, 'profiles', 'hkstock'), { recursive: true });
  for (const name of ['SOUL.md', 'USER.md', 'MEMORY.md', 'skills', 'plugins', 'installs', 'tools']) {
    if (existsSync(join(source, name))) symlinkSync(join(source, name), join(home, name));
  }
  if (existsSync(join(source, 'config.yaml'))) writeOfflineConfig(join(source, 'config.yaml'), join(home, 'config.yaml'));
  for (const name of ['SOUL.md', 'skills', 'bin', 'honcho.json', 'memories', 'plugins']) {
    if (existsSync(join(source, 'profiles', 'hkstock', name))) symlinkSync(join(source, 'profiles', 'hkstock', name), join(home, 'profiles', 'hkstock', name));
  }
  if (existsSync(join(source, 'profiles', 'hkstock', 'config.yaml'))) writeOfflineConfig(join(source, 'profiles', 'hkstock', 'config.yaml'), join(home, 'profiles', 'hkstock', 'config.yaml'));
  for (const relative of ['.env', 'profiles/hkstock/.env']) {
    const content = readFileSync(join(source, relative), 'utf8');
    writeFileSync(join(home, relative), content.split(/\r?\n/).filter(line => !line.startsWith('WEIXIN_TOKEN=')).join('\n') + '\n', { mode: 0o600 });
  }
  return home;
}
export const ARTIFACT_DIR = process.env.AUTOPILOT_ARTIFACT_DIR || '/tmp/autopilot-artifacts';
export const ROUTES = Object.freeze([
  'finance_wind_stock', 'finance_wind_fund', 'finance_wind_docs',
  'finance_hexin_stock', 'finance_hexin_global_stock', 'finance_hexin_fund',
  'finance_search',
]);
mkdirSync(ARTIFACT_DIR, { recursive: true });

export function cleanEnv(extra = {}) {
  const env = { ...process.env, ...extra };
  for (const key of Object.keys(env)) {
    if (/^ANTHROPIC_(AUTH_TOKEN|API_KEY|BASE_URL)$/.test(key)) delete env[key];
  }
  env.NO_COLOR = '1';
  return env;
}

export async function run(command, args, options = {}) {
  const timeout = options.timeout ?? 180000;
  return new Promise((resolveRun, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd || ROOT,
      env: options.env || cleanEnv(),
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGKILL');
      const loggedArgs = args.map((arg, index) => index > 0 && args[index - 1] === '--client-env' ? '[REDACTED]' : arg);
      reject(new Error(`process timeout ${timeout}ms: ${command} ${loggedArgs.join(' ')}`));
    }, timeout);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', error => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(error);
    });
    child.on('close', (code, signal) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolveRun({ code, signal, stdout, stderr });
    });
    if (options.input !== undefined) child.stdin.write(options.input);
    child.stdin.end();
  });
}

export function runBridge(args, options = {}) {
  if (options.sandboxProfile) return run('sandbox-exec', ['-f', options.sandboxProfile, process.execPath, BRIDGE, ...args], options);
  return run(process.execPath, [BRIDGE, ...args], options);
}

export function runHermes(prompt, options = {}) {
  if (options.sandboxProfile && options.isolatedHome) {
    const allowedKeys = new Set(['PATH', 'NO_COLOR', 'HERMES_HOME', 'HKSTOCK_DATA_DIR', 'HKSTOCK_RESEARCH_GUARD', 'HKSTOCK_AUDIT_LOG', 'HKSTOCK_RUN_ID', 'FINANCE_REAL_HERMES', 'FINANCE_TEST_LOOPBACK_URL', 'FINANCE_TEST_PROXY_LOOPBACK', 'FINANCE_TEST_MKTD_MARKER', 'ZCODE_FINANCE_BIN', 'NODE_OPTIONS', 'HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY', 'https_proxy', 'http_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy', 'TMPDIR', 'TMP', 'TEMP', 'XDG_CACHE_HOME', 'UV_CACHE_DIR', 'PIP_CACHE_DIR', 'PYTHONDONTWRITEBYTECODE']);
    const clientEnv = Object.fromEntries(Object.entries(options.env || {}).filter(([key]) => allowedKeys.has(key)));
    const profile = options.profile || 'hkstock';
    clientEnv.HERMES_HOME = profile === 'default' ? options.isolatedHome : join(options.isolatedHome, 'profiles', profile);
    return run('sandbox-exec', ['-f', options.sandboxProfile, activeHermesPython(), ISOLATED_HERMES, '--prompt', prompt, '--cwd', options.cwd || ROOT, '--client-env', JSON.stringify(clientEnv)], { timeout: 900000, ...options, env: clientEnv });
  }
  const args = ['--profile', options.profile || 'hkstock', '-z', prompt];
  if (options.sandboxProfile) return run('sandbox-exec', ['-f', options.sandboxProfile, HERMES, ...args], { timeout: 900000, ...options });
  return run(HERMES, args, { timeout: 900000, ...options });
}

export function runGuard(kind, target, options = {}) {
  return run('python3', [GUARD, kind, target], options);
}

export function artifact(id, value) {
  const path = join(ARTIFACT_DIR, `${id}.out`);
  const safe = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
  writeFileSync(path, safe.replace(/enc:v1:[^\s"']+/g, '[REDACTED]').replace(/Bearer\s+[A-Za-z0-9._~-]+/g, 'Bearer [REDACTED]'));
  assert.ok(statSync(path).size > 0, `${id} artifact must be non-empty`);
}

export function parseSingleJson(stdout, label = 'stdout') {
  const trimmed = stdout.trim();
  assert.ok(trimmed.length > 0, `${label} must contain one JSON value`);
  return JSON.parse(trimmed);
}

export function tempDir(prefix) {
  return mkdtempSync(join(tmpdir(), prefix));
}

export function walk(dir) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(path));
    else if (entry.isFile()) out.push(path);
  }
  return out.sort();
}

export function snapshot(dir) {
  const result = {};
  for (const path of walk(dir)) {
    const body = readFileSync(path);
    result[relative(dir, path)] = {
      sha256: createHash('sha256').update(body).digest('hex'),
      body: body.toString('utf8'),
    };
  }
  return result;
}

export function changedPaths(before, after) {
  return [...new Set([...Object.keys(before), ...Object.keys(after)])]
    .filter(key => !before[key] || !after[key] || before[key].sha256 !== after[key].sha256).sort();
}

export function latestFiles(dir, pattern = /.*/, since = 0) {
  return walk(dir).filter(path => pattern.test(path) && statSync(path).mtimeMs >= since)
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
}

export function readRecords(dir) {
  const records = [];
  for (const path of walk(dir)) {
    if (!['.json', '.jsonl'].includes(extname(path))) continue;
    const text = readFileSync(path, 'utf8').trim();
    if (!text) continue;
    if (extname(path) === '.jsonl') {
      for (const line of text.split(/\r?\n/)) if (line.trim()) records.push({ ...JSON.parse(line), __file: path });
    } else {
      const value = JSON.parse(text);
      if (Array.isArray(value)) for (const item of value) records.push({ ...item, __file: path });
      else records.push({ ...value, __file: path });
    }
  }
  return records;
}

export function parseFrontmatter(text) {
  const match = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return {};
  const out = {};
  for (const line of match[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$/);
    if (!kv) continue;
    let value = kv[2].trim().replace(/^['"]|['"]$/g, '');
    if (/^-?\d+$/.test(value)) value = Number(value);
    out[kv[1]] = value;
  }
  return out;
}

export function tableRows(markdown, heading = null) {
  let body = markdown;
  if (heading) {
    const match = markdown.match(new RegExp(`^##\\s+${heading}[^\\S\\n]*\\n([\\s\\S]*?)(?=^##\\s|(?![\\s\\S]))`, 'm'));
    body = match ? match[1] : '';
  }
  return body.split(/\r?\n/).filter(line => /^\|.*\|\s*$/.test(line))
    .filter(line => !/^\|\s*[-:]+/.test(line.replace(/\s/g, '')))
    .map(line => line.split('|').slice(1, -1).map(cell => cell.trim()))
    .filter(cells => !/^(标的|资产|subject|代码)$/i.test(cells[0] || ''));
}

export function dataRecordCount(value) {
  if (value == null) return 0;
  if (Array.isArray(value)) return value.length;
  if (typeof value === 'object') {
    if (Array.isArray(value.records)) return value.records.length;
    if (Array.isArray(value.data)) return value.data.length;
    if (Array.isArray(value.content)) return value.content.filter(item => String(item.text || '').trim().length > 0).length;
    return Object.keys(value).length > 0 ? 1 : 0;
  }
  return String(value).trim() ? 1 : 0;
}

export function findKey(value, key) {
  if (!value || typeof value !== 'object') return undefined;
  if (Object.hasOwn(value, key)) return value[key];
  for (const child of Object.values(value)) {
    const found = findKey(child, key);
    if (found !== undefined) return found;
  }
  return undefined;
}

export function assertRedacted(...values) {
  const text = values.join('\n');
  const leaks = [
    ...text.matchAll(/enc:v1:[^\s"']+/g),
    ...text.matchAll(/Bearer\s+(?!\[REDACTED\])[\w.~-]{8,}/g),
    ...text.matchAll(/(?:zcodejwttoken|access_token)["'\s:=]+(?!null|undefined|\[REDACTED\])[\w:.-]{8,}/gi),
  ];
  assert.equal(leaks.length, 0, 'token_or_bearer_or_encv1_leak_count must be 0');
}

export function evidenceFixture(overrides = {}) {
  return {
    schema_version: 1,
    id: 'EWind2025001',
    subject: '00700.HK',
    asset_type: 'stock',
    provider: 'Wind',
    route: 'finance_wind_stock',
    tool: 'get_stock_fundamentals',
    query: { stock_code: '00700.HK', year: 2025 },
    retrieved_at: '2026-11-04T08:00:00Z',
    raw_response: { records: [{ revenue: 100 }] },
    report_period: '2025-12-31',
    announcement_date: '2026-03-31',
    currency: 'CNY',
    unit: '亿元',
    source_url: 'https://www1.hkexnews.hk/listedco/listconews/sehk/2026/0331/example.pdf',
    page: 1,
    provenance: '披露',
    source_version: '2026-03-31T00:00:00Z#1',
    supersedes: null,
    ...overrides,
  };
}

export const ACTIONS = Object.freeze(['加仓', '买入', '持有', '减仓', '清仓', '观望', '不判断']);

export function briefFixture(overrides = {}) {
  return {
    workflow_id: 'hkstock-ai-native-v1',
    report_id: 'brief-20261104-001',
    subject: 'portfolio',
    generated_at: '2026-11-04T08:00:00Z',
    sections: ['组合观点', '证据与数据缺口'],
    recommendations: [{
      subject: '00700.HK', asset_type: 'stock', action: '持有',
      reason: '因为现金流覆盖资本开支，盈利质量支持继续持有 [EWind2025001]',
      trigger: '若核心现金流假设证伪则复盘', position_advice: '相对上限 15%',
      evidence_refs: ['EWind2025001'],
    }],
    ...overrides,
  };
}

export function thesisFixture(overrides = {}) {
  const value = {
    workflow_id: 'hkstock-ai-native-v1',
    report_id: 'thesis-00700-002',
    subject: '00700.HK',
    revision: 2,
    updated_at: '2026-11-04T08:00:00Z',
    review_after: '2026-12-01',
    current_conclusion: '持有',
    sections: ['当前观点', '关键假设', '反证与风险', '证据', '观点历史'],
    supporting_evidence_refs: ['EWind2025001'],
    challenging_evidence_refs: ['EChallenge001'],
    triggers: ['若现金流持续低于资本开支则降低仓位上限'],
    history: [
      { revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EWind2025001'] },
      { revision: 2, updated_at: '2026-11-04T08:00:00Z', conclusion: '持有', evidence_refs: ['EWind2025001'] },
    ],
    ...overrides,
  };
  if (value.revision === 1 && overrides.history === undefined) value.history = value.history.slice(0, 1);
  return value;
}

function yamlFrontmatter(fields) {
  const lines = Object.entries(fields).filter(([, value]) => value !== undefined).map(([key, value]) => `${key}: ${value ?? ''}`);
  return `---\n${lines.join('\n')}\n---\n`;
}

export function briefMarkdown(overrides = {}) {
  const value = briefFixture(overrides);
  let text = yamlFrontmatter({ workflow_id: value.workflow_id, report_id: value.report_id, subject: value.subject, generated_at: value.generated_at });
  if (value.sections.includes('组合观点')) {
    text += '\n## 组合观点\n';
    const complete = value.recommendations.every(row => row.reason && row.trigger && row.position_advice && row.evidence_refs);
    if (complete) {
      text += '| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |\n|---|---|---|---|---|---|\n';
      for (const row of value.recommendations) text += `| ${row.subject} | ${row.action} | ${row.position_advice} | ${row.reason} | ${row.trigger} | ${(row.evidence_refs || []).map(id => `[${id}]`).join(' ')} |\n`;
    } else {
      text += '| 标的 | 行动 |\n|---|---|\n';
      for (const row of value.recommendations) text += `| ${row.subject} | ${row.action} |\n`;
    }
  }
  if (value.sections.includes('证据与数据缺口')) {
    text += '\n## 证据与数据缺口\n';
    const gaps = value.recommendations.filter(row => row.action === '不判断');
    if (gaps.length) for (const row of gaps) text += `- ${row.subject}：${row.reason}\n`;
    else text += '- 证据引用均指向证据账本；无额外缺口。\n';
  }
  return text;
}

export function thesisMarkdown(overrides = {}) {
  const value = thesisFixture(overrides);
  let text = yamlFrontmatter({ workflow_id: value.workflow_id, report_id: value.report_id, subject: value.subject, revision: value.revision, updated_at: value.updated_at, review_after: value.review_after });
  if (value.sections.includes('当前观点')) text += `\n## 当前观点\n${value.current_conclusion}\n\n触发条件：${value.triggers.join('；')}\n`;
  if (value.sections.includes('关键假设')) text += `\n## 关键假设\n- 现金流覆盖资本开支 [${value.supporting_evidence_refs[0] || ''}]\n`;
  if (value.sections.includes('反证与风险')) text += `\n## 反证与风险\n- 若现金流持续低于资本开支则当前观点被证伪 [${value.challenging_evidence_refs[0] || ''}]\n`;
  if (value.sections.includes('证据')) {
    text += `\n## 证据\n- 支持：${value.supporting_evidence_refs.map(id => `[${id}]`).join(' ')}\n`;
    text += `- 挑战：${value.challenging_evidence_refs.map(id => `[${id}]`).join(' ')}\n`;
  }
  if (value.sections.includes('观点历史')) {
    text += '\n## 观点历史\n';
    for (const item of value.history) {
      text += `\n### revision ${item.revision}\n`;
      text += `- revision: ${item.revision}\n`;
      if (item.updated_at !== undefined) text += `- updated_at: ${item.updated_at}\n`;
      if (item.conclusion !== undefined) text += `- conclusion: ${item.conclusion}\n`;
      if (item.evidence_refs !== undefined) text += `- 当时证据: ${item.evidence_refs.map(id => `[${id}]`).join(' ')}\n`;
      text += `- 触发条件: ${value.triggers.join('；')}\n`;
    }
  }
  return text;
}

export function deepMarkdown(overrides = {}) {
  const value = thesisFixture(overrides);
  let text = yamlFrontmatter({ workflow_id: value.workflow_id, report_id: value.report_id, subject: value.subject, revision: value.revision, updated_at: value.updated_at, review_after: value.review_after, event_id: value.event_id });
  if (value.event_impact) text += `\n## 事件影响\n${String(value.event_impact).replace(/^##\s*事件影响\s*/i, '')}\n`;
  text += '\n## 组合观点\n| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |\n|---|---|---|---|---|---|\n';
  text += `| ${value.subject} | ${value.current_conclusion} | 相对上限 15% | 因为事件改变现金流假设 [EWind2025001] | 若后续公告证伪则复盘 | [EWind2025001] |\n`;
  text += `\n## 证据\n- 事件证据：[EWind2025001]\n- thesis：[对应活体 thesis](theses/${value.subject}.md)\n`;
  return text;
}

export function reviewMarkdown(overrides = {}) {
  const value = {
    workflow_id: 'hkstock-ai-native-v1', report_id: 'review-001', subject: '00700.HK', revision: 1,
    updated_at: '2026-11-04T08:00:00Z', review_after: '2026-11-04', review_date: '2026-11-04',
    original_assumption: '现金流覆盖资本开支', new_evidence_refs: ['EWind2025001'], verdict: '验证',
    evidence_change: '', ...overrides,
  };
  let text = yamlFrontmatter({ workflow_id: value.workflow_id, report_id: value.report_id, review_date: value.review_date });
  const change = value.evidence_change || `${value.new_evidence_refs.map(id => `[${id}]`).join(' ')} 对原假设形成新的证据支持`;
  text += `\n## 到期复盘\n| 标的 | 结论 | 原假设 | 新增证据变化 |\n|---|---|---|---|\n| ${value.subject} | ${value.verdict} | ${value.original_assumption} | ${change} |\n\n## 证据与数据缺口\n- 无额外缺口。\n`;
  return text;
}

export function parseThesisMarkdown(text) {
  const meta = parseFrontmatter(text);
  const section = name => text.match(new RegExp(`^##\\s+${name}[^\\S\\n]*\\n([\\s\\S]*?)(?=^##\\s|(?![\\s\\S]))`, 'm'))?.[1] || '';
  const refs = value => [...value.matchAll(/\[(E[A-Z][A-Za-z0-9]*)\]/g)].map(match => match[1]);
  const evidence = section('证据');
  const history = [...section('观点历史').matchAll(/^###\s+revision\s+(\d+)[^\S\n]*\n([\s\S]*?)(?=^###\s+revision|(?![\s\S]))/gm)].map(match => ({
    revision: Number(match[1]),
    updated_at: match[2].match(/updated_at:\s*([^\s]+)/)?.[1],
    conclusion: match[2].match(/conclusion:\s*([^\n]+)/)?.[1]?.trim(),
    evidence_refs: refs(match[2]),
  }));
  const current = section('当前观点');
  return {
    ...meta,
    current_conclusion: current.split(/\r?\n/).map(line => line.trim()).find(line => line && !line.startsWith('触发条件')),
    supporting_evidence_refs: refs(evidence.split(/\r?\n/).filter(line => line.includes('支持')).join('\n')),
    challenging_evidence_refs: refs(evidence.split(/\r?\n/).filter(line => line.includes('挑战')).join('\n')),
    triggers: [...current.matchAll(/若[^。\n]+/g)].map(match => match[0]),
    history,
  };
}

function schemaArgumentValue(name, definition, query) {
  const type = Array.isArray(definition.type) ? definition.type[0] : definition.type;
  if (/query|keyword|question|prompt|问财/i.test(name)) return query;
  if (/stock.*code|symbol|ticker|secu.*code|wind.*code|证券代码|股票代码/i.test(name)) return '00700.HK';
  if (/^code$/i.test(name)) return '00700.HK';
  if (/year|年份/i.test(name)) return type === 'string' ? '2025' : 2025;
  if (/report.*period|报告期/i.test(name)) return '2025-12-31';
  if (/start.*date|开始/i.test(name)) return '2025-01-01';
  if (/end.*date|结束/i.test(name)) return '2025-12-31';
  if (/indicator|field|metric|指标/i.test(name)) {
    const values = ['营业收入', '净利润', 'ROE', '毛利率', '经营现金流'];
    return type === 'array' ? values : values.join(',');
  }
  if (/market|市场/i.test(name)) return 'HK';
  if (type === 'array') return [query];
  if (type === 'number' || type === 'integer') return 2025;
  if (type === 'boolean') return true;
  if (type === 'object') return {};
  return query;
}

export async function callRealFinance(route, remoteTool, options = {}) {
  const verifiedArgs = {
    finance_wind_stock: {
      get_stock_fundamentals: {
        question: '查询腾讯控股(0700.HK)2025-12-31的营业收入、净利润、ROE、销售毛利率和经营活动现金流',
      },
    },
    finance_hexin_global_stock: {
      global_stock_financial: {
        codes: '0700.HK', market: '港股', indicators: '营业收入,总资产',
        report_date: '2025-12-31', currency: '港元',
      },
    },
  };
  const args = verifiedArgs[route]?.[remoteTool];
  assert.ok(args, `${route}/${remoteTool} needs a verified real query`);
  const listed = await runBridge(['list', '--json', '--route', route], { ...options, timeout: 180000 });
  assert.equal(listed.code, 0, listed.stderr);
  const payload = parseSingleJson(listed.stdout);
  const tools = findKey(payload, 'tools');
  assert.ok(Array.isArray(tools), `${route} must expose a tools array`);
  const tool = tools.find(item => (item.remote_name || String(item.name).replace(`${route}__`, '')) === remoteTool);
  assert.ok(tool, `${route} must expose ${remoteTool}`);
  const schema = tool.inputSchema || tool.input_schema;
  assert.equal(schema?.type, 'object', `${route}/${remoteTool} input schema must be an object`);
  const missing = (schema.required || []).filter(name => !Object.hasOwn(args, name));
  assert.deepEqual(missing, [], `${route}/${remoteTool} required arguments missing`);
  return runBridge(['call', '--json', '--route', route, '--tool', remoteTool, '--args', JSON.stringify(args)], { ...options, timeout: 180000 });
}

export function writeJson(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(value, null, 2));
}

export function writeMarkdown(path, value) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, value);
}

export function copyTree(source, destination) {
  if (existsSync(source)) cpSync(source, destination, { recursive: true });
}

export class FakeMcp {
  constructor() {
    this.calls = [];
    this.behavior = null;
    this.server = createServer(async (req, res) => {
      let body = '';
      req.setEncoding('utf8');
      for await (const chunk of req) body += chunk;
      let message = null;
      try { message = body ? JSON.parse(body) : null; } catch { /* JSON-RPC error below */ }
      const route = decodeURIComponent(req.url.split('/').filter(Boolean).at(-1) || '');
      this.calls.push({
        method: message?.method || null,
        route,
        tool: message?.params?.name || null,
        authorization_present: Boolean(req.headers.authorization),
        bigmodel_authorization_present: Boolean(req.headers['x-bigmodel-authorization']),
        target_type: req.headers['bigmodel-target-type'] || null,
        encrypted_header_present: /enc:v1:/i.test(String(req.headers.authorization || '') + String(req.headers['x-bigmodel-authorization'] || '')),
      });
      if (this.behavior) {
        const custom = await this.behavior({ req, message, route });
        if (custom) {
          if (custom.delay_ms) await new Promise(resolveDelay => setTimeout(resolveDelay, custom.delay_ms));
          res.writeHead(custom.status || 200, { 'content-type': 'application/json' });
          res.end(JSON.stringify(custom.body));
          return;
        }
      }
      if (!message) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }));
        return;
      }
      const reply = result => ({ jsonrpc: '2.0', id: message.id, result });
      let result;
      if (message.method === 'initialize') {
        result = { protocolVersion: '2025-03-26', capabilities: { tools: {} }, serverInfo: { name: 'fake-zcode', version: '1' } };
      } else if (message.method === 'ping') {
        result = {};
      } else if (message.method === 'tools/list') {
        const tool = this.toolFor(route);
        result = { tools: [{ name: tool, description: `fixture ${tool}`, inputSchema: { type: 'object', properties: {} } }] };
      } else if (message.method === 'tools/call') {
        result = {
          content: [{ type: 'text', text: JSON.stringify({ records: [{ subject: '00700.HK', value: 1 }] }) }],
          _meta: { route, tool: message.params?.name, request_id: 'fixture-request-1' },
        };
      } else if (message.method === 'notifications/initialized') {
        res.writeHead(202); res.end(); return;
      } else {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(reply(result)));
    });
  }

  toolFor(route) {
    return ({
      finance_wind_stock: 'get_stock_fundamentals',
      finance_wind_fund: 'get_fund_profile',
      finance_wind_docs: 'get_company_announcements',
      finance_hexin_stock: 'get_stock_financials',
      finance_hexin_global_stock: 'global_stock_financial',
      finance_hexin_fund: 'get_fund_profile',
      finance_search: 'search',
    })[route] || 'fixture_tool';
  }

  async start() {
    await new Promise(resolveListen => this.server.listen(0, '127.0.0.1', resolveListen));
    this.url = `http://127.0.0.1:${this.server.address().port}`;
    return this;
  }

  async stop() {
    await new Promise(resolveClose => this.server.close(resolveClose));
  }

  env(extra = {}) {
    const loader = join(tempDir('finance-loopback-loader-'), 'loader.mjs');
    writeFileSync(loader, `
      const endpoint = process.env.FINANCE_TEST_LOOPBACK_URL;
      const nativeFetch = globalThis.fetch;
      globalThis.fetch = function(input, init) {
        if (endpoint) {
          const raw = input instanceof Request ? input.url : String(input);
          const url = new URL(raw);
          if (url.hostname === 'zcode.z.ai') {
            const target = process.env.FINANCE_TEST_PROXY_LOOPBACK === '1'
              ? new URL('http://finance.fixture:80' + url.pathname + url.search)
              : new URL(endpoint + url.pathname + url.search);
            if (input instanceof Request) input = new Request(target, input);
            else input = target;
          }
        }
        return nativeFetch(input, init);
      };
    `);
    return cleanEnv({
      NODE_OPTIONS: `${process.env.NODE_OPTIONS || ''} --import=${pathToFileURL(loader).href}`.trim(),
      FINANCE_TEST_LOOPBACK_URL: this.url,
      ...extra,
    });
  }
}

export class EgressProxy {
  constructor() {
    this.allowed = [];
    this.blocked = [];
    this.errors = [];
    this.loopbackTarget = null;
    this.connections = new Set();
    this.server = createNetServer(socket => {
      this.connections.add(socket);
      socket.once('data', firstChunk => {
        const text = firstChunk.toString('utf8');
        const match = text.match(/^CONNECT\s+([^\s:]+):(\d+)\s+HTTP\/1\.[01]/i);
        if (!match) {
          const plain = text.match(/^[A-Z]+\s+http:\/\/([^:/\s]+):(\d+)\//i);
          const fixture = plain && plain[1].toLowerCase() === 'finance.fixture' && this.loopbackTarget;
          if (plain && fixture) {
            const target = fixture ? new URL(this.loopbackTarget) : null;
            const host = target ? target.hostname : plain[1].toLowerCase();
            const port = target ? Number(target.port || 80) : Number(plain[2]);
            this.allowed.push({ host: fixture ? 'finance.fixture' : host, port });
            const upstream = netConnect(port, host, () => {
              upstream.write(firstChunk); upstream.pipe(socket); socket.pipe(upstream);
            });
            this.connections.add(upstream);
            upstream.on('error', error => { this.errors.push({ host, port, code: error.code }); socket.destroy(); });
            socket.on('error', () => upstream.destroy());
            upstream.on('close', () => this.connections.delete(upstream));
          } else {
            this.blocked.push({ host: plain ? plain[1].toLowerCase() : 'non-connect', port: plain ? Number(plain[2]) : 0 });
            socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
          }
          return;
        }
        const host = match[1].toLowerCase();
        const port = Number(match[2]);
        const fixture = host === 'finance.fixture' && this.loopbackTarget;
        const target = fixture ? new URL(this.loopbackTarget) : null;
        const upstreamHost = target ? target.hostname : host;
        const upstreamPort = target ? Number(target.port || 80) : port;
        const allowedHosts = ['open.bigmodel.cn', 'bigmodel.cn', 'zcode.z.ai', 'z.ai', 'api.anthropic.com', 'hkexnews.hk', 'cninfo.com.cn', 'eastmoney.com', 'sina.com.cn', 'wind.com.cn', '10jqka.com.cn', 'akshare.akfamily.xyz'];
        if (!fixture && !allowedHosts.some(domain => host === domain || host.endsWith(`.${domain}`))) {
          this.blocked.push({ host, port });
          socket.end('HTTP/1.1 403 Forbidden\r\n\r\n');
          return;
        }
        this.allowed.push({ host, port });
        const upstream = netConnect(upstreamPort, upstreamHost, () => {
          socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
          upstream.pipe(socket); socket.pipe(upstream);
        });
        this.connections.add(upstream);
        upstream.on('error', () => socket.destroy());
        socket.on('error', () => upstream.destroy());
        upstream.on('close', () => this.connections.delete(upstream));
      });
      socket.on('close', () => this.connections.delete(socket));
    });
  }

  async start() {
    await new Promise(resolveListen => this.server.listen(0, '127.0.0.1', resolveListen));
    this.url = `http://127.0.0.1:${this.server.address().port}`;
    return this;
  }

  env(extra = {}) {
    return { HTTPS_PROXY: this.url, HTTP_PROXY: this.url, ALL_PROXY: this.url, https_proxy: this.url, http_proxy: this.url, all_proxy: this.url, NO_PROXY: '', no_proxy: '', ...extra };
  }

  async stop() {
    for (const connection of this.connections) connection.destroy();
    await new Promise(resolveClose => this.server.close(resolveClose));
  }
}

export function stdioClient(args, messages, options = {}) {
  return new Promise((resolveClient, reject) => {
    const child = spawn(process.execPath, [BRIDGE, ...args], {
      cwd: ROOT,
      env: options.env || cleanEnv(),
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('stdio client timeout')); }, options.timeout || 30000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', code => {
      clearTimeout(timer);
      const lines = stdout.split(/\r?\n/).filter(Boolean);
      const parsed = lines.map(line => JSON.parse(line));
      resolveClient({ code, stdout, stderr, messages: parsed });
    });
    for (const message of messages) child.stdin.write(`${JSON.stringify(message)}\n`);
    child.stdin.end();
  });
}
