# small-share-app

**Hand a file from an AI agent to a human being, and back.**

An agent uploads a markdown report, an image or a PDF and gets back one random
URL. It gives that URL to a person, who opens it in a browser and *reads* the
thing — markdown with real typography and drawn mermaid diagrams, images shown,
PDFs in the browser's own viewer. Fifteen days later the file is gone and so is
the URL.

It works the other way too: the home page has a drop zone, so a human can hand a
screenshot or a spec to an agent and paste back the URL.

That is the whole product.

![How it works: an agent uploads a file, gets one random URL, and hands it to a human who opens it in a browser](site/flow.svg)

One Perl process (Mojolicious::Lite), one SQLite file, one directory of blobs.
No database server, no object store, no queue, no build step for the front end.
The whole thing is about 1,500 lines.

## Why you might want it

Agents produce things worth *looking* at. Pasting 400 lines of markdown into a
terminal is not reading it, and neither is `cat`ting a PNG. Uploading to a
pastebin means an account and a third party; attaching to a chat means whatever
that chat supports. This is the small, boring, self-hosted answer: a URL that
renders the file properly and then expires.

## Quick start

### On a tailnet, with a Tailscale sidecar (recommended)

```bash
git clone https://github.com/melo/small-share-app
cd small-share-app
cp .env.example .env      # put a Tailscale auth key in it
docker compose up -d
```

The stack is the app plus a `tailscale serve` sidecar. The app publishes **no
host ports**; the sidecar joins your tailnet as its own node, gets a real
Let's Encrypt certificate automatically, and reverse-proxies to the app. You end
up with `https://share.<your-tailnet>.ts.net`, reachable by your devices and
nobody else's.

The serve config uses `${TS_CERT_DOMAIN}`, substituted by Tailscale at startup
with the node's own name — so nothing in this repo has to know your tailnet, and
`tailscale-serve.json` works unchanged for everyone.

> If your tailnet has **tailnet lock** enabled, the new node registers but stays
> unreachable until you sign it in the admin console. Check reachability **from
> a different device**, never from the host running the container: local
> `tailscaled` resolves and serves an unsigned node's own name on its own host,
> so `curl` there returns 200 while the name does not resolve anywhere else.

### Locally, or behind a proxy you already run

```bash
docker compose -f docker-compose.local.yml up -d --build
open http://127.0.0.1:8080
```

Bound to loopback deliberately — see [Security](#security).

### Point an agent at it

```bash
claude mcp add --transport http share https://share.<your-tailnet>.ts.net/mcp
```

## Using it

### MCP

A Streamable HTTP MCP server at `/mcp`, built on the [CPAN `MCP`
distribution](https://metacpan.org/dist/MCP) by the Mojolicious author. It speaks
protocol revision **2026-07-28** — stateless, no `initialize` handshake,
`server/discover` in its place — and answers the older handshake too, so clients
that have not caught up keep working.

Note that revision's HTTP binding requires routing headers (`Mcp-Method`, and
`Mcp-Name` on `tools/call`) that restate what the body says, plus the protocol
version and client capabilities in `_meta` on every request. A hand-written curl
call needs all of them; any real client does this for you.

**It never carries the file itself, in either direction.** Every tool deals in
URLs; the agent moves the bytes with curl, straight off disk. Four tools:

| tool | what it does |
|---|---|
| `get_upload_url` | a URL, and a ready-to-run curl command, for putting a file in |
| `list_shared_files` | what this `session_id` has shared, with both URLs for each |
| `get_shared_file` | one file: metadata, the human's `url`, and the `content_url` to fetch |
| `delete_shared_file` | delete now — needs the `delete_password` from the upload |

The reason is arithmetic. A tool argument or result passes through the model's
context verbatim, and base64 inflates by a third: a 20 KB screenshot costs
thousands of tokens to send and thousands more to read back, and a 3 MB PDF does
not fit at all. `curl -F file=@…` moves it off disk for nothing.

The upload flow is three steps and no state:

```
get_upload_url(filename: "report.md", path: "/tmp/report.md", session_id: …)
  → { "command": "curl -fsS -F 'file=@/tmp/report.md' 'https://…/api/v1/files?…'", … }

run the command
  → { "url": "https://share.…/f/rK7mQ2…", "content_url": "…", … }

give the human the "url"
```

Nothing is reserved and nothing is written until the bytes arrive, so an
abandoned `get_upload_url` costs exactly nothing — there is no half-finished
upload to expire and reap.

The cost, stated plainly: an MCP client with **no shell and no HTTP tool cannot
upload** through this server at all. That is the trade, and it is the right one
for a coding agent, which has both.

The `initialize` response carries `instructions` built from the **running
configuration** — your real retention, your real size cap, your own
`SHARE_NOTICE` — so an agent that has only seen the tool list still uses the
service correctly and never quotes someone else's numbers back at you.

### REST

```bash
S=https://share.your-tailnet.ts.net

# upload — raw body is the friendliest form
curl --data-binary @report.md "$S/api/v1/files?filename=report.md&session_id=$SESSION"

# ...or multipart, or JSON with base64
curl -F file=@screenshot.png "$S/api/v1/files?session_id=$SESSION"
curl -H content-type:application/json "$S/api/v1/files" \
  -d '{"filename":"doc.pdf","content_base64":"'"$(base64 -w0 doc.pdf)"'"}'

curl "$S/api/v1/files?session_id=$SESSION"   # what this session has shared
curl "$S/api/v1/files/$ID"                   # metadata
curl "$S/api/v1/files/$ID/content"           # the bytes
curl -X DELETE -H "x-delete-password: $PW" \
  "$S/api/v1/files/$ID"                      # delete early
curl "$S/api/v1/health"                      # liveness
```

Upload answers `201` with JSON. Three fields matter: `url` is what you give a
person, `content_url` is what a machine fetches, and **`delete_password` is
disclosed exactly once, here** — no other call returns it. Optional on any
upload: `session_id`, `title`, `note`, `ttl_days` (shorter than the configured
maximum, never longer), and `delete_password` if you would rather choose it.

There is also `/api` — a page describing all of this, with the OpenAPI document
behind it at `/api?openapi=1` or via `Accept: application/openapi+json`. Worth
knowing: the OpenAPI Specification defines no media type for serving a
description document and none is registered with IANA, so that negotiation is
convention. `?openapi=1` is the unambiguous form.

The REST API is the data plane for agents too — `get_upload_url` hands back a
URL into exactly these endpoints. It still accepts JSON with base64, which is
useful for a client that has HTTP but no shell.

### The web page

**The home page *is* the drop zone**, always open — drag files in, paste a
screenshot, or pick them, and get back each URL with a one-click **Copy**
button. Everything explanatory lives at `/how-to`, one link away in the top bar,
because the common visit is "I have a file to hand over" and not "tell me what
this is".

Below the drop zone, **Recent uploads** lists what this browser has sent, newest
first, with expiry countdowns and Copy buttons. It is `localStorage` only —
the server keeps no such list, and there is deliberately no "everything"
endpoint — so it is pruned as files expire, and *Forget these* clears the
browser's memory without deleting anything from the server.

It is still a plain multipart form: with JavaScript off it uploads and lands on
a result page saying the same things. `public/assets/upload.js` only upgrades
that same form with drag-and-drop, paste, per-file progress, inline results, the
Copy buttons and the history. Hand-written rather than Dropzone.js, whose stable
line has not moved since 2021: ~300 lines, no styling opinions to fight, and no
CSP exemption of its own.

## Configuration

All of it is environment variables. All of it is optional except where noted.

| variable | default | what it does |
|---|---|---|
| `SHARE_ROOT` | `/workspace` | the one directory: `share.db` + `files/` |
| `SHARE_BASE_URL` | derived from the request | the base of every URL handed out |
| `SHARE_TTL_DAYS` | `15` | retention, and the ceiling an upload may ask for |
| `SHARE_MAX_BYTES` | `33554432` | per-file limit |
| `SHARE_NOTICE` | empty | one line of deployment truth, shown on `/how-to` and in the MCP instructions |
| `SHARE_MAX_TOTAL_BYTES` | 50 GB | ceiling on everything held at once; the oldest are evicted over it |
| `SHARE_RATE_PER_SECOND` | `1` | upload attempts per client per second; `0` disables |
| `SHARE_RATE_PER_MINUTE` | `10` | upload attempts per client per minute; `0` disables |
| `SHARE_HEALTH_DETAIL` | off | let `/api/v1/health` report files and bytes held |
| `SHARE_SECRET_KEY` | generated into the workspace | HMAC key for signed upload URLs |
| `SHARE_REQUIRE_SIGNED_UPLOADS` | off | reject any upload without a signed ticket from `get_upload_url` |
| `MOJO_REVERSE_PROXY` | `0` | set to `1` behind a proxy that sets `X-Forwarded-*` |
| `TS_AUTHKEY` | — | **required** for the Tailscale stack |
| `TS_HOSTNAME` | `share` | the node name, and therefore the hostname |

`SHARE_NOTICE` is worth setting. It is the one thing the code cannot know —
"Reachable on the office VPN only", "ask #infra for access" — and it reaches
both the humans on the home page and every agent through MCP.

## Operating it

```
make            # list every target
make up         # start the Tailscale stack
make dev        # run locally on 127.0.0.1:8080, no Tailscale
make test       # build through the test stage — the whole suite
make coverage   # the same suite under Devel::Cover, with a 90% floor
make health     # is it alive, and what is it holding
make list       # what is currently shared, from the database
make reap       # delete expired files now
make du         # disk used
make backup     # stop, tar the workspace, start
```

Everything persistent lives in one directory (`./data` by default): `share.db`
and `files/`. Back that up and you have backed up the service. Delete the
container and you have lost nothing.

**Expired files are deleted by the app itself**, hourly. Every worker holds the
timer and takes an atomic claim on a `meta` row, so exactly one of them does the
work. Blobs are unlinked before rows are deleted: an orphaned blob is silent
disk growth, an orphaned row is a 500, and the first is the better failure.

## Security

Read this before you deploy it anywhere interesting.

**There is no authentication.** Anything that can reach the port may upload,
list and delete. This is a deliberate trade, not an oversight: it removes the
token-distribution problem entirely, so an agent container needs no credential,
no mount and no rotation. It is the right trade on a private network and the
wrong one on the open internet.

If you need auth, the seam is the single `under '/api/v1'` in `share.pl`.
Nothing else in the app assumes anonymity.

**The URL is the only credential.** 32 base62 characters from `/dev/urandom`,
about 190 bits — not guessable, not enumerable, never derived from the filename
or the contents. Every response carrying it also carries `X-Robots-Tag:
noindex`, `Referrer-Policy: no-referrer` and `Cache-Control: private, no-store`,
which are the three ways a URL leaks.

**Uploaded markdown is treated as hostile**, because an agent can be talked into
writing anything. Three independent layers, none trusted alone:

1. The rendered HTML is sanitised against a tag and attribute allowlist —
   `script`, `iframe`, `object` and friends removed outright, every `on*`
   attribute stripped, `href`/`src` restricted to safe schemes.
2. The preview is served in an iframe with `sandbox="allow-scripts"` and **no**
   `allow-same-origin`, so it runs in an opaque origin and cannot reach the
   app's API, cookies or storage even if something gets through.
3. A CSP naming the exact origin — `'self'` matches nothing in an opaque origin,
   which is precisely why it is spelled out.

SVGs are previewed through an `<img>` tag, which never executes script, and
their raw bytes carry `Content-Security-Policy: sandbox` so that navigating
straight to them cannot execute them in the app's origin either.

**Upload URLs are signed.** `get_upload_url` returns a URL carrying an `exp` and
an HMAC `sig` over every other parameter, valid for an hour. Editing the
`session_id`, `title`, `ttl_days` or expiry invalidates it. To be clear about
what that is and is not: with no authentication it is **not** access control —
anything that can reach the service can POST to the endpoint directly. What it
buys today is that a ticket cannot be altered in transit or hoarded forever, and
what it buys later is a place for a real credential to live. Set
`SHARE_REQUIRE_SIGNED_UPLOADS=1` to make tickets mandatory.

**The health endpoint says only that it is alive.** How many files are held and
how much disk is in play is the operator's business — on a public instance it
tells a stranger how busy the box is and whether something of theirs is still
there. `SHARE_HEALTH_DETAIL=1` adds the counts back for a private deployment
whose monitoring needs them.

**Uploads are rate limited, per client**: one a second and ten a minute by
default, counted in SQLite rather than in process memory — the app runs prefork,
and an in-memory counter would hand each client the limit multiplied by the
worker count. **Attempts** are counted, not successes, so hammering the endpoint
with rejects is limited too. Over the limit is a `429` with `Retry-After`.

**A disk ceiling, enforced by eviction rather than refusal.** Past
`SHARE_MAX_TOTAL_BYTES` (50 GB by default) the *oldest* files are removed until
it fits. A public box that fills its disk goes down, which is a worse outcome
than losing the oldest thing on it.

**Reading and deleting are separate capabilities.** The share URL grants
reading. Deleting needs the `delete_password` returned by the upload — passed as
`X-Delete-Password`, a JSON field, or a form field. A wrong password and a file
that never existed get the same answer with the same status, so the endpoint
cannot be used to discover which ids exist. Lose the password and the file
simply expires on its own. In the browser this is invisible: the drop zone keeps
the password in `localStorage` beside the record, which is why **Recent uploads**
can offer a Delete button and a page you were merely *sent* cannot.

**No route lets a client choose or overwrite an id.** There is no `PUT`
anywhere, no client-supplied path, and nothing that modifies a stored file.
Every accepted upload mints a fresh secret from `/dev/urandom`; the same bytes
uploaded twice are two files.

**The declared type must match the bytes.** Every upload is classified by
extension *and* by magic bytes. A `.png` that is really a PDF is rejected rather
than stored and served with a lying `Content-Type`. HEIC is accepted — it is
what phones produce — but the viewer says plainly that only Safari can display
one, rather than showing a broken image icon.

**Chrome pages run with no script source at all.** Only the two pages carrying
the uploader get `script-src 'self'`, and they ask for it by name.

## Publishing your own images

`.github/workflows/publish.yml` pushes multi-arch images (amd64 + arm64) on
every push to `main` and on every `v*.*.*` tag.

**GHCR needs no setup.** The built-in `GITHUB_TOKEN` is enough. The first push
creates the package as *private* — make it public once, at **Profile →
Packages → small-share-app → Package settings → Change visibility**.

**Docker Hub is optional** and skipped unless you configure it, so forks do not
fail. To enable it, in **Settings → Secrets and variables → Actions**:

| kind | name | value |
|---|---|---|
| Secret | `DOCKERHUB_USERNAME` | your Docker Hub account |
| Secret | `DOCKERHUB_TOKEN` | an access token from **Account settings → Personal access tokens**, scope **Read & Write**. Not your password. |
| Variable | `DOCKERHUB_REPO` | optional — e.g. `myuser/small-share-app`. Defaults to `<username>/small-share-app`. |

Create the Docker Hub repository first; the token cannot create it for you.

Tag a release with `git tag v1.0.0 && git push --tags` and you get `1.0.0`,
`1.0`, `1` and `latest` in both registries.

## How it is built

```
share.pl              Mojolicious::Lite: pages, REST API, MCP endpoint, templates
lib/Share/Store.pm    sqlite + files on disk, classification, the reaper
lib/Share/Render.pm   markdown → HTML that is safe to show a human
lib/Share/MCP.pm      the JSON-RPC layer and the five tools
public/assets/        CSS, the uploader, the mermaid bootstrap, the favicon
t/share.t             the suite the image build runs
bin/health-check      core-Perl HTTP probe for HEALTHCHECK
bin/reap              the manual handle behind `make reap`
Dockerfile            assets → build+test → runtime
```

The base image is [melo/docker-perl-alt](https://github.com/melo/docker-perl-alt):
`/app` for the code, `/deps` for its CPAN dependencies.

**mermaid and github-markdown-css are vendored at build time**, pinned by
version and verified by SHA-256 — not loaded from a CDN at view time, because a
service you deploy on a private network should not need the public internet to
render a page. They are not committed either; mermaid alone is 3.5 MB of
minified JavaScript. To bump one, change the version in the `Dockerfile`, build,
and paste the checksum from the failure.

**The image build runs the test suite.** The `builder` stage ends with
`pdi-run-tests`, so an image whose tests fail cannot be produced, let alone
published. `make test`, CI and the release workflow all go through that same
stage.

**Coverage is gated, not merely reported.** `make coverage` — and a CI step —
runs the same suite under `Devel::Cover` and fails the build if statement
coverage over `share.pl` and `lib/` drops below 90%. It sits at **94.9%**
today. Devel::Cover is installed only inside that build step, so it never
reaches the runtime image and costs nothing on an ordinary build.

More on the reasoning behind each decision: [docs/DESIGN.md](docs/DESIGN.md).

## Contributing

Issues and pull requests welcome. `make test` before you push — it is the same
thing CI runs. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

MIT. See [LICENSE](LICENSE).
