# Design notes

Why this is shaped the way it is. The README says what it does; this says what
was traded away for it.

## The product is one URL

An agent produces something a human should *look* at: a report in markdown, a
screenshot, a generated PDF. Pasting 400 lines of markdown into a terminal is
not reading it, and neither is `cat`ting a PNG.

So: upload, get one random URL, hand it over. The human opens it and reads the
thing properly. Some days later the file is gone and so is the URL.

Everything below is in service of that sentence. When a decision was close, the
tiebreaker was "does this make the URL easier to hand over and easier to read".

## No authentication

Anything that can reach the port may upload, list and delete.

This is a trade made with the alternatives on the table. Auth would mean tokens,
and tokens mean distribution: every agent container needs one mounted, rotated,
and revoked when it goes. That machinery is bigger than this entire service. On
a private network — a tailnet, a VPN, a lab LAN — the network is already doing
the job that the tokens would do.

The cost is real and bounded: anything that gets onto that network becomes a
file-drop for the retention window. That is acceptable at this scale and
unacceptable on the open internet, which is why the README says so twice.

**The seam is `under '/api/v1'` in `share.pl`.** One hook, plus a `tokens`
table, and every route below it is covered. Nothing else in the app assumes
anonymity — no route reads an identity, and `session_id` is a grouping key, not
a claim.

## The URL is the only credential

32 characters of base62 from `/dev/urandom` — about 190 bits, with rejection
sampling so the distribution is flat rather than biased toward the first six
letters of the alphabet. Not guessable, not enumerable, never derived from the
filename or the contents.

Because that secret travels *in a URL*, the download side is hardened against
the three ways URLs leak:

- `X-Robots-Tag: noindex, nofollow, noarchive` — never in a crawler's index.
- `Referrer-Policy: no-referrer` — a link inside a shared document does not hand
  the secret to the site it points at.
- `Cache-Control: private, no-store` — not in a shared cache.

There is one identifier, not two: the random part of the human's URL is also the
`id` the API and the MCP tools take. An agent never has to correlate a "share
link" with a "file id".

## Uploaded markdown is hostile until proven otherwise

An agent can be talked into writing anything, including `<script>`. Three
layers, because any one of them alone is a single point of failure:

1. **Sanitised** with `Mojo::DOM` against an allowlist. Known-dangerous elements
   are removed contents and all; unknown elements are *unwrapped*, keeping their
   text; every attribute not on the per-tag list — which is every `on*` handler
   — is dropped; `href` and `src` are restricted to `http`, `https`, `mailto`
   and `data:image`.

2. **Sandboxed.** The preview is a separate document in an iframe with
   `sandbox="allow-scripts"` and no `allow-same-origin`, so it lives in an opaque
   origin and cannot reach the app's API, cookies or storage. `allow-scripts` is
   there because mermaid needs it; without mermaid this would be `sandbox=""`.

3. **CSP**, naming the exact origin for scripts and styles. Spelling out the
   host rather than writing `'self'` is not pedantry: in an opaque origin,
   `'self'` matches nothing at all.

The iframe earns its place twice over — it isolates the untrusted document's
*styles* from the chrome as well as its scripts, which is also why the header
stays put while the file scrolls.

### One thing the tests caught and reading did not

The obvious way to write the sanitiser is `$dom->find('*')->each` and strip as
you go. It hangs the worker. `find` snapshots the whole tree up front, and
Mojo::DOM's internal `_offset` walks a parent's children looking for a node by
identity — if that node has already been detached, the loop never terminates. So
removing one element wedges the process on the next already-detached descendant.

It has to be a depth-first walk that takes a fresh snapshot of each node's
children before touching them. See `_clean` in `lib/Share/Render.pm`.

## Only three kinds, and the bytes must agree

Markdown, images, PDF. Every upload is classified by extension *and* by magic
bytes; a `.png` that is really a PDF is rejected rather than stored and later
served with a lying `Content-Type`.

HEIC is in the list because it is what a phone produces, and refusing the format
people actually have is a poor answer. But accepting it honestly means admitting
that outside Safari almost nothing can *display* one — so the viewer says so
under the image and points at the download, instead of rendering a broken-image
icon and leaving the reader to guess. Detection is by ISO base-media brand
(`ftypheic`, `ftypmif1`, …) rather than by `ftyp` alone, which the same container
shares with MP4.

A general file locker is a different product with a different threat model. The
narrow list is what lets every stored file be rendered rather than merely
downloaded — which is the entire point.

## SQLite and files on disk

Metadata in SQLite (WAL, with a busy timeout), bytes in a sharded directory
tree. No database server, no object store.

The workload is a few writes a day and a few reads. Anything larger would be
architecture for its own sake, and it would break the property that makes this
pleasant to operate: **one directory is the whole state**. Back it up and you
have backed up the service.

Blobs are written before rows and unlinked after them. A crash mid-delete leaves
an orphan blob — silent, bounded, reaped later — rather than a row whose file is
missing, which would be a 500 every time someone opened the link.

## The reaper lives in the app

An hourly `Mojo::IOLoop->recurring` deletes expired rows and their blobs. Under
prefork every worker holds that timer, so the reaper first takes an atomic claim
on a `meta` row (`UPDATE … WHERE last_reap <= ?`) and only proceeds if it
changed a row. One worker reaps; the rest no-op.

No cron entry, no second deployment artifact, correct at any worker count.
`bin/reap` runs the same code by hand for when you want it now.

## Stateless MCP

The Streamable HTTP transport allows a server to answer a request with a single
`application/json` body instead of opening an SSE stream. No tool here streams
progress or asks the client anything, so that is all this server ever does — and
it issues no `Mcp-Session-Id`, because there is no per-client state to key.

That is not laziness; it is what lets prefork work with no shared session store,
nothing pinning a client to a worker, and nothing to expire.

`Origin` is validated on every call — the transport spec requires it, as a
DNS-rebinding defence — and clients that are not browsers send no `Origin` at
all, which is the common case here.

The `initialize` response carries `instructions` **built from the running
configuration**. An operator who sets a three-day retention should not have an
MCP server telling every agent it is fifteen.

## Progressive enhancement, not a framework

The human-facing pages have no build step and, for the most part, no JavaScript.

- Deleting is a GET that asks and a POST that does it — two clicks and no
  `confirm()`, which is what lets every page carrying a secret run under
  `default-src 'none'` with no script source at all.
- The uploader is a `<details>`/`<summary>` around a plain multipart form. The
  button expands the box because that is what `<details>` does, not because a
  script listened for a click. With JavaScript off it still uploads, landing on
  a result page that says the same things in the same words.
- `upload.js` upgrades that same form in place: drag-and-drop, paste, per-file
  progress, inline results, and the Copy buttons. Server-rendered Copy buttons
  ship `hidden` and are woken up by the script, so scripting-off users get no
  dead controls.

It is hand-written rather than Dropzone.js. That library's stable line has not
moved since 2021 and its 6.x has been beta for years; this is ~200 lines with no
styling opinions to fight and no CSP exemption of its own.

## Vendored assets, pinned by checksum

mermaid (3.5 MB) and github-markdown-css are downloaded during `docker build`
and verified against a recorded SHA-256.

Not committed, because 3.5 MB of minified JavaScript does not belong in a source
repository. Not loaded from a CDN at view time, because a service you deploy on
a private network should not need the public internet to render a page — and
because a CDN is a third party watching who reads what.

Upstream changing a published file fails the build loudly instead of silently
shipping something else. The mermaid bundle is only referenced by documents that
actually contain a diagram.

For the record: mermaid 11 does **not** need `'unsafe-eval'`. The bundle is a
self-contained esbuild UMD with no `new Function(`, no bare `eval(` and no
dynamic import. Worth re-checking on a version bump; the CSP is tighter for it.

## The image build runs the tests

The `builder` stage ends with `pdi-run-tests`, which syntax-checks everything in
`bin/` and runs `t/share.t` against the exact dependency set the runtime image
ships. An image whose tests fail cannot be produced, let alone published.

`make test`, CI and the release workflow all go through that one stage. There is
one definition of "does it work".

Coverage has a floor rather than a badge: `bin/coverage` runs the suite under
Devel::Cover and *fails* below 90% statement coverage on `share.pl` and `lib/`.
It is 94.9% today.

Two things in there were learned the hard way and are commented in the script,
because both fail silently — green tests, no number:

  * `cover` takes its database as a **positional** argument. There is no `-db`
    option; passing one makes it look for a database literally named `-db`.
  * Devel::Cover's `+select`, `-ignore` and `-coverage` import options each
    produced an *empty* database in this layout. The instrumentation is
    therefore left broad and the narrowing is done by `cover -select_re` at
    report time, where a mistake shows up as a wrong number instead of none.

## Deliberately not here

- **Authentication.** See above; the seam is identified.
- **Public (Funnel) exposure by default.** Possible in one line of
  `tailscale-serve.json`, and it should not happen without revisiting the
  no-auth decision that the private network is currently holding up.
- **Anything but markdown, images and PDFs.**
- **Editing, versioning, folders, sharing controls.** This is a hand-off, not
  storage. Every feature in that direction turns a thing you can read in an
  afternoon into a thing you cannot.
