(function () {
  'use strict';
  if (typeof document === 'undefined' || typeof window === 'undefined' || window.__xdictDisclosure) return;
  var SELECTOR = '[data-xdict-control=disclosure]';
  function byId(id) { return document.getElementById(id); }
  function shown(el) {
    return typeof el.checkVisibility === 'function'
      ? el.checkVisibility({ visibilityProperty: true }) : el.getClientRects().length > 0;
  }
  function sync() {
    queued = false;
    var controls = document.querySelectorAll(SELECTOR);
    for (var i = 0; i < controls.length && i < XDictDisclosureCore.MAX; i++) {
      var c = controls[i];
      if (c.tagName !== 'A' && c.tagName !== 'BUTTON' && !c.hasAttribute('role')) c.setAttribute('role', 'button');
    }
    return XDictDisclosureCore.sync(controls, byId, shown);
  }
  var queued = false;
  function later() { if (!queued) { queued = true; setTimeout(sync, 16); } }
  function expand(open) {
    sync();
    var want = open ? 'false' : 'true', clicked = 0;
    var controls = document.querySelectorAll(SELECTOR);
    for (var i = 0; i < controls.length && i < XDictDisclosureCore.MAX; i++) {
      var c = controls[i], href = c.getAttribute('href');
      // A head that is a link elsewhere is followed, not folded: never clicked for the reader.
      if (c.getAttribute('aria-expanded') !== want || (href !== null && href.charAt(0) !== '#')) continue;
      c.click();
      clicked += 1;
    }
    sync();
    return clicked;
  }
  function start() {
    sync();
    new MutationObserver(later).observe(document.documentElement, { subtree: true, childList: true,
      attributes: true, attributeFilter: ['class', 'style', 'hidden', 'open'] });
  }
  document.addEventListener('click', later, true);
  document.addEventListener('transitionend', later, true);
  document.addEventListener('animationend', later, true);
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
  window.addEventListener('load', later, { once: true });
  window.__xdictDisclosure = { sync: sync, expand: expand };
})();
