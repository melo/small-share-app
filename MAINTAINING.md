# Maintaining

For anyone releasing this project or publishing images from a fork. If you only
want to *run* it, the [README](README.md) is the whole story.

## Releasing

Tag it. `.github/workflows/publish.yml` does the rest.

```bash
git tag -a v1.2.3 -m "what changed"
git push origin v1.2.3
```

That publishes `1.2.3`, `1.2`, `1` and `latest`, multi-arch (amd64 + arm64), to
GHCR — and to Docker Hub if it is configured. It also deploys the landing page.

**A tag is the only thing that publishes anything.** A push to `main` runs
`ci.yml` and stops there: it builds the image through the `builder` stage,
linux/amd64 only, runs the suite and the coverage floor, and pushes the result
nowhere. There is no `:main` and no `:edge` any more. If you want an unreleased
build, `docker build .` gives you the same thing CI just made.

That means arm64 is only ever exercised at the tag. It is emulated through
QEMU and compiles DBD::SQLite and CryptX from source, which is most of a
release's wall-clock and roughly ten times the native build — worth paying for
an artefact somebody keeps, not for every merge. A cross-platform break is
therefore caught when you tag, before anything is published, rather than on the
merge that caused it.

The image is built through the `builder` stage, which runs the test suite, so a
release whose tests fail cannot be published.

`workflow_dispatch` on `publish.yml` is the handle for re-running a release
whose publish failed. **Run it from the tag** — it refuses any other ref, so a
manual publish cannot mint a `latest` nobody can identify later.

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
release tag and nowhere else**. The page describes what the published software
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
