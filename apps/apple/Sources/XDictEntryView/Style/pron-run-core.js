var XDictPronRunCore = (function () {
  'use strict';
  function run(speaker, is) {
    var n = speaker.nextSibling, steps = 0;
    while (n && steps < 32) {
      if (is.phon(n)) return { first: speaker, last: n };
      if (!is.blank(n) && !is.speaker(n)) return null;
      n = n.nextSibling; steps += 1;
    }
    return null;
  }
  return { run: run };
})();
