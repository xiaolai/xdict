(function () {
  'use strict';
  if (window.__xdictFind) return;
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, TEMPLATE: 1, TEXTAREA: 1, SELECT: 1, OPTION: 1, HEAD: 1, TITLE: 1 };
  function inline(display) {
    return display === 'contents' || display.indexOf('inline') === 0 || display.indexOf('ruby') === 0;
  }
  function blockOf(node, cache) {
    var el = node.parentElement;
    while (el && el !== document.body && el !== document.documentElement) {
      var d = cache.get(el);
      if (d === undefined) { d = getComputedStyle(el).display; cache.set(el, d); }
      if (!inline(d)) return el;
      el = el.parentElement;
    }
    return el;
  }
  function visible(el, cache) {
    var v = cache.get(el);
    if (v === undefined) {
      v = typeof el.checkVisibility === 'function'
        ? el.checkVisibility({ visibilityProperty: true })
        : el.getClientRects().length > 0;
      cache.set(el, v);
    }
    return v;
  }
  function read() {
    var displays = new Map(), shown = new Map();
    var runs = { visible: { text: '', nodes: [] }, hidden: { text: '', nodes: [] } };
    var last = { visible: null, hidden: null };
    var root = document.body || document.documentElement;
    if (!root) return runs;
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, {
      acceptNode: function (n) {
        if (n.nodeType === 1) {
          if (SKIP[n.tagName]) return NodeFilter.FILTER_REJECT;
          return n.tagName === 'BR' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
        }
        return n.nodeValue.length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    var n;
    while ((n = walker.nextNode())) {
      if (n.nodeType === 1) {
        runs.visible.text += '\n'; runs.hidden.text += '\n';
        last.visible = null; last.hidden = null;
        continue;
      }
      var parent = n.parentElement;
      if (!parent) continue;
      var kind = visible(parent, shown) ? 'visible' : 'hidden';
      var block = blockOf(n, displays), run = runs[kind];
      if (last[kind] !== null && last[kind] !== block) run.text += '\n';
      last[kind] = block;
      run.nodes.push({ node: n, start: run.text.length });
      run.text += n.nodeValue;
    }
    return runs;
  }
  function locate(nodes, offset) {
    var lo = 0, hi = nodes.length - 1;
    while (lo < hi) {
      var mid = (lo + hi + 1) >> 1;
      if (nodes[mid].start <= offset) lo = mid; else hi = mid - 1;
    }
    return nodes[lo];
  }
  function toRange(nodes, s, e) {
    var a = locate(nodes, s), b = locate(nodes, e - 1), r = document.createRange();
    r.setStart(a.node, Math.min(s - a.start, a.node.nodeValue.length));
    r.setEnd(b.node, Math.min(e - b.start, b.node.nodeValue.length));
    return r;
  }
  var state = { ranges: [], hidden: 0, current: -1 };
  function ensureStyle() {
    if (document.getElementById('xdict-find-style')) return;
    var s = document.createElement('style');
    s.id = 'xdict-find-style';
    // Apple's find (parity P30): the page dimmed, every match a white lozenge, the current one yellow.
    s.textContent = '::highlight(xdict-find){background-color:#ffffff;color:#000}'
      + '::highlight(xdict-find-current){background-color:#ffff00;color:#000}'
      + 'html.xdict-finding,html.xdict-finding body{background-color:color-mix(in srgb,Canvas 78%,#000)!important}';
    (document.head || document.documentElement).appendChild(s);
  }
  function paint() {
    document.documentElement.classList.toggle('xdict-finding', state.ranges.length > 0);
    if (typeof Highlight === 'undefined' || !window.CSS || !CSS.highlights) return;
    CSS.highlights.set('xdict-find', new Highlight(...state.ranges));
    if (state.current >= 0) CSS.highlights.set('xdict-find-current', new Highlight(state.ranges[state.current]));
    else CSS.highlights.delete('xdict-find-current');
  }
  function reveal() {
    var r = state.ranges[state.current];
    var el = r && (r.startContainer.nodeType === 1 ? r.startContainer : r.startContainer.parentElement);
    if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
  }
  function report() { return { visible: state.ranges.length, hidden: state.hidden, current: state.current + 1 }; }
  window.__xdictFind = {
    find: function (query) {
      var runs = read();
      state.ranges = XDictFindCore.matches(runs.visible.text, query).map(function (m) {
        return toRange(runs.visible.nodes, m[0], m[1]);
      });
      state.hidden = XDictFindCore.matches(runs.hidden.text, query).length;
      state.current = state.ranges.length ? 0 : -1;
      ensureStyle(); paint(); reveal();
      return report();
    },
    step: function (forward) {
      if (!state.ranges.length) return report();
      var n = state.ranges.length;
      state.current = (state.current + (forward ? 1 : n - 1)) % n;
      paint(); reveal();
      return report();
    },
    clear: function () {
      state = { ranges: [], hidden: 0, current: -1 };
      document.documentElement.classList.remove('xdict-finding');
      if (window.CSS && CSS.highlights) { CSS.highlights.delete('xdict-find'); CSS.highlights.delete('xdict-find-current'); }
      return report();
    },
    // Edit ▸ Find ▸ Use Selection for Find (⌘E) and Jump to Selection (⌘J), as Apple's Dictionary has them (P33).
    selection: function () { return String(window.getSelection() || ''); },
    jump: function () {
      var s = window.getSelection();
      if (!s || !s.rangeCount) return false;
      var n = s.getRangeAt(0).startContainer, el = n.nodeType === 1 ? n : n.parentElement;
      if (el) el.scrollIntoView({ block: 'center', inline: 'nearest' });
      return !!el;
    }
  };
})();
