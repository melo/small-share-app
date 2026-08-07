/* The two things the viewer cannot do with markup alone: copy a URL, and fold
 * the file bar away while you read.
 *
 * Everything here is an enhancement. The fold is a checkbox and a <label>, so
 * the button works with scripting off and this file only flips the same
 * checkbox; the Copy links ship hidden and are revealed below, so with scripting
 * off there is no control on the page that cannot do anything.
 *
 * This is the reason the viewer asks for `script-src 'self'` where it once had
 * no script source at all. It gets no `connect-src`: there is nothing here to
 * fetch, and the file itself is in a sandboxed frame in an opaque origin that
 * cannot reach this document.
 *
 * No build step, no modules: served straight from public/assets. */
(function () {
  'use strict';

  // ------------------------------------------------------------- clipboard --

  // The same shape as the copy button in upload.js, deliberately duplicated
  // rather than shared: this is fifteen lines, and the alternative is a second
  // request on every viewer page to pull in an uploader this page does not have.
  //
  // navigator.clipboard needs a secure context. It has one wherever this is
  // sensibly deployed, but a browser can still refuse, so the link says so
  // rather than pretending it worked.
  function wireCopy(button) {
    var text = button.getAttribute('data-copy');
    button.addEventListener('click', function () {
      var was = button.textContent;
      var done = function (ok) {
        button.textContent = ok ? 'Copied' : 'Press ⌘/Ctrl-C';
        button.classList.toggle('is-done', ok);
        setTimeout(function () {
          button.textContent = was;
          button.classList.remove('is-done');
        }, 1600);
      };

      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); },
                                                 function () { done(false); });
      } else {
        done(false);
      }
    });
  }

  var links = document.querySelector('.copy-links');
  if (links) {
    var buttons = links.querySelectorAll('button[data-copy]');
    for (var i = 0; i < buttons.length; i++) wireCopy(buttons[i]);
    links.hidden = false;
  }

  // ------------------------------------------------------------ the fold ----

  // Fold as soon as the reader scrolls, unfold when they come back to the top.
  // The bar is a hat on somebody else's document: once they are reading it, the
  // name and the download button are all of it that still earns its space.
  //
  // The scroll happens inside the frame, so the frame reports it —
  // assets/preview-scroll.js, loaded by both preview documents. Messages are
  // matched on their source window rather than their origin: a sandboxed frame
  // has an opaque origin and always arrives as "null", which would match any
  // other sandboxed frame just as well.
  var toggle = document.getElementById('filebar-toggle');
  var frame = document.querySelector('iframe.preview');
  if (!toggle || !frame) return;

  window.addEventListener('message', function (ev) {
    if (ev.source !== frame.contentWindow) return;
    var data = ev.data;
    if (!data || data.share !== 'preview-scroll') return;
    toggle.checked = !data.atTop;
  });
})();
