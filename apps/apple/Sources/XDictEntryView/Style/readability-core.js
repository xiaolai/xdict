var XDictReadability = (function () {
  'use strict';
  function parse(css) {
    var m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,\/]\s*([\d.]+)(%?))?\s*\)$/.exec(String(css).trim());
    if (!m) return null;
    var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (m[5] === '%' ? 100 : 1);
    return [parseFloat(m[1]), parseFloat(m[2]), parseFloat(m[3]), a];
  }
  function channel(v) { v = v / 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }
  function luminance(c) { return 0.2126 * channel(c[0]) + 0.7152 * channel(c[1]) + 0.0722 * channel(c[2]); }
  function contrast(a, b) {
    var x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }
  return { parse: parse, contrast: contrast };
})();
