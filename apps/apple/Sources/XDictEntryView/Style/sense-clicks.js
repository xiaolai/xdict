(function () {
  'use strict';
  if (typeof document === 'undefined' || window.__xdictSenseClicks) return;
  window.__xdictSenseClicks = true;
  // What a click inside is the control's or the link's, never a sense's.
  var CONTROLS = 'a[href],button,input,select,textarea,label,summary,audio,video,img,svg,[contenteditable],'
    + '[role=button],[role=link],[onclick],[data-xdict-control]';
  function selected() {
    var s = window.getSelection();
    return !!s && !s.isCollapsed && String(s).trim() !== '';
  }
  // The reader's click on a sense names its ordinal and nothing else: the text is read from the core's projection by
  // the native side, never from this page. The nearest sense ancestor is the innermost one, so a subsense is selected
  // where the reader clicked it.
  window.addEventListener('click', function (e) {
    if (!XDictSenseCore.allowed(e, selected())) return;
    var t = e.target;
    if (!t || !t.closest || t.closest(CONTROLS)) return;
    var el = t.closest('[data-xdict-sense]');
    if (!el) return;
    var id = XDictSenseCore.valid(el.getAttribute('data-xdict-sense'));
    if (id === null) return;
    if (!XDictSenseCore.unique(document.querySelectorAll('[data-xdict-sense="' + id + '"]').length)) return;
    try { webkit.messageHandlers.xdictEntry.postMessage({ kind: 'sense', id: id }); } catch (x) {}
  });
})();
