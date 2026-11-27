import { projectOntology } from './ontology.mjs';

// Pure routing. Both the CLI tests and the n8n Code node use these functions.
export function classifyEvent(input) {
  const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const id = value => typeof value === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value);
  const revision = value => Number.isInteger(value) && value > 0 && value <= 2147483647;
  const invalid = code => [{ schema: 'work.route.v1', target: 'local', action: 'blocked', payload: { code } }];
  if (!record(input) || input.schema !== 'work.event.v1') return invalid('unsupported_schema');
  if (!['synthetic', 'personal'].includes(input.classification)) return invalid('disallowed_classification');
  if (!id(input.case_id) || !id(input.event_id) || !revision(input.revision)) return invalid('invalid_identity');
  const { case_id, event_id, type, classification, payload, revision: rev } = input;
  function result(target, action, body) {
    return { schema: 'work.route.v1', case_id, event_id, revision: rev, classification,
      key: [event_id, rev, target, action].join('/'), target, action, payload: body };
  }
  const block = code => [result('local', 'blocked', { code })];
  const envelope = ['schema', 'classification', 'case_id', 'event_id', 'revision', 'type', 'payload'];
  if (Object.keys(input).some(key => !envelope.includes(key))) return block('unexpected_envelope_field');
  const contracts = {
    'issue.received': ['app_version', 'device_os', 'observed', 'expected', 'frequency', 'steps', 'evidence_ref'],
    'work.completed': ['gate_id', 'artifact_id', 'artifact_revision', 'verification_ref'],
    'workday.closed': ['work_date', 'entries'],
    'review.decided': ['artifact_id', 'artifact_revision', 'decision', 'human_review_ref'],
  };
  if (typeof type !== 'string' || !Object.hasOwn(contracts, type)) return block('unknown_type');
  if (!record(payload)) return block('invalid_payload');
  const required = [...contracts[type]];
  const optional = { 'work.completed': ['learning'], 'issue.received': ['channel','issue_key'] };
  const allowed = [...required, ...(optional[type] ?? [])];
  if (Object.keys(payload).some(key => !allowed.includes(key))) return block('unexpected_payload_field');
  const missing = [];
  const clean = {};
  if (type === 'issue.received') {
    if (Object.hasOwn(payload, 'channel')) {
      if (!['jira', 'email', 'phone', 'in_person'].includes(payload.channel)) return block('unknown_channel');
      clean.channel = payload.channel;
    }
    if (payload.channel === 'jira' || Object.hasOwn(payload, 'issue_key')) required.push('issue_key');
  }
  for (const field of required) {
    const value = payload[field];
    if (value == null || (typeof value === 'string' && !value.trim())) {
      missing.push(field);
      continue;
    }
    if (field === 'entries') {
      if (!Array.isArray(value) || value.length > 100) return block('invalid_entries');
      if (!value.length) { missing.push('entries'); continue; }
      const fields = ['case_id', 'work', 'result', 'evidence_ref', 'next_step'];
      clean.entries = [];
      for (const [index, entry] of value.entries()) {
        if (!record(entry) || Object.keys(entry).some(key => !fields.includes(key))) return block('invalid_entry');
        const row = {};
        for (const key of fields) {
          const text = entry[key];
          if (text == null || (typeof text === 'string' && !text.trim())) {
            missing.push('entries[' + index + '].' + key);
            continue;
          }
          if (typeof text !== 'string' || text.length > 1000) return block('invalid_entry_' + key);
          row[key] = text.trim();
          if ((key === 'case_id' || key === 'evidence_ref') && !id(row[key])) return block('invalid_entry_' + key);
        }
        clean.entries.push(row);
      }
    } else if (field === 'artifact_revision') {
      if (!revision(value)) return block('invalid_artifact_revision');
      clean[field] = value;
    } else {
      if (typeof value !== 'string' || value.length > 1000) return block('invalid_' + field);
      clean[field] = value.trim();
      if (field === 'issue_key' && (clean[field].length > 64 || !/^[A-Z][A-Z0-9_]*-[1-9][0-9]*$/.test(clean[field]))) {
        return block('invalid_issue_key');
      }
      if (field === 'work_date') {
        const day = clean[field];
        if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return block('invalid_work_date');
        const date = new Date(day + 'T00:00:00Z');
        if (!Number.isFinite(date.getTime()) || date.toISOString().slice(0,10) !== day) return block('invalid_work_date');
      }
      if ((field.endsWith('_ref') || field.endsWith('_id')) && !id(clean[field])) return block('invalid_' + field);
    }
  }
  if (clean.decision && !['approved', 'changes_requested'].includes(clean.decision)) return block('unknown_decision');
  if (type === 'work.completed' && Object.hasOwn(payload, 'learning')) {
    const learn = payload.learning;
    if (!record(learn) || Object.keys(learn).some(key => !['id', 'text'].includes(key)) ||
        !id(learn.id) || typeof learn.text !== 'string' || !learn.text.trim() || learn.text.length > 1000) {
      return block('invalid_learning');
    }
  }
  if (missing.length) {
    const details = { missing };
    if (clean.issue_key) details.issue_key = clean.issue_key;
    return [result('local', 'needs_input', details)];
  }
  if (type === 'workday.closed') return [result('confluence', 'daily_draft', clean)];
  if (type === 'issue.received') return [result('jira', clean.issue_key ? 'draft_update' : 'draft_issue', clean)];
  if (type === 'review.decided') {
    const action = clean.decision === 'approved' ? 'review_receipt' : 'request_revision';
    return [result('hookboard', action, clean)];
  }
  const outputs = [result('hookboard', 'evidence_candidate', clean)];
  if (payload.learning) {
    const fact = { id: payload.learning.id, kind: 'learning', text: payload.learning.text.trim() };
    outputs.push(result('til', 'private_candidate', { fact, verification_ref: clean.verification_ref }));
  }
  return outputs;
}

export function routeEvent(input) {
  return classifyEvent(input).map(route => ({ ...route, ontology: projectOntology(input, route) }));
}

export function routeBatch(inputs) {
  // Compare wire-equivalent JSON objects independently of property order.
  const canonical = value => {
    if (Array.isArray(value)) return value.map(canonical);
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
    }
    return value;
  };
  const groups = new Map();
  const entries = inputs.map(input => {
    const outputs = classifyEvent(input);
    const head = outputs[0];
    if (!head.event_id) return { input, outputs };
    const key = head.event_id + '/' + head.revision;
    const body = JSON.stringify(canonical(input));
    if (!groups.has(key)) groups.set(key, new Set());
    groups.get(key).add(body);
    return { input, key, outputs };
  });
  const seen = new Set();
  return entries.flatMap(({ input, key, outputs }) => {
    const project = route => ({ ...route, ontology: projectOntology(input, route) });
    if (!key) return outputs.map(project);
    const head = outputs[0];
    const conflict = groups.get(key).size > 1;
    if (!conflict && !seen.has(key)) {
      seen.add(key);
      return outputs.map(project);
    }
    const action = conflict ? 'blocked' : 'duplicate';
    return [project({ schema: head.schema, classification: head.classification, case_id: head.case_id,
      event_id: head.event_id, revision: head.revision, key: key + '/local/' + action,
      target: 'local', action, payload: { code: conflict ? 'revision_conflict' : 'already_in_batch' } })];
  });
}
