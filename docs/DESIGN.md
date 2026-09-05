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

## A room is the same idea as a file

The file side hands one artefact from one agent to one person. Rooms are the
other shape the same problem takes: several agents on one job, in separate
sessions, with a human as the only wire between them — copying messages between
terminals by hand.

So a room is deliberately *the same object* as a file, with the same properties,
because every one of them was already the right answer here:

- one unguessable URL, which is the whole credential and the whole invitation;
- handed to a person, who hands it on — the service has no idea who anyone is
  and no way to invite anybody;
- fifteen days and gone, roster and messages with it, on the same reaper pass.

That is also why there is no setting to turn rooms off. An instance that will
hold arbitrary files for anyone who can reach it is already holding arbitrary
text for them; a switch would imply the two are different exposures, and one
more configuration branch through the tools, the pages and the tests.

### /c opens a room, and yes, that is a GET

`GET /c` creates a room and answers with it: JSON and a 201 for anything that
did not ask for HTML, a redirect into the new room for a browser.

A GET that creates a resource is not what GET is for, and it is the right trade
here. The alternative — POST a JSON body to `/api/v1/chatrooms` — still exists
and is what an agent with a tool calls; what it cannot do is be *said out loud*.
"Open share dot whatever slash c" is a sentence, and a room that starts with one
line of curl, or one typed URL, is a room that gets used instead of a group chat.

The cost is bounded deliberately: the room it makes is empty, it is rate limited
in the same bucket as posting, and it expires like everything else. Nothing links
to `/c` and every page here is `noindex`, so there is nothing for a crawler or a
link prefetcher to walk into. `HEAD` is answered without creating anything, which
is what stops an uptime probe pointed at `/c` from opening a room a minute.

The delete password is the one thing that has to survive that redirect, because
it is disclosed exactly once and a browser never sees the creation response. It
travels in the flash and is shown on the door, once — reload the page and it is
gone, which is the same promise the upload result page makes.

### The URL has to explain itself

The agent at the far end of a room URL got it from a person who got it from
another agent. It may have no MCP server registered, no documentation, and no
context beyond the URL — so fetching the URL with anything that has not asked
for HTML answers with `how_to`: join, post, read from a cursor, wait, grep, and
where a file goes. The MCP tools hand back that same text, so an agent that
arrived through curl and one that arrived through a tool are reading the same
instructions.

The paragraph each session writes when it joins is the feature, not ceremony.
It is required of an agent and optional for a person: the whole point of the
room is that everyone can see what everyone else is holding without asking, and
a person who has opened the page is already visibly present. It is posted into
the transcript rather than only into the roster, so a session parked on `wait`
finds out that somebody arrived and what they are doing, in one answer.

### A room is one sequence of events

A message was always one kind of thing that happens in a room; the table just
did not say so — `kind` was already `message | join | system`. Making that
explicit is what lets an arrival, a departure, a rename and the room's own death
answer the same "what since `<id>`?" question on the same cursor.

The reason is not tidiness. It is that a mutation has to be visible to a reader
that is caching: a watcher holding message 40 has no way to learn that 40 was
edited unless the edit is itself an event. No number of extra endpoints fixes
that, and every side channel added to a room is one more thing a client has to
know to ask about — which is the same as not being told.

Two events have no member behind them, and carry a null `session_id` with the
name `system`: `room.expiring`, written once by the reaper a couple of hours out
while the room is still standing, and `room.destroyed`. That second one is the
only event never read from the stored sequence, because the sequence it would
belong to is being deleted in the same breath. It is synthesized for a parked
reader — somebody demonstrably present while the room still was, and therefore
owed an explanation. A cold read of a dead id still gets a 404: `find_room`
cannot tell "destroyed an hour ago" from "never existed", and 410 Gone would be
inventing knowledge we do not have.

`/messages` still answers, with the list under both names. It already returned
arrivals and renames alongside speech, so nothing about its behaviour moved.

A live room upgrades into this in place, and **keeps its ids**. That is not
tidiness either: an id is a cursor, and there are agents holding one right now.
Renumbering would silently rewind or skip every watcher in every open room.

Two things the migration could not do in SQL, so `init` does them once, guarded
on the schema version it found before migrating. Mentions are backfilled by
running the same matcher over the bodies that are already there — without it an
upgraded room answers "has anyone ever addressed me?" with an empty list, which
reads exactly like "no". And each member's read cursor is seeded from the last
thing they said, which is the only record the old schema kept of where anybody
had got to; starting everyone at zero would hand every upgraded session the whole
room as unread on its first `since=unread`, which is the expensive re-read this
release exists to stop.

Nobody has a member token after an upgrade, and one cannot be granted out of
band — the plaintext exists for a single moment. So reconnecting issues one, and
reconnecting is what an agent does.

### Waiting is a timer over SQLite, and there is still no bus

`?wait=900` holds the request open until somebody posts. No worker sits still for
it: the wait is a `Mojo::IOLoop` timer that re-reads one indexed row range twice
a second and resolves a promise.

A notification bus would be the obvious alternative and is the wrong shape here.
The app runs prefork; a message posted through one worker has to reach a caller
parked in another, and the only thing they share is the database. Polling it is
what the reaper's claim already does, for the same reason, and it stays correct
at any worker count with nothing to expire or go stale.

Reads are deliberately not rate limited, where posting and opening a room are.
A limiter on reads would be a limiter on *following a room*, which is the thing
the feature exists for; and a parked request costs a connection and one indexed
query every half second, which is a smaller number than the reconnect storm a
limiter would cause. Posting is where the writes are, and that is where the
bucket is — a separate one from uploads, so a busy room never stops anybody
sharing a file.

What that bucket is *keyed on* is a decision of its own, and it was got wrong
twice before it was got right. It has to be the caller's address, and behind a
proxy the socket peer is the proxy — key on that and every caller shares one
bucket, so the first busy agent locks out the rest. Reading the address out of a
forwarded header is what avoids that, and it is also the way the limiter is
defeated: a header anybody may write is a bucket anybody may choose. Believing
`CF-Connecting-IP` from all comers meant rotating it turned the limit off, and
writing a *victim's* address into it filled theirs instead — throttling a chosen
agent out of a room from outside it.

So a forwarded address is counted only when every hop that added one is a hop
this deployment vouches for. That is `MOJO_TRUSTED_PROXIES`, and the walk is
Mojolicious': `X-Forwarded-For` from the right with the socket peer appended,
trusted hops dropped, stopping at the first address nobody here vouched for.
Hand-rolling that walk is the second thing this got wrong, and it is why the
allow-list is not ours any more. It compared the list against `remote_address`,
which under `MOJO_REVERSE_PROXY` is already a forwarded address and not the
peer, so it either never fired or fired for a client and handed that client the
header. And it matched CIDR entries by stripping the `/NN` rather than
interpreting it, so `172.64.0.0/13` matched one address and the Cloudflare
ranges the whole mechanism existed for could not be written down at all.
Delegating is not thrift about a dependency — `Mojo::Util::network_contains`
was already installed, and the argument that avoiding it justified matching
prefixes by hand was wrong the day it was written.

The ceiling went from sixty seconds to fifteen minutes, and that is the whole
feature: a backgrounded `curl --max-time 960` exits when the room needs you,
which makes it a wake-up rather than a poll. The old sixty was justified by a
comment saying a proxy in front of this, and every MCP client's own patience, is
comfortably inside its own timeout — and neither assumption had ever been
tested. It is configuration now rather than a constant for exactly that reason:
a deployment that disagrees lowers `SHARE_CHAT_MAX_WAIT` instead of making every
watcher go back to asking in a loop.

There were **two** ceilings, forty lines apart — one in `share.pl` and one in
`Share::MCP` — so changing one silently held. Both come from the same number
now, and a test drives that number down and checks the MCP tool honours it,
because the obvious test (ask for a long wait, post into it) passes whichever
ceiling applied.

A shared bus was considered again at fifteen minutes and rejected on the
arithmetic. One waiter at `wait=900` costs about 1,800 indexed lookups against a
database that does on the order of 100,000 a second; twenty concurrent waiters
is roughly 0.04% of one core. A second service and a second code path is a lot
to pay for noise, against a project whose stated properties are a five-line
dependency list and one directory holding the whole state. The thresholds that
would change the answer are visible ones: more than one instance behind a room,
or hundreds of waiters on one of them.

What the long wait did break, and this is the part worth remembering: a room
deleted underneath a parked reader used to leave it polling a room that no longer
existed until its deadline. Invisible at sixty seconds; a held connection doing
nothing for a quarter of an hour at nine hundred. The poll re-checks the room
and settles with `room.destroyed`.

One promise, two callers: the REST route renders from it, and the MCP tool
returns it, which `MCP::Server` awaits. That is the one place this server
answers over an SSE stream rather than with a single JSON body — the transport's
doing, for an async result — and it happens only when a caller explicitly asked
to wait.

### grep is a substring, and that is the whole feature

A regular expression supplied by a caller is a way to take a worker out of
service: one nested quantifier over a few thousand messages, and Perl's engine
has no timeout to stop it. Meanwhile every real use of grep in a room — "who
mentioned the migration?" — is a substring. So the search is
`instr(lower(body), lower(?))`, and the tool description says so rather than
letting an agent discover it by writing `.*`.

### The transcript is in a frame, like a file preview

Chat messages are markdown written by agents, which is exactly what
`lib/Share/Render.pm` already assumes is hostile. They get the same layers: the
sanitiser, then a sandboxed frame with no `allow-same-origin`, then a CSP naming
this origin.

The frame earns it twice over here. The page around it holds the reader's
identity cookie, which is more than a viewer page has ever carried, and the
conversation scrolls under a header that stays put.

That frame cannot fetch anything — an opaque origin, no cookies, no CORS — so
the page around it does the long polling and hands finished markup in by
`postMessage`. The markup is rendered by the same template the server-rendered
transcript uses, so a live conversation and a reloaded one are built by one
renderer rather than two that drift.

Mermaid is deliberately not loaded in a room. The bundle is 3.5 MB, a diagram is
a thing to look at rather than a thing to say, and this service already has
somewhere to put one: share the file, post the URL. That is the same rule as
"no attachments", and it is why a room needs no upload path of its own.

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

The chat tables are in the same file under their own migration name
(`Mojo::SQLite` keeps a version per name), so the two schemas move
independently and one directory is still the whole state. A message id is a
column of a single monotonic sequence, which is what makes "everything since
4128" an index lookup with no timestamps to be clever about — and a room keeps
only its most recent messages, remembering how far it pruned so a caller reading
from a message that no longer exists is told it missed some rather than handed a
gap it cannot see.

## The reaper lives in the app

An hourly `Mojo::IOLoop->recurring` deletes expired rows and their blobs. Under
prefork every worker holds that timer, so the reaper first takes an atomic claim
on a `meta` row (`UPDATE … WHERE last_reap <= ?`) and only proceeds if it
changed a row. One worker reaps; the rest no-op.

No cron entry, no second deployment artifact, correct at any worker count.
`bin/reap` runs the same code by hand for when you want it now.

## MCP carries no bytes

No tool moves file contents, in either direction. Uploading means calling
`get_upload_url` and running the curl command it returns; reading a file back
means fetching its `content_url`. MCP is the control plane; HTTP is the data
plane.

The reason is arithmetic, not taste. A tool argument or result passes through
the model's context verbatim, and base64 inflates by a third: a 20 KB screenshot
costs thousands of tokens to send and thousands more to read back, and a 3 MB
PDF does not fit at all. Meanwhile `curl -F file=@…` moves it off disk for
nothing. This was not theoretical — an agent using an earlier version of this
server hit the tool-output cap trying to read back a 20 KB PNG it had just
shared, and fell back to curl on its own.

A chat message is not an exception to this. `body` is prose an agent wrote,
capped at a few kilobytes, and a room says so itself: no attachments — share the
file and post the URL, which is also how the person reading along gets to see it.

Once uploads work that way, making downloads work differently would only be an
inconsistency for an agent to trip over. So `get_shared_file` returns metadata
and a URL, and says so in its own description, even for a 2 KB markdown file
where inlining would have been cheap. One rule, no judgement call.

`get_upload_url` deliberately creates **no reservation**. It returns the
ordinary REST endpoint with the metadata already encoded into the query string,
so an abandoned call writes nothing and there is no half-finished upload to
expire and reap. It exists as a tool rather than a line in the instructions for
two reasons: it fills in the base URL and the encoding so the agent cannot get
them wrong, and it is where a one-time ticket would be minted if authentication
ever arrives.

The cost is real: an MCP client with no shell and no HTTP tool cannot upload at
all. For a coding agent, which has both, that is the right trade.

## Stateless MCP

The Streamable HTTP transport allows a server to answer a request with a single
`application/json` body instead of opening an SSE stream. No tool here streams
progress or asks the client anything, so that is what all but one call gets —
and it issues no `Mcp-Session-Id`, because there is no per-client state to key.

The exception is `get_chat_messages` **with a `wait`**, which returns a promise;
`MCP::Server` delivers an async result over an SSE stream. That is the
transport's choice rather than ours, and it is confined to the one call where a
caller explicitly asked to be kept waiting — an ordinary read still answers with
one JSON body, which is why the tool checks `wait` before deciding which shape
to return.

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

## The tests are a stage you ask for

The `test` stage ends with `pdi-run-tests`, which syntax-checks everything in
`bin/` and runs everything under `t/` against the exact dependency set the
runtime image ships. `make test`, CI and the release workflow all build that one
stage. There is one definition of "does it work".

It is a **leaf**: nothing is built `FROM` it, so a plain `docker build .`, a
`--target devel`, and a development container rebuild do not run the suite.

It used to be the last `RUN` of `builder`, which put the suite on the path of
every build that wanted an image at all. The guarantee that bought — "an image
whose tests fail cannot be produced" — was real, but the price was paid by
everyone who was not asking the question: a `--target devel` rebuild, and, on
the arm64 leg of a release under QEMU, the better part of half an hour. The
guarantee that mattered was never about `docker build` on someone's laptop; it
was about what gets published. So publish.yml now builds `test` explicitly, on
both architectures, before it pushes anything, and nothing is published whose
tests do not pass. The toll is gone and the gate is still there.

Coverage has a floor rather than a badge: `bin/coverage` runs the suite under
Devel::Cover and *fails* below 90% statement coverage on `share.pl` and `lib/`.
It is 94.9% today. It is the `coverage` stage, and a leaf for the same reason.

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
- **Anything but markdown, images and PDFs**, and in a room, anything but
  markdown at all: no attachments, no uploads of its own, no mermaid.
- **Private rooms, invites, moderation, read receipts.** The URL is the
  invitation and there are no accounts to attach any of that to.
- **Editing, versioning, folders, sharing controls.** This is a hand-off, not
  storage. Every feature in that direction turns a thing you can read in an
  afternoon into a thing you cannot.
