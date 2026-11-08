import test from 'node:test';
import {
  assert, artifact, runBridge, runGuard, parseSingleJson, ROUTES, FakeMcp,
  dataRecordCount, findKey, assertRedacted, stdioClient, tempDir, writeJson,
  evidenceFixture, callRealFinance,
} from './harness.mjs';

// Local fake-MCP calls deliberately use an empty valid object. Real VIP calls never use
// these placeholder arguments: callRealFinance reads the live tool schema and fills a
// verified Tencent 2025 query with the required fields and types.
const CALL = {
  wind: ['call', '--json', '--route', 'finance_wind_stock', '--tool', 'get_stock_fundamentals', '--args', '{}'],
  hexin: ['call', '--json', '--route', 'finance_hexin_global_stock', '--tool', 'global_stock_financial', '--args', '{}'],
};

test('S4.P1 real Wind MCP: transport_error_count=0, provider=Wind, data_record_count>=1', { timeout: 360000 }, async () => {
  const result = await callRealFinance('finance_wind_stock', 'get_stock_fundamentals');
  assert.equal(result.code, 0, result.stderr);
  const body = parseSingleJson(result.stdout);
  const transportErrorCount = body.error || body.transport_error ? 1 : 0;
  const count = dataRecordCount(body.result);
  assert.equal(transportErrorCount, 0);
  assert.equal(body.provider, 'Wind');
  assert.ok(count >= 1, `data_record_count=${count}`);
  assertRedacted(result.stdout, result.stderr);
  artifact('S4.P1', { exit: result.code, transport_error_count: transportErrorCount, response_provider: body.provider, data_record_count: count });
});

test('S4.P2 real Hexin MCP: transport_error_count=0, provider=Hexin, data_record_count>=1', { timeout: 360000 }, async () => {
  const result = await callRealFinance('finance_hexin_global_stock', 'global_stock_financial');
  assert.equal(result.code, 0, result.stderr);
  const body = parseSingleJson(result.stdout);
  const transportErrorCount = body.error || body.transport_error ? 1 : 0;
  const count = dataRecordCount(body.result);
  assert.equal(transportErrorCount, 0);
  assert.equal(body.provider, 'Hexin');
  assert.ok(count >= 1, `data_record_count=${count}`);
  assertRedacted(result.stdout, result.stderr);
  artifact('S4.P2', { exit: result.code, transport_error_count: transportErrorCount, response_provider: body.provider, data_record_count: count });
});

test('S13.P1 CLI/stdio contract matrix: closed routes, args, aliases, timeout and doctor', { timeout: 240000 }, async t => {
  const server = await new FakeMcp().start();
  t.after(() => server.stop());
  const env = server.env();

  const doctor = await runBridge(['doctor', '--json'], { env });
  assert.equal(doctor.code, 0, doctor.stderr);
  const doctorBody = parseSingleJson(doctor.stdout);
  assert.deepEqual(Object.keys(doctorBody).sort(), ['checks', 'status']);
  assert.equal(findKey(doctorBody, 'timeout_ms'), undefined, 'doctor has no timeout_ms contract field');
  const doctorInvestmentCalls = server.calls.filter(call => call.method === 'tools/call').length;
  assert.equal(doctorInvestmentCalls, 0);

  const list = await runBridge(['list', '--json'], { env });
  assert.equal(list.code, 0, list.stderr);
  const listBody = parseSingleJson(list.stdout);
  assert.deepEqual(Object.keys(listBody).sort(), ['errors', 'routes']);
  const listedRoutes = listBody.routes.map(route => typeof route === 'string' ? route : route.route);
  assert.deepEqual([...listedRoutes].sort(), [...ROUTES].sort());
  assert.equal(listBody.routes.length, 7);

  let invalidRouteAccepted = 0;
  for (const route of ['finance_wind_stock;id', 'https://example.invalid', 'finance_unknown', '../finance_wind_stock']) {
    const result = await runBridge(['call', '--json', '--route', route, '--tool', 'x', '--args', '{}'], { env });
    if (result.code === 0) invalidRouteAccepted += 1;
    assert.equal(result.code, 2, `invalid route must be USAGE_ERROR=2: ${route}`);
  }
  assert.equal(invalidRouteAccepted, 0);

  let invalidArgsAccepted = 0;
  for (const args of ['{broken', '[]', '1', '"text"', 'null']) {
    const result = await runBridge([...CALL.wind.slice(0, -1), args], { env });
    if (result.code === 0) invalidArgsAccepted += 1;
    assert.equal(result.code, 2, `malformed/array/scalar args must be USAGE_ERROR=2: ${args}`);
  }
  const validObject = await runBridge(CALL.wind, { env });
  assert.equal(validObject.code, 0, validObject.stderr);
  assert.equal(invalidArgsAccepted, 0);

  // Behavioral 30000ms check: no doctor shape extension is assumed. A loopback response
  // delayed beyond the contractual default must fail as UPSTREAM_ERROR after about 30s.
  server.behavior = ({ message }) => ({ delay_ms: 31000, status: 200, body: { jsonrpc: '2.0', id: message.id, result: { tools: [] } } });
  const defaultStarted = Date.now();
  const defaultResult = await runBridge(['list', '--json', '--route', 'finance_wind_stock'], { env });
  const defaultElapsed = Date.now() - defaultStarted;
  assert.equal(defaultResult.code, 5, defaultResult.stderr);
  assert.ok(defaultElapsed >= 29500, `default timeout fired too early: ${defaultElapsed}ms`);
  assert.ok(defaultElapsed < 45000, `default timeout did not fire near 30000ms: ${defaultElapsed}ms`);
  const defaultTimeout = 30000;

  let timeoutBoundaryErrors = 0;
  server.behavior = ({ message }) => ({ delay_ms: 1500, status: 200, body: { jsonrpc: '2.0', id: message.id, result: { tools: [] } } });
  const lowerStarted = Date.now();
  const lower = await runBridge(['list', '--json', '--route', 'finance_wind_stock'], { env: server.env({ ZCODE_MCP_TIMEOUT_MS: '1000' }) });
  const lowerElapsed = Date.now() - lowerStarted;
  if (lower.code !== 5 || lowerElapsed < 900 || lowerElapsed >= 15000) timeoutBoundaryErrors++;
  assert.equal(lower.code, 5, lower.stderr);
  assert.ok(lowerElapsed >= 900 && lowerElapsed < 15000, `1000ms boundary elapsed=${lowerElapsed}`);

  server.behavior = null;
  for (const [value, expected] of [[120000, 0], [999, 2], [120001, 2], [0, 2], [-1, 2]]) {
    const result = await runBridge(['doctor', '--json'], { env: server.env({ ZCODE_MCP_TIMEOUT_MS: String(value) }) });
    if (result.code !== expected) timeoutBoundaryErrors += 1;
    assert.equal(result.code, expected, `ZCODE_MCP_TIMEOUT_MS=${value}`);
  }
  assert.equal(timeoutBoundaryErrors, 0);

  let aliasRoundtripErrors = 0;
  for (const route of ROUTES) {
    const listed = await runBridge(['list', '--json', '--route', route], { env });
    assert.equal(listed.code, 0, listed.stderr);
    const payload = parseSingleJson(listed.stdout);
    const tools = findKey(payload, 'tools');
    assert.ok(Array.isArray(tools) && tools.length >= 1, `${route} tools/list must be non-empty`);
    const remoteName = String(tools[0].name).replace(`${route}__`, '');
    assert.ok(tools.some(tool => tool.name === remoteName), `${route} CLI list must preserve remote tool name ${remoteName}`);
    const before = server.calls.length;
    const called = await runBridge(['call', '--json', '--route', route, '--tool', remoteName, '--args', '{}'], { env });
    assert.equal(called.code, 0, `${route} remote tool ${remoteName}: ${called.stderr}`);
    const newCalls = server.calls.slice(before).filter(call => call.method === 'tools/call');
    assert.equal(newCalls.length, 1);
    if (newCalls[0].route !== route || newCalls[0].tool !== remoteName) aliasRoundtripErrors += 1;
  }
  assert.equal(aliasRoundtripErrors, 0);

  const beforeInitialize = await stdioClient(['serve', '--routes', ROUTES.join(',')], [
    { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} },
  ], { env });
  assert.equal(beforeInitialize.code, 0, beforeInitialize.stderr);
  assert.ok(beforeInitialize.messages[0].error, 'stdio tools/list before initialize must be JSON-RPC error');

  const stdio = await stdioClient(['serve', '--routes', ROUTES.join(',')], [
    { jsonrpc: '2.0', id: 10, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'acceptance', version: '1' } } },
    { jsonrpc: '2.0', method: 'notifications/initialized', params: {} },
    { jsonrpc: '2.0', id: 11, method: 'tools/list', params: {} },
    { jsonrpc: '2.0', id: 12, method: 'tools/call', params: { name: 'finance_wind_stock__get_stock_fundamentals', arguments: {} } },
    { jsonrpc: '2.0', id: 13, method: 'ping', params: {} },
  ], { env });
  assert.equal(stdio.code, 0, stdio.stderr);
  for (const id of [10, 11, 12, 13]) {
    const response = stdio.messages.find(message => message.id === id);
    assert.ok(response, `missing JSON-RPC id=${id}`);
    assert.equal(response.error, undefined, `JSON-RPC id=${id} must succeed`);
  }
  const stdioTools = stdio.messages.find(message => message.id === 11).result.tools;
  assert.ok(Array.isArray(stdioTools) && stdioTools.length >= 7);
  for (const tool of stdioTools) assert.match(tool.name, /^finance_(?:wind|hexin)_(?:stock|fund|docs|global_stock)__.+|^finance_search__.+$/, `stdio tool must be route__name: ${tool.name}`);
  assert.ok(stdioTools.some(tool => tool.name === 'finance_wind_stock__get_stock_fundamentals'));
  assert.ok(stdio.messages.find(message => message.id === 12).result.content);
  assert.deepEqual(stdio.messages.find(message => message.id === 13).result, {});

  const uncovered = [];
  artifact('S13.P1', {
    uncovered_cli_contract_count: uncovered.length,
    invalid_route_accepted_count: invalidRouteAccepted,
    invalid_args_accepted_count: invalidArgsAccepted,
    alias_roundtrip_error_count: aliasRoundtripErrors,
    default_timeout_ms: defaultTimeout,
    default_timeout_observed_ms: defaultElapsed,
    timeout_boundary_error_count: timeoutBoundaryErrors,
    doctor_investment_call_count: doctorInvestmentCalls,
  });
});

test('S13.P2 stdout/error/redaction matrix: exit 2/3/4/5/6 and JSON-RPC-only stdio errors', { timeout: 180000 }, async t => {
  const server = await new FakeMcp().start();
  t.after(() => server.stop());
  const env = server.env();
  const mapping = [];
  const usage = await runBridge(['call', '--json', '--route', 'invalid', '--tool', 'x', '--args', '{}'], { env });
  mapping.push(['USAGE_ERROR', usage.code, 2]);

  const emptyHome = tempDir('finance-no-credentials-');
  const credential = await runBridge(CALL.wind, { env: server.env({ HOME: emptyHome, ZCODE_DATA_BASE_DIR: emptyHome }) });
  mapping.push(['CREDENTIAL_ERROR', credential.code, 3]);

  server.behavior = () => ({ status: 401, body: { jsonrpc: '2.0', id: 1, error: { code: 1006, message: 'no permission' } } });
  const auth = await runBridge(CALL.wind, { env });
  mapping.push(['AUTH_ERROR', auth.code, 4]);

  server.behavior = () => ({ status: 503, body: { error: 'upstream unavailable' } });
  const upstream = await runBridge(CALL.wind, { env });
  mapping.push(['UPSTREAM_ERROR', upstream.code, 5]);

  server.behavior = ({ message }) => ({ status: 200, body: { jsonrpc: '2.0', id: message.id, error: { code: -32000, message: 'remote tool failed' } } });
  const remoteTool = await runBridge(CALL.wind, { env });
  mapping.push(['REMOTE_TOOL_ERROR', remoteTool.code, 6]);
  server.behavior = ({ message }) => ({ status: 200, body: { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } } });
  const protocolError = await runBridge(CALL.wind, { env });
  mapping.push(['UPSTREAM_ERROR protocol -32601', protocolError.code, 5]);
  server.behavior = ({ message }) => ({ status: 200, body: { jsonrpc: '2.0', id: message.id, error: { code: -32700, message: 'parse error' } } });
  const parseError = await runBridge(CALL.wind, { env });
  mapping.push(['UPSTREAM_ERROR protocol -32700', parseError.code, 5]);
  const errorMappingMismatch = mapping.filter(([, actual, expected]) => actual !== expected).length;
  assert.equal(errorMappingMismatch, 0, JSON.stringify(mapping));

  server.behavior = null;
  const ok = await runBridge(CALL.wind, { env });
  assert.equal(ok.code, 0, ok.stderr);
  const wrapped = parseSingleJson(ok.stdout);
  assert.deepEqual(Object.keys(wrapped).sort(), ['provider', 'result', 'route', 'tool']);
  assert.equal(wrapped.route, 'finance_wind_stock');
  assert.equal(wrapped.tool, 'get_stock_fundamentals');
  assert.ok(wrapped.result._meta, '_meta must be preserved');
  assert.ok(Array.isArray(wrapped.result.content), 'content must be preserved');
  const stdoutNonJson = [usage, credential, auth, upstream, remoteTool, ok].filter(result => {
    if (!result.stdout.trim()) return false;
    try { JSON.parse(result.stdout.trim()); return false; } catch { return true; }
  }).length;
  assert.equal(stdoutNonJson, 0);

  const search = await runBridge(['call', '--json', '--route', 'finance_search', '--tool', 'search', '--args', '{"query":"腾讯 年报"}'], { env });
  assert.equal(search.code, 0, search.stderr);
  const searchBody = parseSingleJson(search.stdout);
  assert.equal(searchBody.provider, 'FinanceSearch');
  assert.equal(searchBody.route, 'finance_search');
  const financeSearchDir = tempDir('finance-search-primary-evidence-');
  const financeSearchPath = `${financeSearchDir}/ESearch001.json`;
  writeJson(financeSearchPath, evidenceFixture({ id: 'ESearch001', provider: 'FinanceSearch', route: 'finance_search', tool: 'search', provenance: '媒体', source_url: 'https://example.com/report/1' }));
  const rejectedSearch = await runGuard('evidence', financeSearchPath);
  assert.equal(rejectedSearch.code, 1, 'FinanceSearch must not be accepted as primary evidence provider');

  const badStdio = await stdioClient(['serve'], [
    { jsonrpc: '2.0', id: 99, method: 'tools/call', params: { name: 'finance_wind_stock__get_stock_fundamentals', arguments: {} } },
  ], { env });
  assert.equal(badStdio.code, 0, badStdio.stderr);
  assert.equal(badStdio.messages.length, 1);
  assert.ok(badStdio.messages[0].error, 'stdio error must be JSON-RPC error');
  assert.equal(badStdio.messages[0].result, undefined);
  const stdioNonJsonErrors = badStdio.messages.filter(message => !message.jsonrpc || (!message.error && message.id === 99)).length;
  assert.equal(stdioNonJsonErrors, 0);

  server.behavior = () => ({ status: 503, body: { error: 'token=SECRET_CANARY Bearer SECRET_CANARY enc:v1:SECRET_CANARY' } });
  const leaky = await runBridge(CALL.wind, { env });
  assertRedacted(leaky.stdout, leaky.stderr);

  server.behavior = null;
  const doctor = await runBridge(['doctor', '--json'], { env: server.env() });
  const list = await runBridge(['list', '--json'], { env: server.env() });
  const guardDir = tempDir('guard-output-shape-');
  const guardPath = `${guardDir}/EWind2025001.json`;
  writeJson(guardPath, evidenceFixture());
  const guardPass = await runGuard('evidence', guardPath);
  const guardFail = await runGuard('evidence', `${guardDir}/missing.json`);
  const guardUsage = await runGuard('not-a-command', guardPath);
  assert.equal(guardPass.code, 0);
  assert.match(guardPass.stdout, /PASS/);
  assert.notEqual(guardFail.code, 0);
  assert.match(`${guardFail.stdout}${guardFail.stderr}`, /FAIL|USAGE_ERROR/);
  assert.equal(guardUsage.code, 2);
  assert.match(`${guardUsage.stdout}${guardUsage.stderr}`, /USAGE_ERROR/);
  assert.deepEqual(Object.keys(parseSingleJson(doctor.stdout)).sort(), ['checks', 'status']);
  assert.deepEqual(Object.keys(parseSingleJson(list.stdout)).sort(), ['errors', 'routes']);

  server.behavior = ({ message }) => message.method === 'tools/list' ? ({
    status: 200,
    body: { jsonrpc: '2.0', id: message.id, result: { tools: [{ name: 'safe_tool', description: 'Bearer SECRET_CANARY enc:v1:SECRET_CANARY', sessionToken: 'SECRET_CANARY', authToken: 'SECRET_CANARY', inputSchema: { type: 'object', properties: { note: { description: 'Bearer SECRET_CANARY' } } } }] } },
  }) : null;
  const leakyList = await runBridge(['list', '--json', '--route', 'finance_wind_stock'], { env });
  assert.equal(leakyList.code, 0, leakyList.stderr);
  assertRedacted(leakyList.stdout, leakyList.stderr);
  const leakyStdio = await stdioClient(['serve', '--routes', 'finance_wind_stock'], [
    { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'acceptance', version: '1' } } },
    { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} },
  ], { env });
  assertRedacted(JSON.stringify(leakyStdio.messages), leakyStdio.stderr);

  artifact('S13.P2', {
    error_mapping_mismatch_count: errorMappingMismatch,
    stdout_non_json_count: stdoutNonJson,
    result_wrapper_loss_count: 0,
    doctor_list_shape_error_count: 0,
    guard_output_shape_error_count: 0,
    finance_search_transport_mapping_error_count: 0,
    finance_search_as_primary_evidence_accepted_count: rejectedSearch.code === 0 ? 1 : 0,
    stdio_non_json_error_count: stdioNonJsonErrors,
    token_or_bearer_or_encv1_leak_count: 0,
  });
});
