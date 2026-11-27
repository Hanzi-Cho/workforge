// Project only references already accepted by the router; do not copy narrative or identities of people.
// Kept self-contained so build.mjs can embed exactly this function in the n8n Code node.
export function projectOntology(input, route) {
  const classification = route.classification ?? 'unclassified';
  const { case_id: caseId, event_id: eventId, revision, target, action, payload } = route;
  const rejected = action === 'blocked';
  const conflict = rejected && payload.code === 'revision_conflict';
  const eventType = !rejected && ['issue.received', 'work.completed', 'review.decided', 'workday.closed'].includes(input?.type)
    ? input.type : null;
  const nodes = new Map();
  const edges = new Map();
  function node(type, parts, label) {
    const id = type + ':' + [classification, ...parts].map(encodeURIComponent).join('/');
    nodes.set(id, { id, type, label });
    return id;
  }
  function edge(from, type, to) {
    const id = 'edge:' + type + '|' + from + '|' + to;
    edges.set(id, { id, from, type, to });
  }
  const caseNode = id => node('case', [id], id);
  const ref = (type, id, scope = caseId) => node(type, [scope, id], id);
  const eventParts = eventId ? [eventId, revision] : [];
  // An unidentified rejection describes a category. Do not invent an occurrence ID
  // from the input body, clock, execution order, or random data.
  const outputParts = eventId ? [...eventParts, target, action] : [target, action, payload.code];
  const output = node('output', outputParts, action);
  edge(output, 'routed_to', node('destination', [target], target));
  const dispositions = {
    draft_issue: 'draft', draft_update: 'draft', daily_draft: 'draft',
    evidence_candidate: 'candidate', private_candidate: 'candidate',
    review_receipt: 'review_record', request_revision: 'revision_requested',
    needs_input: 'waiting_for_input', duplicate: 'duplicate', blocked: 'blocked',
  };
  const disposition = dispositions[action];
  const reasonParts = payload.code ? [disposition, payload.code] : [disposition];
  edge(output, 'disposition', node('outcome', reasonParts, reasonParts.join(' · ')));
  if (eventId) {
    const event = node('event', eventParts, eventId + '@' + revision);
    edge(event, 'yields', output);
    if (!conflict) edge(event, 'about_case', caseNode(caseId));
    if (action !== 'duplicate' && !rejected) {
      if (eventType === 'issue.received') {
        const channel = input.payload.channel;
        if (channel) edge(node('channel', [channel], channel), 'received', event);
        if (payload.issue_key) edge(output, 'refers_to_ticket', node('ticket', [payload.issue_key], payload.issue_key));
        if (payload.evidence_ref) {
          const evidence = ref('evidence', payload.evidence_ref);
          edge(event, 'cites', evidence);
          edge(evidence, 'supports', output);
        }
      }
      if (action === 'needs_input') {
        for (const field of payload.missing)
          edge(output, 'requires', node('requirement', [...eventParts, field], field));
      } else if (eventType === 'work.completed' || eventType === 'review.decided') {
        // A private_candidate contains the learning fact only. Its verified input
        // still identifies the exact same artifact and gate as the paired route.
        const { artifact_id, artifact_revision, gate_id } = input.payload;
        const artifactId = artifact_id.trim();
        const artifact = node('artifact', [caseId, artifactId, artifact_revision], artifactId + '@' + artifact_revision);
        edge(event, 'concerns_artifact', artifact);
        if (gate_id) edge(event, 'at_gate', ref('gate', gate_id.trim()));
        if (payload.verification_ref) {
          const evidence = ref('evidence', payload.verification_ref);
          edge(event, 'cites', evidence);
          edge(evidence, 'verifies', artifact);
          edge(evidence, 'supports', output);
        }
        if (payload.human_review_ref) {
          const review = ref('review', payload.human_review_ref);
          edge(event, 'cites', review);
          edge(review, 'reviewed_artifact', artifact);
          edge(review, 'supports', output);
        }
        if (payload.fact) {
          const learning = node('learning', [caseId, ...eventParts, payload.fact.id], payload.fact.id);
          edge(output, 'describes_learning', learning);
        }
      } else if (action === 'daily_draft') {
        for (const [index, entry] of payload.entries.entries()) {
          const row = node('journal_entry', [...eventParts, index], payload.work_date + ' #' + (index + 1));
          edge(event, 'includes_entry', row);
          edge(row, 'about_case', caseNode(entry.case_id));
          edge(row, 'cites', ref('evidence', entry.evidence_ref, entry.case_id));
          edge(row, 'contributes_to', output);
        }
      }
    }
  }
  const sorted = map => [...map.values()].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  return {
    schema: 'work.ontology.v1', classification,
    provenance: { route_schema: route.schema, route_key: route.key ?? null, event_type: eventType },
    nodes: sorted(nodes), edges: sorted(edges),
  };
}
