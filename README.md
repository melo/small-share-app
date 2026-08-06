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

```
  agent ──POST /api/v1/files (or MCP share_file)──►┐
                                                    │  small-share-app
  agent ◄────── https://share.your-net/f/<32 random chars> ──┤
    │                                               │  sqlite + files on disk
    │ "here you go"                                 │
    ▼                                               │
  human ──opens the URL in a browser──────────────►┘
          header: name, size, uploaded, expires in 14d, [Download] [Delete]
          below:  the file, rendered, in its own frame
```

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

A Streamable HTTP MCP server at `/mcp`, stateless — no session IDs, no server
state, so it scales to as many workers as you like. Five tools:

| tool | what it does |
|---|---|
| `share_file` | upload text or base64 and get the URL to hand over |
| `list_shared_files` | what this `session_id` has shared, still live, with URLs |
| `get_shared_file` | read a file back — markdown as text, images as images |
| `get_shared_file_metadata` | name, kind, size, checksum, expiry, view count |
| `delete_shared_file` | delete now, before expiry |

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
curl -X DELETE "$S/api/v1/files/$ID"         # delete early
curl "$S/api/v1/health"                      # liveness, count, bytes held
```

Upload answers `201` with JSON; the field to hand over is `url`. Optional on any
upload: `session_id`, `title`, `note`, `ttl_days` (shorter than the configured
maximum, never longer).

**For binaries, prefer REST over MCP.** `share_file` takes base64 in the tool
call, which means the bytes pass through the agent's context — a 20 KB PNG costs
thousands of tokens. `curl -F file=@…` reads straight from disk. Same service,
same store, same URL.

### The web page

The home page explains itself and carries a **Share a file with an agent**
button. It expands a drop zone in place — drag files in, paste a screenshot, or
pick them — and gives back each URL with a one-click **Copy** button.

The button is a `<details>`/`<summary>` around a plain multipart form, so it
expands and uploads with JavaScript switched off entirely.
`public/assets/upload.js` only upgrades that same form with drag-and-drop,
paste, per-file progress and inline results. It is hand-written rather than
Dropzone.js, whose stable line has not moved since 2021: ~200 lines, no styling
opinions to fight, and no CSP exemption of its own.

## Configuration

All of it is environment variables. All of it is optional except where noted.

| variable | default | what it does |
|---|---|---|
| `SHARE_ROOT` | `/workspace` | the one directory: `share.db` + `files/` |
| `SHARE_BASE_URL` | derived from the request | the base of every URL handed out |
| `SHARE_TTL_DAYS` | `15` | retention, and the ceiling an upload may ask for |
| `SHARE_MAX_BYTES` | `33554432` | per-file limit |
| `SHARE_NOTICE` | empty | one line of deployment truth, shown on the home page and in the MCP instructions |
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
