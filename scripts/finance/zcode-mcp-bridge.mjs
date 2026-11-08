#!/usr/bin/env node
/** Read-only ZCode Wind/Hexin MCP bridge. Node.js 22+, zero dependencies. */
import { createDecipheriv, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { homedir, platform, userInfo } from 'node:os';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import readline from 'node:readline';

export const ROUTES = Object.freeze({
  finance_wind_stock: { provider: 'Wind' },
  finance_wind_fund: { provider: 'Wind' },
  finance_wind_docs: { provider: 'Wind' },
  finance_hexin_stock: { provider: 'Hexin' },
  finance_hexin_global_stock: { provider: 'Hexin' },
  finance_hexin_fund: { provider: 'Hexin' },
  finance_search: { provider: 'FinanceSearch' },
});
const ROUTE_NAMES = Object.freeze(Object.keys(ROUTES));
const DEFAULT_BASE_URL = 'https://zcode.z.ai';
const DEFAULT_TIMEOUT_MS = 30000;
const TOOLS_CACHE_TTL_MS = 30000; // Only schemas are cached; investment responses are never cached.
const CLIENT_INFO = { name: 'zcode-finance', version: '1.0.0' };
const PROTOCOL_VERSION = '2025-03-26';

export class BridgeError extends Error {
  constructor(code, message, options = {}) {
    super(message, options);
    this.name = 'BridgeError';
    this.code = code;
    this.exitCode = { USAGE_ERROR: 2, CREDENTIAL_ERROR: 3, AUTH_ERROR: 4, UPSTREAM_ERROR: 5, REMOTE_TOOL_ERROR: 6 }[code] ?? 5;
  }
}

export function redact(value, secrets = []) {
  let text = String(value ?? '');
  for (const secret of secrets) {
    if (typeof secret === 'string' && secret.length > 0) text = text.split(secret).join('[REDACTED]');
  }
  return text
    .replace(/Bearer\s+[^\s,;]+/gi, 'Bearer [REDACTED]')
    .replace(/enc:v1:[^\s,;"']+/g, '[REDACTED]')
    .replace(/((?:access[_-]?token|refresh[_-]?token|session[_-]?token|auth[_-]?token|api[_-]?key|authorization|private[_-]?key|credential|token)["'\s:=]+)[^\s,;}"']+/gi, '$1[REDACTED]');
}

function sensitiveKey(key) {
  const normalized = String(key).toLowerCase().replace(/[^a-z0-9]/g, '');
  return normalized === 'token' || /authorization|accesstoken|refreshtoken|sessiontoken|authtoken|jwttoken|apikey|privatekey|credential|secret|password|cookie|token$/.test(normalized);
}

function credentialPath(env = process.env) {
  if (env.ZCODE_CREDENTIALS_FILE) {
    const path = env.ZCODE_CREDENTIALS_FILE;
    return isAbsolute(path) ? path : resolve(path);
  }
  const base = env.ZCODE_DATA_BASE_DIR || homedir();
  const expanded = base === '~' ? homedir() : base.startsWith('~/') ? resolve(homedir(), base.slice(2)) : base;
  return resolve(expanded, '.zcode', 'v2', 'credentials.json');
}

function credentialSecret(env = process.env) {
  const configured = env.ZCODE_CREDENTIAL_SECRET?.trim();
  if (configured) return configured;
  let username = 'unknown';
  try { username = userInfo().username; } catch { /* Match the official fallback. */ }
  return `zcode-credential-fallback:${platform()}:${homedir()}:${username}`;
}

export function decryptCredential(value, env = process.env) {
  if (typeof value !== 'string' || !value) throw new BridgeError('CREDENTIAL_ERROR', 'Credential value is missing');
  if (!value.startsWith('enc:v1:')) return value;
  const parts = value.slice('enc:v1:'.length).split('.');
  if (parts.length !== 3 || parts.some((part) => !part)) throw new BridgeError('CREDENTIAL_ERROR', 'Credential decrypt failed: invalid ciphertext format');
  try {
    const [iv, tag, ciphertext] = parts.map((part) => Buffer.from(part, 'base64url'));
    if (iv.length !== 12 || tag.length !== 16) throw new Error('invalid IV or auth tag length');
    const key = createHash('sha256').update(credentialSecret(env)).digest();
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
    if (!plaintext) throw new Error('empty plaintext');
    return plaintext;
  } catch {
    throw new BridgeError('CREDENTIAL_ERROR', 'Credential decrypt failed: key mismatch or corrupted ciphertext');
  }
}

export function loadAuthHeaders(env = process.env) {
  let record;
  try {
    record = JSON.parse(readFileSync(credentialPath(env), 'utf8'));
  } catch (error) {
    throw new BridgeError('CREDENTIAL_ERROR', `Unable to read ZCode credentials: ${redact(error.message)}`);
  }
  if (!record || typeof record !== 'object' || Array.isArray(record)) throw new BridgeError('CREDENTIAL_ERROR', 'ZCode credential record must be an object');
  try {
    const jwt = decryptCredential(record.zcodejwttoken, env);
    const accessToken = decryptCredential(record['oauth:bigmodel:access_token'], env);
    return {
      secrets: [jwt, accessToken],
      headers: {
        Authorization: `Bearer ${jwt}`,
        'X-Bigmodel-Authorization': `Bearer ${accessToken}`,
        'Bigmodel-Target-Type': 'PERSONAL',
      },
    };
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    throw new BridgeError('CREDENTIAL_ERROR', 'Unable to decrypt ZCode credentials');
  }
}

function assertRoute(route) {
  if (!Object.hasOwn(ROUTES, route)) throw new BridgeError('USAGE_ERROR', `Invalid read-only route: ${redact(route)}`);
  return route;
}

function endpoint(route, env = process.env) {
  assertRoute(route);
  let base;
  try { base = new URL(env.ZCODE_MCP_BASE_URL || DEFAULT_BASE_URL); } catch { throw new BridgeError('USAGE_ERROR', 'Invalid ZCODE_MCP_BASE_URL'); }
  const loopback = ['127.0.0.1', 'localhost', '::1'].includes(base.hostname);
  const production = base.protocol === 'https:' && base.hostname === 'zcode.z.ai' && (!base.port || base.port === '443');
  if (!(production || (loopback && base.protocol === 'http:'))) throw new BridgeError('USAGE_ERROR', 'Remote URL must be the HTTPS ZCode gateway (HTTP is test-only on loopback)');
  if (base.username || base.password || base.search || base.hash) throw new BridgeError('USAGE_ERROR', 'Remote base URL cannot contain credentials, query, or fragment');
  const finalUrl = new URL(`${base.pathname.replace(/\/+$/, '')}/api/v1/mcp/server/${route}`, base.origin);
  if (finalUrl.origin !== base.origin || finalUrl.hostname !== base.hostname || finalUrl.protocol !== base.protocol) throw new BridgeError('USAGE_ERROR', 'Remote base path escapes the approved gateway');
  if (production && (finalUrl.hostname !== 'zcode.z.ai' || finalUrl.protocol !== 'https:' || (finalUrl.port && finalUrl.port !== '443'))) throw new BridgeError('USAGE_ERROR', 'Remote URL must remain on the production ZCode gateway');
  return finalUrl.toString();
}

function timeoutMs(env = process.env) {
  const raw = env.ZCODE_MCP_TIMEOUT_MS ?? String(DEFAULT_TIMEOUT_MS);
  if (!/^\d+$/.test(raw)) throw new BridgeError('USAGE_ERROR', 'ZCODE_MCP_TIMEOUT_MS must be an integer');
  const value = Number(raw);
  if (value < 1000 || value > 120000) throw new BridgeError('USAGE_ERROR', 'ZCODE_MCP_TIMEOUT_MS must be between 1000 and 120000');
  return value;
}

function parseMcpPayload(text, contentType) {
  if (contentType.includes('text/event-stream')) {
    const events = text.split(/\r?\n\r?\n/);
    const messages = [];
    for (const event of events) {
      const data = event.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trimStart()).join('\n');
      if (data) {
        try { messages.push(JSON.parse(data)); } catch { throw new BridgeError('UPSTREAM_ERROR', 'MCP SSE event contained invalid JSON'); }
      }
    }
    return messages;
  }
  try { return [JSON.parse(text)]; } catch { throw new BridgeError('UPSTREAM_ERROR', 'MCP response was not valid JSON or SSE'); }
}

function isAuthError(code, message) {
  return code === 1006 || /no permission|unauthori[sz]ed|forbidden|authentication|套餐权限/i.test(message);
}

export class McpClient {
  constructor(route, env = process.env) {
    this.route = assertRoute(route);
    this.env = env;
    this.url = endpoint(route, env);
    this.timeout = timeoutMs(env);
    this.sessionId = null;
    this.initialized = false;
    this.nextId = 1;
    this.secrets = [];
    this.toolsCache = null;
  }

  async request(method, params, { notification = false } = {}) {
    const auth = loadAuthHeaders(this.env);
    this.secrets = auth.secrets;
    const id = notification ? undefined : this.nextId++;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeout);
    let response;
    try {
      response = await fetch(this.url, {
        method: 'POST',
        headers: {
          ...auth.headers,
          'Content-Type': 'application/json',
          Accept: 'application/json, text/event-stream',
          ...(this.sessionId ? { 'Mcp-Session-Id': this.sessionId } : {}),
        },
        body: JSON.stringify({ jsonrpc: '2.0', ...(id === undefined ? {} : { id }), method, ...(params === undefined ? {} : { params }) }),
        redirect: 'error',
        signal: controller.signal,
      });
      const text = await response.text();
      const newSessionId = response.headers.get('mcp-session-id');
      if (method === 'initialize' && newSessionId) this.sessionId = newSessionId;
      if (response.status === 401 || response.status === 403) throw new BridgeError('AUTH_ERROR', `Remote authentication failed (HTTP ${response.status})`);
      if (response.status < 200 || response.status >= 300) throw new BridgeError('UPSTREAM_ERROR', `MCP HTTP ${response.status}: ${redact(text.slice(0, 500), this.secrets)}`);
      if (notification || response.status === 202 || response.status === 204 || !text.trim()) return null;
      const messages = parseMcpPayload(text, response.headers.get('content-type') || '');
      const message = messages.find((item) => item?.id === id);
      if (!message || message.jsonrpc !== '2.0') throw new BridgeError('UPSTREAM_ERROR', `MCP protocol response did not contain request id ${id}`);
      if (message.error) {
        const code = message.error.code;
        const detail = redact(message.error.message || 'Remote JSON-RPC error', this.secrets);
        if (isAuthError(code, detail)) throw new BridgeError('AUTH_ERROR', detail);
        if (Number.isInteger(code) && code >= -32700 && code <= -32600) throw new BridgeError('UPSTREAM_ERROR', `MCP protocol error ${code}: ${detail}`);
        throw new BridgeError('REMOTE_TOOL_ERROR', `Remote error ${code}: ${detail}`);
      }
      if (!Object.hasOwn(message, 'result')) throw new BridgeError('UPSTREAM_ERROR', 'MCP response omitted result');
      return message.result;
    } catch (error) {
      if (error instanceof BridgeError) throw error;
      if (error.name === 'AbortError' || error.name === 'TimeoutError') throw new BridgeError('UPSTREAM_ERROR', `MCP request timed out after ${this.timeout}ms`);
      throw new BridgeError('UPSTREAM_ERROR', `MCP transport failed: ${redact(error.message, this.secrets)}`);
    } finally {
      clearTimeout(timer);
    }
  }

  async initialize() {
    if (this.initialized) return;
    const result = await this.request('initialize', { protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: CLIENT_INFO });
    if (!result || typeof result !== 'object' || !result.protocolVersion) throw new BridgeError('UPSTREAM_ERROR', 'MCP initialize returned an invalid result');
    await this.request('notifications/initialized', {}, { notification: true });
    this.initialized = true;
  }

  async listTools() {
    await this.initialize();
    if (this.toolsCache && Date.now() - this.toolsCache.at < TOOLS_CACHE_TTL_MS) return this.toolsCache.tools;
    const result = await this.request('tools/list', {});
    if (!result || !Array.isArray(result.tools)) throw new BridgeError('UPSTREAM_ERROR', 'tools/list omitted tools array');
    for (const tool of result.tools) {
      if (!tool || typeof tool.name !== 'string' || !tool.name) throw new BridgeError('UPSTREAM_ERROR', 'tools/list contained an invalid tool');
    }
    this.toolsCache = { at: Date.now(), tools: result.tools };
    return result.tools;
  }

  async call(tool, args) {
    const tools = await this.listTools();
    if (!tools.some((candidate) => candidate.name === tool)) throw new BridgeError('USAGE_ERROR', `Tool is not advertised by ${this.route}: ${redact(tool)}`);
    const result = await this.request('tools/call', { name: tool, arguments: args });
    if (result?.isError === true) throw new BridgeError('REMOTE_TOOL_ERROR', redact(result.content?.map((item) => item.text || '').join(' ') || 'Remote tool returned isError', this.secrets));
    return result;
  }
}

function parseArgs(argv) {
  const flags = { json: false };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--json') { flags.json = true; continue; }
    if (['--route', '--tool', '--args', '--routes'].includes(key)) {
      if (i + 1 >= argv.length) throw new BridgeError('USAGE_ERROR', `${key} requires a value`);
      flags[key.slice(2)] = argv[++i];
      continue;
    }
    throw new BridgeError('USAGE_ERROR', `Unknown argument: ${redact(key)}`);
  }
  return flags;
}

function parseObject(raw) {
  let value;
  try { value = JSON.parse(raw || '{}'); } catch { throw new BridgeError('USAGE_ERROR', '--args must be valid JSON'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BridgeError('USAGE_ERROR', '--args must be a JSON object');
  return value;
}

function selectedRoutes(raw) {
  const routes = raw ? raw.split(',') : [...ROUTE_NAMES];
  if (!routes.length || routes.some((route) => !route)) throw new BridgeError('USAGE_ERROR', '--routes must be a non-empty CSV');
  return [...new Set(routes.map(assertRoute))];
}

function sanitizeResult(value, secrets = []) {
  if (typeof value === 'string') return redact(value, secrets);
  if (Array.isArray(value)) return value.map((item) => sanitizeResult(item, secrets));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, sensitiveKey(key) ? '[REDACTED]' : sanitizeResult(item, secrets)]));
  return value;
}

async function runCli(command, flags) {
  if (command === 'doctor') {
    if (flags.route || flags.tool || flags.args || flags.routes) throw new BridgeError('USAGE_ERROR', 'doctor only accepts --json');
    const checks = await Promise.all(ROUTE_NAMES.map(async (route) => {
      try { await new McpClient(route).initialize(); return { route, ok: true }; }
      catch (error) { return { route, ok: false, code: error.code || 'UPSTREAM_ERROR', message: redact(error.message, error.secrets) }; }
    }));
    const failed = checks.find((check) => !check.ok);
    return { payload: { status: failed ? 'error' : 'ok', checks }, exitCode: failed ? new BridgeError(failed.code, failed.message).exitCode : 0 };
  }
  if (command === 'list') {
    if (flags.tool || flags.args || flags.routes) throw new BridgeError('USAGE_ERROR', 'list only accepts --route and --json');
    const routes = flags.route ? [assertRoute(flags.route)] : [...ROUTE_NAMES];
    const settled = await Promise.all(routes.map(async (route) => {
      try {
        const client = new McpClient(route);
        return { route, tools: sanitizeResult(await client.listTools(), client.secrets) };
      } catch (error) { return { error, route }; }
    }));
    const errors = settled.filter((item) => item.error).map((item) => ({ route: item.route, code: item.error.code || 'UPSTREAM_ERROR', message: redact(item.error.message, item.error.secrets) }));
    return { payload: { routes: settled.filter((item) => !item.error).map(({ route, tools }) => ({ route, tools })), errors }, exitCode: errors.length ? settled.find((item) => item.error).error.exitCode || 5 : 0 };
  }
  if (command === 'call') {
    if (!flags.route || !flags.tool || flags.routes) throw new BridgeError('USAGE_ERROR', 'call requires --route and --tool');
    const client = new McpClient(flags.route);
    const result = await client.call(flags.tool, parseObject(flags.args));
    return { payload: { provider: ROUTES[client.route].provider, route: client.route, tool: flags.tool, result: sanitizeResult(result, client.secrets) }, exitCode: 0 };
  }
  throw new BridgeError('USAGE_ERROR', `Unknown command: ${redact(command)}`);
}

function rpcError(id, code, message, data) {
  return { jsonrpc: '2.0', id: id ?? null, error: { code, message: redact(message), ...(data ? { data } : {}) } };
}

async function serve(flags) {
  if (flags.json || flags.route || flags.tool || flags.args) throw new BridgeError('USAGE_ERROR', 'serve only accepts --routes');
  const routes = selectedRoutes(flags.routes);
  const clients = new Map(routes.map((route) => [route, new McpClient(route)]));
  let initialized = false;
  const output = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let request;
    try { request = JSON.parse(line); } catch { output(rpcError(null, -32700, 'Parse error')); continue; }
    const id = request?.id;
    if (!request || request.jsonrpc !== '2.0' || typeof request.method !== 'string') { output(rpcError(id, -32600, 'Invalid Request')); continue; }
    if (request.method.startsWith('notifications/')) continue;
    try {
      if (request.method === 'initialize') {
        initialized = true;
        output({ jsonrpc: '2.0', id, result: { protocolVersion: request.params?.protocolVersion || PROTOCOL_VERSION, capabilities: { tools: { listChanged: false } }, serverInfo: CLIENT_INFO } });
      } else if (request.method === 'ping') {
        output({ jsonrpc: '2.0', id, result: {} });
      } else if (['tools/list', 'tools/call'].includes(request.method) && !initialized) {
        output(rpcError(id, -32002, 'Server not initialized'));
      } else if (request.method === 'tools/list') {
        const tools = [];
        for (const [route, client] of clients) {
          for (const tool of await client.listTools()) {
            const safeTool = sanitizeResult(tool, client.secrets);
            tools.push({ ...safeTool, name: `${route}__${safeTool.name}` });
          }
        }
        output({ jsonrpc: '2.0', id, result: { tools } });
      } else if (request.method === 'tools/call') {
        const mappedName = request.params?.name;
        const route = routes.find((candidate) => typeof mappedName === 'string' && mappedName.startsWith(`${candidate}__`));
        if (!route) throw new BridgeError('USAGE_ERROR', 'Unknown mapped tool name');
        const originalName = mappedName.slice(route.length + 2);
        const result = await clients.get(route).call(originalName, request.params?.arguments ?? {});
        output({ jsonrpc: '2.0', id, result: sanitizeResult(result, clients.get(route).secrets) });
      } else {
        output(rpcError(id, -32601, 'Method not found'));
      }
    } catch (error) {
      const bridgeError = error instanceof BridgeError ? error : new BridgeError('UPSTREAM_ERROR', error.message);
      output(rpcError(id, bridgeError.code === 'USAGE_ERROR' ? -32602 : -32000, bridgeError.message, { code: bridgeError.code }));
    }
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const jsonRequested = rest.includes('--json');
  let flags;
  try {
    if (!command || !['doctor', 'list', 'call', 'serve'].includes(command)) throw new BridgeError('USAGE_ERROR', 'Usage: zcode-finance doctor|list|call|serve');
    flags = parseArgs(rest);
    if (command === 'serve') { await serve(flags); return; }
    const { payload, exitCode } = await runCli(command, flags);
    if (flags.json || command === 'call') process.stdout.write(`${JSON.stringify(payload)}\n`);
    else if (command === 'doctor') process.stdout.write(`${payload.status === 'ok' ? 'OK' : 'ERROR'} ${payload.checks.map((check) => `${check.route}:${check.ok ? 'ok' : 'error'}`).join(' ')}\n`);
    else {
      for (const route of payload.routes) {
        process.stdout.write(`${route.route}\n`);
        for (const tool of route.tools) process.stdout.write(`  ${tool.name}\t${tool.description || ''}\n`);
      }
      for (const error of payload.errors) process.stderr.write(`${error.route}: ${error.code}: ${error.message}\n`);
    }
    process.exitCode = exitCode;
  } catch (error) {
    const bridgeError = error instanceof BridgeError ? error : new BridgeError('UPSTREAM_ERROR', error.message);
    const message = redact(bridgeError.message);
    if (flags?.json || jsonRequested) process.stdout.write(`${JSON.stringify({ status: 'error', error: { code: bridgeError.code, message } })}\n`);
    else process.stderr.write(`${bridgeError.code}: ${message}\n`);
    process.exitCode = bridgeError.exitCode;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
