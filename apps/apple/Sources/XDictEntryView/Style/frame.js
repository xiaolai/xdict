(function () {
  'use strict';
  var THEME = '{{theme}}', FACE = '{{face}}', HUE = '{{hue}}', DENSITY = '{{density}}', SHEETS = [['xdict-frame-tokens', {{sheet-tokens}}],
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
    if (root.getAttribute('data-xdict-density') !== DENSITY) root.setAttribute('data-xdict-density', DENSITY);
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
  // G14 (owner, 2026-10-17): a list level whose items show no number or bullet starts flush; one with a visible
  // marker indents 1.5em (column.css, `data-xdict-list`). A marker is XDict's dot, a rendered list style, generated
  // content before the item, or the dictionary's own number or bullet as the item's first visible box.
  var NUMBER = /^(\(?[0-9]{1,3}[.)]?|\(?[a-z][.)]|\(?[ivx]{1,4}[.)]|[•◦▪■□●○◆◇‣·*–-])$/i;
  function drawn(e) {
    var p = getComputedStyle(e, '::before'), c = p.content;
    return p.display !== 'none' && !!c && c !== 'none' && c !== 'normal' && c !== '""';
  }
  function marked(li) {
    if (li.getAttribute('data-xdict-before') === 'marker') return true;
    var st = getComputedStyle(li);
    // A list style counts when its marker draws: OALD's single sense hides the `ol`'s number (`::marker` at 0).
    if (st.display === 'list-item' && (st.listStyleType !== 'none' || st.listStyleImage !== 'none')
        && parseFloat(getComputedStyle(li, '::marker').fontSize) > 0) return true;
    if (drawn(li)) return true;
    for (var c = li.firstElementChild, k = 0; c && k < 3; c = c.firstElementChild, k++) {
      if (drawn(c) || NUMBER.test((c.textContent || '').trim())) return true;
    }
    return false;
  }
  function lists() {
    if (!document.body) return;
    var all = document.body.querySelectorAll('ul,ol');
    for (var i = 0; i < all.length && i < 4096; i++) {
      var items = Array.prototype.filter.call(all[i].children, function (x) { return x.tagName === 'LI'; });
      var v = items.some(marked) ? 'marked' : 'plain';
      if (all[i].getAttribute('data-xdict-list') !== v) all[i].setAttribute('data-xdict-list', v);
    }
  }
  // R16's classes (WI-11, 2026-10-17): each shown image is classed once its pixels are in (`data-xdict-img`,
  // `XDictFrameCore.imageClass`), from its natural size, whether it sits in a table cell, floats, or has text beside it
  // on its line; column.css treats each class. Transparency and monochrome are read from its pixels (a same-origin
  // `xdict:` image draws into a canvas; a tainted one is judged by its type, and never inverted). An image the
  // dictionary hides, a control's, or one the core replaced with a label is left alone. Reading style only.
  function holder(img) {
    var node = img;
    while (node.parentElement && node.parentElement !== document.body && inline(getComputedStyle(node.parentElement))
           && !/\S/.test(node.parentElement.textContent)) node = node.parentElement;
    return node;
  }
  function besideText(node) {
    var parent = node.parentElement;
    return !!parent && Array.prototype.some.call(parent.childNodes, function (c) {
      if (c === node) return false;
      if (c.nodeType === 3) return /\S/.test(c.nodeValue);
      return c.nodeType === 1 && c.getClientRects().length > 0 && inline(getComputedStyle(c)) && /\S/.test(c.textContent);
    });
  }
  function pixels(img) {
    try {
      var c = document.createElement('canvas'), w = c.width = Math.min(64, img.naturalWidth), h = c.height = Math.min(64, img.naturalHeight);
      var g = c.getContext('2d'); g.drawImage(img, 0, 0, w, h);
      var d = g.getImageData(0, 0, w, h).data, alpha = false, mono = true, any = false;
      for (var i = 0; i < d.length; i += 4) {
        if (d[i + 3] < 250) alpha = true;
        if (d[i + 3] > 40) { any = true; if (Math.max(d[i], d[i + 1], d[i + 2]) - Math.min(d[i], d[i + 1], d[i + 2]) > 40) mono = false; }
      }
      return { alpha: alpha, mono: mono && any };
    } catch (err) {
      return { alpha: /\.(png|gif|svg)(\?|#|$)|^data:image\/(png|gif|svg)/i.test(img.currentSrc || img.src || ''), mono: false };
    }
  }
  function classImage(img) {
    // A blocked image's placeholder is ADR-0009's (`xdict://d/blocked/`), drawn as it is.
    if (/^xdict:\/\/d\/blocked\//.test(img.currentSrc || img.src || '')) return;
    if (img.hasAttribute('data-xdict-img') || !img.complete || !img.getClientRects().length
        || img.closest('[data-xdict-control],[data-xdict-icon],[data-xdict-labelled]')) return;
    var st = getComputedStyle(img), node = holder(img), box = null, boxes = [];
    // A picture container that floats, holding no text, floats the picture; every such container up to the first box
    // with text counts (OALECD nests two: `ill-g` and `.pic_thumb`), the outermost giving the side.
    for (var a = node.parentElement; a && a !== document.body; a = a.parentElement) {
      var as = getComputedStyle(a);
      if (/\S/.test(a.textContent)) break;
      if (as.float !== 'none') { box = a; boxes.push(a); }
    }
    var kind = XDictFrameCore.imageClass({ w: img.naturalWidth, h: img.naturalHeight, table: !!img.closest('td,th'),
      floated: st.float !== 'none' || !!box, text: inline(st) && besideText(node) });
    if (!kind) return;
    if (kind === 'badge' || kind === 'icon') {
      // On the element itself: a size the dictionary wrote on the image (ODE's ornament) must not outrank it.
      var em = parseFloat(getComputedStyle(img.parentElement || document.body).fontSize);
      img.style.setProperty('height', (kind === 'badge' ? 1 : 1.25) * em + 'px', 'important');
      img.style.setProperty('width', 'auto', 'important');
      ['min-width', 'min-height'].forEach(function (p) { img.style.setProperty(p, '0', 'important'); });
      img.style.setProperty('padding', '0', 'important');
    }
    // An inline box holding only the picture becomes a block with it, so its margins are a block's (a block inside
    // an inline box collapses its margins unlike one in a block, and the space came out wrong in ODECN's narrow pane).
    for (var hb = img.parentElement; hb && hb !== node.parentElement && hb !== document.body; hb = hb.parentElement) {
      hb.setAttribute('data-xdict-img-holder', kind);
    }
    if (kind === 'float') boxes.forEach(function (b) { b.setAttribute('data-xdict-float-box', ''); });
    if (kind === 'float') {
      var fs = box ? getComputedStyle(box) : st, ltr = fs.direction !== 'rtl', side = fs.float;
      img.setAttribute('data-xdict-side', side === 'inline-start' || side === (ltr ? 'left' : 'right') ? 'start' : 'end');
      for (var b = (box || img).parentElement; b && b !== document.body; b = b.parentElement) {
        if (getComputedStyle(b).display === 'block') { b.setAttribute('data-xdict-clears', ''); break; }
      }
    }
    var px = pixels(img);
    if (px.alpha) img.setAttribute('data-xdict-alpha', '');
    if (px.mono) img.setAttribute('data-xdict-mono', '');
    if (kind === 'illustration' || kind === 'inline') {
      var next = node.nextElementSibling || (node.parentElement && node.parentElement.children.length === 1 ? node.parentElement.nextElementSibling : null);
      if (next && (next.tagName === 'FIGCAPTION' || /caption/i.test(typeof next.className === 'string' ? next.className : '')) && /\S/.test(next.textContent)) {
        next.setAttribute('data-xdict-caption', '');
        img.setAttribute('data-xdict-captioned', '');
      }
    }
    img.setAttribute('data-xdict-img', kind);
  }
  function images() {
    if (!SPACE_CAP || !document.body) return;
    Array.prototype.forEach.call(document.body.getElementsByTagName('img'), function (img, i) {
      if (i > 4096) return;
      if (!img.complete && !img.__xdictWaits) {
        img.__xdictWaits = true;
        img.addEventListener('load', function () { classImage(img); later(); }, { once: true });
      }
      classImage(img);
    });
  }
  // The pictures a dictionary hides itself (owner, 2026-10-17): kept hidden, gathered under one XDict fold at the
  // end of the entry, "Pictures (n)", closed by default; opened, each is an illustration (column.css). Only an
  // illustration its own sheet hides, on itself or on a picture container with no text (`XDictFrameCore.gatherable`);
  // a missing one (no pixels) is never counted. The dictionary's own copy stays where it was, hidden. Reading style only.
  var PICTURES = {{pictures}};
  function hider(img) {
    var top = null;
    for (var e = img; e && e !== document.body; e = e.parentElement) {
      var st = getComputedStyle(e), up = e.parentElement ? getComputedStyle(e.parentElement) : null;
      if (st.display === 'none' || (st.visibility === 'hidden' && (!up || up.visibility !== 'hidden'))) top = e;
    }
    return top;
  }
  function pictures() {
    if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;
    var seen = {}, found = [];
    Array.prototype.forEach.call(document.body.getElementsByTagName('img'), function (img, i) {
      if (i > 4096 || img.closest('#xdict-pictures') || img.getClientRects().length) return;
      if (!img.complete) {
        if (!img.__xdictWaits) { img.__xdictWaits = true; img.addEventListener('load', later, { once: true }); }
        return;
      }
      var h = hider(img), src = img.currentSrc || img.src;
      var hidden = !h ? '' : h === img ? 'image' : /\S/.test(h.textContent) ? 'text' : 'container';
      if (seen[src] || !XDictFrameCore.gatherable({ w: img.naturalWidth, h: img.naturalHeight, hidden: hidden,
          control: !!img.closest('[data-xdict-control],[data-xdict-icon],[data-xdict-labelled]') })) return;
      seen[src] = true;
      found.push(img);
    });
    var fold = document.getElementById('xdict-pictures');
    if (fold && +fold.getAttribute('data-count') === found.length) return;
    if (fold) fold.remove();
    if (!found.length) return;
    fold = document.createElement('div');
    fold.id = 'xdict-pictures';
    fold.setAttribute('data-count', String(found.length));
    var head = document.createElement('div'), list = document.createElement('div');
    head.setAttribute('data-xdict-control', 'disclosure');
    head.setAttribute('role', 'button');
    head.setAttribute('tabindex', '0');
    head.setAttribute('aria-expanded', 'false');
    head.setAttribute('aria-controls', 'xdict-pictures-body');
    head.textContent = PICTURES + ' (' + found.length + ')';
    list.id = 'xdict-pictures-body';
    list.hidden = true;
    found.forEach(function (img) {
      // A copy of the image the dictionary wrote, its own URL only: no shell script writes a URL (ReadingTests).
      var c = img.cloneNode(false);
      Array.prototype.slice.call(c.attributes).forEach(function (a) {
        if (!/^(src|srcset|alt)$/.test(a.name)) c.removeAttribute(a.name);
      });
      list.appendChild(c);
    });
    function toggle() { list.hidden = !list.hidden; head.setAttribute('aria-expanded', list.hidden ? 'false' : 'true'); }
    head.addEventListener('click', toggle);
    head.addEventListener('keydown', function (ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); toggle(); } });
    fold.appendChild(head);
    fold.appendChild(list);
    document.body.appendChild(fold);
  }
  // R7a (WI-11, 2026-10-17): space by role. Each role-marked block that starts a line (and each block image) is
  // marked with its space (`data-xdict-space`, `XDictFrameCore.spaceOf`); on it the margin that makes the gap from the
  // content before it (that content's last line box, or its border box) its token, `type.css`'s: the dictionary's
  // margins on either side collapse with it, so the margin is measured, then corrected (`nextMargin`). A block after
  // a heading is the heading's (`after-heading`); one after a block image at least the image's. A block first in the
  // entry, in a box with a top edge, or in a spaced block, takes none: its box's edge, or the block's gap, is its gap.
  // A role inline in a line (OED's and PEU's run-on senses) is not touched. The margin is a custom property on the
  // element (`--xdict-space-at`) that type.css's !important top margin reads: a margin written straight into the style
  // attribute did not take on ODECN's floats against the frame's own !important margins (measured 2026-10-17), and
  // one rule on the sheet's side keeps a single source for the top margin. Reading style only.
  var SPACES = ['sense', 'example', 'translation', 'subhead', 'heading', 'phrase', 'pos', 'after-heading', 'image'];
  function blockish(st) { return /^(block|list-item|flow-root|table|flex|grid)$/.test(st.display) && st.float === 'none' && !/absolute|fixed/.test(st.position); }
  function rendered(n) {
    if (n.nodeType === 3) { if (!/\S/.test(n.nodeValue)) return false; var r = document.createRange(); r.selectNodeContents(n); return r.getClientRects().length > 0; }
    if (n.nodeType !== 1 || !n.getClientRects().length) return false;
    var st = getComputedStyle(n);
    // An empty block of no height is no content: margins collapse through it (MED's empty related-entries container).
    return st.float === 'none' && !/absolute|fixed/.test(st.position) && !(blockish(st) && n.getBoundingClientRect().height === 0);
  }
  function before(e) {
    for (var n = e; n && n !== document.body; n = n.parentElement) {
      for (var s = n.previousSibling; s; s = s.previousSibling) if (rendered(s)) return s;
      var p = n.parentElement;
      if (!p || p === document.body || p.hasAttribute('data-xdict-space')) return null;
      var ps = getComputedStyle(p);
      if (inline(ps)) continue;
      if (!/^(block|list-item)$/.test(ps.display) || ps.overflow !== 'visible' || parseFloat(ps.paddingTop) > 0
          || parseFloat(ps.borderTopWidth) > 0) return null;
    }
    return null;
  }
  function bottom(n) {
    var rects, parent = n.nodeType === 3 ? n.parentElement : n;
    // An inline box ends where its last content does: one holding blocks (PEU's inline list items around block
    // examples) also has empty fragments after them, which sit at the next block's top and made every gap 0.
    if (n.nodeType === 1 && getComputedStyle(n).display === 'inline') {
      for (var c = n.lastChild; c; c = c.previousSibling) if (rendered(c)) return bottom(c);
    }
    // A run of text is measured by its line; an inline-block is a box (MED's slideshow), measured by its border box.
    if (n.nodeType === 3 || getComputedStyle(n).display === 'inline') {
      var r = document.createRange(); r.selectNodeContents(n); rects = r.getClientRects();
      if (!rects.length) return n.nodeType === 1 ? n.getBoundingClientRect().bottom : 0;
      // The lowest fragment, not the last: a block inside an inline box (ODECN's inline `div`) ends below its text.
      var last = Array.prototype.reduce.call(rects, function (x, y) { return y.height > 0 && y.bottom > x.bottom ? y : x; }, rects[0]);
      var ps = getComputedStyle(parent), lh = parseFloat(ps.lineHeight);
      return last.bottom + (isNaN(lh) ? 0 : Math.max(0, (lh - last.height) / 2));
    }
    return n.getBoundingClientRect().bottom;
  }
  // The blocks that end `n` with their bottom margins adjoining what follows it: `n` itself when a block, then its last
  // content, down through inline boxes and through blocks with no bottom padding or border and visible overflow.
  function ends(n) {
    while (n && n.nodeType === 1) {
      var st = getComputedStyle(n);
      if (!inline(st)) {
        if (!/^(block|list-item)$/.test(st.display) || st.float !== 'none') return;
        n.setAttribute('data-xdict-space-end', '');
        if (st.overflow !== 'visible' || parseFloat(st.paddingBottom) > 0 || parseFloat(st.borderBottomWidth) > 0) return;
      }
      var c = n.lastChild;
      while (c && !rendered(c)) c = c.previousSibling;
      n = c;
    }
  }
  function inInline(e) {
    for (var a = e.parentElement; a && a !== document.body; a = a.parentElement) if (inline(getComputedStyle(a))) return true;
    return false;
  }
  function headingBefore(p) {
    if (!p || p.nodeType !== 1) return false;
    if (p.getAttribute('data-xdict-role') === 'heading') return true;
    var h = p.querySelector('[data-xdict-role=heading]');
    return !!h && h.textContent.trim() === p.textContent.trim();
  }
  function roleSpace() {
    if (!SPACE_CAP || !document.body) return;
    var body = document.body, probe = document.createElement('div'), px = {};
    probe.style.cssText = 'position:absolute;visibility:hidden;margin:0;padding:0';
    body.appendChild(probe);   // the body's em
    SPACES.forEach(function (n) { probe.style.height = 'var(--xdict-space-' + n + ')'; px[n] = parseFloat(getComputedStyle(probe).height) || 0; });
    probe.remove();
    Array.prototype.forEach.call(body.querySelectorAll('[data-xdict-space]'), function (e) {
      e.removeAttribute('data-xdict-space'); e.removeAttribute('data-xdict-space-by'); e.style.removeProperty('--xdict-space-at');
    });
    Array.prototype.forEach.call(body.querySelectorAll('[data-xdict-space-end]'), function (e) { e.removeAttribute('data-xdict-space-end'); });
    var spaced = [];
    Array.prototype.forEach.call(body.querySelectorAll('[data-xdict-role],img[data-xdict-img]'), function (e, i) {
      if (i > 65536 || e.closest('[data-xdict-control]') || !e.getClientRects().length) return;
      var st = getComputedStyle(e);
      var name = e.tagName === 'IMG' ? (st.display === 'block' && st.float === 'none' ? 'image' : '')
        : XDictFrameCore.spaceOf(e.getAttribute('data-xdict-role'), e.getAttribute('data-xdict-section'),
            !!(e.parentElement && e.parentElement.closest('li,[data-xdict-role=sense]')));
      // A block picture is spaced by its outermost holder, a block with it (`data-xdict-img-holder`).
      if (name === 'image') {
        for (var up = e.parentElement; up && up.hasAttribute('data-xdict-img-holder'); up = up.parentElement) e = up;
        st = getComputedStyle(e);
      }
      if (!name || !blockish(st)) return;
      e.setAttribute('data-xdict-space', name);
      // WebKit does not honour a top margin that reaches through a block inside an inline box (PEU's examples, blocks
      // in blocks in inline list items): the gap stayed 0 whatever the margin. Such a block is padded instead.
      if (inInline(e)) e.setAttribute('data-xdict-space-by', 'padding');
      spaced.push(e);
    });
    var want = spaced.map(function (e) {
      var p = before(e), name = e.getAttribute('data-xdict-space');
      if (!p) return null;
      var w = headingBefore(p) && name !== 'image' ? px['after-heading'] : px[name];
      if (p.nodeType === 1 && p.getAttribute('data-xdict-space') === 'image') w = Math.max(w, px.image);
      // A padded block's gap can only grow: a bottom margin that ends the content before it (OALD's examples list, the
      // last block of the idiom before; `type.css`'s list margin) collapses out of that content's box into the gap, and
      // no padding takes it back (D45: 16 px for 12). The blocks that end that content and whose bottom margins adjoin
      // the gap give theirs up (`data-xdict-space-end`, column.css); the padding then makes the whole gap.
      if (e.hasAttribute('data-xdict-space-by')) ends(p);
      return { prev: p, want: w };
    });
    var margin = spaced.map(function (e, i) { return want[i] ? want[i].want : 0; });
    spaced.forEach(function (e, i) {
      e.style.setProperty('--xdict-space-at', margin[i] + 'px');
    });
    // Up to four rounds: the collapse rule's step first, then the step the last two measurements show (a margin that
    // does not adjoin the one before moves the gap one for one); the margin that came nearest is kept.
    var last = spaced.map(function () { return null; }), best = spaced.map(function () { return null; });
    // A padded block's gap runs to its padding's end, where its content starts; a padding is never negative.
    function top(e) { return e.getBoundingClientRect().top + (e.hasAttribute('data-xdict-space-by') ? parseFloat(getComputedStyle(e).paddingTop) || 0 : 0); }
    for (var round = 0; round < 4; round++) {
      var gaps = spaced.map(function (e, i) { return want[i] ? top(e) - bottom(want[i].prev) : 0; });
      var moved = false;
      spaced.forEach(function (e, i) {
        if (!want[i]) return;
        var err = Math.abs(gaps[i] - want[i].want);
        if (!best[i] || err < best[i][1]) best[i] = [margin[i], err];
        if (err <= 0.5) return;
        var m = round === 0 ? XDictFrameCore.nextMargin(margin[i], gaps[i], want[i].want) : margin[i] + (want[i].want - gaps[i]);
        if (e.hasAttribute('data-xdict-space-by')) m = Math.max(0, margin[i] + (want[i].want - gaps[i]));
        if (last[i] && Math.abs(gaps[i] - last[i][1]) < 0.25 && Math.abs(margin[i] - last[i][0]) > 0.5) return;   // the margin does not move it
        last[i] = [margin[i], gaps[i]];
        margin[i] = m;
        e.style.setProperty('--xdict-space-at', m + 'px');
        moved = true;
      });
      if (!moved) break;
    }
    var finalGaps = spaced.map(function (e, i) { return want[i] ? top(e) - bottom(want[i].prev) : 0; });
    spaced.forEach(function (e, i) {
      if (!want[i] || !best[i] || Math.abs(finalGaps[i] - want[i].want) <= best[i][1]) return;
      e.style.setProperty('--xdict-space-at', best[i][0] + 'px');
    });
  }
  // D47: a dot placed from its item's top follows the padding the spacing put above the item's first line (OALD's idiom
  // heads, padded because they are blocks in an inline span), `--xdict-marker-drop` in marks.css. Reading style only.
  function markerDrops() {
    if (!SPACE_CAP || !document.body) return;
    Array.prototype.forEach.call(document.body.querySelectorAll('[data-xdict-before=marker]'), function (m, i) {
      if (i > 65536) return;
      m.style.removeProperty('--xdict-marker-drop');
      var d = m.hasAttribute('data-xdict-space-by') ? m : m.querySelector('[data-xdict-space-by]');
      if (!d || !m.getClientRects().length) return;
      var drop = XDictFrameCore.markerDrop({ padded: true, first: d === m || firstIn(m, d),
        contentTop: d.getBoundingClientRect().top + d.clientTop + (parseFloat(getComputedStyle(d).paddingTop) || 0),
        markerTop: m.getBoundingClientRect().top + m.clientTop });
      if (drop > 0) m.style.setProperty('--xdict-marker-drop', drop + 'px');
    });
  }
  // D46: a height cap its text does not fit in is lifted (`XDictFrameCore.lifts`). Reading style only.
  function overflows() {
    if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;
    var all = document.body.getElementsByTagName('*');
    for (var i = 0; i < all.length && i < 65536; i++) {
      var e = all[i], st = getComputedStyle(e);
      if (st.maxHeight === 'none' || inline(st)) continue;
      if (XDictFrameCore.lifts({ maxHeight: st.maxHeight, overflow: st.overflowY, content: e.scrollHeight, box: e.clientHeight })) {
        e.style.setProperty('max-height', 'none', 'important');
        if (st.overflowY !== 'visible') e.style.setProperty('overflow-y', 'visible', 'important');
      }
    }
  }
  // The nearest block around an element: its line's box.
  function blockOf(e) {
    for (var b = e.parentElement; b && b !== document.body; b = b.parentElement) if (!inline(getComputedStyle(b))) return b;
    return document.body;
  }
  // Whether nothing drawn comes before `e` in its block `b`: no text, no picture (an empty anchor is nothing).
  function firstIn(b, e) {
    for (var n = e; n && n !== b; n = n.parentElement) {
      for (var s = n.previousSibling; s; s = s.previousSibling) {
        if (!rendered(s)) continue;
        if (s.nodeType === 3 || /\S/.test(s.textContent) || s.tagName === 'IMG' || s.querySelector('img')) return false;
      }
    }
    return true;
  }
  // Whether nothing follows `n` on its line in its block `b`: the text after it starts on a later line (MED's number
  // before its definition's block, which hung went under the definition's last line).
  function lineAlone(n, b) {
    var r = document.createRange(), nb = n.getBoundingClientRect();
    r.setStartAfter(n);
    r.setEnd(b, b.childNodes.length);
    var rects = r.getClientRects();
    for (var i = 0; i < rects.length; i++) if (rects[i].width > 0) return rects[i].top >= nb.bottom - 1;
    return true;
  }
  // Parity P22 (2026-10-18): Apple hangs a sense number in a 1em negative indent. A number the core names that starts
  // its block (`XDictFrameCore.hangs`) moves 1em out and its block's text 1em in from the dictionary's own inset, both
  // in em, so they follow the text size; a number inside a line keeps its place. Reading style only.
  function hang() {
    // Once the dictionary's sheets apply (`load`), as `bullets`: its own inset is read then.
    if (!SPACE_CAP || !document.body || document.readyState !== 'complete') return;
    // The number's 1em is its block's: written as a ratio of the number's own size, measured again at each run, since
    // the sizes settle only once the dictionary's sheets and the frame's apply (a ratio read early left COBUILD's 1 px off).
    function hangMeasure(n, b) {
      var em = parseFloat(getComputedStyle(b).fontSize) || 16, nem = parseFloat(getComputedStyle(n).fontSize) || em;
      var v = em / nem + 'em';
      if (n.style.getPropertyValue('--xdict-hang') !== v) n.style.setProperty('--xdict-hang', v);
    }
    Array.prototype.forEach.call(document.body.querySelectorAll('[data-xdict-sure=sensenum]'), function (n, i) {
      if (i > 4096 || !n.getClientRects().length) return;
      if (n.hasAttribute('data-xdict-hung')) { hangMeasure(n, blockOf(n)); return; }
      if (n.parentElement && n.parentElement.closest('[data-xdict-sure=sensenum]')) return;
      var b = blockOf(n), bs = getComputedStyle(b), ns = getComputedStyle(n);
      if (b.hasAttribute('data-xdict-hang')) return;
      // A number the dictionary sets in a table's column (ODECN's `display:table-cell`) is hung by its own layout.
      var facts = { sure: true, first: firstIn(b, n), body: b === document.body, cell: bs.display === 'table-cell',
                    floated: ns.float !== 'none' || /absolute|fixed/.test(ns.position), alone: !inline(ns) || lineAlone(n, b),
                    own: parseFloat(bs.textIndent) < 0 || parseFloat(ns.marginLeft) < 0 || /^table/.test(ns.display)
                      || /^table/.test(bs.display) };
      if (!XDictFrameCore.hangs(facts)) return;
      var em = parseFloat(bs.fontSize) || 16;
      b.style.setProperty('--xdict-hang-pad', (parseFloat(bs.paddingLeft) || 0) / em + 'em');
      b.setAttribute('data-xdict-hang', '');
      n.setAttribute('data-xdict-hung', '');
      hangMeasure(n, b);
    });
  }
  // D37 (2026-10-20): the entry's top-level container takes no start margin: the page's padding is the text's edge,
  // as Apple draws it. A child's own negative start margin that cancelled it for a row of its own (OALD's
  // `.top-container` over `.entry{margin-left:22px}`) goes with it, or that row hangs outside the page. Reading
  // style only: Original style keeps the dictionary's own layout.
  function entryInset() {
    if (!SPACE_CAP || !document.body) return;
    function start(el) {
      var cs = getComputedStyle(el), v = cs.marginInlineStart;
      return parseFloat(v !== '' && v !== 'auto' ? v : cs.marginLeft) || 0;
    }
    function zero(el) {
      if (el.getAttribute('data-xdict-inset') === 'zero') return;
      el.style.setProperty('margin-inline-start', '0px', 'important');
      el.setAttribute('data-xdict-inset', 'zero');
    }
    // The containers that hold the entry's headword: the page's top-level content and its own direct children (one
    // entry per view — each dictionary has its own). Not the frame's own nodes (`#xdict-…`), the head's links, or a
    // box beside the entry's text. The core's entry root is a guess that two headwords defeat (D37, `concept`), so
    // the headword itself is what names the container.
    function head(e) { return e.querySelector('[data-xdict-role=headword],[data-xdict-lead]'); }
    function content(e, i) {
      return i <= 16 && !/^(SCRIPT|STYLE|LINK|TEMPLATE)$/.test(e.tagName) && !/^xdict-/.test(e.id || '');
    }
    Array.prototype.forEach.call(document.body.children, function (c, i) {
      if (!content(c, i)) return;
      var holders = head(c) ? [c] : [];
      Array.prototype.forEach.call(c.children, function (k, j) { if (content(k, j) && head(k)) holders.push(k); });
      holders.forEach(function (h) {
        var m = start(h);
        if (m <= 0.5) return;
        zero(h);
        Array.prototype.forEach.call(h.children, function (k, j) {
          if (j <= 16 && Math.abs(start(k) + m) <= 1) zero(k);
        });
      });
    });
  }
  // Parity P24 (2026-10-18): Apple's thin rule under a section label, drawn under the label's own line
  // (`XDictFrameCore.ruleOn`): on a heading the core names that is a block, or on its block when the heading is all
  // that block shows. Parity P25: an etymology section that holds only its label (NOAD's "Origin:", ODE's) is marked
  // so the text after it sits Apple's 0.2em under it. Reading style only.
  function words(e) { return (e.textContent || '').replace(/[\s:：]+/g, ''); }
  function rules() {
    if (!SPACE_CAP || !document.body) return;
    Array.prototype.forEach.call(document.body.querySelectorAll('[data-xdict-sure=heading]'), function (h, i) {
      if (i > 4096 || !h.getClientRects().length || h.closest('[data-xdict-ruled]') || h.querySelector('[data-xdict-ruled]')) return;
      var block = !inline(getComputedStyle(h)), b = block ? h : blockOf(h);
      var on = XDictFrameCore.ruleOn({ block: block, alone: !block && words(b) === words(h), body: b === document.body });
      var t = on === 'self' ? h : on === 'block' ? b : null;
      if (t) t.setAttribute('data-xdict-ruled', '');
    });
    Array.prototype.forEach.call(document.body.querySelectorAll('[data-xdict-section=etym]'), function (s) {
      var label = '';
      Array.prototype.forEach.call(s.querySelectorAll('[data-xdict-role=heading]'), function (h) {
        if (!h.parentElement.closest('[data-xdict-role=heading]')) label += words(h);   // an outer heading's words only
      });
      if (label && words(s) === label) s.setAttribute('data-xdict-etym-label', '');
    });
  }
  // Again when a picture arrives, the pane is resized, the density changes, or a fold opens: at most once in 16 ms.
  var pending = false;
  function later() {
    if (pending || !SPACE_CAP) return;
    pending = true;
    // A timer, not an animation frame: a pane in the background gets no frames, and still resizes.
    setTimeout(function () {
      pending = false;
      if (tooDeep()) return;
      entryInset(); overflows(); hang(); rules(); pictures(); images(); roleSpace(); markerDrops();
    }, 16);
  }
  // **No pass reads a tree nested deeper than the HTML parser builds** (2026-10-19). The passes ask each element's
  // ancestors (`closest`, `blockOf`, `hider`, `inInline`), so a page script's chain made them cost the square of its
  // depth: 7.0 s at 10,000 for `spacing()` alone, and a 100,000-deep page had not loaded in 28 minutes. WebKit's parser
  // nests no element deeper than 512 below the root, so no parsed entry is ever this deep; a deeper tree is a script's,
  // and its page keeps its own look. One walk of the body, in document order, stopping at the first element too deep.
  var DEEPEST = 512;
  function tooDeep() {
    var body = document.body, e = body, depth = 2;   // the root 1, the body 2: the depth `parentElement` counts
    while (e) {
      if (e.firstElementChild) { e = e.firstElementChild; if (++depth > DEEPEST) return true; continue; }
      while (e !== body && !e.nextElementSibling) { e = e.parentElement; depth--; }
      if (e === body) return false;
      e = e.nextElementSibling;
    }
    return false;
  }
  install();
  function start() {
    install(); name(document);
    if (tooDeep()) return;
    bullets(); loneBullets(); entryInset(); spacing(); lists(); overflows(); hang(); rules(); pictures(); images(); roleSpace(); markerDrops();
  }
  // A resize is spaced again once it settles too: the pane's first resize event can come before its media queries apply.
  window.addEventListener('resize', function () { later(); setTimeout(later, 200); });
  document.addEventListener('click', function () { setTimeout(later, 50); setTimeout(later, 400); });
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
    if (records.some(function (r) { return r.attributeName === 'data-xdict-density'; })) later();
    records.forEach(function (r) {
      Array.prototype.forEach.call(r.addedNodes, function (n) { if (n.nodeType === 1) name(n.parentNode || n); });
    });
  }).observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true,
                                          attributeFilter: ['media', 'disabled', 'id', 'data-xdict-theme', 'data-xdict-face', 'data-xdict-hue', 'data-xdict-density'] });
  window.__xdictFrame = { measure: measure };
})();
