(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictWordClicks) return;
  window.__xdictWordClicks = true;
  if (typeof Intl === 'undefined' || !Intl.Segmenter || !document.caretRangeFromPoint) return;
  var segmenter = new Intl.Segmenter(undefined, { granularity: 'word' });
  // What a click inside is the control's or the link's, never a word's.
  var CONTROLS = 'a[href],button,input,select,textarea,label,summary,audio,video,img,svg,[contenteditable],'
    + '[role=button],[role=link],[onclick],[data-xdict-control]';
  var SLOP = 4;
  var down = null;
  window.addEventListener('mousedown', function (e) {
    down = e.isTrusted ? { x: e.clientX, y: e.clientY } : null;
  }, true);
  function selected() {
    var s = window.getSelection();
    return !!s && !s.isCollapsed && String(s).trim() !== '';
  }
  function wordAt(x, y) {
    var caret = document.caretRangeFromPoint(x, y);
    if (!caret || caret.startContainer.nodeType !== 3) return null;
    var node = caret.startContainer, hit = XDictWordCore.at(node.nodeValue || '', caret.startOffset, segmenter);
    if (!hit) return null;
    var range = document.createRange();
    range.setStart(node, hit.start);
    range.setEnd(node, hit.end);
    var rects = range.getClientRects();
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i];
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return hit.word;
    }
    return null;
  }
  // A Command-click on a word opens it in a new tab, once per click. Bubbling, on the window: the page's own
  // handlers have run, and one that took the click has said so.
  window.addEventListener('click', function (e) {
    if (!XDictWordCore.allowed(e, selected())) return;
    if (!down || Math.abs(down.x - e.clientX) > SLOP || Math.abs(down.y - e.clientY) > SLOP) return;
    var t = e.target;
    if (!t || !t.closest || t.closest(CONTROLS)) return;
    var word = wordAt(e.clientX, e.clientY);
    if (!word) return;
    try { webkit.messageHandlers.xdictEntry.postMessage({ kind: 'word', word: word }); } catch (x) {}
  });
})();
