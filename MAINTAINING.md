# Maintaining

For anyone releasing this project or publishing images from a fork. If you only
want to *run* it, the [README](README.md) is the whole story.

## Releasing

One commit and one signed tag, across two machines. The commit is made on the
box, where the code and docker are; the tag is made on the laptop, because that
is where the GPG key is. `.github/workflows/publish.yml` does the rest.

There are two remotes and they are not interchangeable. `origin` is the forge,
which holds the history. `github` is where the workflows live, and so it is the
only one that publishes anything.

### On the box

**1. Write the message first, to `v<version>.msg` at the root of the repo.** It
is a changelog — what changed in this release, for whoever reads it later, not
a description of the diff. Both the commit and the tag are made from that one
file, so `git log` and `git show v1.3.1` tell the same story. Untracked, and at
the root rather than in a temporary directory so the laptop can `scp` it off
without knowing anything about the container it was written in.

**2. Bump the version and commit with it.**

```bash
# our $VERSION = '1.3.1'; in share.pl
git commit -a -F ./v1.3.1.msg
```

The version has to match the tag about to be made: it is reported by
`/api/v1/health`, by the MCP server on connect, and as `info.version` in the
OpenAPI document. A bump that ships without a matching tag is the failure mode
to avoid — `v1.2.3` was signed onto the same commit as `v1.2.2`, so that image
reports 1.2.2 for the rest of its life.

Run `make test` and `make coverage` here, before the commit leaves the box.
Both build the image, so both want docker — which the box has and the laptop
may not.

**3. Push `main` to the forge and stop.**

```bash
git push origin main
```

Nothing is tagged yet, so nothing publishes. This push exists so that the
laptop has the commit to tag: a tag can only name a commit the machine making
it already has.

### On the laptop

**4. Fetch the commit, and the message file separately.**

```bash
j small-share-app                  # autojump to the checkout
git pull --ff
scp box:small-share-app/v*msg .
ssh box rm small-share-app/v*msg
```

The message is untracked, so it does not arrive with the pull — `scp` is what
carries it across, and that is what the "at the root of the repo" in step 1
buys. Deleting it on the box afterwards is not tidiness: `v*msg` is a glob, and
a leftover `v1.3.1.msg` is a release note the next release would silently pick
up alongside its own.

**5. Tag it, signed.**

```bash
git tag -s v1.3.1 -F ./v1.3.1.msg
rm ./v1.3.1.msg
```

Release tags are GPG-signed and made by hand, from wherever the signing key
lives — which is the whole reason this half runs on the laptop, and the one
step nothing else does for you. `git tag -v v1.3.1` verifies the signature and
prints the message back, if you want to look before pushing.

**6. Push both remotes, the forge first.**

```bash
git push origin main v1.3.1        # the forge: history
git push github main v1.3.1        # the one that matters: this is what reaches GHCR
```

The second one is the release. A tag that only ever reaches the forge builds
nothing, publishes nothing and deploys nothing — it just sits there looking
like a release that happened. Push `main` and the tag together, or `main`
first: the tag has to name a commit the remote already has.

That publishes `1.3.1`, `1.3`, `1` and `latest` to GHCR — and to Docker Hub if
it is configured — for linux/amd64 and linux/arm64. It also deploys the landing
page.

Expect a release to take around half an hour. arm64 is emulated through QEMU and
compiles the XS dependencies from source: roughly 24 minutes against 100 seconds
for the native build. That is the cost of the architecture people actually run
this on, and only a tag pays it.

**A tag is the only thing that publishes anything.** A push to the forge runs
nothing at all. A push of `main` to `github` runs `ci.yml` and stops there: it
builds the image through the `builder` stage, linux/amd64 only, runs the suite
and the coverage floor, and pushes the result nowhere. There is no `:main` and
no `:edge` any more. If you want an unreleased build, `docker build .` gives
you the same thing CI just made.

The image is built through the `builder` stage, which runs the test suite, so a
release whose tests fail cannot be published.

`workflow_dispatch` on `publish.yml` is the handle for re-running a release
whose publish failed. **Run it from the tag** — it refuses any other ref, so a
manual publish cannot mint a `latest` nobody can identify later.

## Working on arm64

`multiarch.yml` builds the full image for **both** architectures on **any
branch that is not main**, and pushes neither. Use it whenever a change could
plausibly behave differently under emulation — a dependency bump, anything
touching the Dockerfile.

```bash
git switch -c arm64-deps
# change something
git push -u github arm64-deps      # both architectures build, nothing ships
```

`github`, not the forge — the workflow only exists there.

It does not run on main, on tags, or on pull requests from forks. QEMU emulates
every instruction of a from-source CPAN install, so it costs roughly ten times
the native build — that is worth paying when you are deliberately working on
arm64 and not otherwise.

The one time it earned its keep so far: v1.1.0, v1.2.0 and v1.2.1 were tagged
and none of them published, because `List::MoreUtils::XS` probes for C headers
by compiling a small program per header, and under QEMU one of those probes ran
past the sixty seconds `App::cpm` allows a configure phase. cpm dropped the
distribution; `List::MoreUtils` requires it, `Markdown::Perl` requires that, and
the release died twenty minutes in. Being a deadline rather than a defect is why
it was intermittent and why it went unnoticed for two versions. The fix is
`PDI_CPM_CONFIGURE_TIMEOUT` in the Dockerfile — see the comment there.

## The `github-pages` environment

Setting Pages' source to "GitHub Actions" creates a `github-pages` environment
whose deployment policy allows **the default branch only**. Because the page now
deploys from a tag, that policy has to allow tags too, or the job is rejected in
about a second with no steps run:

> Tag "v1.2.1" is not allowed to deploy to github-pages due to environment
> protection rules.

**Settings → Environments → `github-pages` → Deployment branches and tags → Add
rule → Tag → `v*.*.*`**. `main` can come off the list at the same time: nothing
deploys the page from a branch any more. The cost of removing it is that a
manual re-deploy through `workflow_dispatch` also has to be run from a tag,
which is the same rule stated once rather than twice.

## Publishing from a fork

**GHCR needs no secrets.** The built-in `GITHUB_TOKEN` plus `packages: write`
is enough. The first push creates the package as **private**; make it public
once, at **Profile → Packages → small-share-app → Package settings → Change
visibility**. That is the one step the workflow cannot do for itself.

**Docker Hub is optional** and skipped entirely when unset, so a fork never
fails for want of credentials. To enable it, create the Docker Hub repository
first — the token cannot create it — then add, under **Settings → Secrets and
variables → Actions**:

| kind | name | value |
|---|---|---|
| Secret | `DOCKERHUB_USERNAME` | the account that owns the token |
| Secret | `DOCKERHUB_TOKEN` | an access token from **Account settings → Personal access tokens**, scope **Read & Write**. Not your password. |
| Variable | `DOCKERHUB_REPO` | optional — e.g. `you/small-share-app`. Defaults to `<username>/small-share-app`. |

## The landing page

`site/` is published to GitHub Pages by `.github/workflows/pages.yml`, **on a
release tag and nowhere else** — which needs the environment rule described
above. The page describes what the published software
does, so it should describe the version people can actually run; deploying it
from `main` meant the site could advertise something that was not in `:latest`
yet. Tag, and the image and the page go out together.

It needs one manual step, once: **Settings → Pages → Build and deployment →
Source → GitHub Actions**. Without it the workflow runs and the deploy step
fails with "Pages site not found".

A Pages site is **public even while the repository is private** — worth knowing
before enabling it on something not ready to be read.

The workflow checks the page is self-contained before deploying: no third-party
requests, and every local asset it references actually present in the artifact.

## Vendored browser assets

`mermaid` and `github-markdown-css` are downloaded during `docker build` and
verified against a SHA-256 recorded in the `Dockerfile`. They are deliberately
not committed — mermaid alone is 3.5 MB of minified JavaScript — and deliberately
not loaded from a CDN at view time, because a service you deploy on a private
network should not need the public internet to render a page.

To bump one: change the version in the `Dockerfile`, build, and paste the
checksum from the failure. An upstream file changing under a pinned version
fails the build loudly instead of silently shipping something else.

While you are there, re-check whether mermaid still needs no `'unsafe-eval'`.
As of 11.16.1 the bundle is a self-contained esbuild UMD with no `new Function(`,
no bare `eval(` and no dynamic import, which is why the preview's CSP does not
grant it.

## How the pieces fit

```
share.pl              Mojolicious::Lite: pages, REST API, MCP endpoint, templates
lib/Share/Store.pm    sqlite + files on disk, classification, tickets, the reaper
lib/Share/Render.pm   markdown → HTML that is safe to show a human
lib/Share/MCP.pm      four tools on top of the CPAN MCP distribution
lib/Share/OpenAPI.pm  the API description, built from the running config
public/assets/        CSS, the uploader, the mermaid bootstrap, the favicon
t/share.t             the suite the image build runs
e2e/                  the browser suite
bin/health-check      core-Perl HTTP probe for HEALTHCHECK
bin/reap              the manual handle behind `make reap`
bin/coverage          the suite under Devel::Cover, with a floor
Dockerfile            assets → build+test → runtime
```

The base image is [melo/docker-perl-alt](https://github.com/melo/docker-perl-alt):
`/app` for the code, `/deps` for its CPAN dependencies, and an entrypoint that
puts both on `PERL5LIB`. `RUN` steps do not go through that entrypoint, so
anything needing the dependencies invokes `pdi-entrypoint` explicitly.
