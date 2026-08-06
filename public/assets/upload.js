/* Upgrade the uploader form in place, and make every URL on the page one click
 * to copy.
 *
 * Everything here is an enhancement and nothing is load-bearing: the markup is a
 * plain multipart <form>, so with scripting off the upload still works and
 * lands on /upload. What this adds is drag-and-drop, paste, a progress bar per
 * file, results that appear in the page instead of navigating away from it, the
 * Copy buttons, and the "recent uploads" history kept in localStorage.
 *
 * Hand-written rather than a library. Dropzone.js is the obvious candidate and
 * its stable line has not moved since 2021; this is ~200 lines, has no styling
 * opinions to fight, and needs no CSP exemption. See README.
 *
 * No build step, no modules: this is served straight from public/assets and runs
 * under `script-src 'self'`. */
(function () {
  'use strict';

  // ------------------------------------------------------------- clipboard --

  // navigator.clipboard needs a secure context. It has one wherever this is
  // sensibly deployed, but a browser can still refuse, so the button says so
  // rather than pretending it worked.
  function copyText(text, done) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { done(true); },
        function () { done(false); }
      );
      return;
    }
    done(false);
  }

  function wireCopy(button, text) {
    button.hidden = false;
    button.addEventListener('click', function () {
      copyText(text, function (ok) {
        var was = button.textContent;
        button.textContent = ok ? 'Copied' : 'Press ⌘/Ctrl-C';
        button.classList.toggle('is-done', ok);
        setTimeout(function () {
          button.textContent = was;
          button.classList.remove('is-done');
        }, 1600);
      });
      // If the clipboard API is unavailable, at least leave the URL selected so
      // the manual copy is one keystroke.
      selectSiblingUrl(button);
    });
  }

  function selectSiblingUrl(button) {
    var url = button.parentNode && button.parentNode.querySelector('.result-url');
    if (!url || !window.getSelection || !document.createRange) return;
    var range = document.createRange();
    range.selectNodeContents(url);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function newCopyButton(text) {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn result-copy';
    button.textContent = 'Copy';
    button.hidden = true;
    wireCopy(button, text);
    return button;
  }

  // Server-rendered results (the no-JavaScript /upload page) ship their Copy
  // buttons hidden, so that with scripting off there is no dead control on the
  // page. Waking them up is the first thing this script does, before anything
  // below can bail out.
  var buttons = document.querySelectorAll('button[data-copy]');
  for (var i = 0; i < buttons.length; i++) wireCopy(buttons[i], buttons[i].getAttribute('data-copy'));

  // --------------------------------------------------------------- history --

  // This browser's own record of what it has sent. The server keeps no such
  // list -- there is deliberately no "everything" endpoint -- so if it is not
  // here it does not exist anywhere.
  var STORE_KEY = 'share.recent';
  var STORE_MAX = 200;

  function readHistory() {
    var raw;
    try { raw = window.localStorage.getItem(STORE_KEY); } catch (err) { return []; }
    if (!raw) return [];

    var rows;
    try { rows = JSON.parse(raw); } catch (err) { return []; }
    if (!Array.isArray(rows)) return [];

    // Drop anything the server has already reaped, so the list never offers a
    // link that 404s.
    var now = Date.now();
    return rows.filter(function (r) {
      return r && r.url && r.expires_at && Date.parse(r.expires_at) > now;
    });
  }

  function writeHistory(rows) {
    try { window.localStorage.setItem(STORE_KEY, JSON.stringify(rows.slice(0, STORE_MAX))); }
    catch (err) { /* private mode, or full: the upload still worked */ }
  }

  function remember(record) {
    if (!record || !record.url) return;
    var rows = readHistory().filter(function (r) { return r.id !== record.id; });
    rows.unshift(record);
    writeHistory(rows);
    renderHistory();
  }

  var recent = document.querySelector('.recent');
  var recentList = recent && recent.querySelector('.recent-list');

  function renderHistory() {
    if (!recent || !recentList) return;
    var rows = readHistory();
    writeHistory(rows);                 // persist the pruning

    recentList.textContent = '';
    recent.hidden = rows.length === 0;

    rows.forEach(function (r) {
      var li = document.createElement('li');

      var name = document.createElement('span');
      name.className = 'result-name';
      name.textContent = r.filename || r.id;

      var meta = document.createElement('span');
      meta.className = 'result-meta';
      meta.textContent = [r.kind, r.size_human, 'expires ' + relative(r.expires_at)]
        .filter(Boolean).join(', ');

      var link = document.createElement('a');
      link.className = 'result-url';
      link.href = r.url;
      link.textContent = r.url;

      li.appendChild(name);
      li.appendChild(meta);
      li.appendChild(link);
      li.appendChild(newCopyButton(r.url));
      recentList.appendChild(li);
    });
  }

  // "in 14 days" / "in 6 hours" — the same shape the server uses, so the two
  // never read as different units for the same file.
  function relative(when) {
    var left = Date.parse(when) - Date.now();
    if (!(left > 0)) return 'now';
    var day = 86400000, hour = 3600000, minute = 60000;
    if (left >= day) return 'in ' + plural(Math.floor(left / day), 'day');
    if (left >= hour) return 'in ' + plural(Math.floor(left / hour), 'hour');
    if (left >= minute) return 'in ' + plural(Math.floor(left / minute), 'minute');
    return 'in less than a minute';
  }

  function plural(n, unit) { return n + ' ' + unit + (n === 1 ? '' : 's'); }

  if (recent) {
    var clear = recent.querySelector('.recent-clear');
    if (clear) {
      clear.addEventListener('click', function () {
        writeHistory([]);
        renderHistory();
      });
    }
    renderHistory();
  }

  // Fold a no-JavaScript upload — one that landed on /upload and came back as
  // server-rendered HTML — into the same history.
  document.querySelectorAll('li[data-record]').forEach(function (li) {
    try { remember(JSON.parse(li.getAttribute('data-record'))); } catch (err) { /* ignore */ }
  });

  // -------------------------------------------------------------- uploader --

  var uploader = document.querySelector('.uploader');
  if (!uploader) return;

  var form = uploader.querySelector('form');
  var zone = uploader.querySelector('.dropzone');
  var input = uploader.querySelector('input[type=file]');
  var results = uploader.querySelector('.results');

  // If any of this is missing, or the browser is too old for FormData/XHR2,
  // leave the plain form alone — it works.
  if (!form || !zone || !input || !results) return;
  if (!window.FormData || !window.XMLHttpRequest || !('upload' in new XMLHttpRequest())) return;

  var queue = [];
  var busy = false;

  // ------------------------------------------------------------------ drop --

  ['dragenter', 'dragover'].forEach(function (name) {
    zone.addEventListener(name, function (ev) {
      ev.preventDefault();
      zone.classList.add('is-over');
    });
  });

  ['dragleave', 'drop'].forEach(function (name) {
    zone.addEventListener(name, function (ev) {
      ev.preventDefault();
      zone.classList.remove('is-over');
    });
  });

  zone.addEventListener('drop', function (ev) {
    if (ev.dataTransfer && ev.dataTransfer.files) enqueue(ev.dataTransfer.files);
  });

  // The whole point of a share service, most days, is a screenshot.
  document.addEventListener('paste', function (ev) {
    if (!ev.clipboardData) return;
    var files = ev.clipboardData.files;
    if (files && files.length) {
      ev.preventDefault();
      enqueue(files);
    }
  });

  input.addEventListener('change', function () {
    if (input.files && input.files.length) enqueue(input.files);
    input.value = '';    // so choosing the same file twice fires again
  });

  form.addEventListener('submit', function (ev) {
    ev.preventDefault();
    if (input.files && input.files.length) {
      enqueue(input.files);
      input.value = '';
    }
  });

  // --------------------------------------------------------------- uploads --

  function enqueue(files) {
    for (var i = 0; i < files.length; i++) queue.push(files[i]);
    results.hidden = false;
    pump();
  }

  // One at a time. Concurrency buys nothing here and makes the progress bars lie
  // about what is actually moving.
  function pump() {
    if (busy || !queue.length) return;
    busy = true;
    upload(queue.shift(), function () {
      busy = false;
      pump();
    });
  }

  function upload(file, done) {
    var row = addRow(file.name);
    var body = new FormData();
    // A pasted screenshot arrives as "image.png" or with no name at all; the
    // server needs an extension it can check against the bytes.
    body.append('file', file, file.name || 'pasted.png');

    var xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/v1/files', true);
    xhr.setRequestHeader('Accept', 'application/json');

    xhr.upload.addEventListener('progress', function (ev) {
      if (ev.lengthComputable) row.progress.style.width = (ev.loaded / ev.total) * 100 + '%';
    });

    xhr.addEventListener('load', function () {
      var data = null;
      try { data = JSON.parse(xhr.responseText); } catch (err) { /* handled below */ }

      if (xhr.status === 201 && data && data.url) succeed(row, data);
      else fail(row, (data && data.error) || 'upload failed (HTTP ' + xhr.status + ')');
      done();
    });

    xhr.addEventListener('error', function () { fail(row, 'the connection dropped'); done(); });
    xhr.addEventListener('abort', function () { fail(row, 'cancelled'); done(); });

    xhr.send(body);
  }

  // --------------------------------------------------------------- results --

  function addRow(name) {
    var li = document.createElement('li');
    li.className = 'is-uploading';

    var label = document.createElement('span');
    label.className = 'result-name';
    label.textContent = name || 'pasted image';

    var meta = document.createElement('span');
    meta.className = 'result-meta';
    meta.textContent = 'uploading…';

    var bar = document.createElement('span');
    bar.className = 'result-bar';
    var progress = document.createElement('span');
    progress.className = 'result-progress';
    bar.appendChild(progress);

    li.appendChild(label);
    li.appendChild(meta);
    li.appendChild(bar);
    results.appendChild(li);

    return { li: li, meta: meta, bar: bar, progress: progress };
  }

  function succeed(row, data) {
    row.li.className = '';
    row.bar.remove();
    row.meta.textContent = data.kind + ', ' + data.size_human + ', expires in ' + data.expires_in;

    var link = document.createElement('a');
    link.className = 'result-url';
    link.href = data.url;
    link.textContent = data.url;

    row.li.appendChild(link);
    row.li.appendChild(newCopyButton(data.url));

    remember({
      id: data.id, url: data.url, filename: data.filename, kind: data.kind,
      size_human: data.size_human, created_at: data.created_at, expires_at: data.expires_at
    });
  }

  function fail(row, message) {
    row.li.className = 'failed';
    row.bar.remove();
    row.meta.textContent = message;
  }
})();
