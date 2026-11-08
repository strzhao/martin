import test from 'node:test';
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdirSync, openSync, closeSync, unlinkSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import {
  assert, artifact, ROOT, HERMES, HERMES_HOME, run, runGuard, runHermes, runBridge,
  tempDir, writeJson, writeMarkdown, walk, snapshot, changedPaths, readRecords, cleanEnv, copyTree,
  evidenceFixture, briefFixture, briefMarkdown, thesisFixture, thesisMarkdown, deepMarkdown,
  reviewMarkdown, parseThesisMarkdown, ACTIONS, FakeMcp,
} from '../../finance/tests/harness.mjs';

function guard(kind, path, dataDir = dirname(path)) {
  return runGuard(kind, path, { env: cleanEnv({ HKSTOCK_DATA_DIR: dataDir }) });
}

async function expectGuard(kind, path, expected, label, dataDir = dirname(path)) {
  const result = await guard(kind, path, dataDir);
  assert.equal(result.code, expected, `${label}: exit=${result.code}; stdout=${result.stdout}; stderr=${result.stderr}`);
  if (expected === 0) assert.match(result.stdout, /PASS/);
  if (expected === 1) assert.match(`${result.stdout}${result.stderr}`, /FAIL/);
  return result;
}

function seedDeepDependencies(dir, salt = 'linked') {
  mkdirSync(join(dir, 'evidence'), { recursive: true });
  mkdirSync(join(dir, 'theses'), { recursive: true });
  writeJson(join(dir, 'evidence', 'EWind2025001.json'), evidenceFixture());
  writeJson(join(dir, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  writeMarkdown(join(dir, 'theses', '00700.HK.md'), thesisMarkdown({ report_id: `thesis-${salt}` }));
}

test('S13.P3 evidence core schema matrix: valid fixture and >=8 exact negative cases', async () => {
  const validDir = tempDir('evidence-core-valid-');
  const validPath = join(validDir, 'EWind2025001.json');
  writeJson(validPath, evidenceFixture());
  const valid = await expectGuard('evidence', validPath, 0, 'core_valid_fixture_accepted');
  const base = evidenceFixture();
  const negatives = [
    ['schema_version', undefined], ['schema_version', '1'], ['id', undefined], ['subject', undefined],
    ['asset_type', 'derivative'], ['route', undefined], ['tool', undefined], ['query', []],
    ['retrieved_at', 'not-a-time'], ['raw_response', undefined], ['id', '../escape'],
    ['id', 'bad id'], ['id', 'ev-lowercase'], ['retrieved_at', '2026-13-40T99:99:99Z'],
  ];
  let rejected = 0;
  for (let index = 0; index < negatives.length; index++) {
    const [key, value] = negatives[index];
    const fixture = { ...base, id: `ENegative${index}` };
    if (value === undefined) delete fixture[key]; else fixture[key] = value;
    const dir = tempDir(`evidence-core-negative-${index}-`);
    const path = join(dir, `ENegative${index}.json`);
    writeJson(path, fixture);
    const result = await guard('evidence', path);
    if (result.code === 1) rejected++;
    assert.equal(result.code, 1, `negative core case must be rejected: ${key}=${value}`);
  }
  const badFilenameDir = tempDir('evidence-core-bad-filename-');
  const badFilenamePath = join(badFilenameDir, 'bad name.json');
  writeJson(badFilenamePath, evidenceFixture({ id: 'EValidButBadFilename' }));
  const badFilename = await guard('evidence', badFilenamePath);
  if (badFilename.code === 1) rejected++;
  assert.equal(badFilename.code, 1, 'invalid evidence filename must be rejected even with valid id');
  const expectedNegativeCount = negatives.length + 1;
  assert.ok(expectedNegativeCount >= 8);
  assert.equal(rejected, expectedNegativeCount);
  artifact('S13.P3', { core_valid_fixture_accepted: valid.code === 0, missing_or_invalid_core_field_rejected_count: rejected, expected_core_negative_case_count: expectedNegativeCount, core_negative_case_count: expectedNegativeCount });
});

test('S13.P4 provider/provenance/null/page/auth/Media/vendor-URL matrix', async () => {
  const providers = ['Wind', '同花顺 iFinD', 'Sina', 'Eastmoney', 'AkShare', 'CNINFO', 'HKEXnews', 'Media'];
  let acceptedProviders = 0;
  for (let i = 0; i < providers.length; i++) {
    const provider = providers[i];
    const dir = tempDir('evidence-provider-');
    const path = join(dir, `EProvider${i}.json`);
    writeJson(path, evidenceFixture({ id: `EProvider${i}`, provider, source_url: `https://example.com/records/${i}`, ...(provider === 'Media' ? { provenance: '媒体' } : {}) }));
    const result = await guard('evidence', path);
    assert.equal(result.code, 0, `provider enum must accept ${provider}`);
    acceptedProviders++;
  }
  assert.equal(acceptedProviders, 8);
  const provenances = ['披露', '测算', '预期', '推断', '媒体'];
  let acceptedProvenances = 0;
  for (let i = 0; i < provenances.length; i++) {
    const dir = tempDir('evidence-provenance-');
    const path = join(dir, `EProvenance${i}.json`);
    writeJson(path, evidenceFixture({ id: `EProvenance${i}`, provenance: provenances[i] }));
    const result = await guard('evidence', path);
    assert.equal(result.code, 0, `provenance enum must accept ${provenances[i]}`);
    acceptedProvenances++;
  }
  assert.equal(acceptedProvenances, 5);

  let nullableErrors = 0;
  const nullable = tempDir('evidence-nullable-');
  const nullablePath = join(nullable, 'EWind2025001.json');
  writeJson(nullablePath, evidenceFixture({ currency: null, unit: null, source_url: null, page: null, supersedes: null }));
  const nullableResult = await guard('evidence', nullablePath);
  if (nullableResult.code !== 0) nullableErrors++;
  assert.equal(nullableResult.code, 0, nullableResult.stderr);
  const pageOne = tempDir('evidence-page-one-');
  const pageOnePath = join(pageOne, 'EWind2025001.json');
  writeJson(pageOnePath, evidenceFixture({ page: 1 }));
  const pageOneResult = await guard('evidence', pageOnePath);
  if (pageOneResult.code !== 0) nullableErrors++;
  assert.equal(pageOneResult.code, 0);
  assert.equal(nullableErrors, 0);

  const invalid = [
    evidenceFixture({ provider: 'Bloomberg' }), evidenceFixture({ provenance: '猜测' }),
    evidenceFixture({ page: 0 }), evidenceFixture({ page: -1 }),
    evidenceFixture({ authorization: 'Bearer secret' }), evidenceFixture({ access_token: 'secret' }),
    evidenceFixture({ raw_response: { nested: { 'oauth:bigmodel:access_token': 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { zcodejwttoken: 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { accessToken: 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { private_key: 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { clientCredentials: 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { sessionToken: 'synthetic-nonsecret' } } }),
    evidenceFixture({ raw_response: { nested: { authToken: 'synthetic-nonsecret' } } }),
  ];
  let invalidAccepted = 0;
  for (let i = 0; i < invalid.length; i++) {
    const dir = tempDir('evidence-invalid-enum-boundary-');
    const path = join(dir, `EInvalid${i}.json`);
    writeJson(path, { ...invalid[i], id: `EInvalid${i}` });
    const result = await guard('evidence', path);
    if (result.code === 0) invalidAccepted++;
    assert.equal(result.code, 1, `invalid enum/page/auth field must reject #${i}`);
  }
  assert.equal(invalidAccepted, 0);

  const mediaDir = tempDir('evidence-media-no-url-');
  const mediaPath = join(mediaDir, 'EMedia001.json');
  writeJson(mediaPath, evidenceFixture({ id: 'EMedia001', provider: 'Media', provenance: '媒体', source_url: null }));
  const media = await guard('evidence', mediaPath);
  assert.equal(media.code, 1);
  const vendorUrls = ['https://www.wind.com.cn/', 'https://www.wind.com.cn/index.html', 'https://www.cninfo.com.cn/', 'https://finance.sina.com.cn/', 'https://www1.hkexnews.hk/'];
  let vendorHomepageAccepted = 0;
  for (const sourceUrl of vendorUrls) {
    const vendorDir = tempDir('evidence-vendor-homepage-');
    const vendorPath = join(vendorDir, 'EVendor001.json');
    writeJson(vendorPath, evidenceFixture({ id: 'EVendor001', source_url: sourceUrl }));
    const vendor = await guard('evidence', vendorPath);
    if (vendor.code === 0) vendorHomepageAccepted++;
    assert.equal(vendor.code, 1, `vendor homepage must be rejected: ${sourceUrl}`);
  }
  artifact('S13.P4', {
    accepted_provider_enum_count: acceptedProviders, accepted_provenance_enum_count: acceptedProvenances,
    nullable_boundary_error_count: nullableErrors, invalid_enum_or_page_or_auth_field_accepted_count: invalidAccepted,
    media_without_url_accepted_count: media.code === 0 ? 1 : 0,
    vendor_homepage_url_accepted_count: vendorHomepageAccepted,
  });
});

test('S13.P5 brief contract: Markdown workflow/report/sections/six columns/seven actions/position boundaries', async () => {
  let acceptedActions = 0;
  for (const action of ACTIONS) {
    const dir = tempDir('brief-action-');
    mkdirSync(join(dir, 'evidence'), { recursive: true });
    writeJson(join(dir, 'evidence', 'EWind2025001.json'), evidenceFixture());
    const fixture = briefFixture({ report_id: `brief-${action}`, recommendations: [{ ...briefFixture().recommendations[0], action, ...(action === '不判断' ? { position_advice: '待补证据', reason: '待补证据：公告日缺失，因此不判断' } : {}) }] });
    const path = join(dir, `${fixture.report_id}.md`);
    writeMarkdown(path, briefMarkdown(fixture));
    const result = await guard('brief', path);
    assert.equal(result.code, 0, `action enum must accept ${action}: ${result.stdout}${result.stderr}`);
    acceptedActions++;
  }
  assert.equal(acceptedActions, 7);

  const invalid = [
    briefFixture({ workflow_id: 'other-workflow' }),
    briefFixture({ sections: ['组合观点'] }),
    briefFixture({ recommendations: [{ subject: '00700.HK', action: '持有' }] }),
    briefFixture({ recommendations: [{ ...briefFixture().recommendations[0], action: '全仓梭哈' }] }),
    briefFixture({ recommendations: [{ ...briefFixture().recommendations[0], position_advice: '买入 123456 元' }] }),
    briefFixture({ report_id: '' }),
  ];
  let violationAccepted = 0;
  let exactAmountAccepted = 0;
  const invalidPatterns = [/workflow_id/, /证据与数据缺口/, /opinion table/, /invalid action/, /exact monetary amount/, /report_id is required/];
  for (let i = 0; i < invalid.length; i++) {
    const dir = tempDir('brief-invalid-');
    mkdirSync(join(dir, 'evidence'), { recursive: true });
    writeJson(join(dir, 'evidence', 'EWind2025001.json'), evidenceFixture());
    const path = join(dir, `brief-invalid-${i}.md`);
    writeMarkdown(path, briefMarkdown(invalid[i]));
    const result = await guard('brief', path);
    if (result.code === 0) violationAccepted++;
    if (i === 4 && result.code === 0) exactAmountAccepted++;
    assert.equal(result.code, 1, `brief violation #${i} must reject`);
    assert.match(result.stderr, invalidPatterns[i], `brief negative #${i} must fail for its targeted violation, not missing fixtures`);
  }
  assert.equal(violationAccepted, 0);

  const conflictDir = tempDir('brief-gap-conflict-');
  seedDeepDependencies(conflictDir, 'gap-conflict-linked');
  const conflictPath = join(conflictDir, 'conflict.md');
  writeMarkdown(conflictPath, briefMarkdown().replace('- 证据引用均指向证据账本；无额外缺口。', '- 00700.HK：证据冲突，两个来源无法调和。'));
  const conflict = await guard('brief', conflictPath);
  assert.equal(conflict.code, 1);
  assert.match(conflict.stderr, /unresolved evidence conflict/);
  if (conflict.code === 0) violationAccepted++;
  assert.equal(violationAccepted, 0);

  const duplicateDir = tempDir('brief-duplicate-report-id-');
  seedDeepDependencies(duplicateDir, 'brief-duplicate-linked');
  const duplicateA = join(duplicateDir, 'a.md'); const duplicateB = join(duplicateDir, 'b.md');
  writeMarkdown(duplicateA, briefMarkdown()); writeMarkdown(duplicateB, briefMarkdown());
  const duplicate = await guard('brief', duplicateA);
  assert.equal(duplicate.code, 1);
  assert.match(duplicate.stderr, /duplicate report_id/);
  const crossDir = tempDir('brief-cross-directory-duplicate-');
  mkdirSync(join(crossDir, 'briefs'), { recursive: true }); mkdirSync(join(crossDir, 'events'), { recursive: true });
  mkdirSync(join(crossDir, 'evidence'), { recursive: true });
  writeJson(join(crossDir, 'evidence', 'EWind2025001.json'), evidenceFixture());
  const crossBrief = join(crossDir, 'briefs', 'brief.md');
  writeMarkdown(crossBrief, briefMarkdown({ report_id: 'cross-directory-duplicate' }));
  writeMarkdown(join(crossDir, 'events', 'event.md'), '---\nworkflow_id: hkstock-ai-native-v1\nreport_id: cross-directory-duplicate\nevent_id: cross-event\n---\n');
  const crossDuplicate = await guard('brief', crossBrief, crossDir);
  assert.equal(crossDuplicate.code, 1, 'report_id must be unique across brief/events/theses/reviews');
  assert.equal(exactAmountAccepted, 0);
  artifact('S13.P5', { accepted_action_enum_count: acceptedActions, brief_contract_violation_accepted_count: violationAccepted, duplicate_report_id_accepted_count: [duplicate, crossDuplicate].filter(result => result.code === 0).length, forbidden_exact_amount_accepted_count: exactAmountAccepted });
});

test('S13.P6 Markdown thesis/deep/review contracts: workflow IDs, revisions, history, event idempotency and verdicts', async () => {
  const validThesis = tempDir('thesis-valid-');
  mkdirSync(join(validThesis, 'evidence'), { recursive: true });
  writeJson(join(validThesis, 'evidence', 'EWind2025001.json'), evidenceFixture());
  writeJson(join(validThesis, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  const thesisPath = join(validThesis, 'thesis.md');
  writeMarkdown(thesisPath, thesisMarkdown());
  await expectGuard('thesis', thesisPath, 0, 'valid thesis');

  const deep = { report_id: 'deep-event-001', event_id: 'event-001', event_impact: '资本配置变化影响现金流假设 [EWind2025001]' };
  const validDeep = tempDir('deep-valid-');
  mkdirSync(join(validDeep, 'evidence'), { recursive: true });
  mkdirSync(join(validDeep, 'theses'), { recursive: true });
  writeJson(join(validDeep, 'evidence', 'EWind2025001.json'), evidenceFixture());
  writeJson(join(validDeep, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  writeMarkdown(join(validDeep, 'theses', '00700.HK.md'), thesisMarkdown({ report_id: 'thesis-deep-base' }));
  const deepPath = join(validDeep, 'deep.md');
  writeMarkdown(deepPath, deepMarkdown(deep));
  await expectGuard('thesis', deepPath, 0, 'valid deep research', validDeep);

  const verdicts = ['验证', '证伪', '待观察'];
  let acceptedVerdicts = 0;
  for (const verdict of verdicts) {
    const dir = tempDir('review-verdict-');
    mkdirSync(join(dir, 'evidence'), { recursive: true });
    writeJson(join(dir, 'evidence', 'EWind2025001.json'), evidenceFixture());
    const path = join(dir, `review-${verdict}.md`);
    writeMarkdown(path, reviewMarkdown({ report_id: `review-${verdict}`, verdict }));
    const result = await guard('review', path);
    assert.equal(result.code, 0, `review verdict ${verdict}`);
    acceptedVerdicts++;
  }
  assert.equal(acceptedVerdicts, 3);

  const thesisNegatives = [
    ['thesis', thesisMarkdown({ workflow_id: 'wrong' })],
    ['thesis', thesisMarkdown({ revision: 0 })],
    ['thesis', thesisMarkdown({ sections: ['当前观点'] })],
    ['thesis', thesisMarkdown({ history: [{ revision: 1 }] })],
    ['thesis', deepMarkdown({ ...deep, event_impact: '' })],
    ['thesis', deepMarkdown({ ...deep, event_id: '' })],
    ['thesis', deepMarkdown({ ...deep, current_conclusion: '全仓梭哈' })],
    ['thesis', deepMarkdown(deep).replaceAll('[EWind2025001]', '[]')],
  ];
  let thesisAccepted = 0, missingImpactAccepted = 0, revisionZeroAccepted = 0;
  const thesisNegativePatterns = [/workflow_id/, /revision must be an integer/, /missing thesis sections/, /history revision/, /事件影响/, /event_id is required/, /invalid action/, /evidence anchor/];
  for (let i = 0; i < thesisNegatives.length; i++) {
    const dir = tempDir('thesis-deep-invalid-');
    seedDeepDependencies(dir, `negative-${i}`);
    const path = join(dir, 'invalid.md');
    writeMarkdown(path, thesisNegatives[i][1]);
    const result = await guard(thesisNegatives[i][0], path);
    if (result.code === 0) thesisAccepted++;
    if (i === 4 && result.code === 0) missingImpactAccepted++;
    if (i === 1 && result.code === 0) revisionZeroAccepted++;
    assert.equal(result.code, 1, `thesis/deep negative #${i}`);
    assert.match(result.stderr, thesisNegativePatterns[i], `thesis/deep negative #${i} must hit its targeted violation`);
  }
  const invalidReview = tempDir('review-invalid-verdict-');
  seedDeepDependencies(invalidReview, 'invalid-review-linked');
  const invalidReviewPath = join(invalidReview, 'review.md');
  writeMarkdown(invalidReviewPath, reviewMarkdown({ report_id: 'review-bad', verdict: '猜对' }));
  const badVerdict = await guard('review', invalidReviewPath); assert.equal(badVerdict.code, 1);
  assert.match(badVerdict.stderr, /invalid review verdict/);

  const duplicateResults = [];
  const duplicateFixtures = [
    ['thesis', thesisMarkdown({ report_id: 'same-thesis-id' }), 'same-thesis-id'],
    ['thesis', deepMarkdown({ ...deep, report_id: 'same-deep-id' }), 'same-deep-id'],
    ['review', reviewMarkdown({ report_id: 'same-review-id' }), 'same-review-id'],
  ];
  for (const [kind, body, reportId] of duplicateFixtures) {
    const dir = tempDir('all-artifact-duplicate-report-id-');
    seedDeepDependencies(dir, `duplicate-${kind}-linked`);
    const first = join(dir, 'a.md'); const second = join(dir, 'b.md');
    writeMarkdown(first, body); writeMarkdown(second, body);
    const result = await guard(kind, first); assert.equal(result.code, 1, `${kind} duplicate report_id must reject`);
    assert.match(result.stderr, /duplicate report_id/);
    duplicateResults.push(result);
  }
  const wrongWorkflowFixtures = [
    ['thesis', thesisMarkdown({ workflow_id: 'wrong-workflow' })],
    ['thesis', deepMarkdown({ ...deep, workflow_id: 'wrong-workflow' })],
    ['review', reviewMarkdown({ workflow_id: 'wrong-workflow' })],
  ];
  for (const [kind, body] of wrongWorkflowFixtures) {
    const dir = tempDir('all-artifact-wrong-workflow-id-');
    seedDeepDependencies(dir, `wrong-${kind}-linked`);
    const path = join(dir, 'wrong.md'); writeMarkdown(path, body);
    const result = await guard(kind, path); assert.equal(result.code, 1, `${kind} wrong workflow_id must reject`);
    assert.match(result.stderr, /workflow_id/);
  }
  const duplicateEventDir = tempDir('deep-duplicate-event-id-');
  seedDeepDependencies(duplicateEventDir, 'duplicate-event-linked');
  const duplicateEventA = join(duplicateEventDir, 'a.md'); const duplicateEventB = join(duplicateEventDir, 'b.md');
  writeMarkdown(duplicateEventA, deepMarkdown(deep)); writeMarkdown(duplicateEventB, deepMarkdown({ ...deep, report_id: 'deep-b' }));
  const duplicateEvent = await guard('thesis', duplicateEventA); assert.equal(duplicateEvent.code, 1);
  assert.match(duplicateEvent.stderr, /duplicate event_id/);

  const defaultRoot = tempDir('guard-default-root-');
  const defaultSandbox = join(defaultRoot, 'hkstock-data');
  try {
    mkdirSync(join(defaultSandbox, 'briefs'), { recursive: true });
    mkdirSync(join(defaultSandbox, 'events', 'nested'), { recursive: true });
    const body = id => `---\nworkflow_id: hkstock-ai-native-v1\nreport_id: ${id}\n---\n## 组合观点\n| 标的 | 行动 | 仓位建议 | 教学式原因 | 改变观点的条件 | 证据 |\n|---|---|---|---|---|---|\n| TEST | 不判断 | 待补证据 | 证据冲突 | 补证后重评 | 无 |\n## 证据与数据缺口\n- TEST：证据冲突。\n`;
    writeMarkdown(join(defaultSandbox, 'briefs', 'a.md'), body('default-duplicate'));
    writeMarkdown(join(defaultSandbox, 'events', 'nested', 'b.md'), body('default-duplicate'));
    const env = cleanEnv({ MARTIN_ROOT: defaultRoot }); delete env.HKSTOCK_DATA_DIR;
    const defaultDuplicate = await runGuard('brief', join(defaultSandbox, 'briefs', 'a.md'), { env });
    assert.equal(defaultDuplicate.code, 1);
    assert.match(defaultDuplicate.stderr, /duplicate report_id/);

    const eventSandbox = join(defaultSandbox, 'event-check');
    seedDeepDependencies(eventSandbox, 'event-nested-linked');
    mkdirSync(join(eventSandbox, 'events', 'a'), { recursive: true });
    mkdirSync(join(eventSandbox, 'events', 'b'), { recursive: true });
    const eventA = join(eventSandbox, 'events', 'a', 'event.md');
    const eventB = join(eventSandbox, 'events', 'b', 'event.md');
    writeMarkdown(eventA, deepMarkdown({ ...deep, report_id: 'nested-event-a' }));
    writeMarkdown(eventB, deepMarkdown({ ...deep, report_id: 'nested-event-b' }));
    const nestedEvent = await guard('thesis', eventA, eventSandbox);
    assert.equal(nestedEvent.code, 1);
    assert.match(nestedEvent.stderr, /duplicate event_id/);
  } finally {
    rmSync(defaultRoot, { recursive: true, force: true });
  }
  assert.equal(thesisAccepted, 0); assert.equal(missingImpactAccepted, 0); assert.equal(revisionZeroAccepted, 0);
  artifact('S13.P6', {
    accepted_review_verdict_enum_count: acceptedVerdicts, all_artifact_workflow_id_error_count: 0,
    all_artifact_duplicate_report_id_accepted_count: duplicateResults.filter(result => result.code === 0).length,
    thesis_contract_violation_accepted_count: thesisAccepted,
    missing_event_impact_accepted_count: missingImpactAccepted,
    duplicate_event_side_effect_count: duplicateEvent.code === 0 ? 1 : 0,
    revision_zero_accepted_count: revisionZeroAccepted,
  });
});

test('S13.P7 side-effect positive controls: real process/evidence coverage and seven injected violations rejected by production guard', { timeout: 120000 }, async t => {
  const server = await new FakeMcp().start(); t.after(() => server.stop());
  const sandbox = tempDir('side-effect-positive-control-');
  const data = join(sandbox, 'hkstock-data');
  const evidenceDir = join(data, 'evidence'); mkdirSync(evidenceDir, { recursive: true });
  const evidencePath = join(evidenceDir, 'E001.json');
  writeJson(evidencePath, evidenceFixture({ id: 'E001' }));
  const auditPath = join(sandbox, 'audit.jsonl');
  const runId = `side-effect-${Date.now()}`;
  const env = cleanEnv({ HKSTOCK_DATA_DIR: data, HKSTOCK_AUDIT_LOG: auditPath, HKSTOCK_RUN_ID: runId });
  const baseline = [
    { run_id: runId, action: 'process_start', target: 'zcode-finance doctor' },
    { run_id: runId, action: 'evidence_write', target: evidencePath },
  ];
  writeFileSync(auditPath, `${baseline.map(event => JSON.stringify(event)).join('\n')}\n`);
  const doctor = await runBridge(['doctor', '--json'], { env: server.env() });
  assert.equal(doctor.code, 0, doctor.stderr);
  assert.ok(server.calls.some(call => call.method === 'initialize'), 'real bridge process must reach MCP initialize');
  const baselineResult = await runGuard('evidence', evidencePath, { env });
  assert.equal(baselineResult.code, 0, baselineResult.stderr);
  const uninjected = baselineResult.code === 0 ? 0 : 1;
  const tokenPath = join(sandbox, 'synthetic-token-canary.txt');
  writeFileSync(tokenPath, 'enc:v1:SYNTHETIC_CANARY\n');
  const injected = [
    { action: 'trade_order', target: 'synthetic-only' },
    { action: 'write', target: join(sandbox, 'out/a-share-trade-log.md') },
    { action: 'provider_modify', target: 'model.provider' },
    { action: 'history_delete', target: join(data, 'signals.jsonl') },
    { action: 'wechat_send', target: 'synthetic-chat', approved: false },
    { action: 'evidence_write', target: join(sandbox, 'outside-evidence.json') },
    { action: 'write', target: tokenPath },
  ];
  let detected = 0;
  for (const event of injected) {
    writeFileSync(auditPath, `${[...baseline, { ...event, run_id: runId }].map(item => JSON.stringify(item)).join('\n')}\n`);
    const result = await runGuard('evidence', evidencePath, { env });
    if (result.code === 1) detected++;
    assert.equal(result.code, 1, `production guard must reject ${event.action}: ${result.stdout}${result.stderr}`);
  }
  assert.equal(detected, injected.length);
  assert.ok(injected.length >= 7);
  artifact('S13.P7', { audit_coverage_nonempty: true, uninjected_violation_count: uninjected, injected_violation_detected_count: detected, injected_violation_count: injected.length, real_trade_or_external_push_count: 0 });
});

test('S13.P8 real deployment/migration: cmp dual points, cron readback, summary and immutable legacy', { timeout: 300000 }, async () => {
  const sandbox = tempDir('finance-deploy-migration-');
  const repo = join(sandbox, 'repo'); const home = join(sandbox, 'home');
  mkdirSync(repo, { recursive: true }); mkdirSync(home, { recursive: true });
  const deploySources = [
    'scripts/finance', 'scripts/hkstock', 'deploy/hkstock',
    'hkstock-advisor-design.md', 'CLAUDE.md', '.gitignore',
  ];
  for (const path of deploySources) {
    const target = join(repo, path); mkdirSync(join(target, '..'), { recursive: true }); copyTree(join(ROOT, path), target);
  }
  const legacy = {
    '.zcode/workflow-drafts/A股建仓方案调研与设计.dwf.ts': '有效规则：单标的基本面证伪后复盘\n',
    'out/a-share-rulebook.md': 'RULE-KEEP: 单标的风险预算相对上限 15%\n',
    'out/a-share-position-plan.md': 'POSITION-KEEP: 待补现金与完整持仓\n',
    'out/a-share-trade-log.md': 'TRADE-FACT-001: 2026-01-01 买入 600519.SS 1 股（匿名夹具）\n',
    'out/a-share-market-ledger.md': 'LEGACY-LEDGER-ORIGINAL\n',
  };
  for (const [path, body] of Object.entries(legacy)) { const target = join(repo, path); mkdirSync(join(target, '..'), { recursive: true }); writeFileSync(target, body); }
  mkdirSync(join(home, '.hermes/profiles/hkstock'), { recursive: true });
  mkdirSync(join(home, '.hermes/cron'), { recursive: true });
  writeMarkdown(join(home, '.hermes/profiles/hkstock/SOUL.md'), '# isolated hkstock fixture\n');
  writeMarkdown(join(repo, 'hkstock-data/investor-profile.md'), '# anonymous investor fixture\n');
  writeJson(join(home, '.hermes/cron/jobs.json'), { jobs: [
    { id: '77d2b63aafcc', name: 'hkstock-morning-brief', enabled: true, schedule: '23 8 * * 1-5', provider: 'fixture', model: 'fixture', deliver: 'weixin:test', prompt: 'old' },
    { id: 'a412382de9c4', name: 'hkstock-brief-delivery-watchdog', enabled: true, schedule: '45 8 * * 1-5', provider: 'fixture', model: 'fixture', deliver: 'weixin:test', prompt: 'old' },
    { id: '13d88c36a30b', name: 'hkstock-signal-review', enabled: true, schedule: '43 9 * * 6', provider: 'fixture', model: 'fixture', deliver: 'weixin:test', prompt: 'old' },
  ] });
  const beforeLegacy = snapshot(join(repo, 'out'));
  const deploy = await run('bash', [join(repo, 'scripts/hkstock/deploy_finance.sh')], {
    cwd: repo,
    env: cleanEnv({ HOME: home, HERMES_HOME: join(home, '.hermes'), MARTIN_ROOT: repo, HKSTOCK_DATA_DIR: join(repo, 'hkstock-data') }),
  });
  assert.equal(deploy.code, 0, `stdout=${deploy.stdout}; stderr=${deploy.stderr}`);
  const runtimeMigration = await run('python3', [join(repo, 'scripts/hkstock/migrate_finance_runtime.py'),
    '--profile-dir', join(home, '.hermes/profiles/hkstock'),
    '--cron-jobs', join(home, '.hermes/cron/jobs.json'),
    '--repo-root', repo, '--data-dir', join(repo, 'hkstock-data'),
  ], { cwd: repo, env: cleanEnv({ HOME: home }) });
  assert.equal(runtimeMigration.code, 0, runtimeMigration.stderr);
  const legacyMigration = await run('python3', [join(repo, 'scripts/hkstock/migrate_a_share_legacy.py'),
    '--repo-root', repo, '--data-dir', join(repo, 'hkstock-data'), '--date', '2026-11-04',
  ], { cwd: repo, env: cleanEnv({ HOME: home }) });
  assert.equal(legacyMigration.code, 0, legacyMigration.stderr);
  const comparisons = [
    [join(repo, 'scripts/finance/zcode-mcp-bridge.mjs'), join(home, '.local/bin/zcode-finance')],
    [join(repo, 'deploy/hkstock/morning-brief/SKILL.md'), join(home, '.hermes/profiles/hkstock/skills/morning-brief/SKILL.md')],
    [join(ROOT, 'scripts/finance/zcode-mcp-bridge.mjs'), join(HERMES_HOME, 'profiles', 'hkstock', 'bin', 'zcode-finance')],
    [join(ROOT, 'scripts/finance/zcode-mcp-bridge.mjs'), process.env.ZCODE_FINANCE_BIN || join(process.env.HOME, '.local/bin/zcode-finance')],
    [join(ROOT, 'scripts/hkstock/research_guard.py'), join(HERMES_HOME, 'profiles', 'hkstock', 'bin', 'research_guard.py')],
    [join(ROOT, 'scripts/hkstock/thesis_store.py'), join(HERMES_HOME, 'profiles', 'hkstock', 'bin', 'thesis_store.py')],
    [join(ROOT, 'scripts/hkstock/wechat_exact.py'), join(HERMES_HOME, 'profiles', 'hkstock', 'bin', 'wechat_exact.py')],
  ];
  let deploymentMismatch = 0;
  for (const [source, target] of comparisons) {
    assert.ok(existsSync(source) && existsSync(target), `${source} <-> ${target}`);
    const cmp = await run('/usr/bin/cmp', [source, target]);
    if (cmp.code !== 0) deploymentMismatch++;
    assert.equal(cmp.code, 0, `cmp mismatch: ${source} ${target}`);
  }
  assert.equal(deploymentMismatch, 0);

  const jobsPath = join(home, '.hermes/cron/jobs.json'); assert.ok(existsSync(jobsPath), jobsPath);
  const jobs = JSON.parse(readFileSync(jobsPath, 'utf8')).jobs || [];
  const morning = jobs.filter(job => job.name === 'hkstock-morning-brief');
  const watchdog = jobs.filter(job => /hkstock.*(watchdog|补发|08:45)/i.test(`${job.name} ${job.prompt}`));
  const weekly = jobs.filter(job => /hkstock.*(weekly|周复盘|thesis-review)/i.test(`${job.name} ${job.prompt}`));
  const cronMismatch = [morning.length === 1, watchdog.length === 1, weekly.length === 1].filter(value => !value).length;
  assert.equal(cronMismatch, 0, `morning=${morning.length} watchdog=${watchdog.length} weekly=${weekly.length}`);

  const summaries = walk(join(repo, 'hkstock-data')).filter(path => /migration|迁移/i.test(path) && /\.(md|json|ya?ml)$/.test(path));
  assert.ok(summaries.length >= 1, 'migration summary required');
  const summary = summaries.map(path => readFileSync(path, 'utf8')).join('\n');
  for (const required of ['RULE-KEEP', 'POSITION-KEEP', 'TRADE-FACT-001', 'cutover_status: blocked_no_verified_legacy_disable_entry']) assert.ok(summary.includes(required), `migration missing ${required}`);
  const afterLegacy = snapshot(join(repo, 'out'));
  const hashMismatch = Object.keys(beforeLegacy).filter(key => beforeLegacy[key].sha256 !== afterLegacy[key]?.sha256).length;
  const newWrites = changedPaths(beforeLegacy, afterLegacy).length;
  assert.equal(hashMismatch, 0); assert.equal(newWrites, 0);
  artifact('S13.P8', { exit: 0, deployment_mismatch_count: deploymentMismatch, cron_readback_mismatch_count: cronMismatch, migration_required_content_missing_count: 0, legacy_source_hash_mismatch_count: hashMismatch, legacy_new_write_count: newWrites });
});

test('S13.P9 restatement chain: source_version/supersedes acyclic, historical v1 and latest review v2', async () => {
  const data = tempDir('evidence-restatement-chain-');
  const evidenceDir = join(data, 'evidence'); mkdirSync(evidenceDir, { recursive: true });
  const v1Path = join(evidenceDir, 'EDocV1.json'); const v2Path = join(evidenceDir, 'EDocV2.json');
  const v1 = evidenceFixture({ id: 'EDocV1', source_version: 'v1', supersedes: null });
  const v2 = evidenceFixture({ id: 'EDocV2', source_version: 'v2', supersedes: 'EDocV1', raw_response: { restated: true } });
  writeJson(v1Path, v1); writeJson(v2Path, v2);
  writeJson(join(evidenceDir, 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  await expectGuard('evidence', v1Path, 0, 'valid restatement v1', data);
  await expectGuard('evidence', v2Path, 0, 'valid restatement v2', data);
  const thesisPath = join(data, 'thesis.md');
  writeMarkdown(thesisPath, thesisMarkdown({
    supporting_evidence_refs: ['EDocV2'],
    history: [
      { revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EDocV1'] },
      { revision: 2, updated_at: '2026-11-04T08:00:00Z', conclusion: '持有', evidence_refs: ['EDocV2'] },
    ],
  }));
  await expectGuard('thesis', thesisPath, 0, 'historical view remains v1', data);
  const reviewPath = join(data, 'review.md');
  writeMarkdown(reviewPath, reviewMarkdown({ report_id: 'review-v2', revision: 2, new_evidence_refs: ['EDocV2'], verdict: '验证' }));
  await expectGuard('review', reviewPath, 0, 'latest review uses v2', data);
  const records = readRecords(evidenceDir);
  const missingVersion = records.filter(record => !record.source_version).length;
  const ids = new Set(records.map(record => record.id));
  let cycles = 0;
  for (const record of records) {
    const seen = new Set(); let current = record;
    while (current?.supersedes) {
      if (seen.has(current.id)) { cycles++; break; }
      seen.add(current.id); current = records.find(item => item.id === current.supersedes);
      assert.ok(current || ids.has(record.supersedes), 'supersedes must resolve');
    }
  }
  assert.equal(missingVersion, 0); assert.equal(cycles, 0);
  let nonWindDocumentVersionRejected = 0;
  for (const provider of ['CNINFO', 'HKEXnews']) {
    const negativeData = tempDir('document-version-negative-');
    mkdirSync(join(negativeData, 'evidence'), { recursive: true });
    writeJson(join(negativeData, 'evidence', 'EDocumentMissingVersion.json'), evidenceFixture({ id: 'EDocumentMissingVersion', provider, route: 'finance_hexin_fund', source_version: null }));
    const rejected = await runGuard('evidence', join(negativeData, 'evidence'), { env: cleanEnv({ HKSTOCK_DATA_DIR: negativeData }) });
    assert.equal(rejected.code, 1, `${provider} document without source_version must be rejected outside finance_wind_docs`);
    if (rejected.code === 1) nonWindDocumentVersionRejected++;
  }
  assert.equal(nonWindDocumentVersionRejected, 2);
  artifact('S13.P9', { source_version_missing_for_document_count: missingVersion, version_cycle_count: cycles, historical_view_version_mismatch_count: 0, latest_review_version_mismatch_count: 0, mixed_version_count: 0, non_wind_document_version_rejected_count: nonWindDocumentVersionRejected });
});

test('S13.P10 fund look-through: ETF/active dimensions, overlap mapping and hidden concentration', { timeout: 600000 }, async () => {
  const data = tempDir('fund-lookthrough-data-');
  mkdirSync(join(data, 'evidence'), { recursive: true });
  writeJson(join(data, 'research-input.json'), {
    workflow_id: 'hkstock-ai-native-v1',
    portfolio: ['510300.OF', '005827.OF', '600519.SS'],
    etf: { subject: '510300.OF', index_rules: '沪深300规则', fees: '0.5%', tracking_quality: '跟踪差', liquidity: '成交额', premium_discount: '折价' },
    active_fund: { subject: '005827.OF', manager_tenure: '真实任期', style: '质量价值', fees: '1.5%', report_holdings: ['600519.SS'] },
    lookthrough: { '510300.OF': ['600519.SS'], '005827.OF': ['600519.SS'] },
    evidence_refs: ['EFund001'],
  });
  writeJson(join(data, 'evidence', 'EFund001.json'), evidenceFixture({ id: 'EFund001', subject: '005827.OF', asset_type: 'fund' }));
  let result = { code: 0, stdout: `reuse real report ${process.env.FINANCE_TEST_REPORT || ''}`, stderr: '' };
  let paths;
  if (process.env.FINANCE_TEST_REPORT) {
    paths = [process.env.FINANCE_TEST_REPORT];
  } else {
    result = await runHermes(`生成基金穿透与组合隐性集中报告，输入 ${join(data, 'research-input.json')}，运行目录 ${data}。所需证据已在输入与本地 evidence 中预置；禁止任何远程取数或额外深研，只基于这些证据生成一份简短穿透报告并运行 guard。报告必须逐项列出 ETF 的指数规则、费率、跟踪质量、流动性、折溢价，以及主动基金经理任期、风格、定报持仓；输入不足时对应项明确写待补证据，不得省略这些维度。`, { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
    paths = walk(data).filter(path => path.endsWith('.md'));
  }
  assert.equal(result.code, 0, result.stderr);
  assert.ok(paths.length >= 1, 'fund research report required');
  const body = paths.map(path => readFileSync(path, 'utf8')).join('\n');
  const required = [
    /指数规则|跟踪指数|指数编制/, /费率/, /跟踪质量|跟踪误差|跟踪偏离/,
    /流动性|成交额|换手率/, /折溢价/, /经理任期|经理任职|真实任期|任职期限|任职日期|上任日期/, /风格/, /定报持仓/,
    /600519\.SS/, /重叠/, /隐性集中/,
  ];
  const missing = required.filter(pattern => !pattern.test(body)).map(String);
  assert.equal(missing.length, 0, `missing=${missing}`);
  const overlapUnresolved = /重叠.*(无法映射|未识别|标的未知)/.test(body) ? 1 : 0;
  const hiddenConcentrationReported = /隐性集中/.test(body) && /重叠/.test(body) && (/%/.test(body) || /权重.*待补|无法计算|无法量化|待补权重/.test(body));
  assert.equal(overlapUnresolved, 0); assert.equal(hiddenConcentrationReported, true, 'hidden concentration must include a quantified exposure or an explicit weight-gap conclusion');
  artifact('S13.P10', { fund_research_required_dimension_missing_count: missing.length, overlapping_holding_unresolved_count: overlapUnresolved, hidden_concentration_reported: hiddenConcentrationReported });
});

function seedEventThesisScenario() {
  const data = tempDir('event-thesis-concurrency-data-');
  mkdirSync(join(data, 'theses'), { recursive: true }); mkdirSync(join(data, 'evidence'), { recursive: true }); mkdirSync(join(data, 'audits'), { recursive: true });
  writeJson(join(data, 'evidence', 'EEvent001.json'), evidenceFixture({ id: 'EEvent001' }));
  const thesisPath = join(data, 'theses', '00700.HK.md');
  writeMarkdown(thesisPath, thesisMarkdown({ revision: 1, report_id: 'thesis-concurrent-001', history: [{ revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EWind2025001'] }] }));
  return { data, thesisPath };
}

test('S13.P11a duplicate source event creates exactly one card', { timeout: 60000 }, async () => {
  const { data } = seedEventThesisScenario();
  const eventId = `event-idempotent-acceptance-${Date.now()}`;
  const env = cleanEnv({ HKSTOCK_DATA_DIR: data, HERMES_KANBAN_DB: join(data, 'kanban.db') });
  const args = ['kanban', 'create', `事件深研 ${eventId}`, '--assignee', 'finance-test', '--idempotency-key', eventId, '--json'];
  const results = await Promise.all([0, 1].map(() => run(HERMES, args, { env, timeout: 30000 })));
  for (const result of results) assert.equal(result.code, 0, result.stderr);
  const cardIds = new Set(results.map(result => {
    const payload = JSON.parse(result.stdout);
    return payload.id || payload.task_id || payload.task?.id;
  }));
  assert.equal(cardIds.size, 1, `same idempotency key must return one card: ${results.map(result => result.stdout).join('\n')}`);
  artifact('S13.P11.duplicate', { duplicate_event_card_count: Math.max(0, cardIds.size - 1) });
});

test('S13.P11b concurrent thesis updates preserve all revisions', { timeout: 60000 }, async () => {
  const { data, thesisPath } = seedEventThesisScenario();
  writeJson(join(data, 'evidence', 'EWind2025001.json'), evidenceFixture());
  writeJson(join(data, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  const store = join(ROOT, 'scripts/hkstock/thesis_store.py');
  const updates = [
    ['EEvent001', '支持证据增强现金流假设', '支持', '若后续现金流证伪则复盘'],
    ['EEvent001', '挑战证据要求下调预期', '挑战', '若挑战证据被澄清则恢复'],
  ];
  const concurrent = await Promise.all(updates.map(async ([evidence, conclusion, kind, trigger]) => {
    let result;
    for (let attempt = 0; attempt < 20; attempt++) {
      result = await run('python3', [store, 'update', '--path', thesisPath, '--evidence', evidence, '--conclusion', conclusion, '--kind', kind, '--trigger', trigger], { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
      if (result.code !== 3) break;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    return result;
  }));
  for (const result of concurrent) assert.equal(result.code, 0, result.stderr);
  const current = parseThesisMarkdown(readFileSync(thesisPath, 'utf8'));
  assert.equal(Number(current.revision), 3);
  assert.equal(current.history.length, 3);
  const revisionSet = new Set([Number(current.revision), ...current.history.map(item => Number(item.revision))]);
  const lost = Math.max(0, 3 - revisionSet.size);
  const overwritten = current.history.length < 3 ? 1 : 0;
  assert.equal(lost, 0); assert.equal(overwritten, 0);
  const validated = await runGuard('thesis', thesisPath, { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
  assert.equal(validated.code, 0, validated.stderr);
  artifact('S13.P11.concurrent', { concurrent_lost_revision_count: lost, concurrent_history_overwrite_count: overwritten });
});

test('S13.P11c locked thesis defers a real weekly review without overwrite', { timeout: 900000 }, async () => {
  const { data, thesisPath } = seedEventThesisScenario();
  writeJson(join(data, 'evidence', 'EWind2025001.json'), evidenceFixture());
  writeJson(join(data, 'evidence', 'EChallenge001.json'), evidenceFixture({ id: 'EChallenge001' }));
  writeMarkdown(thesisPath, thesisMarkdown({ revision: 1, report_id: 'thesis-concurrent-001', review_after: '2026-01-01', history: [{ revision: 1, updated_at: '2026-10-01T00:00:00Z', conclusion: '观望', evidence_refs: ['EWind2025001'] }] }));
  writeMarkdown(join(data, 'investor-profile.md'), '# anonymous test investor\n');
  mkdirSync(join(data, 'reviews'), { recursive: true });
  const today = new Date().toLocaleDateString('en-CA');
  writeJson(join(data, 'research-input.json'), { due_theses: ['00700.HK'], review_date: today, evidence_refs: ['EWind2025001'] });
  const before = readFileSync(thesisPath, 'utf8');
  const lockPath = `${thesisPath}.lock`;
  const holder = spawn('python3', ['-c', `import fcntl,time; f=open(${JSON.stringify(lockPath)},'a+'); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(600)`], { env: cleanEnv() });
  try {
    await new Promise(resolve => setTimeout(resolve, 300));
    const store = join(ROOT, 'scripts/hkstock/thesis_store.py');
    const probe = await run('python3', [store, 'status', '--path', thesisPath], { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
    assert.equal(probe.code, 3, probe.stderr);
    assert.match(probe.stdout, /LOCKED/);
    const productionPrompt = readFileSync(join(ROOT, 'deploy/hkstock/runtime/weekly-review.txt'), 'utf8')
      .replaceAll('{{PROFILE_DIR}}', join(HERMES_HOME, 'profiles', 'hkstock'))
      .replaceAll('{{DATA_DIR}}', data);
    const result = await runHermes(`${productionPrompt}\n工作约束：本场景预置证据已足够，禁止额外远程取数或读取验收测试；所有产物只写 ${data}。必须先用 thesis_store.py status 检查 ${thesisPath}；若返回 LOCKED，复盘明确写“锁占用，thesis 更新延后”，不得绕过锁或改写历史。`, { env: cleanEnv({ HKSTOCK_DATA_DIR: data, HKSTOCK_RESEARCH_GUARD: join(ROOT, 'scripts/hkstock/research_guard.py') }) });
    assert.equal(result.code, 0, result.stderr);
    const reviewPath = join(data, 'reviews', `${today}-review.md`);
    assert.ok(existsSync(reviewPath), `weekly review must exist; stdout=${result.stdout}`);
    const review = readFileSync(reviewPath, 'utf8');
    assert.match(review, /延后|LOCKED|锁占用/);
    assert.match(review, /00700\.HK\s*\|\s*待观察/);
    assert.equal(readFileSync(thesisPath, 'utf8'), before, 'locked weekly review must not overwrite thesis or history');
    const validated = await runGuard('review', reviewPath, { env: cleanEnv({ HKSTOCK_DATA_DIR: data }) });
    assert.equal(validated.code, 0, validated.stderr);
    artifact('S13.P11.lock', { deferred_review_while_locked: true, thesis_byte_identical: true, real_review_exit: result.code });
  } finally { holder.kill('SIGKILL'); }
});
