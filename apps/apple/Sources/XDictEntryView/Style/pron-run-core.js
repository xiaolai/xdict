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
  // A transcription followed by the speakers that play it (PEU's `/ˈraɪdə(r)/<div data-xdict-speakers>…</div>`):
  // the transcription and the last of the speakers, or their box, after it with nothing but space between.
  function after(phon, is) {
    var n = phon.nextSibling, steps = 0, last = null;
    while (n && steps < 32) {
      if (is.speaker(n) || is.speakers(n)) last = n;
      else if (!is.blank(n)) break;
      n = n.nextSibling; steps += 1;
    }
    return last ? { first: phon, last: last } : null;
  }
  return { run: run, after: after };
})();
