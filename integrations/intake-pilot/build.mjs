import { readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { routeEvent, routeBatch } from './route.mjs';

const siblings = name => new URL(name, import.meta.url);
const { values } = parseArgs({ options: { input: { type: 'string' }, output: { type: 'string' } } });
const cases = JSON.parse(readFileSync(values.input ?? siblings('examples.json'), 'utf8'));
if (!Array.isArray(cases) || !cases.length) throw new Error('Expected a nonempty JSON event array');
const source = values.input
  ? 'JSON.parse(' + JSON.stringify(JSON.stringify(cases)) + ')'
  : JSON.stringify(cases, null, 2);
const branches = {
  draft_issue: 'Jira 티켓 초안',
  draft_update: '기존 Jira 티켓 보완 초안',
  daily_draft: 'Confluence 업무일지 초안',
  needs_input: '누락 필드 보완',
  evidence_candidate: 'Hookboard 검증 근거 후보',
  private_candidate: 'TIL 비공개 후보',
  review_receipt: '사람 검토 근거 접수',
  request_revision: '수정 요청',
  duplicate: '동일 입력 건너뛰기',
  blocked: '처리 차단',
};
function node(name, type, typeVersion, position, parameters = {}) {
  return { id: 'agentasm-' + position.join('-'), name, type: 'n8n-nodes-base.' + type,
    typeVersion, position, parameters };
}
const nodes = [
  node('수동 실행', 'manualTrigger', 1, [0, 0]),
  node('이벤트 입력', 'code', 2, [220, 0], {
    // n8n requires an object in item.json. Invalid event shapes still reach the router.
    jsCode: 'const events = ' + source + ';\n' +
      "return events.map(value => ({ json: value && typeof value === 'object' && !Array.isArray(value) ? value : {} }));",
  }),
  node('계약 검증과 출력 생성', 'code', 2, [440, 0], {
    jsCode: [routeEvent.toString(), routeBatch.toString(),
      'return routeBatch($input.all().map(item => item.json)).map(json => ({ json }));'].join('\n\n'),
  }),
];
const rules = Object.keys(branches).map(action => ({
  renameOutput: true, outputKey: action, conditions: {
    options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
    conditions: [{ id: action, leftValue: '={{ $json.action }}', rightValue: action,
      operator: { type: 'string', operation: 'equals' } }], combinator: 'and',
  },
}));
nodes.push(node('동작 분기', 'switch', 3.2, [660, 0], { mode: 'rules', rules: { values: rules }, options: {} }));
for (const [index, title] of Object.values(branches).entries()) {
  nodes.push(node(title, 'noOp', 1, [1000, -420 + 120 * index]));
}
const edge = target => [{ node: target.name, type: 'main', index: 0 }];
const connections = {};
for (let i = 0; i < 3; i++) connections[nodes[i].name] = { main: [edge(nodes[i + 1])] };
connections[nodes[3].name] = { main: nodes.slice(4).map(edge) };
const workflow = { id: 'agentAsmWorkContractV1', name: 'AgentASM · 개인 업무 입출력과 동작 분기 v1',
  active: false, nodes, connections, settings: { executionOrder: 'v1' } };
writeFileSync(values.output ?? siblings('n8n-workflow.json'), JSON.stringify(workflow, null, 2) + '\n');
