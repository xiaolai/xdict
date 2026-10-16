(function () {
  'use strict';
  if (window.__xdictColours) return;
  var BATCH = 200, queue = new Set(), scheduled = false;
  var stats = { mapped: 0, dropped: 0, batches: 0, deferred: 0 };
  var paint = null;
  // Any CSS colour to RGBA through a canvas's own parser; a value it cannot read leaves both sentinels apart.
  function resolve(value) {
    var c = XDictColourCore.parse(value);
    if (c) return c;
    if (!paint) paint = document.createElement('canvas').getContext('2d');
    if (!paint) return null;
    paint.fillStyle = '#000'; paint.fillStyle = value; var a = paint.fillStyle;
    paint.fillStyle = '#fff'; paint.fillStyle = value;
    return a === paint.fillStyle ? XDictColourCore.parse(a) : null;
  }
  function apply(el) {
    var s = el.style;
    if (!el.isConnected || !s || !s.length) return;
    var declarations = [];
    for (var i = 0; i < s.length; i++) declarations.push([s[i], s.getPropertyValue(s[i]), s.getPropertyPriority(s[i])]);
    XDictColourCore.plan(declarations, resolve).forEach(function (a) {
      if (a[0] === 'remove') { s.removeProperty(a[1]); stats.dropped += 1; }
      else { s.setProperty(a[1], a[2], a[3]); stats.mapped += 1; }
    });
  }
  function collect(records) {
    records.forEach(function (r) {
      if (r.type === 'attributes') { if (r.target.nodeType === 1) queue.add(r.target); return; }
      Array.prototype.forEach.call(r.addedNodes, function (n) {
        if (n.nodeType !== 1) return;
        if (n.hasAttribute('style')) queue.add(n);
        if (n.firstElementChild) Array.prototype.forEach.call(n.querySelectorAll('[style]'), function (e) { queue.add(e); });
      });
    });
  }
  var observer = new MutationObserver(function (records) { collect(records); schedule(); });
  function watch() {
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true,
                                                 attributeFilter: ['style'] });
  }
  function run() {
    scheduled = false;
    collect(observer.takeRecords());
    observer.disconnect();
    var n = 0;
    for (var el of queue) {
      queue.delete(el);
      try { apply(el); } catch (e) {}
      if (++n >= BATCH) break;
    }
    stats.batches += 1;
    watch();
    if (queue.size) { stats.deferred += 1; schedule(); }
  }
  function schedule() {
    if (scheduled) return;
    scheduled = true;
    var done = false;
    var once = function () { if (!done) { done = true; run(); } };
    requestAnimationFrame(once);
    setTimeout(once, 100);
  }
  watch();
  window.__xdictColours = { stats: function () { return Object.assign({ queued: queue.size }, stats); } };
})();
