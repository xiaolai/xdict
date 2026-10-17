var XDictFrameCore = (function () {
  'use strict';
  function dominant(samples) {
    var weight = {};
    samples.forEach(function (s) {
      if (!(s[0] > 0) || !(s[1] > 0)) return;
      var b = Math.round(s[0] * 2) / 2;
      weight[b] = (weight[b] || 0) + s[1];
    });
    var best = NaN, most = 0;
    Object.keys(weight).forEach(function (k) {
      if (weight[k] > most) { most = weight[k]; best = parseFloat(k); }
    });
    return best;
  }
  function opaque(css) {
    var m = /rgba?\(([^)]*)\)/.exec(String(css));
    if (!m) return false;
    var p = m[1].split(/[\s,\/]+/).filter(function (x) { return x.length; });
    return p.length < 4 || parseFloat(p[3]) > 0.05;
  }
  // R7a (WI-11, 2026-10-17): the space token a role-marked block takes (`--xdict-space-<name>`), '' for none. A
  // section is a phrase block when it holds idioms, phrasal verbs, collocates or derived words.
  var ROLE_SPACE = { sense: 'sense', sensenum: 'sense', example: 'example', 'example-trans': 'translation',
                     trans: 'translation', subhead: 'subhead', heading: 'heading', pos: 'pos' };
  // A section or heading inside a sense is that sense's note (OALD's "synonym proviso", "see also", D43): it keeps
  // the dictionary's own gap, as its "Topics" line does, never a heading's.
  function spaceOf(role, section, inSense) {
    if (inSense && (role === 'section' || role === 'heading')) return '';
    if (role === 'section') return /^(idioms|phrasal|colloc|derivatives)$/.test(section || '') ? 'phrase' : 'heading';
    return Object.prototype.hasOwnProperty.call(ROLE_SPACE, role) ? ROLE_SPACE[role] : '';
  }
  // The margin before a block that makes its collapsed gap `want`, from the gap `margin` gave. Adjoining margins
  // collapse to the largest positive plus the most negative: a positive margin that left a larger gap met a larger
  // one before it, which a negative margin cancels; otherwise the gap moves with the margin.
  function nextMargin(margin, gap, want) {
    return margin >= 0 && gap > want ? want - gap : margin + (want - gap);
  }
  // R16's classes (WI-11, 2026-10-17), from an image's natural size and its place: `table` (in a cell), `badge` (a
  // small image floated: an ornament in a heading), `icon` (small: ≤ 96 × 48), `text` (low and wide: an image of a
  // phrase, in its line or alone), `float`, `inline` (an illustration beside text), `illustration`; '' when it has no pixels (missing,
  // ADR-0009's). `text` is a heuristic: low (≤ 64) and wide (≥ 2.5:1), more than an icon's width.
  function imageClass(f) {
    var w = f.w || 0, h = f.h || 0;
    if (!(w > 0 && h > 0)) return '';
    if (f.table) return 'table';
    var small = w <= 96 && h <= 48;
    if (h <= 64 && w > 48 && w / h >= 2.5) return 'text';
    if (small) return f.floated ? 'badge' : 'icon';
    if (f.floated) return 'float';
    return f.text ? 'inline' : 'illustration';
  }
  // A picture the dictionary hides itself (owner, 2026-10-17), gathered under XDict's "Pictures" fold: hidden by its
  // own `display:none`/`visibility:hidden` (`image`) or its picture container's, a box with no text (`container`);
  // never inside a hidden block of text (`text`: a dictionary's closed fold), never a control, and only an
  // illustration by the class rules, with pixels (a missing one is never counted).
  function gatherable(f) {
    if (f.control || (f.hidden !== 'image' && f.hidden !== 'container')) return false;
    var kind = imageClass({ w: f.w, h: f.h });
    return kind === 'illustration';
  }
  return { dominant: dominant, opaque: opaque, gatherable: gatherable, spaceOf: spaceOf, nextMargin: nextMargin, imageClass: imageClass };
})();
