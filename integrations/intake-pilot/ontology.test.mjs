import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { compileFunction } from 'node:vm';
import { routeBatch, routeEvent } from './route.mjs';

const read = file => JSON.parse(readFileSync(new URL(file, import.meta.url), 'utf8'));
const events = read('examples.json');
const [intake, incomplete, done, noLesson, approved, rejected] = events;
const journal = events.at(-1);
const ids = (graph, type) => graph.nodes.filter(n => n.type === type).map(n => n.id);
const has = (graph, from, type, to) => graph.edges.some(e => e.from === from && e.type === type && e.to === to);

test('all ten terminal actions include a deterministic closed graph identical in n8n and Node', () => {
  const expected = routeBatch(events);
  assert.equal(new Set(expected.map(r => r.action)).size, 10);
  for (const route of expected) {
    const graph = route.ontology;
    assert.equal(graph.schema, 'work.ontology.v1');
    assert.deepEqual(graph.provenance.route_key, route.key);
    const nodeIds = graph.nodes.map(n => n.id), edgeIds = graph.edges.map(e => e.id);
    assert.deepEqual(nodeIds, [...new Set(nodeIds)].sort());
    assert.deepEqual(edgeIds, [...new Set(edgeIds)].sort());
    assert.ok(graph.edges.every(e => nodeIds.includes(e.from) && nodeIds.includes(e.to)));
    assert.ok(has(graph, ids(graph, 'output')[0], 'routed_to', 'destination:synthetic/' + route.target));
  }
  const workflow = read('n8n-workflow.json');
  const source = workflow.nodes.find(n => n.name === '계약 검증과 출력 생성').parameters.jsCode;
  const actual = compileFunction(source, ['$input'])({ all: () => events.map(json => ({json})) });
  assert.deepEqual(actual.map(item => item.json), expected);
  assert.deepEqual(routeBatch(events.map(e => Object.fromEntries(Object.entries(e).reverse()))), expected);
});

test('the same physical case, evidence and artifact persist across verified work, review and journal entries', () => {
  const [proof, learning] = routeEvent(done).map(r => r.ontology);
  const artifact = 'artifact:synthetic/file-import/demo-patch/2';
  const review = routeEvent(approved)[0].ontology;
  const evidence = 'evidence:synthetic/file-import/fixture-replay';
  for (const graph of [proof, learning, routeEvent(noLesson)[0].ontology, review, routeEvent(rejected)[0].ontology])
    assert.deepEqual(ids(graph, 'artifact'), [artifact]);
  assert.ok(has(proof, evidence, 'verifies', artifact));
  assert.ok(has(learning, ids(learning,'output')[0], 'describes_learning', ids(learning,'learning')[0]));
  assert.ok(has(review, 'review:synthetic/file-import/demo-review', 'reviewed_artifact', artifact));
  const second = {...journal.payload.entries[0], case_id: 'other-case'};
  const graph = routeEvent({...journal, payload: {...journal.payload, entries: [...journal.payload.entries, second]}})[0].ontology;
  for (const [index, row] of [journal.payload.entries[0], second].entries()) {
    const rowId = 'journal_entry:synthetic/demo-journal/1/' + index;
    assert.ok(has(graph, rowId, 'about_case', 'case:synthetic/' + row.case_id));
    assert.ok(has(graph, rowId, 'cites', 'evidence:synthetic/' + row.case_id + '/fixture-replay'));
  }
  assert.ok(ids(graph,'evidence').includes(evidence));
  assert.deepEqual(ids(routeEvent({...done, classification:'personal'})[0].ontology, 'artifact'),
    ['artifact:personal/file-import/demo-patch/2']);
  assert.deepEqual(ids(routeEvent({...done, case_id:'other-case'})[0].ontology, 'artifact'),
    ['artifact:synthetic/other-case/demo-patch/2']);
});

test('the graph distinguishes a reported channel, a waiting requirement and a routing outcome', () => {
  const graph = routeEvent(incomplete)[0].ontology;
  assert.ok(has(graph, 'channel:synthetic/phone', 'received', 'event:synthetic/intake-b/1'));
  assert.ok(has(graph, 'event:synthetic/intake-b/1', 'about_case', 'case:synthetic/file-import'));
  assert.ok(has(graph, ids(graph,'output')[0], 'disposition', 'outcome:synthetic/waiting_for_input'));
  assert.deepEqual(ids(graph,'requirement').map(id => id.split('/').at(-1)), ['app_version','frequency']);
  const pendingReview = routeEvent({...approved, payload:{...approved.payload, human_review_ref:''}})[0].ontology;
  assert.equal(ids(pendingReview,'review').length, 0);
  const original = structuredClone(intake);
  delete original.payload.channel;
  assert.equal(ids(routeEvent(original)[0].ontology,'channel').length, 0);
  const duplicate = routeBatch([intake,intake])[1].ontology;
  assert.equal(ids(duplicate,'channel').length, 0);
  assert.equal(ids(duplicate,'evidence').length, 0);
  for (const other of ['draft_issue','daily_draft','review_receipt','request_revision']) {
    const r = routeBatch(events).find(x => x.action === other);
    assert.ok(ids(r.ontology,'outcome').length);
  }
});

test('previously rejected identities, conflict contents and free text never enter ontology data', () => {
  const forbidden = {...done, classification:'company', case_id:'secret-case', event_id:'secret-event'};
  const graph = routeEvent(forbidden)[0].ontology;
  assert.equal(graph.classification, 'unclassified');
  assert.equal(graph.provenance.route_key, null);
  assert.equal(ids(graph,'event').length, 0);
  assert.doesNotMatch(JSON.stringify(graph), /secret-case|secret-event|fixture-replay/);
  const changed = {...intake, case_id:'untrusted-case', payload:{...intake.payload, observed:'private-symptom'}};
  for (const item of routeBatch([intake,changed])) {
    assert.equal(item.ontology.provenance.event_type, null);
    assert.equal(ids(item.ontology,'case').length, 0);
    assert.equal(ids(item.ontology,'evidence').length, 0);
    assert.doesNotMatch(JSON.stringify(item.ontology), /untrusted-case|private-symptom/);
  }
  for (const route of routeBatch(events))
    assert.doesNotMatch(JSON.stringify(route.ontology), /확장자의 예제|단말|예제 문서의 가져오기 오류|확장자 정규화/);
});
