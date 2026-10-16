(function () {
  'use strict';
  var mode = '{{theme}}';
  var css = (mode === 'dark'
    ? 'html{color-scheme:dark;background-color:rgb(30,30,30);color:rgb(230,230,230)}'
    : 'html{color-scheme:light;background-color:rgb(255,255,255)}') + '{{inset}}';
  function install() {
    var s = document.getElementById('xdict-appearance-style');
    if (!s) {
      s = document.createElement('style');
      s.id = 'xdict-appearance-style';
      (document.head || document.documentElement).appendChild(s);
    }
    s.textContent = css;
  }
  install();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  else install();
  window.__xdictAppearance = { mode: mode };
})();
