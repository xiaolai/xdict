// A dictionary's display options (ADR-0013 d.3), in the shell's world: the root is given every option's value, the
// default included, and the core's CSS goes in beside it. Set at document start and again when the document is ready,
// so an entry that writes the attribute itself (on its <html>, or from a script before then) never chooses for the
// reader. `set` gives the shown document new values in place, without loading it again.
(function () {
  'use strict';
  var given = {{given}};
  var sheet = null;
  function install() {
    var root = document.documentElement;
    if (!root) return null;
    var read = [];
    for (var i = 0; i < given.values.length; i++) {
      root.setAttribute(given.values[i][0], given.values[i][1]);
      read.push(root.getAttribute(given.values[i][0]));
    }
    if (given.css && (!sheet || !sheet.isConnected)) {
      sheet = document.createElement('style');
      sheet.textContent = given.css;
      (document.head || root).appendChild(sheet);
    }
    return read;
  }
  install();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install, { once: true });
  window.__xdictDisplay = {
    set: function (values) {
      given.values = values;
      return install();
    }
  };
})();
