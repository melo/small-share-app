# Maintaining

For anyone releasing this project or publishing images from a fork. If you only
want to *run* it, the [README](README.md) is the whole story.

## Releasing

Tag it. `.github/workflows/publish.yml` does the rest.

```bash
git tag -a v1.2.3 -m "what changed"
git push origin v1.2.3
```

That publishes `1.2.3`, `1.2`, `1` and `latest` to GHCR — and to Docker Hub if
it is configured. It also deploys the landing page.

> **linux/amd64 only, for now.** The arm64 leg fails in `pdi-build-deps` under
> QEMU and has done since some point after v1.0.0 — v1.1.0, v1.2.0 and v1.2.1
> were all tagged and none of them published, so `latest` sat on 1.0.0 for two
> releases while the tags existed in git. Nobody saw it, because a push to main
> was still publishing `:main` and `:edge` on amd64 and that was the only thing
> succeeding. A release that does not exist is worse than a single-architecture
> one, so releases ship amd64 and say so in the workflow. See "Working on
> arm64" below.

**A tag is the only thing that publishes anything.** A push to `main` runs
`ci.yml` and stops there: it builds the image through the `builder` stage,
linux/amd64 only, runs the suite and the coverage floor, and pushes the result
nowhere. There is no `:main` and no `:edge` any more. If you want an unreleased
build, `docker build .` gives you the same thing CI just made.

The image is built through the `builder` stage, which runs the test suite, so a
release whose tests fail cannot be published.

`workflow_dispatch` on `publish.yml` is the handle for re-running a release
whose publish failed. **Run it from the tag** — it refuses any other ref, so a
manual publish cannot mint a `latest` nobody can identify later.

## Working on arm64

`multiarch.yml` builds the full image for **both** architectures on **any
branch that is not main**, and pushes neither. That is where the arm64 problem
gets worked out.

```bash
git switch -c arm64-deps
# change something
git push -u origin arm64-deps      # both architectures build, nothing ships
```

It does not run on main, on tags, or on pull requests from forks. QEMU emulates
every instruction of a from-source CPAN install, so it costs roughly ten times
the native build — that is worth paying when you are deliberately working on
arm64 and not otherwise.

When it goes green, put `linux/arm64` back into `publish.yml`'s `platforms` and
delete the `TEMPORARY` note above it. Nothing else needs to change.

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
