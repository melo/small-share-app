/* Tell the page around this frame whether the file is scrolled to the top.
 *
 * That is the whole job. The viewer's file bar folds itself away the moment you
 * start reading and comes back when you return to the top, and only the frame
 * knows when that happens — the document scrolls in here, not out there, and a
 * sandboxed frame's scroll events do not cross the boundary.
 *
 * Loaded by both preview documents. There is no equivalent for a PDF: that is
 * the browser's own viewer inside the frame and nothing of ours runs in it, so
 * the bar on a PDF stays wherever the reader left it.
 *
 * No build step, no modules: served straight from public/assets and running
 * under `script-src <origin>`. */
(function () {
  'use strict';

  var THRESHOLD = 8;    // px of slack, so a rubber-band bounce is still "top"
  var last = null;

  function report() {
    var y = window.scrollY || document.documentElement.scrollTop || 0;
    var atTop = y <= THRESHOLD;
    if (atTop === last) return;
    last = atTop;

    // '*' as the target origin, because this frame is sandboxed without
    // allow-same-origin: it lives in an opaque origin and cannot read its
    // parent's to name it. The payload is one boolean about scroll position and
    // carries nothing that is not already on screen.
    if (window.parent !== window) {
      window.parent.postMessage({ share: 'preview-scroll', atTop: atTop }, '*');
    }
  }

  // Coalesced to one report per frame: a scroll fires far more often than the
  // bar can usefully change, and every extra message is a postMessage across a
  // process boundary.
  var pending = false;
  window.addEventListener('scroll', function () {
    if (pending) return;
    pending = true;
    window.requestAnimationFrame(function () {
      pending = false;
      report();
    });
  }, { passive: true });

  // The opening state, so a preview that loads already scrolled — a fragment
  // link, a restored position — does not start out disagreeing with the bar.
  report();
})();
