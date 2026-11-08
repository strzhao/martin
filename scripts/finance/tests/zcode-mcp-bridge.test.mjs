import assert from 'node:assert/strict';
import { after, before, test } from 'node:test';
import { spawn } from 'node:child_process';
import { createCipheriv, randomBytes } from 'node:crypto';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const CLI = fileURLToPath(new URL('../zcode-mcp-bridge.mjs', import.meta.url));
const SECRET = 'unit-test-credential-secret';
const JWT = 'unit-jwt-plaintext-do-not-leak';
const ACCESS = 'unit-access-plaintext-do-not-leak';
const ROUTES = [
  'finance_wind_stock', 'finance_wind_fund', 'finance_wind_docs',
  'finance_hexin_stock', 'finance_hexin_global_stock', 'finance_hexin_fund',
  'finance_search',
];

function encrypt(value) {
  const iv = randomBytes(12);
  const key = createHash('sha256').update(SECRET).digest();
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const body = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return `enc:v1:${iv.toString('base64url')}.${cipher.getAuthTag().toString('base64url')}.${body.toString('base64url')}`;
}

let server;
let origin;
let temp;
let baseEnv;
let mode = 'ok';
let requests;

function rpc(id, result) {
  return JSON.stringify({ jsonrpc: '2.0', id, result });
}

before(async () => {
  temp = mkdtempSync(join(tmpdir(), 'zcode-finance-test-'));
  const credentials = join(temp, 'credentials.json');
  writeFileSync(credentials, JSON.stringify({
    zcodejwttoken: encrypt(JWT),
    'oauth:bigmodel:access_token': encrypt(ACCESS),
  }), { mode: 0o600 });
  requests = [];
  server = createServer((req, res) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      const message = body ? JSON.parse(body) : null;
      requests.push({ url: req.url, headers: req.headers, message });
      if (req.headers.authorization !== `Bearer ${JWT}`
        || req.headers['x-bigmodel-authorization'] !== `Bearer ${ACCESS}`
        || req.headers['bigmodel-target-type'] !== 'PERSONAL') {
        res.writeHead(401, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: message?.id ?? null, error: { code: 1006, message: 'no permission' } }));
        return;
      }
      if (mode === 'permission') {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: 1006, message: 'no permission' } }));
        return;
      }
      if (mode === 'leak') {
        res.writeHead(500, { 'content-type': 'text/plain' });
        res.end(`upstream echoed Bearer ${JWT} and ${encrypt(ACCESS)}`);
        return;
      }
      if (message.method === 'notifications/initialized') {
        res.writeHead(202);
        res.end();
        return;
      }
      if (message.method === 'initialize') {
        res.writeHead(200, { 'content-type': 'application/json', 'mcp-session-id': 'unit-session' });
        res.end(rpc(message.id, { protocolVersion: message.params.protocolVersion, capabilities: {}, serverInfo: { name: 'fake', version: '1' } }));
        return;
      }
      if (message.method === 'tools/list') {
        if (mode === 'timeout') {
          setTimeout(() => {
            if (!res.destroyed) {
              res.writeHead(200, { 'content-type': 'application/json' });
              res.end(rpc(message.id, { tools: [] }));
            }
          }, 1400);
          return;
        }
        const result = { tools: [
          { name: 'get_fundamentals', description: 'Read fundamentals', inputSchema: { type: 'object', properties: { symbol: { type: 'string' } } } },
          { name: 'business_error', description: 'Synthetic failure', inputSchema: { type: 'object' } },
        ] };
        if (mode === 'sse') {
          res.writeHead(200, { 'content-type': 'text/event-stream' });
          res.end(`event: message\ndata: ${rpc(message.id, result)}\n\n`);
        } else {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(rpc(message.id, result));
        }
        return;
      }
      if (message.method === 'tools/call') {
        const result = message.params.name === 'business_error'
          ? { isError: true, content: [{ type: 'text', text: 'synthetic business failure' }] }
          : { _meta: { source: 'fixture' }, content: [{ type: 'text', text: 'ok' }], structuredContent: { value: 12.34, currency: 'CNY' } };
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(rpc(message.id, result));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'unknown method' } }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  baseEnv = {
    ...process.env,
    ZCODE_CREDENTIAL_SECRET: SECRET,
    ZCODE_CREDENTIALS_FILE: credentials,
    ZCODE_MCP_BASE_URL: origin,
    ZCODE_MCP_TIMEOUT_MS: '3000',
  };
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  rmSync(temp, { recursive: true, force: true });
});

async function run(args, env = {}) {
  const child = spawn(process.execPath, [CLI, ...args], { env: { ...baseEnv, ...env } });
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (chunk) => { stdout += chunk; });
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const timer = setTimeout(() => child.kill('SIGKILL'), 10000);
  const status = await new Promise((resolve) => child.on('close', resolve));
  clearTimeout(timer);
  mode = 'ok';
  return { status, stdout, stderr };
}

function jsonStdout(child) {
  assert.equal(child.status, 0, child.stderr);
  return JSON.parse(child.stdout);
}

test('list initializes, sends three authentication headers, and preserves tool schemas', async () => {
  requests = [];
  const out = jsonStdout(await run(['list', '--route', 'finance_wind_stock', '--json']));
  assert.equal(out.routes[0].route, 'finance_wind_stock');
  assert.equal(out.routes[0].tools[0].name, 'get_fundamentals');
  assert.equal(out.routes[0].tools[0].inputSchema.type, 'object');
  assert.deepEqual(out.errors, []);
  assert.equal(requests.filter((r) => r.message?.method === 'initialize').length, 1);
  assert.equal(requests[0].headers.authorization, `Bearer ${JWT}`);
  assert.equal(requests[0].headers['x-bigmodel-authorization'], `Bearer ${ACCESS}`);
  assert.equal(requests[0].headers['bigmodel-target-type'], 'PERSONAL');
  assert.ok(requests.every((r) => r.url.endsWith('/finance_wind_stock')));
  assert.ok(requests.slice(1).every((r) => r.headers['mcp-session-id'] === 'unit-session'));
});

test('call preserves provider, route, tool, _meta, content, and numeric result', async () => {
  const out = jsonStdout(await run(['call', '--route', 'finance_wind_stock', '--tool', 'get_fundamentals', '--args', '{"symbol":"TEST"}', '--json']));
  assert.equal(out.provider, 'Wind');
  assert.equal(out.route, 'finance_wind_stock');
  assert.equal(out.tool, 'get_fundamentals');
  assert.deepEqual(out.result._meta, { source: 'fixture' });
  assert.equal(out.result.structuredContent.value, 12.34);
  assert.equal(out.result.content[0].text, 'ok');
});

test('SSE responses are decoded as Streamable HTTP MCP', async () => {
  mode = 'sse';
  const out = jsonStdout(await run(['list', '--route', 'finance_hexin_fund', '--json']));
  assert.equal(out.routes[0].tools.length, 2);
});

test('doctor initializes every fixed route without investment data calls', async () => {
  requests = [];
  const out = jsonStdout(await run(['doctor', '--json']));
  assert.deepEqual(out, { status: 'ok', checks: ROUTES.map((route) => ({ route, ok: true })) });
  assert.equal(requests.filter((r) => r.message?.method === 'initialize').length, ROUTES.length);
  assert.equal(requests.filter((r) => r.message?.method === 'tools/call').length, 0);
});

test('usage errors cover route, JSON object, and tool membership', async () => {
  assert.equal((await run(['call', '--route', 'https://evil.invalid', '--tool', 'x', '--json'])).status, 2);
  assert.equal((await run(['call', '--route', 'finance_wind_stock', '--tool', 'get_fundamentals', '--args', '[]', '--json'])).status, 2);
  assert.equal((await run(['call', '--route', 'finance_wind_stock', '--tool', 'not_listed', '--json'])).status, 2);
  assert.equal((await run(['list', '--route', 'finance_wind_stock', '--json'], { ZCODE_MCP_BASE_URL: 'https://evil.invalid' })).status, 2);
});

test('early argument errors still honor --json with one JSON stdout value', async () => {
  for (const args of [['doctor', '--json', '--bogus'], ['call', '--json', '--route']]) {
    const child = await run(args);
    assert.equal(child.status, 2);
    assert.equal(child.stderr, '');
    const payload = JSON.parse(child.stdout);
    assert.equal(payload.status, 'error');
    assert.equal(payload.error.code, 'USAGE_ERROR');
  }
});

test('production base path cannot replace the approved gateway host', async () => {
  requests = [];
  const child = await run(['list', '--route', 'finance_wind_stock', '--json'], { ZCODE_MCP_BASE_URL: 'https://zcode.z.ai//attacker.invalid' });
  assert.equal(child.status, 2);
  assert.equal(child.stderr, '');
  const payload = JSON.parse(child.stdout);
  assert.deepEqual(payload.routes, []);
  assert.equal(payload.errors.length, 1);
  assert.equal(payload.errors[0].code, 'USAGE_ERROR');
  assert.match(payload.errors[0].message, /approved gateway|production ZCode gateway/);
  assert.equal(requests.length, 0);
});

test('missing fields and corrupt ciphertext are CREDENTIAL_ERROR without secret leakage', async () => {
  const missing = join(temp, 'missing.json');
  writeFileSync(missing, JSON.stringify({ zcodejwttoken: encrypt(JWT) }));
  const a = await run(['doctor', '--json'], { ZCODE_CREDENTIALS_FILE: missing });
  assert.equal(a.status, 3);
  assert.ok(!`${a.stdout}${a.stderr}`.includes(JWT));
  const corrupt = join(temp, 'corrupt.json');
  const ciphertext = encrypt(ACCESS);
  writeFileSync(corrupt, JSON.stringify({ zcodejwttoken: encrypt(JWT), 'oauth:bigmodel:access_token': ciphertext.slice(0, -2) }));
  const b = await run(['doctor', '--json'], { ZCODE_CREDENTIALS_FILE: corrupt });
  assert.equal(b.status, 3);
  assert.ok(!`${b.stdout}${b.stderr}`.includes(ciphertext));
  assert.ok(!`${b.stdout}${b.stderr}`.includes(ACCESS));
});

test('permission, timeout, and remote business errors use distinct exit codes', async () => {
  mode = 'permission';
  assert.equal((await run(['list', '--route', 'finance_wind_stock', '--json'])).status, 4);
  mode = 'timeout';
  assert.equal((await run(['list', '--route', 'finance_wind_stock', '--json'], { ZCODE_MCP_TIMEOUT_MS: '1000' })).status, 5);
  assert.equal((await run(['call', '--route', 'finance_wind_stock', '--tool', 'business_error', '--json'])).status, 6);
  assert.equal((await run(['doctor', '--json'], { ZCODE_MCP_TIMEOUT_MS: '0' })).status, 2);
});

test('upstream diagnostics redact bearer values and complete enc:v1 ciphertext', async () => {
  mode = 'leak';
  const child = await run(['list', '--route', 'finance_wind_stock', '--json']);
  const output = `${child.stdout}${child.stderr}`;
  assert.equal(child.status, 5);
  assert.ok(!output.includes(JWT));
  assert.ok(!output.includes(ACCESS));
  assert.ok(!/enc:v1:[A-Za-z0-9_.-]+/.test(output));
  assert.ok(!new RegExp(`Bearer ${JWT}`).test(output));
});

test('stdio MCP supports initialize, mapped tools/list, tools/call, ping, and JSON-RPC parse errors', async () => {
  const child = spawn(process.execPath, [CLI, 'serve', '--routes', 'finance_wind_stock'], { env: baseEnv, stdio: ['pipe', 'pipe', 'pipe'] });
  let buffer = '';
  const pending = new Map();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const index = buffer.indexOf('\n');
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      if (!line.trim()) continue;
      const message = JSON.parse(line);
      pending.get(message.id)?.(message);
      pending.delete(message.id);
    }
  });
  const request = (message) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`stdio timeout: ${JSON.stringify(message)}`)), 5000);
    pending.set(message.id, (value) => { clearTimeout(timer); resolve(value); });
    child.stdin.write(`${JSON.stringify(message)}\n`);
  });
  try {
    const init = await request({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'unit', version: '1' } } });
    assert.equal(init.result.serverInfo.name, 'zcode-finance');
    const listed = await request({ jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} });
    const mapped = listed.result.tools.find((tool) => tool.name === 'finance_wind_stock__get_fundamentals');
    assert.ok(mapped);
    const called = await request({ jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: mapped.name, arguments: { symbol: 'TEST' } } });
    assert.equal(called.result.structuredContent.value, 12.34);
    assert.deepEqual((await request({ jsonrpc: '2.0', id: 4, method: 'ping', params: {} })).result, {});
    const parseResponse = new Promise((resolve) => pending.set(null, resolve));
    child.stdin.write('{bad json}\n');
    assert.equal((await parseResponse).error.code, -32700);
  } finally {
    child.kill('SIGTERM');
  }
});
