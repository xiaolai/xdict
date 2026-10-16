var XDictFindCore = (function () {
  'use strict';
  function pattern(query) {
    var words = String(query).trim().split(/\s+/).filter(function (w) { return w.length > 0; });
    if (words.length === 0) return null;
    var escaped = words.map(function (w) { return w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); });
    return new RegExp(escaped.join('\\s+'), 'giu');
  }
  function matches(text, query) {
    var re = pattern(query), out = [], m;
    if (!re) return out;
    while ((m = re.exec(text)) !== null) {
      if (m[0].length === 0) { re.lastIndex += 1; continue; }
      out.push([m.index, m.index + m[0].length]);
    }
    return out;
  }
  return { pattern: pattern, matches: matches };
})();
