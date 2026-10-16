var XDictDisclosureCore = (function () {
  'use strict';
  var MAX = 2000;
  function target(control, byId) {
    var id = control.getAttribute('aria-controls');
    if (id) { var named = byId(id); if (named) return named; }
    for (var e = control, up = 0; e && up < 3; e = e.parentElement, up++) {
      if (e.nextElementSibling) return e.nextElementSibling;
    }
    return null;
  }
  function sync(controls, byId, shown) {
    var changed = 0;
    for (var i = 0; i < controls.length && i < MAX; i++) {
      var c = controls[i], t = target(c, byId);
      if (!t) continue;
      var v = shown(t) ? 'true' : 'false';
      if (c.getAttribute('aria-expanded') !== v) { c.setAttribute('aria-expanded', v); changed += 1; }
    }
    return changed;
  }
  return { MAX: MAX, target: target, sync: sync };
})();
