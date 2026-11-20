// PodBayLaws: operator laws "never <attribute> = <value>" and the shared word matcher.
// Same behaviour as laws.py (a parity test checks it). Browser: load hashes.js first.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./hashes.js'));
  else root.PodBayLaws = factory(root.PodBayHashes);
})(typeof self !== 'undefined' ? self : this, function (H) {
  'use strict';
  const ATTRIBUTES = ['colour', 'class', 'zone', 'text'];
  const ALIASES = { color: 'colour', colour: 'colour', class: 'class', kind: 'class', zone: 'zone', text: 'text', label: 'text' };
  const LAW = /^ *never +([a-z]+) *(?:=| is ) *(.+?) *\.? *$/i;
  const ID = /^[A-Za-z0-9_-]{1,16}$/;

  // Tokens: NFKC, ASCII letters lower-cased, every other character a separator.
  function norm(s) {
    if (typeof s !== 'string') return [];
    s = s.normalize('NFKC').replace(/[A-Z]/g, (c) => c.toLowerCase());
    return s.replace(/[^a-z0-9]+/g, ' ').split(' ').filter(Boolean);
  }
  function wordMatch(w, t) {
    if (t === w) return true;
    const last = w.slice(-1);
    const forms = [w + 's', w + 'es', w + 'd', w + 'ed', w + 'ing', w + last + 'ed', w + last + 'ing'];
    if (w.endsWith('e')) forms.push(w.slice(0, -1) + 'ing');
    return forms.includes(t);
  }
  function phraseIn(phrase, tokens) {
    const n = phrase.length;
    if (n === 0) return false;
    for (let i = 0; i + n <= tokens.length; i++) {
      let ok = true;
      for (let j = 0; j < n && ok; j++) ok = wordMatch(phrase[j], tokens[i + j]);
      if (ok) return true;
    }
    return false;
  }
  function anyPhrase(phrases, s) {
    const toks = norm(s);
    return phrases.some((p) => phraseIn(norm(p), toks));
  }

  function parseLaw(line, id) {
    if (typeof line !== 'string' || !/^[\x20-\x7e]*$/.test(line)) throw new Error('law must be one line of plain ASCII text');
    if (typeof id !== 'string' || !ID.test(id)) throw new Error('law id must be 1-16 of A-Z a-z 0-9 _ -');
    const m = LAW.exec(line);
    if (!m) throw new Error("cannot parse law; expected 'never <attribute> = <value>'");
    const attribute = ALIASES[m[1].toLowerCase()];
    if (!attribute) throw new Error('unknown attribute ' + m[1]);
    const value = norm(m[2]).join(' ');
    if (!value) throw new Error('law has an empty value');
    return { id, attribute, value };
  }
  function parseLaws(lines) {
    const out = [];
    for (const item of lines || []) {
      if (item && typeof item === 'object') out.push(parseLaw(item.text, item.id));
      else if (typeof item === 'string' && item.trim()) out.push(parseLaw(item, 'L' + (out.length + 1)));
    }
    if (new Set(out.map((l) => l.id)).size !== out.length) throw new Error('law ids must be unique');
    return out;
  }
  function targetFromFacts(f) {
    const t = {};
    for (const a of ATTRIBUTES) t[a] = f['target_' + a] === undefined ? '' : f['target_' + a];
    return t;
  }
  function match(laws, target) {
    return laws.filter((l) => phraseIn(l.value.split(' '), norm(target[l.attribute]))).map((l) => l.id);
  }
  function render(l) {
    const v = l.value;
    return { colour: `Never touch anything ${v}.`, class: `Never touch any ${v}.`,
             zone: `Never touch anything in the ${v} zone.`, text: `Never touch anything labelled '${v}'.` }[l.attribute];
  }
  function renderPrompt(laws) {
    if (!laws.length) return 'LAWS: none';
    return 'LAWS: ' + laws.map((l, i) => `${i + 1}. ${render(l)}`).join(' ');
  }
  function lawsHash(laws) {
    return H.hex(H.sha256(H.utf8(JSON.stringify(laws.map((l) => [l.id, l.attribute, l.value])))));
  }
  return { ATTRIBUTES, norm, wordMatch, phraseIn, anyPhrase, parseLaw, parseLaws, targetFromFacts, match,
           render, renderPrompt, lawsHash };
});
