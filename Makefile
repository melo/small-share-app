# small-share-app — everything you need to run, test and operate this.
#
# `make` on its own lists the targets.

SHELL   := /bin/bash
COMPOSE := docker compose
LOCAL   := docker compose -f docker-compose.local.yml
DATA    ?= ./data
PORT    ?= 8080
COVERAGE_MIN ?= 90

.DEFAULT_GOAL := help

## help: list these targets
help:
	@echo "small-share-app — targets:"
	@sed -n 's/^## //p' $(MAKEFILE_LIST) | awk -F': ' '{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

## test: build the image up to the test stage, running the whole suite
# This is the same thing CI runs, and the same stage the published image is
# built through — one definition of "does it work".
test:
	docker build --target builder --progress plain -t small-share-app-test .

## coverage: run the suite under Devel::Cover and enforce the floor
# The same command CI runs. Slower than `make test` — Devel::Cover roughly
# triples the run — which is why it is a separate target.
coverage:
	docker build --target builder --progress plain \
	  --build-arg COVERAGE=1 --build-arg COVERAGE_MIN=$(COVERAGE_MIN) \
	  -t small-share-app-coverage .

## dev: run locally on 127.0.0.1:8080, no Tailscale, rebuilding first
dev:
	$(LOCAL) up -d --build
	@echo "listening on http://127.0.0.1:$(PORT)"

## dev-logs: follow the local container's log
dev-logs:
	$(LOCAL) logs -f --tail=100

## dev-down: stop the local container
dev-down:
	$(LOCAL) down

## up: start the Tailscale stack (needs .env with TS_AUTHKEY)
up:
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory ps

## down: stop the Tailscale stack (the data directory is untouched)
down:
	$(COMPOSE) down

## ps: container status
ps:
	@$(COMPOSE) ps

## logs: follow the logs
logs:
	$(COMPOSE) logs -f --tail=100

## ts-status: what the Tailscale sidecar thinks its state is
ts-status:
	@$(COMPOSE) exec tailscale tailscale status </dev/null || true

## health: ask the app whether it is alive and what it is holding
health:
	@$(COMPOSE) exec -T share perl /app/bin/health-check </dev/null && echo "ok"

## list: what is currently shared, newest first, read from the database
# There is no "list everything" endpoint on purpose — an agent should only ever
# see its own session — so this reads SQLite directly.
list:
	@sqlite3 -header -column $(DATA)/share.db \
	  "SELECT substr(secret,1,12)||'…' AS id, filename, kind, size, \
	          datetime(created_at,'unixepoch') AS uploaded, \
	          datetime(expires_at,'unixepoch') AS expires, \
	          COALESCE(session_id,'-') AS session \
	     FROM files ORDER BY created_at DESC;" \
	  2>/dev/null || echo "no database at $(DATA)/share.db (or sqlite3 is not installed)"

## reap: delete expired files now instead of waiting for the hourly pass
# </dev/null is not decoration: `docker compose exec -T` inherits this shell's
# stdin, and without it a `make reap` inside a piped script swallows the rest of
# the script.
reap:
	@$(COMPOSE) exec -T share /usr/bin/pdi-entrypoint /app/bin/reap </dev/null

## du: how much disk the workspace is using
du:
	@du -sh $(DATA) 2>/dev/null || echo "no workspace at $(DATA)"
	@echo -n "  files: "; find $(DATA)/files -type f 2>/dev/null | wc -l

## backup: stop, tar the workspace to ./backups, start again
# Stopped for the duration so the SQLite file is not captured mid-write. At this
# size that is seconds, and it beats a subtly corrupt tarball.
backup:
	@mkdir -p backups
	@ts=$$(date +%Y%m%d-%H%M%S); \
	  $(COMPOSE) stop share; \
	  tar -C $(dir $(DATA)) -czf backups/share-$$ts.tar.gz $(notdir $(DATA)); \
	  $(COMPOSE) start share; \
	  echo "wrote backups/share-$$ts.tar.gz"; ls -lh backups/share-$$ts.tar.gz

.PHONY: help test coverage dev dev-logs dev-down up down ps logs ts-status health list reap du backup
