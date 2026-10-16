var XDictColourCore = (function () {
  'use strict';
  var FALLBACK = {{fallbacks}};
  var HEX = /^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i;
  var RGB = /^rgba?\(\s*([\d.]+%?)[,\s]+([\d.]+%?)[,\s]+([\d.]+%?)(?:\s*[,\/]\s*([\d.]+%?))?\s*\)$/i;
  function parse(css) {
    var v = String(css).trim(), m = HEX.exec(v);
    if (m) {
      var h = m[1];
      if (h.length <= 4) h = h.split('').map(function (x) { return x + x; }).join('');
      var n = function (i) { return parseInt(h.slice(i, i + 2), 16); };
      return [n(0), n(2), n(4), h.length === 8 ? n(6) / 255 : 1];
    }
    m = RGB.exec(v);
    if (!m) return null;
    var ch = function (x) { var f = parseFloat(x); return Math.min(255, Math.max(0, /%$/.test(x) ? f * 2.55 : f)); };
    var a = m[4] === undefined ? 1 : parseFloat(m[4]) / (/%$/.test(m[4]) ? 100 : 1);
    return [ch(m[1]), ch(m[2]), ch(m[3]), Math.min(1, Math.max(0, a))];
  }
  function linear(c) { c = c / 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  function lch(c) {
    var w = function (x) { return x * c[3] + 255 * (1 - c[3]); };
    var r = linear(w(c[0])), g = linear(w(c[1])), b = linear(w(c[2]));
    var l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    var m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    var s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    var L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
    var A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
    var B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
    return { l: L, c: Math.hypot(A, B), h: Math.atan2(B, A) };
  }
  function token(c) {
    var p = lch(c);
    if (p.l >= 0.95 && p.c < 0.03) return 'text';
    if (p.c < 0.035) return p.l < 0.45 ? 'text' : 'text-2';
    return 'accent';
  }
  function text(c) {
    if (!c) return null;
    var t = token(c);
    return 'var(--xdict-' + t + ', ' + FALLBACK[t] + ')';
  }
  // What the core drops inside an entry ("Plain by default"), and a fill colour that would override the token.
  var DROP = /^(background|border|outline|box-shadow$|text-shadow$|-webkit-text-fill-color$)/;
  var NOTHING = /^(0|0px|none|hidden)$/i;
  var LEFT = /^(inherit|initial|unset|revert|revert-layer|currentcolor|transparent)$/i;
  // `declarations`: [name, value, priority] of one element's inline style; `resolve`: a CSS colour to RGBA.
  // A token, a keyword and a value the resolver cannot read are left alone, so the guard never rewrites its own.
  function plan(declarations, resolve) {
    var out = [];
    declarations.forEach(function (d) {
      var name = String(d[0]), value = String(d[1]).trim();
      // A border that draws nothing (the core's `<hr>` gap, Q9) stays: removing it brings back the UA's line.
      var none = /^(border|outline)/.test(name) && NOTHING.test(value);
      if (DROP.test(name)) { if (!none) out.push(['remove', name]); return; }
      if (name !== 'color' || /^var\(\s*--xdict-/.test(value) || /var\(/.test(value) || LEFT.test(value)) return;
      var css = text(resolve(value));
      if (css && css !== value) out.push(['set', 'color', css, d[2] || '']);
    });
    return out;
  }
  return { parse: parse, token: token, text: text, plan: plan };
})();
