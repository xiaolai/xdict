(function () {
  'use strict';
  window.addEventListener('click', function (e) {
    var t = e.target, c = t && t.closest ? t.closest('a[href][data-xdict-control="speaker"]') : null;
    if (c) e.stopImmediatePropagation();
  }, true);
})();
