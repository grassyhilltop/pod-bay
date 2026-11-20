// PodBayLadder: the guard ladder in JavaScript, from the same rules.json as ladder.py.
//   node:    const L = require('./ladder.js'); L.evaluate(facts, switches)
//   browser: <script src="hashes.js"> <script src="laws.js"> <script src="rules.js"> <script src="ladder.js">
//            then PodBayLadder.evaluate(facts, switches)
// The parity test runs thousands of random fact sets through both and requires identical answers.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    const rules = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, 'rules.json'), 'utf8'));
    module.exports = factory(require('./hashes.js'), require('./laws.js'), rules);
  } else {
    root.PodBayLadder = factory(root.PodBayHashes, root.PodBayLaws, root.PODBAY_RULES);
  }
})(typeof self !== 'undefined' ? self : this, function (H, Laws, RULES) {
  'use strict';

  // Canonical JSON identical to Python's json.dumps(sort_keys=True, separators=(",", ":"), ensure_ascii=True).
  function canonical(v) {
    if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
    if (v && typeof v === 'object') {
      return '{' + Object.keys(v).sort().map((k) => canonical(k) + ':' + canonical(v[k])).join(',') + '}';
    }
    const s = JSON.stringify(v);
    return typeof v === 'string' ? s.replace(/[\u0080-￿]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0')) : s;
  }
  function policyHash(rules) {
    const body = Object.assign({}, rules); delete body.policy_hash;
    return H.hex(H.sha256(H.utf8(canonical(body)))).slice(0, 12);
  }
  function check(rules) {
    const h = policyHash(rules);
    if (rules.policy_hash !== h) throw new Error('rules policy_hash ' + rules.policy_hash + ' != computed ' + h);
    return rules;
  }

  // A fact keeps its value only if it has the type of its fail-safe default.
  function typed(v, d) {
    if (typeof d === 'boolean') return typeof v === 'boolean' ? v : d;
    if (typeof d === 'number') return typeof v === 'number' && isFinite(v) ? v : d;
    if (typeof d === 'string') return typeof v === 'string' ? v : d;
    if (Array.isArray(d)) {
      if (v === undefined || v === null) return d;
      if (!Array.isArray(v)) return ['malformed'];
      return v.map((x) => (typeof x === 'string' ? x : 'malformed'));
    }
    throw new Error('bad fail_safe default');
  }
  function cleanFacts(facts, rules) {
    const f = {};
    for (const [k, d] of Object.entries(rules.fail_safe)) f[k] = typed(facts[k], d);
    return f;
  }
  function resolveSwitches(sw, rules) {
    const on = {};
    rules.rungs.forEach((r) => { on[r.id] = r.enabled; });
    sw = sw || {};
    const groups = rules.switch_groups, has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
    for (const [name, val] of Object.entries(sw)) {
      if (typeof val !== 'boolean') throw new Error('switch ' + name + ' must be true or false');
      if (!has(groups, name) && !has(on, name)) throw new Error('unknown switch ' + name);
    }
    for (const [name, val] of Object.entries(sw)) if (has(groups, name)) groups[name].forEach((id) => { on[id] = val; });
    for (const [name, val] of Object.entries(sw)) if (has(on, name)) on[name] = val;
    return on;
  }

  function trips(f, rules) {
    const th = rules.thresholds, vo = rules.vocab, ctl = f.target_is_control, enters = f.path_enters_chamber;
    const red = Laws.norm(f.target_colour).some((t) => vo.red_words.includes(t));
    return {
      R0: { key_invalid: !f.key_valid },
      R1: { cams_stale: !f.cams_fresh || f.frame_age_ms >= th.max_frame_age_ms,
            low_confidence: f.target_seen < th.min_confidence },
      R2: { human_close: f.human_dist_m < th.human_halt_m },
      R3: { is_estop: Laws.anyPhrase(vo.estop_classes, f.target_class),
            red_control: ctl && red,
            destructive_control: ctl && Laws.anyPhrase(vo.destructive_phrases, f.target_text) },
      R4: { law_hit: f.law_hits.length > 0 },
      R5: { chamber_printing: enters && !vo.chamber_ok_printer_states.includes(f.printer_state),
            chamber_door_closed: enters && !vo.chamber_ok_door_states.includes(f.door_state) },
      R6: { edge_margin: f.path_min_edge_margin_m < th.edge_margin_m, hits_printer: f.path_hits_printer },
    };
  }

  function evaluate(facts, switches, rules) {
    rules = rules || RULES;
    const f = cleanFacts(facts || {}, rules), on = resolveSwitches(switches, rules), tr = trips(f, rules);
    const trace = [];
    let decided = null;
    for (const r of rules.rungs) {
      if (r.id === 'R7') continue;
      const tripped = Object.values(tr[r.id]).some(Boolean);
      trace.push({ rung: r.id, name: r.name, enabled: on[r.id], pass: on[r.id] ? !tripped : null, trips: tr[r.id] });
      if (on[r.id] && tripped && !decided) {
        decided = { verdict: r.verdict, rung: r.id, reason: r.reason + (r.id === 'R4' ? ':' + f.law_hits[0] : '') };
      }
    }
    const r7 = rules.rungs[rules.rungs.length - 1], n = f.blocks_in_a_row, limit = rules.thresholds.halt_after_blocks;
    const t7 = { still_halted: n >= limit, third_block: !!decided && decided.verdict === 'BLOCK' && n + 1 >= limit };
    const t7on = t7.still_halted || t7.third_block;
    trace.push({ rung: 'R7', name: r7.name, enabled: on.R7, pass: on.R7 ? !t7on : null, trips: t7 });
    const out = Object.assign({ verdict: 'ALLOW', rung: null, reason: 'ok', blocked_by: null }, decided || {});
    if (on.R7 && t7on && out.verdict !== 'HALT') {
      Object.assign(out, { blocked_by: out.rung, verdict: 'HALT', rung: 'R7', reason: r7.reason });
    }
    out.trace = trace;
    out.policy = rules.policy_hash;
    return out;
  }

  check(RULES);
  return { RULES, POLICY_HASH: RULES.policy_hash, canonical, policyHash, check, cleanFacts, resolveSwitches,
           evaluate };
});
