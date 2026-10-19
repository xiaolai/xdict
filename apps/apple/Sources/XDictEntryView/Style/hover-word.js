(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictHoverWord) return;
  if (typeof Intl === 'undefined' || !Intl.Segmenter || !document.caretRangeFromPoint) return;
  var words = new Intl.Segmenter(undefined, { granularity: 'word' });
  var characters = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  // The longest text handed back, in UTF-16 code units, whatever the caller asks: the native side holds its own bound.
  var CEILING = 4096;
  // **The script's own work is bounded** (verifier, 2026-10-19: a 100,000-deep tree cost 23.8 s, 50 MB before the word
  // was walked): no element deeper than DEPTH below the root is read; at most STEPS nodes are visited on each side of the
  // word; the word is segmented in AROUND units each side of the caret; a character is found in SPAN units each side.
  var DEPTH = 64;
  var STEPS = 4096;
  var AROUND = 256;
  var SPAN = 32;
  // Elements whose text is never shown as text.
  var UNSHOWN = { SCRIPT: 1, STYLE: 1, TEMPLATE: 1, NOSCRIPT: 1, TEXTAREA: 1, TITLE: 1 };

  // Whether `element` and every element above it let its text be seen: none unshown by tag, `display: none`,
  // `opacity: 0` or `content-visibility: hidden`, and no more than DEPTH of them — past that the text is not read, before the rest are asked anything.
  // One answer per element per call (`known`); `visibility` is inherited, so it is the text's own parent's alone
  // (`shown`). `aria-hidden` hides from assistive technology, not from the eye, and is no reason.
  function open(element, known) {
    var chain = [], verdict = true, e = element;
    for (var i = 0; e && e.nodeType === 1; i++, e = e.parentNode) {
      if (known.has(e)) { verdict = known.get(e); break; }
      if (i > DEPTH) { verdict = false; break; }
      chain.push(e);
      if (UNSHOWN[e.tagName]) { verdict = false; break; }
      var style = getComputedStyle(e);
      // `content-visibility: hidden` skips the element's contents, the text read here being among them.
      if (style.display === 'none' || style.opacity === '0' || style.contentVisibility === 'hidden') {
        verdict = false; break;
      }
    }
    for (var j = 0; j < chain.length; j++) known.set(chain[j], verdict);
    return verdict;
  }

  // Whether text node `t` is seen.
  function shown(t, known) {
    var parent = t.parentNode;
    return !!parent && parent.nodeType === 1 && open(parent, known) && getComputedStyle(parent).visibility === 'visible';
  }

  // The block the word's sentence is read from: the nearest element that is not laid out inline.
  function block(node) {
    for (var e = node.parentNode; e && e.nodeType === 1; e = e.parentNode) {
      if (e === document.body || e === document.documentElement) return e;
      var d = getComputedStyle(e).display;
      if (d !== 'inline' && d !== 'contents') return e;
    }
    return null;
  }

  // The node before `node` in document order inside `root`, not entering unshown elements, counting every node passed
  // in `steps`; null at the start of `root` or when the steps run out (`steps.out`).
  function previous(node, root, steps) {
    if (node.previousSibling) {
      node = node.previousSibling;
      while (node.lastChild && !(node.nodeType === 1 && UNSHOWN[node.tagName])) {
        if (++steps.n > STEPS) { steps.out = true; return null; }
        node = node.lastChild;
      }
    } else {
      node = node.parentNode;
      if (!node || node === root) return null;
    }
    if (++steps.n > STEPS) { steps.out = true; return null; }
    return node;
  }

  function next(node, root, steps) {
    if (node.firstChild && !(node.nodeType === 1 && UNSHOWN[node.tagName])) {
      node = node.firstChild;
    } else {
      while (node !== root && !node.nextSibling) {
        if (++steps.n > STEPS) { steps.out = true; return null; }
        node = node.parentNode;
        if (!node) return null;
      }
      if (node === root) return null;
      node = node.nextSibling;
    }
    if (++steps.n > STEPS) { steps.out = true; return null; }
    return node;
  }

  // Up to `most` units of the shown text before `from` (exclusive) in `root`, nearest last; `cut` where it stopped short.
  function before(from, root, most, known) {
    var parts = [], got = 0, steps = { n: 0, out: false };
    for (var n = previous(from, root, steps); n && got < most; n = previous(n, root, steps)) {
      if (n.nodeType !== 3 || !shown(n, known)) continue;
      var data = n.data, take = Math.min(data.length, most - got);
      parts.push(data.substring(data.length - take));
      got += take;
    }
    return { text: parts.reverse().join(''), cut: got >= most || steps.out };
  }

  function after(from, root, most, known) {
    var parts = [], got = 0, steps = { n: 0, out: false };
    for (var n = next(from, root, steps); n && got < most; n = next(n, root, steps)) {
      if (n.nodeType !== 3 || !shown(n, known)) continue;
      var data = n.data, take = Math.min(data.length, most - got);
      parts.push(data.substring(0, take));
      got += take;
    }
    return { text: parts.join(''), cut: got >= most || steps.out };
  }

  // The first character boundary at or after `i` in `s` (`up`), or the last at or before it: never inside a surrogate
  // pair or a combining sequence.
  function boundary(s, i, up) {
    if (i <= 0 || i >= s.length) return i;
    var lo = Math.max(0, i - SPAN);
    var c = characters.segment(s.substring(lo, Math.min(s.length, i + SPAN))).containing(i - lo);
    var start = lo + c.index;
    return start === i || !up ? start : start + c.segment.length;
  }

  // **The word under a hover point, for XDict's own hover** (owner, 2026-10-19: hover reads XDict's own windows; an
  // Accessibility request about our own web view waits on WebKit, which waits on our main thread). Viewport CSS pixels
  // in; out, the shown text of the word's block windowed to `max` around the word on whole characters, the word's offset
  // in it and whether either end may be cut — or null off a shown word. It reads, never writes: no event, no request.
  window.__xdictHoverWord = function (x, y, max) {
    if (typeof x !== 'number' || typeof y !== 'number') return null;
    max = Math.max(1, Math.min(Math.floor(Number(max) || 0), CEILING));
    // **The depth first, by the plain hit test**: the caret's own lookup computes editability through the tree it lands
    // in, and over a 100,000-deep tree it took 19 s (measured 2026-10-19), while the element hit test took under 1 ms.
    // WebKit renders no box that deep, so the hit test names a shallower element there — or the root, or the body, where
    // the point is over no element's box: nothing is read there, and the caret is never asked. (Text set straight into
    // the body, with no element around it, is therefore not read: an entry always wraps its text.)
    var under = document.elementFromPoint(x, y), up = 0;
    if (!under || under === document.documentElement || under === document.body) return null;
    for (var a = under; a && a.nodeType === 1; a = a.parentNode) if (++up > DEPTH + 1) return null;
    var caret = document.caretRangeFromPoint(x, y);
    if (!caret || caret.startContainer.nodeType !== 3) return null;
    var node = caret.startContainer, at = caret.startOffset;
    var known = new Map();
    if (!shown(node, known)) return null;
    var data = node.data, lo = Math.max(0, at - AROUND);
    var hit = XDictWordCore.at(data.substring(lo, Math.min(data.length, at + AROUND)), at - lo, words);
    if (!hit) return null;
    var start = lo + hit.start, end = lo + hit.end;
    var range = document.createRange();
    range.setStart(node, start);
    range.setEnd(node, end);
    var rects = range.getClientRects(), on = false;
    for (var i = 0; i < rects.length && !on; i++) {
      var r = rects[i];
      on = x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
    }
    if (!on) return null;
    var root = block(node);
    if (!root || !open(root, known)) return null;
    // Each side is read SPAN units past what the window can use, so the window's ends are cut on whole characters with
    // the text around them in hand; a head or tail of the word's own node that long is enough, the rest may be cut.
    var need = max + SPAN;
    var head = data.substring(Math.max(0, start - need), start);
    var left = head.length >= need ? { text: '', cut: true } : before(node, root, need - head.length, known);
    var tail = data.substring(start, Math.min(data.length, start + need));
    var right = tail.length >= need ? { text: '', cut: true } : after(node, root, need - tail.length, known);
    var all = left.text + head + tail + right.text, word = left.text.length + head.length;
    var from = Math.max(0, word - Math.floor(max / 2)), to = Math.min(all.length, from + max);
    from = boundary(all, Math.max(0, to - max), true);
    to = boundary(all, to, false);
    if (from > word || to <= word) return null;
    return {
      text: all.substring(from, to), offset: word - from,
      cutStart: from > 0 || left.cut, cutEnd: to < all.length || right.cut
    };
  };
})();
