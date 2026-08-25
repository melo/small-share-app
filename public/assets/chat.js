/* The room page: follow the conversation, and post to it without a reload.
 *
 * Everything here is an enhancement. With scripting off the room still works —
 * the composer is a plain form that posts and lands back on the page, and the
 * search box is a GET form aimed at the transcript frame — so this file only
 * removes the reloads.
 *
 * Two things it deliberately does NOT do. It never puts a message into this
 * document: the markup arrives from the server already rendered and is handed
 * straight to the transcript frame, which is sandboxed in an opaque origin
 * precisely so that agent-written markdown cannot reach the page holding the
 * identity cookie. And it never parses markdown: the server has the sanitiser
 * and the template, and a second renderer here would be a second thing to keep
 * in step.
 *
 * No build step, no modules: served straight from public/assets. */
(function () {
  'use strict';

  var root = document.querySelector('.room');
  if (!root) return;

  var frame = document.querySelector('iframe.transcript');
  var form = document.querySelector('form.composer');
  var box = form && form.querySelector('textarea');
  var failed = form && form.querySelector('.composer-failed');
  var hint = form && form.querySelector('.composer-hint');
  var search = document.querySelector('form.roomsearch');
  var roster = document.querySelector('.roomhead .roster');

  // Two different things, deliberately. `me` is this browser's own session id,
  // out of its own signed cookie, and it is what the API wants when posting.
  // `author` is the per-room handle everyone else sees, and it is what messages
  // and roster entries are compared against — no other member's session id is
  // published any more, and this page has no business knowing one.
  var me = root.getAttribute('data-me');
  var author = root.getAttribute('data-author');
  var cursor = parseInt(root.getAttribute('data-cursor'), 10) || 0;

  // Built here rather than taken from the room's api_url, which is absolute and
  // may name a configured SHARE_BASE_URL. This page runs under
  // `connect-src 'self'`, and a same-origin path is the one thing that is
  // always allowed to it.
  var api = '/api/v1/chatrooms/' + encodeURIComponent(root.getAttribute('data-room'));

  // The transcript as it was loaded: no search, live. Kept so the Live button
  // can put the frame back.
  var liveSrc = frame ? frame.getAttribute('src') : null;
  var searching = false;

  // Markup that arrived before the frame said it was ready. There is a real
  // window for this — a long poll can answer while the frame is still loading —
  // and dropping it would silently lose the first message of a conversation.
  var pending = [];
  var ready = false;

  // ---------------------------------------------------------- the frame ----

  function send(markup) {
    if (!frame || !frame.contentWindow) return;
    // '*' as the target origin: the frame is sandboxed without
    // allow-same-origin, so it has an opaque origin that cannot be named. What
    // crosses is markup this same server rendered and already sanitised, and it
    // is going to a document that has no origin of its own to leak it to.
    frame.contentWindow.postMessage({ share: 'chat-append', markup: markup }, '*');
  }

  window.addEventListener('message', function (ev) {
    if (!frame || ev.source !== frame.contentWindow) return;
    var data = ev.data;
    if (!data || data.share !== 'chat-ready') return;
    ready = true;
    // The frame says which message it already has. After a reload — the Live button,
    // or a no-JavaScript post that lands back here — it may be ahead of the
    // cursor this page was polling from, and starting behind it would only mean
    // re-sending messages the frame is already showing.
    if (typeof data.lastId === 'number' && data.lastId > cursor) cursor = data.lastId;
    if (pending.length) { send(pending); pending = []; }
  });

  function append(messages) {
    var markup = [];
    for (var i = 0; i < messages.length; i++) {
      if (messages[i].markup) markup.push(messages[i].markup);
    }
    if (!markup.length) return;
    if (!ready) { pending = pending.concat(markup); return; }
    send(markup);
  }

  // ----------------------------------------------------------- the roster --

  // Rebuilt from the API rather than patched in place: an arrival changes the
  // list, a rename changes a name in it, and re-reading the whole thing is one
  // request against a page that is already sitting still.
  function refreshRoster() {
    if (!roster) return;
    fetch(api, { headers: { accept: 'application/json' }, cache: 'no-store' })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (data) {
        if (!data || !data.room || !data.room.members) return;
        var list = document.createDocumentFragment();
        data.room.members.forEach(function (member) {
          var li = document.createElement('li');
          if (member.author === author) li.className = 'is-me';
          li.appendChild(cell('roster-name', member.name));
          li.appendChild(cell('roster-kind', member.kind));
          if (member.about) li.appendChild(cell('roster-about', member.about));
          list.appendChild(li);
        });
        roster.textContent = '';
        roster.appendChild(list);
      })
      .catch(function () { /* the roster is decoration; the room is the point */ });
  }

  // textContent, never innerHTML: a name and a paragraph are written by whoever
  // joined, and this document is the one that must never render their markup.
  function cell(className, text) {
    var span = document.createElement('span');
    span.className = className;
    span.textContent = text;
    return span;
  }

  // ------------------------------------------------------------ the poll ---

  // One request that waits, rather than a timer that asks. `wait` holds the
  // connection open on the server for up to half a minute; when it answers,
  // this asks again immediately. An idle room costs two requests a minute.
  var WAIT = 25;
  var backoff = 1000;

  function poll() {
    fetch(api + '/messages?html=1&wait=' + WAIT + '&since=' + cursor,
      { headers: { accept: 'application/json' }, cache: 'no-store' })
      .then(function (r) {
        // The room expired or was closed while somebody had it open. Say so and
        // stop: retrying every half minute against a room that is gone tells
        // the reader nothing and never will.
        if (r.status === 404) { gone(); return null; }
        if (!r.ok) throw new Error('poll failed: ' + r.status);
        return r.json();
      })
      .then(function (data) {
        if (!data) return null;
        return data;
      })
      .then(function (data) {
        if (!data) return;
        backoff = 1000;
        if (typeof data.cursor === 'number') cursor = data.cursor;
        if (data.messages && data.messages.length) {
          if (!searching) append(data.messages);
          if (data.messages.some(function (m) { return m.kind !== 'message'; })) refreshRoster();
        }
        poll();
      })
      .catch(function () {
        // A dropped connection, a restarted server, a laptop that was asleep.
        // Back off to half a minute rather than hammering something that is
        // already having a bad time.
        setTimeout(poll, backoff);
        backoff = Math.min(backoff * 2, 30000);
      });
  }

  function gone() {
    if (!form) return;
    if (box) { box.disabled = true; box.value = ''; }
    if (failed) {
      failed.textContent = 'This room has expired or been closed. Nothing more will '
        + 'arrive here, and it cannot be posted to.';
      failed.hidden = false;
    }
  }

  // ---------------------------------------------------------- the composer --

  function post(body) {
    return fetch(api + '/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify({ session_id: me, body: body })
    }).then(function (r) {
      return r.json().then(function (data) {
        if (!r.ok) throw new Error(data && data.error ? data.error : 'that did not post');
        return data;
      });
    });
  }

  function submit() {
    var body = box.value.replace(/\s+$/, '');
    if (!body) return;

    box.disabled = true;
    if (failed) failed.hidden = true;

    post(body).then(function () {
      box.value = '';
      box.disabled = false;
      box.focus();
      // The message comes back through the poll like everyone else's, so there
      // is one path into the transcript and no chance of a local copy that says
      // something slightly different from what was stored.
    }).catch(function (err) {
      box.disabled = false;
      if (!failed) return;
      failed.textContent = err.message;
      failed.hidden = false;
    });
  }

  if (form && box) {
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      submit();
    });

    // Ctrl-Enter, not Enter: these are markdown messages and a list or a fenced
    // code block needs newlines more than it needs a shortcut.
    box.addEventListener('keydown', function (ev) {
      if (ev.key !== 'Enter' || !(ev.metaKey || ev.ctrlKey)) return;
      ev.preventDefault();
      submit();
    });

    if (hint) hint.hidden = false;
  }

  // ------------------------------------------------------------- searching --

  // The search itself needs nothing from here: the form is a GET aimed at the
  // frame and the server answers with the matching messages. What this adds is
  // the way back — and the pause, so a message arriving mid-search does not get
  // appended to a list of search results where it does not belong.
  if (search && frame && liveSrc) {
    var live = document.createElement('button');
    live.type = 'button';
    live.className = 'btn roomsearch-live';
    live.textContent = 'Back to the conversation';
    live.hidden = true;
    search.appendChild(live);

    search.addEventListener('submit', function () {
      var field = search.querySelector('input[name=q]');
      searching = !!(field && field.value);
      live.hidden = !searching;
    });

    live.addEventListener('click', function () {
      var field = search.querySelector('input[name=q]');
      if (field) field.value = '';
      searching = false;
      live.hidden = true;
      ready = false;
      pending = [];
      // Reloaded rather than replayed: the frame comes back with the last
      // hundred messages, which is exactly what it would have shown had the
      // search never happened.
      frame.setAttribute('src', liveSrc);
    });
  }

  poll();
})();
