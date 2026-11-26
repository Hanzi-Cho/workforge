import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { routeBatch, routeEvent } from './route.mjs';
const events = JSON.parse(readFileSync(new URL('examples.json', import.meta.url), 'utf8'));
const [intake, incomplete, done, noLesson, approved, rejected] = events;
const actions = input => routeEvent(input).map(out => out.action);
test('the example exercises every canvas branch', () => {
  assert.deepEqual(routeBatch(events).map(out => out.action), [
    'draft_issue','needs_input','evidence_candidate','private_candidate','evidence_candidate',
    'review_receipt','request_revision','blocked','duplicate','draft_update','draft_issue','daily_draft',
  ]);
  assert.deepEqual(routeEvent(incomplete)[0].payload.missing, ['app_version','frequency']);
});
test('completed work requires verification, learning is optional', () => {
  assert.deepEqual(actions(noLesson), ['evidence_candidate']);
  assert.deepEqual(actions({ ...done, payload: { ...done.payload, verification_ref: '' } }), ['needs_input']);
  assert.deepEqual(actions({ ...done, payload: { ...done.payload, learning: {} } }), ['blocked']);
  const outputs = routeEvent(done);
  assert.equal(outputs[0].payload.artifact_revision, 2);
  assert.equal(outputs[1].payload.fact.kind, 'learning');
  assert.equal(outputs[1].payload.verification_ref, done.payload.verification_ref);
  assert.notEqual(outputs[1].key, outputs[0].key);
});
test('review decisions preserve the target revision and require a human evidence reference', () => {
  for (const event of [approved, rejected]) assert.equal(routeEvent(event)[0].payload.artifact_revision, 2);
  assert.deepEqual(actions({ ...approved, payload: { ...approved.payload, human_review_ref: '' } }), ['needs_input']);
  assert.deepEqual(actions({ ...approved, payload: { ...approved.payload, decision: 'auto' } }), ['blocked']);
});
test('unsupported or unauthorised inputs yield only local output', () => {
  for (const event of [null, {...intake, revision: false}, {...intake, schema: 'unknown'},
      {...intake, classification: 'company'}, {...intake, type: 'constructor'},
      {...intake, payload: {...intake.payload, extra: 'private'}},
      {...intake, payload: {...intake.payload, app_version: 2}}]) {
    const [out] = routeEvent(event);
    assert.equal(out.action, 'blocked');
    assert.equal(out.target, 'local');
    assert.ok(!JSON.stringify(out).includes('private'));
  }
});
test('reordered fields replay as duplicates, conflicts block both sides in either order', () => {
  const same = Object.fromEntries(Object.entries(intake).reverse());
  assert.deepEqual(routeBatch([intake, same]).map(x => x.action), ['draft_issue','duplicate']);
  const changed = { ...intake, payload: { ...intake.payload, frequency: 'new' } };
  for (const pair of [[intake, changed], [changed, intake]]) {
    assert.deepEqual(routeBatch(pair).map(x => x.payload.code), ['revision_conflict','revision_conflict']);
  }
  assert.deepEqual(routeBatch([intake, {...changed, revision: 2}]).map(x => x.action), ['draft_issue','draft_issue']);
  assert.deepEqual(routeBatch(events), routeBatch(events));
});

test('intake keeps existing tickets across channels and requests a missing Jira key', () => {
  const known = key => ({...intake, payload: {...intake.payload, channel: 'phone', issue_key: key}});
  assert.deepEqual(actions(known('DEMO-21')), ['draft_update']);
  assert.deepEqual(actions(known('not-a-key')), ['blocked']);
  const received = {...intake, payload: {...intake.payload, channel: 'jira'}};
  assert.deepEqual(routeEvent(received)[0].payload.missing, ['issue_key']);
  assert.deepEqual(routeEvent({...received, payload: {...received.payload, frequency: '', issue_key: 'DEMO-21'}})[0].payload,
    {missing: ['frequency'], issue_key: 'DEMO-21'});
  const legacy = structuredClone(intake);
  delete legacy.payload.channel;
  assert.deepEqual(actions(legacy), ['draft_issue']);
});
test('daily draft keeps ordered case evidence, reports missing fields and rejects invalid dates', () => {
  const entry = events.at(-1).payload.entries[0];
  const journal = (work_date, entries) => ({...events.at(-1), payload: {work_date, entries}});
  assert.deepEqual(routeEvent(journal('2024-02-29', [entry, {...entry,case_id:'demo-two'}]))[0].payload.entries.map(e=>e.case_id), ['file-import','demo-two']);
  assert.deepEqual(actions(journal('2025-02-29', [entry])), ['blocked']);
  assert.deepEqual(actions(journal('2026-11-26', [])), ['needs_input']);
  assert.deepEqual(routeEvent(journal('2026-11-26', [{...entry, result:''}]))[0].payload.missing, ['entries[0].result']);
});
