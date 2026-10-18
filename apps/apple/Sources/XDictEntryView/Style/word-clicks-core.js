var XDictWordCore = (function () {
  'use strict';
  // The longest word a click looks up, in code points; the native side holds the same bound (`EntryWordClick`).
  var MAX = 64;
  var EDGE = /^[\p{P}\p{S}\s]+|[\p{P}\p{S}\s]+$/gu;
  function word(s) {
    if (!s || !s.isWordLike) return null;
    var w = s.segment.replace(EDGE, '');
    if (!w || Array.from(w).length > MAX) return null;
    return { word: w, start: s.index, end: s.index + s.segment.length };
  }
  // The word of `text` at the caret `offset`, by the segmenter's word granularity (so a CJK run gives its word, an
  // accented word stays whole), trimmed of punctuation and symbols; null on a space or punctuation. A caret just after
  // a word (the right half of its last letter) is that word: the DOM side checks the point is on its letters.
  function at(text, offset, segmenter) {
    if (typeof text !== 'string' || typeof offset !== 'number' || offset < 0 || offset > text.length) return null;
    var segments = segmenter.segment(text);
    return word(segments.containing(offset)) || (offset > 0 ? word(segments.containing(offset - 1)) : null);
  }
  // Whether a click opens its word in a new tab: the reader's (trusted) single primary Command-click, no other modifier,
  // nothing selected, and not already taken by the page (`defaultPrevented`). A plain click is never a lookup (owner,
  // 2026-10-18: readers misclick).
  function allowed(e, selected) {
    return !!e && e.isTrusted === true && e.button === 0 && e.detail === 1 && e.metaKey === true && !e.altKey
      && !e.ctrlKey && !e.shiftKey && !e.defaultPrevented && !selected;
  }
  return { at: at, allowed: allowed, MAX: MAX };
})();
