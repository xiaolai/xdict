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
  // **The chosen sense, marked where it is** (HIG audit UI21): the shell's own attribute, drawn by `marks.css`, and
  // `aria-current` so VoiceOver names it. The native side marks what the session holds; a page's own attributes are
  // never read back as a choice.
  var chosen = null;
  function unmark() {
    var marked = document.querySelectorAll('[data-xdict-chosen]');
    for (var i = 0; i < marked.length; i++) {
      marked[i].removeAttribute('data-xdict-chosen');
      marked[i].removeAttribute('aria-current');
    }
  }
  function mark(id) {
    unmark();
    chosen = null;
    if (typeof id !== 'number' || XDictSenseCore.valid(String(id)) === null) return null;
    var els = document.querySelectorAll('[data-xdict-sense="' + id + '"]');
    if (!XDictSenseCore.unique(els.length)) return null;
    els[0].setAttribute('data-xdict-chosen', '');
    els[0].setAttribute('aria-current', 'true');
    chosen = id;
    if (els[0].scrollIntoView) els[0].scrollIntoView({ block: 'nearest' });
    return id;
  }
  // The page's valid, unique ordinals, in document order.
  function ids() {
    var all = document.querySelectorAll('[data-xdict-sense]'), seen = {}, out = [];
    for (var i = 0; i < all.length; i++) {
      var id = XDictSenseCore.valid(all[i].getAttribute('data-xdict-sense'));
      if (id === null) continue;
      seen[id] = (seen[id] || 0) + 1;
      if (seen[id] === 1) out.push(id);
    }
    return out.filter(function (id) { return seen[id] === 1; });
  }
  window.__xdictSense = {
    mark: mark,
    // The next or previous sense's ordinal, or null: the native side selects it as it would a click.
    step: function (delta) { return XDictSenseCore.step(ids(), chosen, delta); }
  };
})();
