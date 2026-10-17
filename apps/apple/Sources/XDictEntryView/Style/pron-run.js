(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictPronRun) return;
  var is = {
    speaker: function (n) { return n.nodeType === 1 && n.getAttribute('data-xdict-control') === 'speaker'; },
    speakers: function (n) { return n.nodeType === 1 && n.hasAttribute('data-xdict-speakers'); },
    phon: function (n) { return n.nodeType === 1 && n.hasAttribute('data-xdict-phon'); },
    blank: function (n) { return n.nodeType === 3 && !/\S/.test(n.nodeValue); }
  };
  var MAX = 2000;
  function inRun(n) { return n.parentNode && n.parentNode.hasAttribute && n.parentNode.hasAttribute('data-xdict-pron-run'); }
  function wrap(r) {
    var w = document.createElement('span');
    w.setAttribute('data-xdict-pron-run', '');
    r.first.parentNode.insertBefore(w, r.first);
    var n = r.first, stop = r.last.nextSibling;
    while (n && n !== stop) { var next = n.nextSibling; w.appendChild(n); n = next; }
  }
  function glue() {
    var speakers = document.querySelectorAll('[data-xdict-control=speaker]'), done = 0;
    for (var i = 0; i < speakers.length && i < MAX; i++) {
      var s = speakers[i];
      if (!s.parentNode || inRun(s)) continue;
      var prev = s.previousSibling;
      while (prev && is.blank(prev)) prev = prev.previousSibling;
      if (prev && is.speaker(prev)) continue;
      var r = XDictPronRunCore.run(s, is);
      if (!r) continue;
      wrap(r);
      done += 1;
    }
    // And a transcription with the speakers after it: a line never breaks between them (PEU, gallery 2026-10-17).
    var phons = document.querySelectorAll('[data-xdict-phon]');
    for (var j = 0; j < phons.length && j < MAX; j++) {
      var p = phons[j];
      if (!p.parentNode || inRun(p)) continue;
      var a = XDictPronRunCore.after(p, is);
      if (!a) continue;
      wrap(a);
      done += 1;
    }
    return done;
  }
  function start() { window.__xdictPronRun = { glued: glue() }; }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
