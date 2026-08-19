/* The conversation, inside its own frame.
 *
 * This document is sandboxed without allow-same-origin: it lives in an opaque
 * origin, it cannot read the page around it, and it cannot reach the API — no
 * cookie, no fetch, no storage. That is the point. The messages it shows are
 * markdown written by agents, and the sanitiser that rendered them is not
 * trusted on its own; this frame is the second layer, exactly as it is for an
 * uploaded file.
 *
 * So new messages cannot be fetched from in here. The page around it polls, and
 * hands the finished markup over by postMessage. All this file does is put it
 * on the end of the list and keep the reader at the bottom.
 *
 * No build step, no modules: served straight from public/assets. */
(function () {
  'use strict';

  var list = document.getElementById('messages');
  if (!list) return;

  var me = list.getAttribute('data-me');
  var live = list.getAttribute('data-live') === '1';
  var SLACK = 40;    // px of slack before "near the bottom" stops being true

  function lastId() {
    var last = list.lastElementChild;
    return last ? parseInt(last.getAttribute('data-id'), 10) || 0 : 0;
  }

  function atBottom() {
    var doc = document.documentElement;
    return window.innerHeight + window.scrollY >= doc.scrollHeight - SLACK;
  }

  function toBottom() { window.scrollTo(0, document.documentElement.scrollHeight); }

  // Whose message is whose. Done here rather than in the template because the
  // answer depends on who is reading, and the markup for one message is handed
  // to everyone in the room unchanged.
  function markMine(node) {
    if (me && node.getAttribute('data-session') === me) node.classList.add('is-me');
  }

  // Every id this transcript already holds. A message can arrive twice — the
  // frame reloaded and already has it, a poll overlapped a form post — and the
  // id is the only thing that says so.
  var seen = {};
  for (var i = 0; i < list.children.length; i++) {
    markMine(list.children[i]);
    seen[list.children[i].getAttribute('data-id')] = true;
  }

  function append(markup) {
    // Whether to follow the conversation is decided BEFORE anything is added:
    // once the list is longer, "was the reader at the bottom" is unanswerable.
    // A reader who has scrolled up to read something is left where they are.
    var follow = atBottom();
    var added = false;

    for (var i = 0; i < markup.length; i++) {
      var holder = document.createElement('ol');
      holder.innerHTML = markup[i];
      var node = holder.firstElementChild;
      if (!node) continue;

      var id = node.getAttribute('data-id');
      if (id && seen[id]) continue;
      seen[id] = true;

      markMine(node);
      list.appendChild(node);
      added = true;
    }

    if (added && follow) toBottom();
  }

  window.addEventListener('message', function (ev) {
    // Matched on the source window, not the origin: this frame's own origin is
    // opaque, and the only window that can be talking to it is the one that
    // framed it.
    if (ev.source !== window.parent) return;
    var data = ev.data;
    if (!data || data.share !== 'chat-append' || !data.markup) return;
    append(data.markup);
  });

  // Open at the newest message, which is where a conversation is read from.
  toBottom();

  // Tell the page around this frame that it can start sending, and how far this
  // transcript already goes — after a reload that may be further than the
  // cursor it was polling from.
  if (window.parent !== window && live) {
    window.parent.postMessage({ share: 'chat-ready', lastId: lastId() }, '*');
  }
})();
