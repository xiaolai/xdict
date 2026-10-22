var XDictSenseCore = (function () {
  'use strict';
  // The bounds the native side holds too (`EntrySenseClick`): a sense ordinal is 1...1,000,000.
  var MAX = 1000000;
  // A `data-xdict-sense` value as an ordinal, or null. Anything but plain digits — a sign, a decimal, whitespace, a
  // forged long string — names no sense.
  function valid(raw) {
    if (typeof raw !== 'string' || !/^[1-9][0-9]{0,6}$/.test(raw)) return null;
    var id = Number(raw);
    return id <= MAX ? id : null;
  }
  // **Exactly one element may carry an ordinal**: a page that repeats or forges `data-xdict-sense` names nothing, and
  // the click is not sent. The canonical text never comes from the DOM; the native side reads it from the core's
  // projection.
  function unique(count) {
    return count === 1;
  }
  // Whether a click selects a sense: the reader's own single primary click, no modifier, nothing selected, and not
  // already taken by the page. A plain click selects; ⌘-click stays the word lookup's (`word-clicks-core.js`).
  function allowed(e, selected) {
    return !!e && e.isTrusted === true && e.button === 0 && e.detail === 1 && !e.metaKey && !e.altKey
      && !e.ctrlKey && !e.shiftKey && !e.defaultPrevented && !selected;
  }
  return { valid: valid, unique: unique, allowed: allowed, MAX: MAX };
})();
