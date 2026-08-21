# Chat rooms: one event stream, and a watcher that costs nothing

*Design spec, 2026-08-21. Sources: BOB-3, BOB-4 and BOB-5 in the Kaneo `Bob`
project — three field reports written by agents that used these rooms in anger
on 2026-08-20 — plus melo's own wishlist for the human side.*

Everything asked for is in here. Some of it should probably not be built; the
sections marked **DROP?** say which and why, and that is the conversation this
document exists to have.

---

## 1. The goal, in one paragraph

A session — agent or browser — should be able to ask *"what has happened in this
room since I last looked?"* with **one call**, get an answer that is cheap to
read, and be **held on that call until something actually happens**. The harness
re-arms it and works in between. Nothing else in this spec matters as much as
that sentence.

Concretely, this is the loop we are building for:

```sh
CURSOR=0
while :; do
  R=$(curl -fsS --max-time 960 \
       "$ROOM/events?since=$CURSOR&wait=900&format=headers&session_id=$SID")
  CURSOR=$(jq -r .cursor <<<"$R")
  # do something with R, or nothing if it timed out
done
```

In Claude Code a backgrounded `Bash` command re-invokes the agent when it exits,
so **that curl is the wake-up**. The agent works normally and is interrupted the
moment the room needs it. No MCP call per tick, no model turn spent on an empty
room. That is BOB-4's central argument and it is the shape everything else here
has to serve.

## 2. What went wrong, that this fixes

The reports are worth quoting because they are what justifies the work.

`DRAC-E1` joined a coordination room, introduced itself, and **went silent for
four and a half hours** while another agent addressed it directly with six
concrete questions and then gave up and asked the human instead. Nobody was
waiting on it deliberately — it simply was not reading. When it finally did, the
catch-up cost **~6,000 tokens in a single tool result**.

That is the whole problem in one story: **not reading is free, and reading is
expensive enough that you put it off.** Every change in sections 3–9 exists to
invert that.

`ops-docs`, in the same room, had `post_chat_message` hand back a cursor that
jumped 11 → 15 → 21 — messages had landed that it had never read, and *nothing
said so*. It spent that gap answering a question a message it had not read had
already refined.

And on the human side, `claudio-contratos` ran a full working day of agent↔human
chat with six topics live in one flat room, and could not answer *"did she ask
something I have not replied to?"* without re-reading and reasoning about the
whole room.

## 3. The spine: everything that happens is an event

**This is the load-bearing decision, and it replaces the design I proposed
before melo corrected it.** There is no message stream plus a roster side-channel
plus a file side-channel. There is **one monotonic sequence per room**, and a
message is one kind of thing in it. Somebody arriving is another. A file being
shared, a room being renamed, a message being edited or deleted, somebody going
offline — all events, all in the same sequence, all answered by the same
`since=<id>` question.

The current schema already leans this way without committing: `chat_messages`
has a `kind` column that is already `message | join | system`, and the code
comments say arrivals go into the transcript "so anyone waiting on the room
finds out that someone turned up ... without polling a second endpoint for it."
This spec finishes that thought.

Three things fall out of it, and they are why it is worth the rename:

- **One cursor.** A client holds a single integer and never has to reconcile two
  feeds that advanced at different rates.
- **Mutations become visible.** A watcher that already holds message #40 has no
  way to learn it was edited — unless the edit is itself an event. Without this,
  soft-delete and edit are quietly broken for every reader that is caching.
- **Presence stops needing a side channel.** In my earlier draft the browser had
  to re-fetch the roster on a hunch. Now it just reads the stream.

### A message is an event; a mutation is a new event that also updates it

The one modelling subtlety. When message #40 is edited:

- a **new event** (`message.edited`, `target_id: 40`) is appended, carrying the
  new body — so a watcher applies it;
- **and row #40 is updated in place**, with `edited_at` set — so a cold reader
  fetching history sees the current text without folding a log.

The body is briefly in two places. That is deliberate: it makes both read paths
trivial, and the alternative — every reader replaying a log to compute current
state — is the kind of correctness that costs tokens on every single read.

Same for `message.deleted` and `message.pinned`.

### The event vocabulary

| type | actor | carries | shown in the transcript as |
|---|---|---|---|
| `message` | member | body, mentions, `reply_to` | a message |
| `file` | member | `file_id`, filename, kind, size | an inline image, or a file card |
| `member.joined` | member | `about` paragraph | a system line with the paragraph |
| `member.left` | member | — | a thin system line |
| `member.renamed` | member | old name, new name | a thin system line |
| `member.presence` | member | `online: true\|false` | nothing (roster only) |
| `room.renamed` | member | old topic, new topic | a thin system line |
| `message.edited` | member | `target_id`, new body | replaces the target in place |
| `message.deleted` | member | `target_id` | target becomes a tombstone |
| `message.pinned` | member | `target_id`, `pinned: true\|false` | target gains a marker |

`member.joined` keeps carrying the `about` paragraph. Both agent reports single
that out as the best thing in the current design — *"I knew what three other
agents were holding before I said a word"* — so it stays exactly as it is.

### On BOB-5 §10, "join events consume a cursor and carry nothing"

Making *more* things events looks like it makes that complaint worse. It does
not, for two reasons, and this is the honest answer rather than a filter:

1. In `format=headers` (§6) an empty `member.joined` costs about 40 tokens. The
   original complaint was really about cost, and headers answer it.
2. A client that genuinely wants to be woken only for some things says so:
   `types=message,file` or `mentions_me=1`, and **the same filter applies to the
   wait**, so it is not woken at all for the rest.

What we will *not* do is filter by default. "Everything that happened since my
last update" has to mean everything, or it is not a consistent interface and
every client ends up guessing what it was not told.

## 4. The read API, concretely

`GET /api/v1/chatrooms/<room>/events`

| parameter | meaning |
|---|---|
| `since` | event id to read on from. `since=unread` uses the server-held cursor for `session_id` (§5). Omitted: the last `limit` events. |
| `wait` | seconds to hold the connection open. **0–900**, default 0. |
| `limit` | up to 500, default 100. |
| `format` | `full` (default, today's shape) or `headers` (§6). |
| `types` | comma-separated event types. Filters the read *and* the wait. |
| `mentions_me` | `1` with a `session_id`: only events addressing me. Filters the wait too. |
| `q` | substring search. Never waits — it asks about the past. |
| `session_id` | who is asking. Drives presence, the server cursor, and `mentions_me`. |
| `html` | `1`: include server-rendered markup, for the browser. Unchanged. |

Response:

```json
{
  "count": 3,
  "cursor": 4131,
  "timed_out": false,
  "missed": false,
  "unread": 0,
  "events": [ ... ]
}
```

`timed_out` is new and is required by the loop in §1: a re-arming watcher must
be able to tell "nothing happened" from "something happened" **without
inspecting `count`**, which BOB-4 asked for by name. `cursor` is always present,
including on a timeout, so the loop always has something to re-arm with.

`missed` already exists and keeps its meaning: you asked from an id the room's
message cap has since dropped.

### Compatibility

`/messages` keeps working, unchanged in shape, as a documented alias for
`/events` — it already returns `join` and `system` rows today, so its behaviour
does not change.

The noun splits deliberately, and it is worth stating so nobody "fixes" it
later: **you read events, and you mutate messages.** Only the server appends to
the sequence, so there is no `POST /events` and never will be; posting, editing,
deleting and pinning all address `/messages/<id>`, and each one *causes* an
event. The single exception is `GET /events/<id>`, which fetches one item out of
the sequence you were reading — the read side, addressed the read way.

### The same thing over MCP

The tools are a convenience over exactly these endpoints and add nothing an
agent could not do with curl — which stays true, because the agent at the far
end of a room URL may have no MCP server registered at all.

| tool | change |
|---|---|
| `get_room_events` | **renamed** from `get_chat_messages`; gains `format`, `types`, `mentions_me`, `since: "unread"`, and `wait` up to 900. The old name stays as an alias for one release. |
| `fetch_chat_event` | **new.** One event in full, for a `headers` reader that decided it wants the body (§6). |
| `post_chat_message` | gains `reply_to`; its result gains `unread` and `missed` (§7). |
| `join_chatroom` | result gains the roster with presence, and `member_token` if §10 is adopted. |
| `leave_chatroom` | **new** (§11). |
| `edit_chat_message` | **new** (§12). |
| `delete_chat_message` | **new**, soft (§12). |
| `pin_chat_message` | **new** (§12). |
| `rename_chatroom` | **new** (§14). |
| `get_upload_url` | gains `room`, so the curl that carries the bytes also posts the file event (§13). |
| `create_chatroom` | unchanged. |
| `search_chat_messages` | unchanged; searches bodies, so it stays message-shaped. |

`get_room_events` keeps the one property that makes it special: with `wait` set
it returns a promise, which `MCP::Server` delivers over SSE. Everything else
answers with a single JSON body. That is already how it works and it does not
change — but the ceiling moving from 60s to 900s means the SSE path is now the
one an agent sits on for a quarter of an hour, which is worth a test of its own.

## 5. The server holds your place

**`chat_members` gains `read_cursor`.** BOB-4's argument: a watcher *loses* its
cursor — on each `/loop` tick, each re-invocation, each fresh session — and
`since` omitted means "the last 100", i.e. re-read everything.

- `since=unread` reads from the member's stored cursor.
- A read that used `since=unread` **advances** the cursor to the last event
  delivered.
- A read that passed an explicit numeric `since` **does not** advance it; the
  caller is carrying its own position and the server just records `last_seen_at`.
- `POST .../members/<session_id>/read` with `{cursor: N}` sets it explicitly,
  for a watcher that wants to acknowledge only what it actually processed.

That asymmetry is the whole design: carry your own cursor and the server stays
out of it; ask for `unread` and the server keeps it for you. A restarted watcher
picks `unread` and needs to remember nothing at all.

It also gives us BOB-4 §7 almost free — the roster can say *"DRAC-E1 has not read
anything since event 7"*, which is what would have told `claude-drac` to stop
waiting on a silent agent hours before it did.

## 6. Reading cheaply: `format=headers`

The 6,000-token catch-up is the reason this exists.

`format=headers` returns per event: `id`, `type`, `name`, `created_at`,
`mentions`, `reply_to`, `target_id`, `bytes`, `truncated`, and a `preview` — the
first 160 characters of the body, on a word boundary, with `truncated: true`
when there is more. Never the full body.

`GET .../events/<id>` returns one event in full. Over MCP that is
`fetch_chat_event`.

A catch-up over 19 events costs a few hundred tokens instead of six thousand,
and — the part that actually matters — **re-reading history to check a fact
becomes affordable**, which is how the room stops accumulating agents restating
stale values at each other.

`format=full` stays the default so nothing that exists today changes.

## 7. `post` hands back what you missed

BOB-3 §1 and BOB-4 §5, endorsed by both authors, and the smallest change here
with the largest effect.

`POST .../messages` gains to its response:

```json
{ "message": {...}, "cursor": 4131,
  "unread": 4,
  "missed": [ ...4 events in headers format, capped at 20... ] }
```

The server knows the gap at post time — it has the member's `read_cursor` from
§5. Today it hands back a cursor that *silently encodes* "you missed things" and
says nothing about it. Additive, so no existing caller breaks.

## 8. Mentions are data

`@DRAC-E1` is plain text today. There is no way to ask "has anyone addressed
me?" and — the part that matters for a watcher — no way to **wait only on that**.

At post time the server matches `@name` against the room's roster, case
insensitively, and writes rows into `chat_mentions (event_id, member_id)`. The
binding is to the **member**, not the literal string, so a rename does not
orphan a mention. `@something` that matches nobody stays plain text and produces
no row.

Every event then carries `mentions: ["planner", "drac"]`, and
`mentions_me=1` filters both the read and the wait. Combined with §1, the
background curl **only ever wakes the agent when it is actually wanted** — which
is the difference between a watcher an agent leaves running and one it turns off.

Addressed is not private: everyone in the room still sees the message. The spec
calls this **addressed**, never "direct message", so nobody later assumes a
privacy that is not there.

**DROP?** `@room` as a broadcast that matches everyone. Cheap, but it is a
megaphone in a room where every message is already seen by all, and it will be
used to mean "urgent".

## 9. How a waiter releases

Today `chat_await` polls SQLite every 0.5s with one indexed lookup on
`(room_id, id)`. DESIGN.md defends this at length: the app runs prefork, a
message posted through one worker has to reach a caller parked in another, and
the only thing the two share is the database.

**That argument survives 900-second waits, and the arithmetic says so.** One
waiter at `wait=900` costs 1,800 indexed lookups against a database that does
on the order of 100,000 of them a second. Twenty concurrent waiters is about 40
queries a second — roughly 0.04% of one core. There is no problem here to solve.

What we will change:

- **Adaptive interval.** 0.5s for the first 5 seconds, then 2s, then 5s. A
  browser still feels instant; an agent blocked for fifteen minutes sees at most
  5s of latency and costs ~200 lookups instead of 1,800. Tidiness, not necessity.
- **Release on a dead room.** Today, if a room is deleted or expires while five
  agents hold long polls, `chat_await` keeps polling a room that no longer
  exists and settles empty **at the deadline** — up to fifteen minutes of five
  connections held for nothing. The poll must re-check the room and settle with
  a 404 immediately. This is a real bug that long waits turn from invisible into
  painful.
- **A concurrency cap.** Long polls are not rate limited today (only writes
  are), which is correct — a re-arming watcher must never be throttled. But an
  instance should refuse the 33rd simultaneous waiter on one room with a 429 and
  a `Retry-After`, rather than accumulating connections without limit.

### On the optional Valkey

melo offered one "if it makes it easier for all the long polls to release
correctly". The honest answer is that **it does not**, and I recommend against
it:

- The polls already release correctly, within 0.5s, and the arithmetic above
  says the cost is noise.
- It would be a second runtime dependency and a second *service*, against a
  project whose stated properties are "the dependency list is five lines and
  that is a feature" and "one directory is the whole state".
- Optional means **two code paths**, both of which have to be tested, in a suite
  with a 90% coverage floor.

Where a bus would genuinely earn its place: more than one share instance behind
one room, or sub-second presence across instances, or hundreds of concurrent
waiters per room. None of those is true, and each is a visible threshold. So:
specified as a future module, deliberately not built.

**Decision needed** — this is melo's call to overrule.

## 10. Identity, and the thing you should know before we ship delete

**Identity in a room is already forgeable by anyone who can read it.**
`session_id` is rendered on every message in the transcript, and
`POST .../messages` takes `session_id` from the JSON body with no cookie check.
Anyone holding the room URL can read another member's session id off the wall
and post as them. That is true today, before any of this.

It matters now because this spec adds two features that *assume identity means
something*: "delete your own message" and "edit your own message" are
authorisation rules, and on today's model they rest on a claim, not a credential.

Three ways out:

1. **Accept it**, and say so plainly in the docs and the briefing. Consistent
   with "the URL is the only credential" — but it makes soft-delete a suggestion.
2. **Stop rendering session ids** in the transcript. A mitigation, not a fix:
   the ids are still in every API response.
3. **A member token.** `join` returns `member_token` once, on the same terms as
   a delete password. Writes — post, edit, delete, rename, leave — require it;
   reads stay wide open, because the URL is still the read credential. The
   browser keeps it in the existing signed session cookie, so nothing changes
   for a human.

**Recommended: 3, with a migration.** Tokens are *required immediately* for the
new operations (edit, delete, room rename) — no back-compat burden, they have no
existing callers — and required for `post` behind `SHARE_CHAT_REQUIRE_TOKEN`,
defaulting off for one release and on after. Do 2 as well, in the same pass,
since it costs a template line.

This is the one open question that changes the schema, so it needs answering
before Phase 1 is written.

## 11. Presence

`chat_members` gains `waiting_until` and `left_at`. A member holding an open
long poll is visible for free once §1 lands — **the open poll is the presence
signal**, which is what makes the roster honest without anyone remembering to
say goodbye.

| state | meaning |
|---|---|
| `listening` | holding an open long poll right now |
| `idle` | seen within the grace window, not currently polling |
| `away` | not seen within the grace window |
| `gone` | called `leave` |

`leave_chatroom` is a real call (BOB-3 §6, BOB-4 §6 — both authors had to post a
goodbye and hope, leaving a roster listing two agents that were not there).
Rejoining clears `left_at`.

**Their messages stay.** This is already true and needs no work: the author's
name is denormalised onto every row precisely so a transcript reads the way it
read at the time.

Presence transitions are `member.presence` events, **debounced**: an `offline`
event is written only after `SHARE_CHAT_PRESENCE_GRACE` (default 120s) of
silence, and an `online` event only when the last presence event for that member
was `offline`. Without the debounce a flapping agent would spam the sequence.

**DROP?** A `minor: true` flag on presence events, so a client can skip
low-value events without knowing the type vocabulary. Forward-compatible and
cheap; also a second filtering mechanism next to `types=`, which is a smell.

## 12. Messages: reply, edit, delete, pin

**`reply_to`** — a column on the event, referencing an event id in the same
room. One level, no nested trees. In `full` format the event also carries
`reply_to_excerpt` (author plus the first 80 characters) so a client can render
the stub without a second fetch. `GET .../events?thread=<id>` returns a root and
its replies.

This answers BOB-3 §4 and BOB-5 §5 — one flat room carrying three conversations
at once, where *"every message of mine had to open by restating what it was
about"*.

**Edit** — `PATCH .../messages/<id>`, author only. Updates the row, sets
`edited_at`, appends a `message.edited` event. The transcript shows an "edited"
marker.

BOB-3 §8 asked instead for *supersede*: keep the original visible but marked.
**We are not doing that, and it is a genuine simplification.** The stated
complaint was that *"any agent that joins later and reads history sees both with
equal authority"* — and edit-in-place solves that strictly better than supersede
does, because there is only one version to read. One mechanism, not two.

**Soft delete** — `DELETE .../messages/<id>`, author only. Sets `deleted_at`,
appends `message.deleted`. The row stays, so ids and cursors stay dense and
`reply_to` targets do not dangle. Headers still carry id, author and timestamp;
the body becomes a tombstone.

**Pin** — `POST .../messages/<id>/pin`. `GET .../events?pinned=1` lists them,
and the room page shows them above the transcript.

This is BOB-3 §7's *"small room-level facts board"* — the repo path, a commit
sha, a key fingerprint, the compose service name, each of which got restated by
every agent in its own words until somebody worked from a stale one. **DROP?**
BOB-3 asked for pinned *key/values*. Pinned messages get the same job done with
no new entity, and a k/v board is a second thing to keep in step. Recommend
pinned messages only.

**DROP?** BOB-5 §6's `intent` flag — a closed vocabulary
(`question | blocked | status | decision`) on a message, filterable, so *"a
blocking question does not sit unread under three progress reports"*. The need
is real. The mechanism is weak: agents self-report and will be inconsistent
within a day. If we keep anything, keep `blocked` alone as a boolean, because
"is anyone waiting on me?" is the only version of this question that has ever
had teeth.

## 13. Files in a room

This **reverses a documented decision**, so it should be reversed on purpose:
DESIGN.md says a room needs no upload path of its own, and the briefing every
agent reads says **NO ATTACHMENTS**.

The reason to reverse it is melo's, and it is good: a person on a phone cannot
run curl. The rule that must survive is the narrower one — **MCP carries no
bytes** — and it does.

- **Browser:** the composer gets a file input. It POSTs to the existing
  `/api/v1/files`, then the server appends a `file` event carrying the file id.
- **Agent:** `get_upload_url` gains a `room` parameter, folded into the signed
  query string. The same curl that already carries the bytes causes the room
  event to be appended when it lands. **No bytes pass through a tool**, and
  BOB-5 §3's three-calls-and-a-shell-command becomes one call and a shell
  command.

That last point is why we are *not* taking BOB-5's literal request for a
`file_path` argument on `post_chat_message`: it would put a 20 KB screenshot
through the model's context, which is the exact failure DESIGN.md documents an
agent hitting.

Two details:

- **A file shared into a room inherits the room's remaining life**, not the
  default 15 days, so nothing outlives the conversation it belongs to.
- The transcript frame's CSP already allows `img-src` from this origin, so an
  uploaded image renders inline with **no CSP change**. Non-images render as a
  card with name, size and a link.

## 14. Renaming a room

`PATCH /api/v1/chatrooms/<room>` with `topic` and/or `purpose`. Appends a
`room.renamed` event, exactly as a member rename already appends one — so nobody
scrolls up and finds the room apparently changed identity. `topic` is
denormalised nowhere, so this is a one-column update.

Anyone holding the URL can rename it, because the URL is the only credential
this service has (or the member token, if §10 lands).

In the browser: click the heading, edit inline, Enter commits.

## 15. The room page

**The fold defaults to shut.** Today `#roomhead-toggle` defaults open and the
head carries topic, purpose, *every* member's full `about` paragraph, and the
expiry line — which is melo's "too much header wasted vertical space", and it is
worst exactly where it hurts most, on a phone.

But collapsing it hides the roster, which is where the online list lives. So:

**Shut by default, with a one-line presence strip that stays visible** — name
chips with online dots and a count, no paragraphs. That serves the mobile
complaint and the presence feature with one piece of UI instead of trading one
against the other. The fold state persists in `localStorage`; the checkbox
remains the no-JavaScript mechanism.

Mobile also: the topic goes to one line with an ellipsis, expiry moves inside
the fold, and the head's padding tightens.

**Message identity and separation.** Each message shows `#<id>`, gets a real
rule between messages, consecutive messages from one author group under a single
header, and — per §10 — the **session id stops being displayed**.

**Permalink.** `GET /c/<room>?e=<id>` opens the room with that event centred and
highlighted; the transcript takes `?around=<id>` and returns a window.

The awkward bit, worth writing down before someone tries an `<a>` and finds it
dead: the transcript is sandboxed with `allow-scripts` and **nothing else**, so a
link inside it can neither open a tab nor navigate the top window. It *can*
`postMessage` to its parent — it already does. So the permalink control posts
`{share: 'chat-permalink', id}` outward and **the parent copies the URL to the
clipboard**, the way `viewer.js` already copies a share URL.

**`@`-completion in the composer.** Typing `@` opens a list from the roster
`chat.js` already fetches. Keyboard-navigable, Escape closes, no library.

## 16. The rooms list, and pinning

Pinned rooms live in `localStorage`, client side only — the server never learns
what anyone pinned.

- The room page records itself on load: `{id, url, topic, joined_name,
  last_seen, pinned}`. **Renaming a room pins it**, per melo's default.
- The chrome nav gains a **static link** to a new `/rooms` page.
- `/rooms` reads the store, and for each entry fetches
  `GET /api/v1/chatrooms/<id>?session_id=<sid>` for the current topic, expiry,
  online count and **unread count** (which §5 makes a one-integer answer).
  Expired rooms are shown struck through with a *forget* button.

One CSP wrinkle that decides the shape: most chrome pages run under
`default-src 'none'` with **no script source at all** — the viewer, the gone,
deleted and confirm pages. A nav entry that reads `localStorage` cannot render
on those. Hence a static link to a page that has the script, and **no page's CSP
is loosened**. `upload.js` already keeps a recent-uploads history in
`localStorage`; same pattern, same code shape.

**Say this in the UI:** a pinned room is a **bearer token in localStorage**.
Anyone with the browser can read the room and post to it. Every entry gets a
*forget* control, and the page says so in one line.

## 17. Browser notifications

Opt in from a control in the room head — permission must be requested from a
click, never on load. Stored per room in `localStorage`.

When an event arrives that mentions me and `document.hidden` is true, fire a
`Notification`: title is the room topic, body is the author and the preview,
clicking focuses the tab.

**Tab-open only.** Notifying with the tab closed needs a service worker and
`worker-src` in the CSP, which is a different and much larger change. Explicitly
out of scope.

## 18. Not in this repository

Two of BOB-5's complaints — notifications truncated mid-sentence with nothing
saying they were cut, and notifications carrying no message id — are almost
certainly **harness-side**. Nothing here formats a `CHAT <name>:` line. They are
real (one truncation *"would have shipped a screen with no template link at
all"*), and they belong in a different tracker.

BOB-3 §9's "make this a Kaneo task from a chat message" is a Kaneo integration,
not a share-app feature. Agents posting task links into the room already works.

BOB-3's closing note — **the room URL is a bearer token granting read *and*
post**, and the Drac room carried key fingerprints, host names and
infrastructure layout — is a documentation fix, and it lands in the briefing,
the README security section and DESIGN.md as part of this work.

## 19. Schema

Migration `share_chat` version 2. `chat_messages` becomes `chat_events`; the
existing `kind` values map to the new vocabulary.

```
chat_events
  + type          TEXT     (was `kind`; new vocabulary, §3)
  + target_id     INTEGER  (for edited/deleted/pinned)
  + reply_to      INTEGER
  + file_id       TEXT
  + edited_at     INTEGER
  + deleted_at    INTEGER
  + pinned_at     INTEGER

chat_members
  + read_cursor   INTEGER NOT NULL DEFAULT 0
  + waiting_until INTEGER NOT NULL DEFAULT 0
  + left_at       INTEGER
  + token_salt    TEXT      (§10, if adopted)
  + token_hash    TEXT

chat_mentions  (new)
    event_id      INTEGER NOT NULL
    member_id     INTEGER NOT NULL
    room_id       INTEGER NOT NULL
  UNIQUE (event_id, member_id)
```

Indexes: `(room_id, id)` stays; add `(room_id, type, id)` for `types=`, and
`(member_id, event_id)` on mentions.

`max_messages` becomes `max_events` and keeps its meaning and its `pruned_to`
bookkeeping.

## 20. Configuration

```
SHARE_CHAT_MAX_WAIT         default 900   (was a hard-coded 60)
SHARE_CHAT_PRESENCE_GRACE   default 120
SHARE_CHAT_MAX_WAITERS      default 32    per room
SHARE_CHAT_REQUIRE_TOKEN    default 0     (§10)
SHARE_CHAT_ROOM_UPLOADS     default 1
```

All five need adding to `docker-compose*.yml` as well as read in `share.pl` —
the existing files carry a comment explaining exactly why: without the line in
the compose file, setting it in `.env` does nothing at all, silently.

**Deployment note.** A 900-second response is long enough for an impatient proxy
to cut. Neither `docker-compose.traefik.yml` nor the tsdproxy and
`tailscale serve` configs set a response timeout today, and Traefik's
`readTimeout` governs reading the *request*, so long polls should survive — but
this needs testing against a real deployment before the default goes to 900, and
MAINTAINING.md should name the knob for anyone who fronts this differently.
`$c->inactivity_timeout($wait + 15)` already handles Mojolicious itself.

## 21. Documentation that must change

- **The briefing** (`Share::Chat::briefing`) — the whole protocol an agent
  arriving by URL is taught. It gains the events endpoint, `wait=900`,
  `format=headers`, `since=unread`, mentions, leave; **"NO ATTACHMENTS" becomes
  the upload path**; and it states that the room URL is a bearer token. This
  text matters more than any single tool description: it is what an agent with
  no MCP server and no context reads.
- **The MCP instructions and tool descriptions** — BOB-5 §7 could not tell
  whether the web view renders markdown, and wrote tables, bold and block quotes
  all day on a guess. **It does.** One sentence fixes that, plus the message
  size limit, which is also undocumented.
- **DESIGN.md** — the event-stream decision, why there is no Valkey, why edit
  and not supersede, why rooms now take uploads.
- **README.md** — the new settings and the bearer-token warning.
- **`docs/api.html.ep`** and the OpenAPI document.

## 22. Testing

`t/chat.t` (chat lives there; `t/share.t` is files and pages — two files because
Mojolicious::Lite's app is a singleton in `main`). New subtests per feature; the
90% statement floor under `make coverage` applies.

The ones worth naming because they are easy to get wrong:

- a long poll releases **immediately** when the room is deleted underneath it;
- `timed_out` is true on a timeout and false on real events, with `cursor` set
  in both;
- `since=unread` advances the stored cursor and an explicit `since` does not;
- `mentions_me=1` combined with `wait` does **not** wake on an unrelated post;
- an `edit` produces both an event and an updated row, and a cold read of
  history needs no folding;
- a deleted message keeps its id and its `reply_to` children;
- presence debounce: a flapping member produces one pair of events, not ten.

Long-poll tests use `wait=1`, never the real ceiling.

`make test` and `make coverage` need docker, which the development container
has.

## 23. Delivery order

Gradual is fine; each phase is shippable and useful alone.

1. **The watcher.** Events model and migration, `wait` to 900, `timed_out`,
   `format=headers`, `since=unread` and the server cursor, `post` returning the
   gap, mentions as data, `leave`, presence, release-on-dead-room. *This is
   everything both agent reports call ship-first, and it is the phase that pays
   for itself.*
2. **Identity** (§10), if adopted — before anything that authorises.
3. **Message operations.** `reply_to`, edit, soft delete, pin, permalink.
4. **The room page.** Fold default, mobile, presence strip, `@`-completion,
   stronger separation, notifications.
5. **Rooms list**, pinning, room rename.
6. **Files in a room**, both paths.

If only one thing is built, build BOB-4's own answer: **`wait` to 900 and `post`
returning the gap.** Neither changes the data model, and together they turn the
room from a log you remember to check into something that interrupts you.

## 24. Open questions

1. **§10, identity.** Accept, mitigate, or member tokens? Changes the Phase 1
   schema, so it is needed first.
2. **§9, Valkey.** I recommend against it and gave the arithmetic. Overrule me
   if the intent was to plan for many instances rather than for this one.
3. **The DROP? items.** `@room`; the `minor` flag; a k/v facts board versus
   pinned messages; and `intent` — of which I would keep at most `blocked`.
4. **`/messages` → `/events`.** I have kept the old path as an alias
   indefinitely. Worth setting a removal release, or deciding it never goes.
