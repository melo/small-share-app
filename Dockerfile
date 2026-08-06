# share — image build.
#
# Three stages: fetch the two vendored browser assets, build and test the app,
# then assemble a runtime image that carries neither a compiler nor a network
# fetch.
#
# Base is melopt/perl-alt (https://github.com/melo/docker-perl-alt): /app for the
# code, /deps for its CPAN dependencies, and pdi-entrypoint to put both on
# PERL5LIB. RUN steps do NOT go through the entrypoint, so anything below that
# needs the dependencies is invoked through pdi-entrypoint explicitly.

ARG PERL_ALT=perl-5.44-slim

# ------------------------------------------------------------------ assets ---
# mermaid and github-markdown-css are downloaded here, once, and verified
# against a recorded checksum. They are deliberately NOT committed (mermaid is
# 3.5 MB of minified JavaScript) and deliberately NOT loaded from a CDN at view
# time: a service meant to run on a private network should not need the public
# internet to render a page. Upstream changing a published file fails this build loudly.
#
# To bump: change the version, build, and copy the checksum from the failure.

FROM melopt/perl-alt:${PERL_ALT}-build AS assets

ARG MERMAID_VERSION=11.16.1
ARG MERMAID_SHA256=18327bef70d96fb505fe7287d9f6a7362ebf07ff6576ddfaffb1a06f3e1a2954
ARG GHMD_VERSION=5.9.0
ARG GHMD_SHA256=6112686f954db5d3806fb96116d2ab20ad3018469ab1015c587fd8efe7d25cf4

WORKDIR /assets
RUN set -eux; \
    if ! command -v curl >/dev/null 2>&1; then \
      apt-get update; \
      apt-get install -y --no-install-recommends curl ca-certificates; \
      rm -rf /var/lib/apt/lists/*; \
    fi; \
    curl -fsSL -o mermaid.min.js \
      "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID_VERSION}/dist/mermaid.min.js"; \
    curl -fsSL -o github-markdown.css \
      "https://cdn.jsdelivr.net/npm/github-markdown-css@${GHMD_VERSION}/github-markdown.css"; \
    echo "${MERMAID_SHA256}  mermaid.min.js"       | sha256sum -c -; \
    echo "${GHMD_SHA256}  github-markdown.css"     | sha256sum -c -

# ----------------------------------------------------------------- builder ---

FROM melopt/perl-alt:${PERL_ALT}-build AS builder

# cpanfile* alone first, so the dependency layer survives every change to the
# application itself.
COPY cpanfile* /app/
RUN pdi-build-deps

COPY . /app/

# The suite in t/ exercises the sanitiser, every upload path, the viewer and the
# whole MCP handshake. Running it here means a broken build never ships.
# pdi-run-tests also syntax-checks everything in /app/bin.
RUN /usr/bin/pdi-entrypoint pdi-run-tests

# Coverage, with a floor. Off by default because Devel::Cover roughly triples
# the run time and every `docker build` would pay it; CI turns it on:
#
#     docker build --build-arg COVERAGE=1 --target builder .
#
# The threshold is enforced by bin/coverage itself, so the build fails on a drop
# rather than printing a number nobody reads.
ARG COVERAGE=0
ARG COVERAGE_MIN=90
RUN if [ "$COVERAGE" = "1" ]; then \
      cpm install -g --show-build-log-on-failure Devel::Cover \
      && /usr/bin/pdi-entrypoint /app/bin/coverage "$COVERAGE_MIN"; \
    else \
      echo "coverage: skipped (build with --build-arg COVERAGE=1)"; \
    fi

# ----------------------------------------------------------------- runtime ---

FROM melopt/perl-alt:${PERL_ALT}-runtime

COPY --from=builder /deps/    /deps/
COPY --from=builder /app/     /app/
COPY --from=assets  /assets/  /app/public/assets/

# The workspace is a bind mount in every real deployment. Creating it here means
# the image still runs standalone: docker run --rm -p 8080:8080 share
RUN mkdir -p /workspace && chmod 0777 /workspace

ENV SHARE_ROOT=/workspace \
    MOJO_MODE=production

EXPOSE 8080

# Docker does not run HEALTHCHECK through the ENTRYPOINT, so PERL5LIB is unset
# for it and nothing from /deps is reachable. bin/health-check is core-only.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["perl", "/app/bin/health-check"]

# Two workers: a low-traffic hand-off service, and SQLite writes serialise
# anyway. The reaper's claim logic is correct at any worker count.
CMD ["perl", "/app/share.pl", "prefork", "-l", "http://*:8080", "-w", "2"]
