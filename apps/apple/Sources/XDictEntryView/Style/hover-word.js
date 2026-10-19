(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictHoverWord) return;
  if (typeof Intl === 'undefined' || !Intl.Segmenter || !document.caretRangeFromPoint) return;
  var segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
  // The longest text handed back, in UTF-16 code units, whatever the caller asks: the native side holds its own bound.
  var CEILING = 4096;
  // The block the word's sentence is read from: the nearest ancestor that is not laid out inline.
  function block(node) {
    var e = node.parentElement;
    while (e && e !== document.body) {
      var d = getComputedStyle(e).display;
      if (d !== 'inline' && d !== 'contents') return e;
      e = e.parentElement;
    }
    return document.body || e;
  }
  // **The word under a hover point, for XDict's own hover** (owner, 2026-10-19: hover reads XDict's own windows; an
  // Accessibility request about our own web view waits on WebKit, which waits on our main thread). Viewport CSS pixels
  // in; out, the text of the word's block windowed to `max` around the word, the word's offset in it and whether either
  // end was cut — or null off every word. It reads, never writes: no event, no request, no URL.
  window.__xdictHoverWord = function (x, y, max) {
    if (typeof x !== 'number' || typeof y !== 'number') return null;
    max = Math.max(1, Math.min(Math.floor(Number(max) || 0), CEILING));
    var caret = document.caretRangeFromPoint(x, y);
    if (!caret || caret.startContainer.nodeType !== 3) return null;
    var node = caret.startContainer, hit = XDictWordCore.at(node.nodeValue || '', caret.startOffset, segmenter);
    if (!hit) return null;
    var range = document.createRange();
    range.setStart(node, hit.start);
    range.setEnd(node, hit.end);
    var rects = range.getClientRects(), on = false;
    for (var i = 0; i < rects.length && !on; i++) {
      var r = rects[i];
      on = x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    }
    if (!on) return null;
    var b = block(node);
    if (!b) return null;
    var before = document.createRange();
    before.setStart(b, 0);
    before.setEnd(node, hit.start);
    var all = b.textContent || '', at = before.toString().length;
    if (at > all.length) return null;
    var from = Math.max(0, at - Math.floor(max / 2)), to = Math.min(all.length, from + max);
    from = Math.max(0, to - max);
    return { text: all.slice(from, to), offset: at - from, cutStart: from > 0, cutEnd: to < all.length };
  };
})();
