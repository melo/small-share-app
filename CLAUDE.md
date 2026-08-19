# Working on this repository

Short notes for an agent working here. Everything below points at a document
that has the whole story; nothing is duplicated, because two copies of a rule is
one copy that goes stale.

## Read these before changing things

- **[README.md](README.md)** — what the service is, how it is run, every setting.
- **[docs/DESIGN.md](docs/DESIGN.md)** — *why* it is shaped this way, and what was
  traded away for it. Most "obvious improvements" are in here as decisions with
  reasons; read it before proposing one.
- **[CONTRIBUTING.md](CONTRIBUTING.md)** — what a good change looks like: a test,
  comments that say why, no new runtime dependency without an argument, no build
  step for the front end.
- **[MAINTAINING.md](MAINTAINING.md)** — releasing, the workflows, arm64, the
  vendored assets, and a map of the files.

## Releasing

**Read [What "ready to release" means](MAINTAINING.md#what-ready-to-release-means)
before you tell anyone a release is prepared.** The short version: committed on
`main`, `make test` and `make coverage` green *here*, `$VERSION` matching the tag
about to be made, and `main` pushed to both remotes. The person on the other end
runs pull-tag-push and nothing else, so anything left undone here becomes a tag
naming the wrong commit.

## Things that will bite

- **`lib/Share/Render.pm` is a security boundary**, and so is the sandboxed frame
  around anything it renders — an uploaded file's preview and a chat room's
  transcript alike. Both layers, every time; neither is trusted alone.
- **The chrome pages run under `default-src 'none'`.** A page asks for
  `script-src` by name or does without.
- **Tests are two files.** `t/share.t` for files, pages and MCP; `t/chat.t` for
  chat rooms. They are separate processes because Mojolicious::Lite's app is a
  singleton in `main`.
- **`make test` and `make coverage` need docker**, which the development
  container has. Do not report them as unrunnable.
