# Contributing

Issues and pull requests are welcome.

## Running the tests

```bash
make test
```

That builds the image up to its `builder` stage, which ends with
`pdi-run-tests`: every script in `bin/` is syntax-checked and `t/share.t` runs
in full, against the exact dependency set the runtime image ships. It is the
same thing CI runs and the same stage published images are built through, so if
it passes locally it passes in CI.

You need Docker and nothing else — no local Perl, no CPAN.

## Running it while you work

```bash
make dev        # http://127.0.0.1:8080, rebuilds first
make dev-logs
make dev-down
```

## What a good change looks like

- **A test.** `t/share.t` is one file of `Test::Mojo` subtests and it is where
  behaviour is pinned down. New behaviour, new subtest.
- **Comments that say why.** The code is short enough to read; what is not
  obvious from reading it is the reasoning, especially where something is
  deliberately not the obvious approach. There are several of those, and each
  one has a comment explaining what went wrong with the obvious version.
- **No new runtime dependency without a reason in the pull request.** The
  dependency list is five lines and that is a feature.
- **No build step for the front end.** The CSS and JavaScript are served
  straight from `public/assets` and run under a strict CSP. Anything that needs
  bundling, transpiling or a CDN is the wrong shape for this project.

## Things to be careful with

- **`lib/Share/Render.pm` is a security boundary.** It renders markdown written
  by an AI agent, which means markdown that can contain anything. If you touch
  it, add a test that proves the thing you changed still refuses to emit script.
- **The chrome pages run with no script source at all** (`default-src 'none'`).
  Only the two pages carrying the uploader get `script-src 'self'`, and they
  ask for it by name. Please keep it that way.
- **Bumping mermaid or github-markdown-css** means changing the version *and*
  the SHA-256 in the `Dockerfile`. Build once, and paste the checksum from the
  failure.

## Releasing

Maintainers: tag it.

```bash
git tag v1.2.3 && git push --tags
```

That publishes `1.2.3`, `1.2`, `1` and `latest` to GHCR, and to Docker Hub if it
is configured. See the README.
