/* Draw the mermaid blocks that Share::Render promoted to <pre class="mermaid">.
 *
 * Loaded only when the document actually contains one — mermaid is 3.5 MB and
 * most shared markdown has no diagrams in it.
 *
 * This runs inside a sandboxed iframe with no allow-same-origin, so it has an
 * opaque origin and can reach nothing of the app's. securityLevel 'strict' is
 * belt to that braces: it stops mermaid honouring click handlers or raw HTML
 * written into a diagram by whoever produced the file. */
(function () {
  'use strict';

  var dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: dark ? 'dark' : 'default',
    fontFamily:
      '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif'
  });

  // preview.css hides these blocks until they are drawn, so that a 40-line
  // diagram definition does not flash up as text first. Whatever happens next,
  // every block has to end up visible: a diagram with a syntax error should
  // show as its own source, not as a hole in the page.
  function reveal() {
    var blocks = document.querySelectorAll('pre.mermaid');
    for (var i = 0; i < blocks.length; i++) blocks[i].style.visibility = 'visible';
  }

  // Scripts sit at the end of <body>, so the blocks are already parsed.
  try {
    mermaid
      .run({ querySelector: 'pre.mermaid', suppressErrors: true })
      .catch(function (err) { console.error('mermaid failed', err); })
      .then(reveal, reveal);
  } catch (err) {
    console.error('mermaid failed', err);
    reveal();
  }
})();
