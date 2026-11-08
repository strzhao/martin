import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { makeIsolatedHermesHome, tempDir, HERMES_HOME, ROOT } from './harness.mjs';

test('isolated hkstock config disables catalog egress without changing provider semantics', () => {
  const home = makeIsolatedHermesHome({ dir: tempDir('offline-config-') });
  assert.ok(existsSync(`${home}/profiles/hkstock/plugins`), 'profile plugins must be visible without a catalog migration fetch');
  const python = `
import json, sys, yaml
source = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))
isolated = yaml.safe_load(open(sys.argv[2], encoding='utf-8'))
assert source['model'] == isolated['model']
assert source.get('providers') == isolated.get('providers')
assert isolated['model_catalog']['enabled'] is False
assert isolated['plugins']['auto_update_check_hours'] == 0
assert isolated['memory']['provider'] == 'builtin', isolated['memory'].get('provider')
print(json.dumps({'offline_catalog': True, 'plugin_update_hours': 0, 'provider_semantics_unchanged': True}))
`;
  const result = spawnSync('python3', ['-c', python, `${HERMES_HOME}/profiles/hkstock/config.yaml`, `${home}/profiles/hkstock/config.yaml`], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), { offline_catalog: true, plugin_update_hours: 0, provider_semantics_unchanged: true });
});

test('runtime audit detects synthetic raw secrets and fails closed on session DB loss', () => {
  const dir = tempDir('runtime-audit-control-');
  const home = makeIsolatedHermesHome({ dir }, 'audit-control');
  const profile = `${home}/profiles/hkstock`;
  const sessionId = 'unit-isolated-session';
  const dbPath = `${profile}/state.db`;
  const logs = `${profile}/logs`;
  mkdirSync(logs, { recursive: true });
  writeFileSync(`${home}/.env`, 'BIGMODEL_API_KEY=unit-raw-secret-123456789\n', { mode: 0o600 });
  writeFileSync(`${profile}/.env`, 'BIGMODEL_API_KEY=unit-raw-secret-123456789\n', { mode: 0o600 });
  const createDb = `
import sqlite3, sys, yaml
config = yaml.safe_load(open(sys.argv[2], encoding='utf-8'))
db = sqlite3.connect(sys.argv[1])
db.execute('create table sessions (id text, profile_name text, model text, billing_provider text, billing_base_url text, started_at real)')
db.execute('create table messages (session_id text, content text, tool_calls text, reasoning text, reasoning_content text, api_content text)')
db.execute('insert into sessions values (?,?,?,?,?,?)', (sys.argv[4], 'hkstock', config['model']['default'], 'custom', config['model']['base_url'], float(sys.argv[3])))
db.commit()
db.close()
`;
  const started = Date.now() / 1000 - 2;
  const created = spawnSync('python3', ['-c', createDb, dbPath, `${profile}/config.yaml`, String(started), sessionId], { encoding: 'utf8' });
  assert.equal(created.status, 0, created.stderr);
  const acceptance = readFileSync(`${ROOT}/scripts/hkstock/tests/ai-native-finance.e2e.acceptance.test.mjs`, 'utf8');
  const auditCode = acceptance.match(/const RUNTIME_AUDIT_PY = String.raw`([\s\S]*?)`;/)[1];
  const baseline = `${dir}/baseline.json`;
  writeFileSync(baseline, '{}');
  const args = ['-c', auditCode, String(started), String(Date.now() / 1000 + 2), baseline, sessionId, dbPath,
    `${HERMES_HOME}/profiles/hkstock/config.yaml`, `${profile}/config.yaml`, `${home}/.env`, `${profile}/.env`, logs];
  const audit = (zcodeSecrets = []) => {
    const result = spawnSync('python3', args, { input: JSON.stringify({ zcode_secrets: zcodeSecrets }), encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  const zcodeFixtures = ['unit-zcode-jwt-123456789', 'unit-zcode-access-987654321'];
  const clean = audit(zcodeFixtures);
  assert.equal(clean.ok, true, clean.errors?.join('; '));
  assert.equal(clean.secret_count, 0);
  assert.equal(clean.zcode_secret_values_loaded, 2);
  assert.equal(clean.session_count, 1);
  assert.equal(clean.provider_semantics_match, true);
  assert.equal(clean.route_matches, true);
  writeFileSync(`${logs}/agent.log`, 'unit-raw-secret-123456789\napi_key=unit-assignment-secret-987654321\nunit-zcode-jwt-123456789\nunit-zcode-access-987654321\n');
  const injected = audit(zcodeFixtures);
  assert.ok(injected.secret_count >= 2, 'raw and assignment-form synthetic secrets must both be detected');
  assert.ok(injected.zcode_secret_count >= 2, 'ZCode raw JWT/access-token forms must be detected without Bearer prefixes');
  rmSync(dbPath);
  const unreadable = audit();
  assert.equal(unreadable.ok, false, 'missing exact session DB must fail closed');
  assert.ok(unreadable.errors.some(error => /state audit failed/.test(error)));
});

