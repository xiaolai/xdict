(function () {
  'use strict';
  document.addEventListener('click', function (e) {
    if (!e.isTrusted) return;
    var t = e.target, img = t && t.closest ? t.closest('img') : null;
    if (!img || img.closest('a[href]')) return;
    var src = img.currentSrc || img.src || '';
    if (src.indexOf('xdict://d/blocked/') !== 0) return;
    e.preventDefault();
    try { webkit.messageHandlers.xdictEntry.postMessage({ kind: 'blocked-image', url: src }); } catch (x) {}
  }, true);
})();
