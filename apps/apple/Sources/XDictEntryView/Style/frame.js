(function () {
  'use strict';
  var THEME = '{{theme}}', FACE = '{{face}}', HUE = '{{hue}}', SHEETS = [['xdict-frame-tokens', {{sheet-tokens}}],
    ['xdict-frame-column', {{sheet-column}}], ['xdict-frame-type', {{sheet-type}}],
    ['xdict-frame-minimal', {{sheet-minimal}}]];
  var ID = /^xdict-frame-/;
  function sheet(id, text) {
    var s = document.getElementById(id);
    if (!s) { s = document.createElement('style'); s.id = id; }
    if (s.textContent !== text) s.textContent = text;
    // Last in the head. Only another node of the entry's after it moves it: the frame's own sheets
    // following each other is the settled state, so two of them never chase each other to the end.
    var parent = document.head || document.documentElement;
    var after = s.parentNode === parent ? s.nextSibling : parent.firstChild;
    while (after && ID.test(after.id || '')) after = after.nextSibling;
    if (s.parentNode !== parent || after !== null) parent.appendChild(s);
  }
  function install() {
    if (!SHEETS.some(function (s) { return s[1]; })) return;
    var root = document.documentElement;
    if (root.getAttribute('data-xdict-theme') !== THEME) root.setAttribute('data-xdict-theme', THEME);
    if (root.getAttribute('data-xdict-face') !== FACE) root.setAttribute('data-xdict-face', FACE);
    if (root.getAttribute('data-xdict-hue') !== HUE) root.setAttribute('data-xdict-hue', HUE);
    SHEETS.forEach(function (s) { if (s[1]) sheet(s[0], s[1]); });
  }
  // §5.2: each speaker the core marked is a button with a name, set here in the shell's world.
  var NAMES = {{names}};
  function name(root) {
    if (!NAMES.other || !root || !root.querySelectorAll) return;
    root.querySelectorAll('[data-xdict-control=speaker]').forEach(function (a) {
      var label = NAMES[a.getAttribute('data-xdict-accent')] || NAMES.other;
      if (a.getAttribute('aria-label') !== label) a.setAttribute('aria-label', label);
      if (a.getAttribute('role') !== 'button') a.setAttribute('role', 'button');
    });
  }
  // The palette's values in this theme, as computed colours, for the gallery's check that every text colour
  // on the page is one of them.
  var TOKENS = [{{token-names}}];
  function palette() {
    var probe = document.createElement('span'), out = {};
    (document.body || document.documentElement).appendChild(probe);
    TOKENS.forEach(function (t) { probe.style.color = 'var(--xdict-' + t + ')'; out[getComputedStyle(probe).color] = t; });
    probe.remove();
    return out;
  }
  function measure() {
    var colours = {}, families = {}, prose = 0, proseFramed = 0, below = 0, lowest = null, root = document.documentElement;
    var samples = [], leading = [], left = Infinity, right = -Infinity, chars = 0, framed = 0;
    var walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    for (var n = walker.nextNode(); n; n = walker.nextNode()) {
      var t = n.nodeValue.replace(/\s+/g, '');
      if (!t.length || !n.parentElement) continue;
      var r = document.createRange(); r.selectNodeContents(n);
      var rects = r.getClientRects();
      if (!rects.length) continue;
      var pcs = getComputedStyle(n.parentElement);
      samples.push([parseFloat(pcs.fontSize), t.length]);
      var lh = pcs.lineHeight === 'normal' ? 1.2 : parseFloat(pcs.lineHeight) / parseFloat(pcs.fontSize);
      leading.push([Math.round(lh * 20) / 20, t.length]);
      chars += t.length;
      if (/^-apple-system/.test(pcs.fontFamily)) framed += t.length;
      if (!n.parentElement.closest('[data-xdict-phon]')) {
        prose += t.length;
        if (/^-apple-system|^ui-serif/.test(pcs.fontFamily)) proseFramed += t.length;
      }
      families[pcs.fontFamily] = (families[pcs.fontFamily] || 0) + t.length;
      // Computed contrast, not pixels: the text's colour against the first opaque background behind it.
      var fg = XDictReadability.parse(pcs.color), bg = null;
      for (var e = n.parentElement; e && !bg; e = e.parentElement) {
        var c = XDictReadability.parse(getComputedStyle(e).backgroundColor);
        if (c && c[3] >= 0.5) bg = c;
      }
      if (!bg) bg = XDictReadability.parse(getComputedStyle(root).backgroundColor) || [255, 255, 255, 1];
      if (bg[3] < 0.5) bg = [255, 255, 255, 1];
      colours[pcs.color] = colours[pcs.color] || { chars: 0, sample: n.nodeValue.trim().slice(0, 30) + ' <'
        + n.parentElement.tagName.toLowerCase() + (n.parentElement.className ? '.' + String(n.parentElement.className) : '') + '>' };
      colours[pcs.color].chars += t.length;
      if (fg) {
        var ratio = XDictReadability.contrast(fg, bg);
        if (ratio < 4.5) below += t.length;
        if (!lowest || ratio < lowest.ratio) {
          lowest = { ratio: Math.round(ratio * 100) / 100, colour: pcs.color, background: 'rgb(' + bg.slice(0, 3).join(', ') + ')',
                     text: n.nodeValue.trim().slice(0, 40) };
        }
      }
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width < 1) continue;
        left = Math.min(left, rects[i].left); right = Math.max(right, rects[i].right);
      }
    }
    var size = XDictFrameCore.dominant(samples);
    var body = document.body;
    // R13's containment, observed: a fixed probe at `right:0` ends at the body's padding box when the body
    // contains it, at the viewport's right edge otherwise; undecided (null) where the two coincide, as in a
    // window no wider than the column. (`top:0` cannot tell: the body starts at the viewport's top; nor can
    // `bottom:0`: a dictionary's `body{height:100%}` ends it at the viewport's bottom.)
    var contained = null;
    if (body) {
      var probe = document.createElement('div');
      probe.style.cssText = 'position:fixed;right:0;top:0;width:1px;height:1px';
      body.appendChild(probe);
      var bs = getComputedStyle(body), box = body.getBoundingClientRect();
      var inner = box.right - parseFloat(bs.borderRightWidth || '0'), view = root.clientWidth;
      var at = probe.getBoundingClientRect().right;
      probe.remove();
      if (Math.abs(inner - view) >= 1) contained = Math.abs(at - inner) < 1;
    }
    // What "Plain by default" leaves: elements with a background or a border, and images on the page.
    var boxes = 0, kinds = {}, all = body ? body.getElementsByTagName('*') : [];
    for (var j = 0; j < all.length && j < 8000; j++) {
      if (all[j].hasAttribute('data-xdict-icon')) continue;   // the frame's own glyph, drawn as a mask
      var es = getComputedStyle(all[j]), what = '';
      var bg = XDictFrameCore.opaque(es.backgroundColor);
      if (bg || es.backgroundImage !== 'none') what = 'background';
      else if (['Top', 'Right', 'Bottom', 'Left'].some(function (sd) {
        return parseFloat(es['border' + sd + 'Width']) > 0 && es['border' + sd + 'Style'] !== 'none';
      })) what = 'border';
      if (what) { boxes += 1; var k = what + ' ' + all[j].tagName.toLowerCase() + (all[j].className ? '.' + String(all[j].className).split(' ')[0] : ''); kinds[k] = (kinds[k] || 0) + 1; }
    }
    var top = Object.keys(kinds).sort(function (a, b) { return kinds[b] - kinds[a]; }).slice(0, 4)
      .map(function (k) { return k + ' ×' + kinds[k]; });
    var imgs = Array.prototype.filter.call(document.images, function (i) { return i.getClientRects().length > 0; });
    var faces = Object.keys(families).sort(function (a, b) { return families[b] - families[a]; }).slice(0, 4)
      .map(function (f) { return [f, chars ? Math.round(families[f] / chars * 1000) / 1000 : 0]; });
    var tokens = palette();
    var nonToken = Object.keys(colours).filter(function (c) { return !tokens[c]; })
      .map(function (c) { return [c, colours[c].chars, colours[c].sample]; });
    return { colours: Object.keys(colours).map(function (c) { return [c, tokens[c] || null, colours[c].chars]; }),
             nonToken: nonToken, proseFaceShare: prose ? proseFramed / prose : 1, lowestContrast: lowest, below45Share: chars ? below / chars : 0, families: faces, boxes: boxes, boxKinds: top, images: document.images.length, imagesShown: imgs.length,
             leading: XDictFrameCore.dominant(leading),
             dominant: size, left: left, right: root.clientWidth - right, width: root.clientWidth,
             lineChars: size > 0 ? Math.round((right - left) / (size * 0.5)) : 0,
             overflow: root.scrollWidth > root.clientWidth + 1,
             bodyMaxWidth: body ? getComputedStyle(body).maxWidth : '',
             xdictFontShare: chars ? framed / chars : 0, fixedContained: contained };
  }
  // R's inline spacing (coordinator, 2026-10-16): between two words of a line a dictionary's horizontal
  // margins and padding add up to at most SPACE_CAP of the size, so a line's words are set off alike (MW's
  // 1.06em before a part of speech; OALECD's region label, four nested boxes with a margin each; COBUILD's
  // padded links). Nested boxes sharing an edge share the cap: the outermost keeps its spacing first, each
  // inner one what is left. Blocks keep theirs: there it is indentation. XDict's
  // controls, tags, icons and marked boxes (a marker's place) are XDict's already. Reading style only.
  var SPACE_CAP = {{space-cap}}, LABEL = '{{label}}';
  function inline(st) { return st.display === 'inline' || /^inline-/.test(st.display); }
  function edge(e, first) {
    var n = first ? e.previousSibling : e.nextSibling;
    while (n && n.nodeType === 3 && !/\S/.test(n.nodeValue)) n = first ? n.previousSibling : n.nextSibling;
    return !n && e.parentElement && inline(getComputedStyle(e.parentElement));
  }
  function spacing() {
    if (!SPACE_CAP || !document.body) return;
    var all = document.body.getElementsByTagName('*'), mine = '[data-xdict-control],[data-xdict-tag],[data-xdict-icon],[data-xdict-before],[data-xdict-after]';
    for (var i = 0; i < all.length && i < 65536; i++) {
      var e = all[i];
      if (e.tagName === 'IMG' || e.closest(mine)) continue;
      var st = getComputedStyle(e);
      if (!inline(st)) continue;
      // A label owns 0.35em after it (icon sweep §8.4), more than a word's set-off.
      var outerLabel = e.matches(LABEL) && !(e.parentElement && e.parentElement.closest(LABEL));
      var cap = (outerLabel ? Math.max(SPACE_CAP, 0.35) : SPACE_CAP) * parseFloat(st.fontSize);
      [['left', true], ['right', false]].forEach(function (side) {
        var m = Math.max(0, parseFloat(st.getPropertyValue('margin-' + side[0])));
        var p = Math.max(0, parseFloat(st.getPropertyValue('padding-' + side[0])));
        // What the boxes around it already put at this edge, the parent first in document order.
        var outside = edge(e, side[1]) ? (e.parentElement.__xdictSpace || {})[side[0]] || 0 : 0;
        var room = Math.max(0, cap - outside), np = Math.min(p, room), nm = Math.min(m, room - np);
        if (np < p - 0.5) e.style.setProperty('padding-' + side[0], np + 'px', 'important');
        if (nm < m - 0.5) e.style.setProperty('margin-' + side[0], nm + 'px', 'important');
        (e.__xdictSpace = e.__xdictSpace || {})[side[0]] = outside + np + nm;
      });
    }
  }
  // The browser's own bullet on a list item (MWU's homograph strip) is XDict's marker, as a bullet the
  // dictionary draws is (the core marks those). A list the dictionary marks itself, its own ::before
  // drawing, is left alone, so nothing gets two. Reading style only.
  function bullets() {
    // Only once the dictionary's sheets apply (`load`): before, every item reads the browser's default disc,
    // and COBUILD-EC's examples, which its sheet sets `list-style:none`, got a marker they never show.
    if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;
    Array.prototype.forEach.call(document.body.getElementsByTagName('li'), function (li, i) {
      if (i > 65536 || li.hasAttribute('data-xdict-before') || !li.getClientRects().length) return;
      var st = getComputedStyle(li), mk = getComputedStyle(li, '::marker');
      if (st.display !== 'list-item' || !/^(disc|circle|square)$/.test(st.listStyleType) || st.listStyleImage !== 'none') return;
      if (!(parseFloat(mk.fontSize) > 0) || st.visibility === 'hidden') return;
      var own = getComputedStyle(li, '::before').content;
      if (own && own !== 'none' && own !== 'normal') return;
      li.setAttribute('data-xdict-before', 'marker');
    });
  }
  // A bullet the dictionary wrote as text, with nothing after it in its block (NOAD's phrase block opens with
  // `<div class="m1"><div class="opt">•</div></div>`, a dot alone on a line): it marks nothing, so the reading style
  // does not draw it. Its block is marked, never removed; `marks.css` hides it. Reading style only.
  var GLYPHS = /^[\u2022\u25E6\u25AA\u25A0\u25A1\u25CF\u25CB\u25C6\u25C7\u2023]+$/;
  function loneBullets() {
    if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;
    var all = document.body.getElementsByTagName('*');
    for (var i = 0; i < all.length && i < 65536; i++) {
      var e = all[i];
      if (e.hasAttribute('data-xdict-lone-bullet') || !/^(block|list-item|flow-root)$/.test(getComputedStyle(e).display)) continue;
      if (GLYPHS.test((e.innerText || '').replace(/\s+/g, '')) && !e.querySelector('img,svg,video,canvas')) {
        e.setAttribute('data-xdict-lone-bullet', '');
      }
    }
  }
  install();
  function start() { install(); name(document); bullets(); loneBullets(); spacing(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true });
  else start();
  window.addEventListener('load', start, { once: true });
  // A page script can remove or rewrite the frame's stylesheets or the theme; they come back, at most once
  // per change.
  new MutationObserver(function (records) {
    var hit = records.some(function (r) {
      if (r.type === 'attributes' && r.target === document.documentElement) return true;
      var gone = Array.prototype.some.call(r.removedNodes, function (n) { return ID.test(n.id || ''); });
      var t = r.target.nodeType === 1 ? r.target : r.target.parentElement;
      return gone || (t && ID.test(t.id || ''));
    });
    if (hit) install();
    records.forEach(function (r) {
      Array.prototype.forEach.call(r.addedNodes, function (n) { if (n.nodeType === 1) name(n.parentNode || n); });
    });
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
                                          attributeFilter: ['media', 'disabled', 'id', 'data-xdict-theme', 'data-xdict-face', 'data-xdict-hue'] });
  window.__xdictFrame = { measure: measure };
})();
