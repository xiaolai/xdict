(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictPronRun) return;
  var is = {
    speaker: function (n) { return n.nodeType === 1 && n.getAttribute('data-xdict-control') === 'speaker'; },
    phon: function (n) { return n.nodeType === 1 && n.hasAttribute('data-xdict-phon'); },
    blank: function (n) { return n.nodeType === 3 && !/\S/.test(n.nodeValue); }
  };
  var MAX = 2000;
  function glue() {
    var speakers = document.querySelectorAll('[data-xdict-control=speaker]'), done = 0;
    for (var i = 0; i < speakers.length && i < MAX; i++) {
      var s = speakers[i];
      if (!s.parentNode || s.parentNode.hasAttribute && s.parentNode.hasAttribute('data-xdict-pron-run')) continue;
      var prev = s.previousSibling;
      while (prev && is.blank(prev)) prev = prev.previousSibling;
      if (prev && is.speaker(prev)) continue;
      var r = XDictPronRunCore.run(s, is);
      if (!r) continue;
      var wrap = document.createElement('span');
      wrap.setAttribute('data-xdict-pron-run', '');
      s.parentNode.insertBefore(wrap, s);
      var n = s, stop = r.last.nextSibling;
      while (n && n !== stop) { var next = n.nextSibling; wrap.appendChild(n); n = next; }
      done += 1;
    }
    return done;
  }
  function start() { window.__xdictPronRun = { glued: glue() }; }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
})();
