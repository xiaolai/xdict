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
  return { dominant: dominant, opaque: opaque };
})();
