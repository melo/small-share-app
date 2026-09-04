# Problems with this project's instructions, found the hard way

Written after a session that added chat rooms and tried to cut a release from
them. Every item below is something the documents say, do not say, or say twice
in different places — with what it actually cost. The last section is separate on
purpose: things that were my error and not a document's.

Nothing here is fixed yet except where noted. This is the input for a session
that improves the documents.

---

## A. The release ritual assumes work that nothing tells you to do

### A1. "Prepared" was never defined *(a section for this was added this session — review the wording)*

`MAINTAINING.md` begins at **step 1, write the message**, and every step after it
assumes the code is already committed, already tested and already correct. So a
reader who has *written the code* can walk the whole ritual and hand over
tag-and-push commands over an **uncommitted working tree** — which is exactly
what happened here. The tag would have been signed onto the previous release's
commit.

The document already records that failure from the other direction (`v1.2.3` was
signed onto the same commit as `v1.2.2`) without noticing that its own numbered
steps allow it.

### A2. Step 2's own command silently drops new files

> ```bash
> git commit -a -F ./v1.3.1.msg
> ```

`git commit -a` stages modifications to **tracked** files. A release that adds
new source files — this one added six — commits without them, and both `make
test` and `make coverage` still pass **on the box**, because the files are on
disk. The failure only appears in CI, or in the published image.

The example command in the document is the trap. It needs `git add` beside it, or
a `git status` check.

### A3. Where the gates run is ambiguous, and there is no answer for "docker seems missing"

> Run `make test` and `make coverage` here, before the commit leaves the box.
> Both build the image, so both want docker — which the box has and the laptop
> may not.

"Here" means the box. But nothing says what to do when you *believe* docker is
absent — and a sandboxed shell in the development container answers
`docker: command not found` while `/usr/bin/docker` works perfectly through
`DOCKER_HOST`. I took the false negative at face value and reported both gates as
unrunnable. They run in about two minutes.

### A4. Nothing says to verify what the tag will name

Step 5 tags whatever `HEAD` is. There is no `git log -1` check, no instruction to
tag an explicit SHA, and no reminder that a `git pull --ff` may have brought
commits the tagger has not read. The published version string comes from
`share.pl` in that commit, so a tag on the wrong commit produces an image that
misreports itself for the rest of its life — the `v1.2.3` story again.

### A5. The process has no answer for "the version commit is no longer the tip"

The ritual assumes: bump, commit, push, tag. When a later commit lands before
tagging — a doc fix, a review comment — the version commit is one behind the tip,
and the document says nothing about which of these is right:

- tag the tip, and accept that `git log` at the tip and `git show <tag>` tell
  different stories;
- tag the version commit, leaving later commits unreleased;
- amend or squash, which means a force-push to a remote the laptop may have
  pulled.

That is exactly the state this release is in now, and the choice was mine to
invent.

### A6. There is no answer for a burnt version number

`v1.4.0` was tagged onto a commit that did not contain the feature its notes
described. Nothing in the documents covers it: do you delete and re-tag, do you
move to the next patch number, and what do you tell whoever pulled the bad image?
We invented "1.4.0 stands as a version nobody should install, the feature lands
in 1.4.1" — a reasonable answer, and it should be written down rather than
re-derived under pressure.

### A7. The release notes are only tied to the *version*, never to the *content*

The document is careful that the version, the tag and the bump agree. Nothing
says the message must describe **what is in the commits being tagged**. So a
`v1.4.0.msg` describing chat rooms could sit next to a `v1.4.0` tag containing no
chat rooms, and every rule in the file was still satisfied.

### A8. The `v*.msg` glob is a known hazard with no defence

> `scp box:small-share-app/v*msg .`

The document warns, correctly, that a leftover message file would be picked up by
the next release. Its only defence is a human remembering `ssh box rm ...` in a
later step. The file is untracked, so nothing enforces or notices it. There was a
stale `v1.3.4.msg` on the box at the start of this session, from a release that
had already shipped.

A glob is the wrong tool here: `scp` the exact filename, or have step 1 refuse to
write a second one.

### A9. "box" and "laptop" are never defined, and one path is hardcoded

The steps are split across two machines that the document never introduces. In an
agent session neither word fits: the code lives in a container that is not the
user's machine and not the laptop, reached over ssh as `box`. The `scp
box:small-share-app/...` path also assumes one host's directory layout.

Worth one sentence at the top: which machine holds the code, which holds the
signing key, and that `box` is an ssh alias rather than a hostname.

### A10. No mechanical pre-flight check

Everything above is prose spread across two documents. A `make release-check`
that asserted — clean tree, exactly one `v*.msg`, `$VERSION` matching it, both
gates green, `main` pushed — would have caught A1, A2, A4, A5 and A8 without
anyone reading a word.

---

## B. The project's instructions and the container's instructions disagree

### B1. Push one remote, or both?

- `MAINTAINING.md`, step 3: **"Push `main` to the forge and stop."**
- The `ccc` skill's `more.md`: **"push both, in the same breath. A forge that is
  ahead of GitHub is the kind of drift nobody notices until it matters."**

Both are defensible — the project wants GitHub to receive `main` and the tag
together in step 6, so that nothing publishes early. Neither document mentions
the other, so an agent reading both does the wrong one. I went looking for a
GitHub push from the box, hit a `GH_TOKEN` scope refusal, and reported a blocker
that this process never needed.

Whichever rule wins, it should be stated in `MAINTAINING.md` **as a deliberate
exception**, naming the other.

### B2. The GitHub token cannot push this repository at all

`/run/ccc/secret-GH_TOKEN` lacks the `workflow` scope, so any push from the box
that touches `.github/workflows/*` is refused — including comment-only edits.
Under the current process that is harmless (the laptop pushes GitHub), but it
means the box can *never* be the fallback, and nothing says so.

### B3. Nothing in the repo points an agent at any of this *(a `CLAUDE.md` was added this session)*

There was no `CLAUDE.md`. An agent landing in the checkout had four documents to
discover on its own, and no pointer to the release rules before it started
talking about releases.

---

## C. Testing and quality documents

### C1. `CONTRIBUTING.md` described the suite as a single file *(fixed this session)*

> **A test.** `t/share.t` is one file of `Test::Mojo` subtests and it is where
> behaviour is pinned down.

A feature large enough to want its own test file had no documented home, and the
reason a second file is *necessary* here — Mojolicious::Lite's app is a singleton
in `main`, so two `Test::Mojo` instances in one process fight over the store — was
not written down anywhere. Three other documents named `t/share.t` individually,
so adding a file meant editing all of them.

### C2. The browser suite has no defined place in a release

`CONTRIBUTING.md` calls `make e2e` "the pass you make by hand when the front end
changes". The release ritual never mentions it. So for a release that changes the
front end — this one adds a whole page — nobody says whether it is required,
optional, or someone else's job.

### C3. The coverage floor is documented in three places with two numbers

`CONTRIBUTING.md` says "It sits above 93%", `docs/DESIGN.md` says "It is 94.9%
today", `Makefile` says `COVERAGE_MIN ?= 90`. The live number is now 95.1%. Any
prose number goes stale the moment someone writes a test; only the floor belongs
in a document.

---

## D. What the documents never say about upgrading a live instance

### D1. Nothing describes what a release does to the database

The migrations are documented as an implementation detail in `docs/DESIGN.md`
("one directory is the whole state"), and nowhere as a release concern. This
release adds a column and three tables, which is fine — but the interesting part
is that **it cannot be undone by installing the old image**: `Mojo::SQLite`
refuses to start against a database newer than the code, so the previous release
dies at boot with `Active version 4 is greater than the latest version 3`.

I only know that because I tested it against the real 1.3.4 code. It belongs in
the release checklist as a question every release must answer — *does this
migrate, and how does an operator go back?* — and the answer belongs in the
notes.

### D2. Settings are documented in five places and forwarded in four

A setting has to be added to: `share.pl`, `.env.example`, the README table, and
all four compose files. `1.3.4` was a release about exactly this failure — a
setting nobody forwarded looks identical to a setting nobody set — and the
mechanism that caused it is unchanged. `SHARE_RATE_PER_SECOND`,
`SHARE_RATE_PER_MINUTE`, `SHARE_REQUIRE_SIGNED_UPLOADS` and `SHARE_SECRET_KEY`
are **still** in the README's "read by the app" table and still forwarded by no
compose file at all.

A test that reads `%CFG`'s keys and asserts each one appears in every compose
file would end this class of bug permanently.

---

## E. Not the documents' fault — mine

Listed so the fixes above are not asked to carry weight they should not.

1. **I said a release was prepared while the code was uncommitted.** No document
   told me to commit, and no document had to.
2. **I concluded docker was unavailable** from one sandboxed `which docker`,
   without reading the `ccc` skill that documents it — a skill whose description
   says to read it "when something about this machine is surprising".
3. **I handed over container paths and a local-file send** instead of the `share`
   MCP server, which the same skill states plainly is the only way to give the
   user a file.
4. **I wrote project process into agent memory** instead of the repository, where
   the next person — human or agent — would find it.
