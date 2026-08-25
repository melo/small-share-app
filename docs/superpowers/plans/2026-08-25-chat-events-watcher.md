# Chat events and the cheap watcher — Implementation Plan (Phase 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a chat room from a log an agent forgets to read into one event
stream it can park on for fifteen minutes, read for a few hundred tokens, and be
woken by only when it is actually addressed.

**Architecture:** One monotonic sequence per room (`chat_events`, renamed from
`chat_messages`), where a message is one kind of event and arrivals, departures,
renames, presence flips and the room's own death are others. Reads answer
"everything since `<id>`" with an optional long park; the server keeps each
member's read position so a restarted watcher needs to remember nothing. Writes
are authorised by a member token issued once at join.

**Tech Stack:** Perl 5, Mojolicious::Lite (`share.pl`), `Mojo::SQLite` with
per-name migrations, `MCP::Server`, `Test::Mojo`. No new runtime dependency.

**Spec:** `docs/superpowers/specs/2026-08-21-chat-events-design.md` — read §3,
§4, §5, §6, §9, §10 and §11 before starting. This plan implements Phase 1 and
Phase 2 of §23; Phases 3–6 get their own plans.

## Global Constraints

- **No new runtime dependency** without an argument in the PR. The list is five
  lines and that is a feature. (`CONTRIBUTING.md`)
- **No build step for the front end.** CSS and JS are served straight from
  `public/assets` under a strict CSP.
- **Tests are two files.** `t/chat.t` for rooms, `t/share.t` for files and pages.
  Never a second `Test::Mojo` in one process — Mojolicious::Lite's app is a
  singleton in `main`.
- **`make test` and `make coverage` need docker, which this container has.**
  Never report them as unrunnable. `make coverage` fails below **90%** statement
  coverage over `share.pl` and `lib/`.
- **`lib/Share/Render.pm` is a security boundary**, and so is the sandboxed frame
  around what it renders. Both layers, every time.
- **Comments say *why*.** Where something is deliberately not the obvious
  approach, the comment explains what went wrong with the obvious version.
- **Chat schema migrates under its own name** (`share_chat`), independently of
  the file store's. Never touch `Share::Store`'s migration set.
- **MCP carries no bytes**, in either direction.
- Backwards compatibility: `/messages` keeps working with its current response
  shape. Additive fields only.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `lib/Share/Chat.pm` | Schema, rooms, members, the event sequence, the briefing | Heavily extended; `MIGRATIONS` gains a `-- 2 up` block |
| `share.pl` | Routes, long-poll helper, config, templates | New `/events` routes, config keys, `chat_await` rework |
| `lib/Share/MCP.pm` | The tool surface over those routes | Tools renamed and added |
| `t/chat.t` | Every behaviour here | New subtests |
| `Makefile` | `make rooms` reads `chat_messages` **by name** | Rename with the table |
| `README.md`, `docs/DESIGN.md`, `docs/api.html.ep`, `lib/Share/OpenAPI.pm` | Docs | Task 13 |

**Local test loop** (much faster than `make test` while iterating):

```bash
cd /tmp/claude-1000/-app/e892be32-9998-4cc9-b903-1e770b7abccd/scratchpad/chat-events
SHARE_ROOT=$(mktemp -d) prove -l t/chat.t
```

`make test` before every commit that touches `lib/` or `share.pl`.

---

### Task 1: Migration 2 — the event table

**Files:**
- Modify: `lib/Share/Chat.pm` (the `MIGRATIONS` constant, and every query naming `chat_messages`)
- Modify: `Makefile` (the `rooms` target)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: nothing.
- Produces: table `chat_events` with columns `id, room_id, session_id, name,
  type, body, created_at, target_id`; `chat_members` gains `read_cursor,
  waiting_until, left_at, token_salt, token_hash`; `chat_rooms` gains
  `warned_at`; new table `chat_mentions (event_id, member_id, room_id)`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the sequence is events, and the old rows kept their meaning' => sub {
  my $id   = _room(topic => 'migrating')->{room}{id};
  _join($id, session_id => 'sess-m', name => 'planner', about => 'schema test');
  _post($id, 'sess-m', 'hello');

  my $db = $t->app->chat->sql->db;

  # The table exists under its new name, and the old one does not.
  ok $db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_events'})
    ->array, 'chat_events exists';
  ok !$db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_messages'})
    ->array, 'chat_messages is gone';

  # `kind` became `type`, with the vocabulary of the spec.
  my $types = $db->query('SELECT type FROM chat_events ORDER BY id')->arrays->flatten->to_array;
  is_deeply $types, ['member.joined', 'message'], 'join became member.joined';

  # The new columns are there and default sanely.
  my $m = $db->query('SELECT * FROM chat_members WHERE session_id = ?', 'sess-m')->hash;
  is $m->{read_cursor},   0, 'read_cursor starts at zero';
  is $m->{waiting_until}, 0, 'waiting_until starts at zero';
  is $m->{left_at},   undef, 'nobody has left';

  ok $db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_mentions'})
    ->array, 'chat_mentions exists';
};
```

- [ ] **Step 2: Run it and watch it fail**

Run: `SHARE_ROOT=$(mktemp -d) prove -l t/chat.t`
Expected: FAIL — `chat_events` does not exist.

- [ ] **Step 3: Write the migration**

Append to the `MIGRATIONS` heredoc in `lib/Share/Chat.pm`, after the `-- 1 down`
block. `Mojo::SQLite::Migrations` runs `-- 2 up` on an existing database and both
blocks on a fresh one, so the rename has to work either way.

```sql
-- 2 up
-- A message was always one kind of thing that happens in a room; the table just
-- did not say so. Renaming it is what lets an arrival, a departure, a rename and
-- the room's own death answer the same "what since <id>?" question on the same
-- cursor -- and it is what makes an edit visible to a reader that is caching,
-- which no amount of extra endpoints would have done.
ALTER TABLE chat_messages RENAME TO chat_events;
ALTER TABLE chat_events RENAME COLUMN kind TO type;

-- The old vocabulary was message | join | system, and `system` was only ever
-- written by the rename path in join_room. Map both, so a room that has been
-- running for a fortnight reads correctly after the upgrade.
UPDATE chat_events SET type = 'member.joined'  WHERE type = 'join';
UPDATE chat_events SET type = 'member.renamed' WHERE type = 'system';

-- What an event is about, when it is about another event: an edit, a delete, a
-- pin. Null for everything that stands on its own.
ALTER TABLE chat_events ADD COLUMN target_id INTEGER;

CREATE INDEX chat_events_type_idx ON chat_events (room_id, type, id);

-- Where this member has read to. The cursor used to be the caller's alone to
-- carry, and a watcher LOSES it: every re-invocation, every fresh session, and
-- `since` omitted means "the last hundred" -- i.e. read everything again.
ALTER TABLE chat_members ADD COLUMN read_cursor INTEGER NOT NULL DEFAULT 0;

-- "I will be here until T". last_seen_at already means "last touched the room in
-- any way" -- touch_member fires on reads as well as posts -- which is enough
-- for presence today. It stops being enough the moment a poll can park for
-- fifteen minutes: the member is silent that whole time while genuinely
-- listening, and any grace window short enough to spot a dead session would mark
-- a live listener away.
ALTER TABLE chat_members ADD COLUMN waiting_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE chat_members ADD COLUMN left_at INTEGER;

-- Issued once at join, on the same terms as a room's delete password. The room
-- URL stays the READ credential; this is what makes "your own message" mean
-- something when you edit or delete it.
ALTER TABLE chat_members ADD COLUMN token_salt TEXT;
ALTER TABLE chat_members ADD COLUMN token_hash TEXT;

-- room.expiring is written once, and only once, however many times the reaper
-- passes over a room in its last two hours.
ALTER TABLE chat_rooms ADD COLUMN warned_at INTEGER;

-- Mentions bind to the MEMBER, not to the literal text, so renaming yourself
-- does not orphan every message that ever addressed you.
CREATE TABLE chat_mentions (
  event_id  INTEGER NOT NULL,
  member_id INTEGER NOT NULL,
  room_id   INTEGER NOT NULL
);
CREATE UNIQUE INDEX chat_mentions_pair_idx ON chat_mentions (event_id, member_id);
CREATE INDEX chat_mentions_member_idx ON chat_mentions (member_id, event_id);

-- 2 down
DROP TABLE chat_mentions;
ALTER TABLE chat_events RENAME COLUMN type TO kind;
ALTER TABLE chat_events RENAME TO chat_messages;
```

- [ ] **Step 4: Rename the table everywhere it is named**

In `lib/Share/Chat.pm`, `chat_messages` appears in `_purge_room`, `_write`,
`_prune`, `messages`, `last_id`, `stats` and `reap`. Change every one to
`chat_events`. Leave `kind => ` argument names alone for now — Task 2 handles the
vocabulary in Perl.

In `Makefile`, the `rooms` target reads the table **by name** through `sqlite3`.
It is not code and nothing tests it, so it breaks silently:

```make
	          (SELECT COUNT(*) FROM chat_events g WHERE g.room_id = r.id) AS messages, \
```

- [ ] **Step 5: Run the whole file and make it green**

Run: `SHARE_ROOT=$(mktemp -d) prove -l t/chat.t`
Expected: PASS, all subtests.

- [ ] **Step 6: Commit**

```bash
git add lib/Share/Chat.pm Makefile t/chat.t
git commit -m "A message was always one kind of thing that happens in a room"
```

---

### Task 2: The event vocabulary in Perl

**Files:**
- Modify: `lib/Share/Chat.pm` (`join_room`, `_write`, `message_public`, `post`)
- Modify: `share.pl` (`_chat_view`, `_chat_markup`, `chat_message.html.ep`)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 1's `chat_events.type`.
- Produces: `Share::Chat::event_public($row)` returning
  `{id, session_id, name, type, body, created_at, target_id}` — `message_public`
  stays as an alias so nothing existing breaks. Events written by the server
  carry `session_id => undef, name => 'system'`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'an event says what kind of thing happened, and who did it' => sub {
  my $id = _room(topic => 'vocabulary')->{room}{id};
  _join($id, session_id => 'sess-v', name => 'planner', about => 'vocab test');
  _join($id, session_id => 'sess-v', name => 'dispatcher', about => 'vocab test');
  _post($id, 'sess-v', 'said something');

  my $got = $t->get_ok("/api/v1/chatrooms/$id/messages")->tx->res->json;
  is_deeply [map { $_->{type} } @{$got->{messages}}],
    ['member.joined', 'member.renamed', 'message'],
    'arrival, rename and speech are three kinds of event';

  # `kind` is still emitted, because the browser and any existing caller read it.
  is $got->{messages}[0]{kind}, 'member.joined', 'kind mirrors type for old callers';

  # An event the server wrote has no member behind it.
  my $row = $t->app->chat->_write($t->app->chat->find_room($id),
    undef, 'system', 'room.expiring' => 'this room closes soon');
  is $row->{session_id}, undef,    'a system event has no session';
  is $row->{name},       'system', 'and says so by name';
};
```

- [ ] **Step 2: Run it and watch it fail**

Run: `SHARE_ROOT=$(mktemp -d) prove -l t/chat.t`
Expected: FAIL — `type` is not in the JSON.

- [ ] **Step 3: Implement**

In `lib/Share/Chat.pm`, add the vocabulary as a documented constant and rename
the writer's argument:

```perl
# What can happen in a room. The sequence is the whole interface -- "everything
# since <id>" has to mean EVERYTHING, or a client is guessing at what it was not
# told -- so anything the server does to a room ends up here rather than in a
# side channel a caller has to know to ask about.
#
# Two of these have no member behind them. A room ends whether or not anybody
# made it happen, so `session_id` may be null with the name `system`.
use constant EVENT_TYPES => [qw(
  message file
  member.joined member.left member.renamed member.presence
  room.renamed room.expiring room.destroyed
  message.edited message.deleted message.pinned
)];
```

`join_room` writes `member.joined` and `member.renamed` instead of `join` and
`system`. `post` writes `message`. `_write`'s fourth argument is now a type.

`message_public` becomes `event_public`, gaining `type` and `target_id` and
keeping `kind` as a mirror:

```perl
sub event_public ($self, $row) {
  return {
    id         => 0 + $row->{id},
    session_id => $row->{session_id},
    name       => $row->{name},
    type       => $row->{type},
    # The old name for the same thing. `assets/chat.js` switches on it, and so
    # does every caller written against the shape this endpoint had yesterday.
    # It costs one key and it is why /messages can keep its promise.
    kind       => $row->{type},
    body       => $row->{body},
    created_at => iso8601($row->{created_at}),
    (defined $row->{target_id} ? (target_id => 0 + $row->{target_id}) : ()),
  };
}

*message_public = \&event_public;
```

In `share.pl`, `chat_message.html.ep` tests `$m->{kind} eq 'join'` for its
"joined" tag — change to `$m->{type} eq 'member.joined'`, and give the thin
system kinds (`member.left`, `member.renamed`, `room.renamed`, `room.expiring`,
`room.destroyed`) the `msg-system` class the CSS already has for `msg-system`.

- [ ] **Step 4: Run the tests**

Run: `SHARE_ROOT=$(mktemp -d) prove -l t/chat.t`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "Everything that happens in a room says what kind of thing it was"
```

---

### Task 3: Both wait caps, and `timed_out`

**Files:**
- Modify: `share.pl` (`CHAT_MAX_WAIT`, `_chat_wait_seconds`, config, `_chat_messages_json`)
- Modify: `lib/Share/MCP.pm:481` (the second, independent clamp)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: nothing.
- Produces: config key `chat_max_wait` (env `SHARE_CHAT_MAX_WAIT`, default 900);
  every read response carries `timed_out` as a JSON boolean.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a park that ends in silence says so, and the ceiling is configurable' => sub {
  my $id = _room(topic => 'patience')->{room}{id};
  _join($id, session_id => 'sess-w', name => 'watcher', about => 'wait test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/messages")->tx->res->json->{cursor};

  # Nothing happens, so the answer is explicit about why it is empty. A
  # re-arming loop must never have to infer this from count == 0.
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=1")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->true)
    ->json_is('/count' => 0)
    ->json_is('/cursor' => $cursor);

  # Something happens, so it is not a timeout.
  Mojo::IOLoop->timer(0.2 => sub {
    $t->app->chat->post($t->app->chat->find_room($id), session_id => 'sess-w', body => 'oi') });
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=10")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->false)
    ->json_is('/count' => 1);

  # An immediate read is not a timeout either -- it never waited.
  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->false);
};

subtest 'both wait ceilings move together' => sub {
  # There are two, and they are independent: share.pl has its own constant and
  # lib/Share/MCP.pm clamps again on the way past. Changing one and shipping was
  # the bug this test exists to prevent.
  is $t->app->config->{chat_max_wait}, 900, 'the HTTP ceiling comes from config';

  my $id = _room(topic => 'mcp patience')->{room}{id};
  _call(join_chatroom => {room => $id, session_id => 'sess-mw',
    name => 'mcpwatcher', about => 'ceiling test'});

  # 600 is above the old hard-coded 60 and below the new ceiling: if MCP.pm is
  # still clamping to 60 this answers far too early to be a 600s park.
  my $res = _call(get_room_events =>
    {room => $id, session_id => 'sess-mw', since => 99999, wait => 600});
  # It returns at once only because the test posts nothing and we do not wait for
  # it -- what is asserted is that the tool ACCEPTED the number.
  ok exists $res->{structuredContent}{timed_out}, 'the MCP read reports timing out too';
};
```

> **Note for the implementer:** the second half of that MCP subtest would park
> for ten minutes if written naively. Post from a `Mojo::IOLoop->timer` at 0.2s
> as the existing wait subtest does, so the call returns on the write.

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — no `timed_out` key, and `chat_max_wait` is not in config.

- [ ] **Step 3: Implement**

In `share.pl`, replace the constant with a configured value and record it beside
the other chat settings near line 100:

```perl
  # The longest a caller may park on a room. Sixty seconds was chosen so that "a
  # proxy in front of this -- and every MCP client's own patience -- is still
  # comfortably inside its own timeout", and NEITHER of those assumptions was
  # ever tested. Fifteen minutes is what makes a backgrounded curl a wake-up
  # instead of a poll; if a deployment's proxy cuts it, lower this rather than
  # going back to asking in a loop.
  chat_max_wait => _number(SHARE_CHAT_MAX_WAIT => 900),
```

`_chat_wait_seconds` clamps to `$c->app->config->{chat_max_wait}`.

In `lib/Share/MCP.pm`, the tool has its **own** clamp — this is the one that
silently holds if you only change `share.pl`:

```perl
      my $max = $c->app->config->{chat_max_wait};
      $wait = $max if $wait > $max;
      $wait = 0    if $wait < 0;
```

`_chat_messages_json` gains `timed_out`. It knows because a park that found
nothing returns an empty list *and* was asked to wait:

```perl
sub _chat_messages_json ($c, $room, $rows, $since, %opt) {
  ...
  timed_out => ($opt{waited} && !@$rows) ? \1 : \0,
```

Both call sites pass `waited => $wait`. The MCP tool's `$answer` closure does the
same.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add share.pl lib/Share/MCP.pm t/chat.t
git commit -m "There were two wait ceilings, and only one of them was documented"
```

---

### Task 4: `/events`, with `/messages` still keeping its promise

**Files:**
- Modify: `share.pl` (the messages route becomes a shared handler on two paths)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 2's `event_public`, Task 3's `timed_out`.
- Produces: `GET /api/v1/chatrooms/<room>/events` answering
  `{count, cursor, timed_out, missed, events => [...]}`; `/messages` answering
  the same body with the list additionally under `messages`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'events and messages are one endpoint under two names' => sub {
  my $id = _room(topic => 'two names')->{room}{id};
  _join($id, session_id => 'sess-e', name => 'planner', about => 'alias test');
  _post($id, 'sess-e', 'first');

  my $ev = $t->get_ok("/api/v1/chatrooms/$id/events")->status_is(200)->tx->res->json;
  is $ev->{count}, 2, 'the arrival and the message are both events';
  is $ev->{events}[1]{body}, 'first', 'events is the canonical key';

  my $msg = $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)->tx->res->json;
  is_deeply $msg->{messages}, $ev->{events}, 'the old key is the same list';
  is_deeply $msg->{events},   $ev->{events}, 'and the new key is there too';

  # Every parameter works on both paths.
  $t->get_ok("/api/v1/chatrooms/$id/events?q=first")->status_is(200)->json_is('/count' => 1);
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — 404 on `/events`.

- [ ] **Step 3: Implement**

Lift the existing `/messages` handler into a named sub and mount it twice:

```perl
# Reading, waiting and grepping are one question asked with different patience,
# and now under two names. `/events` is what this is: one monotonic sequence
# where a message is one kind of thing that happened. `/messages` is what it was
# called yesterday, and it keeps working unchanged -- it already returned
# arrivals and renames alongside speech, so its behaviour does not change at all,
# only its name for the list.
my $read_events = sub ($c) { ... the existing body ... };

$api->get('/chatrooms/<room:id>/events'   => $read_events);
$api->get('/chatrooms/<room:id>/messages' => $read_events);
```

`_chat_messages_json` emits both keys:

```perl
  my @public = map { $chat->event_public($_) } @$rows;
  ...
  events   => \@public,
  # The name this list had before rooms had an event stream. One extra key on the
  # wire is what lets assets/chat.js and every curl loop written last week keep
  # working, and it costs nothing to keep.
  messages => \@public,
```

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add share.pl t/chat.t
git commit -m "One sequence, reachable by the name it has and the name it had"
```

---

### Task 5: `format=headers`, and fetching one event

**Files:**
- Modify: `lib/Share/Chat.pm` (a `header_public`), `share.pl` (the read handler, a new route)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 4's read handler.
- Produces: `?format=headers` returning per event
  `{id, type, name, created_at, mentions, target_id, bytes, preview, truncated}`;
  `GET /api/v1/chatrooms/<room>/events/<id>` returning `{event => {...}}` in full.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a catch-up can cost hundreds of tokens instead of thousands' => sub {
  my $id = _room(topic => 'headers')->{room}{id};
  _join($id, session_id => 'sess-h', name => 'planner', about => 'headers test');

  my $long = 'x' x 4000;
  my $ev   = _post($id, 'sess-h', "the first line\n\n$long")->{message}{id};

  my $got = $t->get_ok("/api/v1/chatrooms/$id/events?format=headers")->status_is(200)
    ->tx->res->json;
  my ($head) = grep { $_->{id} == $ev } @{$got->{events}};

  ok !exists $head->{body}, 'a header carries no body';
  ok length($head->{preview}) <= 160, 'the preview is bounded';
  like $head->{preview}, qr/^the first line/, 'and it is the top of the message';
  is $head->{truncated}, Mojo::JSON->true, 'which it says, so nobody acts on half a sentence';
  is $head->{bytes}, length("the first line\n\n$long"), 'and how much it did not send';
  is $head->{name}, 'planner', 'the author is a header field, not a body field';

  # The body is one call away when it turns out to matter.
  $t->get_ok("/api/v1/chatrooms/$id/events/$ev")->status_is(200)
    ->json_is('/event/body' => "the first line\n\n$long")
    ->json_is('/event/type' => 'message');

  # A short message is not marked truncated.
  my $short = _post($id, 'sess-h', 'brief')->{message}{id};
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?format=headers&since=" . ($short - 1))
    ->tx->res->json;
  is $got->{events}[0]{truncated}, Mojo::JSON->false, 'nothing was cut';
  is $got->{events}[0]{preview}, 'brief', 'so the preview is the whole of it';

  # An id from another room is not readable through this one.
  $t->get_ok("/api/v1/chatrooms/$id/events/999999")->status_is(404);
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `format` is ignored, `/events/<id>` is a 404 for everything.

- [ ] **Step 3: Implement**

In `lib/Share/Chat.pm`:

```perl
# How much of a body a header shows. Enough to know whether the thing concerns
# you, short enough that catching up on twenty events costs hundreds of tokens
# rather than thousands -- a real catch-up on nineteen messages cost about six
# THOUSAND, which is why an agent that had gone quiet stayed quiet.
has preview_chars => 160;

sub header_public ($self, $row, $mentions = []) {
  my $body  = $row->{body} // '';
  my $bytes = $body;
  utf8::encode($bytes);

  my $preview = $body;
  $preview =~ s/\s+/ /g;
  $preview =~ s/\A\s+|\s+\z//g;
  my $cut = length($preview) > $self->preview_chars;
  if ($cut) {
    $preview = substr $preview, 0, $self->preview_chars;
    # On a word boundary, because a preview that stops mid-word reads as a
    # truncation bug rather than as a summary -- and because a message that
    # happens to end on one would otherwise read as complete.
    $preview =~ s/\s+\S*\z// if $preview =~ /\s/;
  }

  return {
    id         => 0 + $row->{id},
    type       => $row->{type},
    name       => $row->{name},
    created_at => iso8601($row->{created_at}),
    mentions   => $mentions,
    bytes      => length $bytes,
    preview    => $preview,
    truncated  => $cut ? \1 : \0,
    (defined $row->{target_id} ? (target_id => 0 + $row->{target_id}) : ()),
  };
}

sub event ($self, $room, $id) {
  return undef unless defined $id && $id =~ /\A\d+\z/;
  return $self->sql->db->query('SELECT * FROM chat_events WHERE room_id = ? AND id = ?',
    $room->{id}, $id)->hash;
}
```

In `share.pl`, `_chat_messages_json` picks the serialiser:

```perl
  my $headers = ($c->param('format') // '') eq 'headers';
  my @public = $headers
    ? map { $chat->header_public($_) } @$rows
    : map { $chat->event_public($_) } @$rows;
```

and the new route:

```perl
$api->get('/chatrooms/<room:id>/events/<event:num>' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));
  my $row = $chat->event($room, $c->stash('event'))
    or return _api_error($c, 404, 'no such event in this room');
  $c->render(json => {event => $chat->event_public($row)});
});
```

Add `num => qr/\d+/` to the placeholder types if the app does not already have
one; otherwise use `<event:id>` and validate in the handler.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "Reading a room should not cost six thousand tokens"
```

---

### Task 6: The server holds your place

**Files:**
- Modify: `lib/Share/Chat.pm` (cursor read/write helpers), `share.pl` (the read handler, a new route)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 4's read handler.
- Produces: `since=unread`; `Share::Chat::read_cursor($room, $session_id)` and
  `mark_read($room, $session_id, $cursor)`; every read carrying `unread`;
  `POST /api/v1/chatrooms/<room>/members/<session>/read`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the server keeps your place, but only when you ask it to' => sub {
  my $id = _room(topic => 'cursors')->{room}{id};
  _join($id, session_id => 'sess-r', name => 'reader',  about => 'cursor test');
  _join($id, session_id => 'sess-p', name => 'speaker', about => 'cursor test');
  _post($id, 'sess-p', 'one');
  _post($id, 'sess-p', 'two');

  # A watcher that remembers nothing asks for what it has not read.
  my $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r")
    ->status_is(200)->tx->res->json;
  is $got->{count}, 4, 'two arrivals and two messages';
  is $got->{unread}, 0, 'and it is now caught up';

  # Asking again gets nothing, because the server advanced the cursor.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r")
    ->status_is(200)->json_is('/count' => 0);

  # An explicit cursor does NOT move the stored one: the caller is carrying its
  # own position and the server has no business overwriting it.
  _post($id, 'sess-p', 'three');
  $t->get_ok("/api/v1/chatrooms/$id/events?since=0&session_id=sess-r")->status_is(200)
    ->json_is('/count' => 5);
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r")
    ->status_is(200)->json_is('/count' => 1)->json_is('/events/0/body' => 'three');

  # And a watcher can acknowledge only what it actually processed.
  _post($id, 'sess-p', 'four');
  _post($id, 'sess-p', 'five');
  my $back = $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r")
    ->tx->res->json;
  $t->post_ok("/api/v1/chatrooms/$id/members/sess-r/read" => json =>
      {cursor => $back->{events}[0]{id}})->status_is(200)->json_is('/unread' => 1);

  # Somebody who never joined has no place to keep.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=nobody")
    ->status_is(200)->json_is('/count' => 0);
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `since=unread` is not numeric, so it is treated as absent and
returns the last hundred.

- [ ] **Step 3: Implement**

In `lib/Share/Chat.pm`:

```perl
# Where this member has read to, and how to move it.
#
# The asymmetry is the whole design: carry your own cursor and the server stays
# out of it; ask for `unread` and the server keeps it for you. A watcher that
# picks `unread` is stateless, which is the only kind that survives an agent
# being re-invoked -- and being re-invoked is exactly what a backgrounded curl
# does to it.
sub read_cursor ($self, $room, $session_id) {
  my $member = $self->member($room, $session_id) or return undef;
  return 0 + $member->{read_cursor};
}

sub mark_read ($self, $room, $session_id, $cursor) {
  return unless defined $cursor && $cursor =~ /\A\d+\z/;
  my $member = $self->member($room, $session_id) or return;
  # Never backwards: two reads can overlap, and the later one landing first must
  # not un-read what the earlier one already delivered.
  return if $cursor <= $member->{read_cursor};
  $self->sql->db->query('UPDATE chat_members SET read_cursor = ? WHERE id = ?',
    $cursor, $member->{id});
  return;
}

sub unread_count ($self, $room, $session_id) {
  my $member = $self->member($room, $session_id) or return 0;
  return $self->sql->db->query(
    'SELECT COUNT(*) FROM chat_events WHERE room_id = ? AND id > ?',
    $room->{id}, $member->{read_cursor})->array->[0];
}
```

In `share.pl`'s read handler, resolve `unread` before querying, and advance only
in that case:

```perl
  my $since   = $c->param('since');
  my $session = $c->param('session_id');

  # "Give me what I have not read." A watcher LOSES its cursor -- every
  # re-invocation, every fresh session -- and `since` omitted means "the last
  # hundred", which is how catching up became re-reading everything.
  my $by_cursor = defined $since && $since eq 'unread';
  $since = $chat->read_cursor($room, $session) // 0 if $by_cursor;
```

and after the rows are in hand (both the immediate and the parked path):

```perl
  $chat->mark_read($room, $session, $rows->[-1]{id}) if $by_cursor && @$rows;
```

`unread` goes into every response via `unread_count`.

The acknowledgement route:

```perl
$api->post('/chatrooms/<room:id>/members/<session>/read' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));
  my $args = eval { _chat_args($c, qw(cursor)) };
  return _api_error($c, 400, $@) if $@;
  $chat->mark_read($room, $c->stash('session'), $args->{cursor});
  $c->render(json => {
    cursor => $chat->read_cursor($room, $c->stash('session')) // 0,
    unread => $chat->unread_count($room, $c->stash('session')),
  });
});
```

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "A watcher that must remember where it was is a watcher that forgets"
```

---

### Task 7: `post` hands back what you missed

**Files:**
- Modify: `share.pl` (the post route), `lib/Share/MCP.pm` (`post_chat_message`)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 5's `header_public`, Task 6's `read_cursor`/`unread_count`.
- Produces: the post response gains `unread` (integer) and `missed` (array of
  headers, at most 20).

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the moment you post is the moment you are provably listening' => sub {
  my $id = _room(topic => 'crossing')->{room}{id};
  _join($id, session_id => 'sess-x', name => 'talker',  about => 'gap test');
  _join($id, session_id => 'sess-y', name => 'other',   about => 'gap test');

  # Catch up, so the gap below is unambiguous.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-x");

  # Two things are said while sess-x is not looking. This is the exact failure
  # from the field: a cursor that jumped 11 -> 15 -> 21 and said nothing.
  _post($id, 'sess-y', 'you missed this');
  _post($id, 'sess-y', 'and this');

  my $res = _post($id, 'sess-x', 'saying my piece');
  is $res->{unread}, 2, 'the ack says how far behind you were';
  is scalar @{$res->{missed}}, 2, 'and hands the gap over';
  is $res->{missed}[0]{preview}, 'you missed this', 'as headers, not as bodies';
  ok !exists $res->{missed}[0]{body}, 'because the point was to be cheap';

  # Posting caught you up, so the next post has nothing to report.
  is _post($id, 'sess-x', 'again')->{unread}, 0, 'and posting marks you current';
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — the post response has only `message` and `cursor`.

- [ ] **Step 3: Implement**

In `share.pl`'s post route, between storing and rendering:

```perl
  # What landed while this caller was not looking. The server has known this all
  # along -- it has the room and it has the member's read cursor -- and until now
  # the acknowledgement spent that knowledge saying {"cursor": 9}. Two separate
  # sessions reported losing work to it: one answered a question that an unread
  # message had already refined, the other had its six questions go unread for
  # four and a half hours.
  my $missed = $chat->messages($room,
    since => $chat->read_cursor($room, $args->{session_id}) // 0,
    limit => 20);
  # Not the message just posted -- it is in the response already.
  $missed = [grep { $_->{id} != $row->{id} } @$missed];

  # Posting proves you are here, so it also catches you up.
  $chat->mark_read($room, $args->{session_id}, $row->{id});

  $c->render(json => {
    message => $chat->event_public($row),
    cursor  => 0 + $row->{id},
    unread  => scalar @$missed,
    missed  => [map { $chat->header_public($_) } @$missed],
  }, status => 201);
```

Mirror it in `lib/Share/MCP.pm`'s `post_chat_message` result, and say so in the
tool description:

```perl
    description => 'Say something in a room you have joined. Markdown. The result '
      . 'tells you what landed while you were not looking -- "unread", and the '
      . 'headers of what you missed -- because the moment you post is the one '
      . 'moment you are provably listening. No attachments: share the file with '
      . 'get_upload_url and put its URL in the message.',
```

> **Cap note:** 20 is a deliberate ceiling, not a page size. A caller that is
> further behind than that should read properly rather than have an
> acknowledgement quietly become a catch-up. `unread` is the true count either
> way, so nothing is hidden — it is reported even when the headers are cut off.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add share.pl lib/Share/MCP.pm t/chat.t
git commit -m "The acknowledgement knew you were behind and never said so"
```

---

### Task 8: Mentions, `@agents`, and waiting only on being wanted

**Files:**
- Modify: `lib/Share/Chat.pm` (extraction, storage, the `mentions_me` filter)
- Modify: `share.pl` (the read handler and `chat_await` query)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 1's `chat_mentions`, Task 5's `header_public`.
- Produces: `Share::Chat::mentions_for($room, \@event_ids)` returning
  `{event_id => [names]}`; every event carrying `mentions`; read parameter
  `mentions_me=1` filtering the read **and** the park.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a mention is data, and an agent can wait on being wanted' => sub {
  my $id = _room(topic => 'mentions')->{room}{id};
  _join($id, session_id => 'sess-1', name => 'planner',  about => 'mention test');
  _join($id, session_id => 'sess-2', name => 'DRAC-E1',  about => 'mention test');
  $t->post_ok("/api/v1/chatrooms/$id/members" => json => {session_id => 'sess-3',
    name => 'melo', about => 'the human', kind => 'human'});

  _post($id, 'sess-1', 'nothing for anybody here');
  my $direct = _post($id, 'sess-1', 'can @DRAC-E1 confirm the compose file?');

  # Bound to the member, and reported by name.
  my $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($direct->{message}{id} - 1))
    ->tx->res->json;
  is_deeply $got->{events}[0]{mentions}, ['DRAC-E1'], 'the mention is a field, not prose';

  # Case-insensitive, because nobody types a name back exactly.
  _post($id, 'sess-1', 'and @drac-e1 again');

  # An unmatched @ stays plain text and produces nothing.
  my $noise = _post($id, 'sess-1', 'ping @nobody-here');
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($noise->{message}{id} - 1))
    ->tx->res->json;
  is_deeply $got->{events}[0]{mentions}, [], 'an @ that matches nobody is just an @';

  # "Has anyone addressed me?" is one call.
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-2&since=0")
    ->status_is(200)->tx->res->json;
  is $got->{count}, 2, 'both, and neither of the others';

  # @agents reaches every agent and NO human -- which is what keeps it from
  # being the megaphone a broadcast usually becomes.
  my $all = _post($id, 'sess-3', '@agents stop what you are doing and read BOB-6');
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($all->{message}{id} - 1))
    ->tx->res->json;
  is_deeply [sort @{$got->{events}[0]{mentions}}], ['DRAC-E1', 'planner'],
    'both agents, not the human who sent it';

  $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-3&since=0")
    ->json_is('/count' => 0), 'a human is not swept up by @agents';
};

subtest 'a park on being wanted is not woken by ordinary chatter' => sub {
  my $id = _room(topic => 'selective')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'alpha', about => 'park test');
  _join($id, session_id => 'sess-b', name => 'bravo', about => 'park test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  # Chatter first, then the thing that actually concerns bravo. If the filter is
  # not applied to the PARK as well as the read, the first post ends the wait and
  # this returns the wrong message.
  Mojo::IOLoop->timer(0.2 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-a', body => 'unrelated noise') });
  Mojo::IOLoop->timer(0.6 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-a', body => 'over to you @bravo') });

  $t->get_ok("/api/v1/chatrooms/$id/events?since=$cursor&wait=10"
      . "&mentions_me=1&session_id=sess-b")->status_is(200)
    ->json_is('/count' => 1)
    ->json_is('/events/0/body' => 'over to you @bravo');
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — no `mentions` key.

- [ ] **Step 3: Implement**

In `lib/Share/Chat.pm`, extract at post time and store:

```perl
# Who a message addressed.
#
# Matched against the roster, never against a caller-supplied pattern -- the same
# discipline the room's search already follows and for the same reason: one
# nested quantifier over a few thousand messages takes a worker out of service
# and Perl's engine has no timeout to stop it. A name is a name.
#
# The row binds to the MEMBER, not to the text, so renaming yourself does not
# orphan every message that ever addressed you.
sub _record_mentions ($self, $room, $row) {
  my $body = $row->{body} // '';
  return unless length $body;

  my %wanted;
  # A broadcast to the fleet. Agents only, deliberately: melo's one message
  # assigning roles reached four sessions at once and nobody drifted from it,
  # which is the use this earns its place on -- and not pinging the humans, who
  # are reading anyway, is what stops it becoming a megaphone.
  my $agents = $body =~ /(?:\A|\W)\@agents(?:\W|\z)/i;

  for my $member (@{$self->members($room)}) {
    next if $member->{left_at};
    $wanted{$member->{id}} = 1 if $agents && $member->{kind} eq 'agent';
    next unless $body =~ /(?:\A|\W)\@\Q$member->{name}\E(?:\W|\z)/i;
    $wanted{$member->{id}} = 1;
  }

  my $db = $self->sql->db;
  $db->query('INSERT OR IGNORE INTO chat_mentions (event_id, member_id, room_id) VALUES (?,?,?)',
    $row->{id}, $_, $room->{id})
    for keys %wanted;
  return;
}

# name-by-event, for serialising. One query for a whole page rather than one per
# event: a hundred events would otherwise be a hundred round trips.
sub mentions_for ($self, $room, $ids) {
  return {} unless @$ids;
  my $in   = join ',', ('?') x @$ids;
  my $rows = $self->sql->db->query(
    "SELECT n.event_id, m.name FROM chat_mentions n
       JOIN chat_members m ON m.id = n.member_id
      WHERE n.room_id = ? AND n.event_id IN ($in)", $room->{id}, @$ids)->hashes;
  my %by;
  push @{$by{$_->{event_id}}}, $_->{name} for @$rows;
  return \%by;
}
```

Call `_record_mentions` from `_write` after the row exists. Add to `messages`:

```perl
  # "Has anyone addressed me?" -- and, combined with `wait`, the difference
  # between parking on "someone needs me" and parking on "someone spoke". That is
  # the difference between a watcher an agent leaves running and one it turns off.
  if (my $me = $opt{mentions_me}) {
    push @where, 'id IN (SELECT event_id FROM chat_mentions WHERE member_id = ?)';
    push @bind,  $me;
  }
```

In `share.pl`, resolve `mentions_me=1` + `session_id` to a member id and put it
in `%query` — which `chat_await` already passes through verbatim, so the park
inherits the filter for free.

`_chat_messages_json` attaches names to both serialisations:

```perl
  my $mentions = $chat->mentions_for($room, [map { $_->{id} } @$rows]);
  ... $chat->event_public($_, $mentions->{$_->{id}} // []) ...
```

- [ ] **Step 4: Run the tests**

Expected: PASS. The second subtest is the one that catches applying the filter to
the read but not the park.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "An at-sign was decoration, and waiting could not tell you from anyone"
```

---

### Task 9: Leaving, and a roster that is honest

**Files:**
- Modify: `lib/Share/Chat.pm` (`leave_room`, presence, `member_public`)
- Modify: `share.pl` (leave route, `waiting_until` bookkeeping in `chat_await`, `roster=1`)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 1's `left_at` / `waiting_until`.
- Produces: `DELETE /api/v1/chatrooms/<room>/members/<session>`;
  `Share::Chat::presence($member)` returning
  `listening | idle | away | gone`; `member_public` gaining `presence`,
  `read_cursor` and `online`; read parameter `roster=1`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'leaving is a call, and the roster stops lying about it' => sub {
  my $id = _room(topic => 'presence')->{room}{id};
  _join($id, session_id => 'sess-s', name => 'stayer', about => 'presence test');
  _join($id, session_id => 'sess-g', name => 'goer',   about => 'presence test');
  _post($id, 'sess-g', 'something worth keeping');

  $t->delete_ok("/api/v1/chatrooms/$id/members/sess-g")->status_is(200)
    ->json_is('/left' => 'goer');

  my $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  my ($gone) = grep { $_->{name} eq 'goer' } @{$room->{members}};
  is $gone->{presence}, 'gone', 'the roster says so instead of guessing';

  # The departure is an event, so a parked watcher learns about it.
  my $ev = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  is $ev->{events}[-1]{type}, 'member.left', 'and it is in the sequence';

  # Their words stay. The author's name is denormalised onto every row precisely
  # so a transcript reads the way it read at the time.
  ok scalar(grep { ($_->{body} // '') eq 'something worth keeping' } @{$ev->{events}}),
    'what they said outlives them';

  # Coming back clears it rather than making a second member.
  _join($id, session_id => 'sess-g', name => 'goer', about => 'back again');
  $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  ($gone) = grep { $_->{name} eq 'goer' } @{$room->{members}};
  isnt $gone->{presence}, 'gone', 'rejoining is not resurrection, it is just being here';
  is scalar @{$room->{members}}, 2, 'and it is still two people';
};

subtest 'a roster comes with a read only when it is asked for' => sub {
  my $id = _room(topic => 'roster on reads')->{room}{id};
  _join($id, session_id => 'sess-o', name => 'planner', about => 'roster test');

  my $bare = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  ok !exists $bare->{members}, 'off by default, because headers exist to be cheap';

  my $with = $t->get_ok("/api/v1/chatrooms/$id/events?roster=1")->tx->res->json;
  is $with->{members}[0]{name}, 'planner', 'and on request it is the roster you know';
  ok exists $with->{members}[0]{presence}, 'with presence on it';
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — 404 on the delete.

- [ ] **Step 3: Implement**

```perl
# How long after a member was last seen the room stops calling them present.
has presence_grace => 120;

# What the roster can honestly say about somebody.
#
# `last_seen_at` already means "last touched the room in any way" -- touch_member
# fires on every READ as well as every post, from five call sites -- so it was
# always a better presence signal than the tickets asking for one assumed. What
# it cannot survive is a fifteen-minute park: the member is silent that whole
# time while genuinely listening. So a waiter records how long it intends to be
# there, and holding an open poll IS the presence signal.
sub presence ($self, $member, $now = time) {
  return 'gone'      if $member->{left_at};
  return 'listening' if ($member->{waiting_until} // 0) > $now;
  return 'idle'      if $member->{last_seen_at} > $now - $self->presence_grace;
  return 'away';
}

sub leave_room ($self, $room, $session_id) {
  my $member = $self->member($room, $session_id) or return undef;
  return $member if $member->{left_at};
  $self->sql->db->query('UPDATE chat_members SET left_at = ?, waiting_until = 0 WHERE id = ?',
    time, $member->{id});
  $self->_write($room, $session_id, $member->{name}, 'member.left' => '');
  return $self->member($room, $session_id);
}

# A waiter announces how long it means to stay, so the roster can tell a live
# listener from a dead session without either of them saying anything.
sub hold ($self, $room, $session_id, $seconds) {
  return unless defined $session_id && length $session_id;
  eval {
    $self->sql->db->query(
      'UPDATE chat_members SET waiting_until = ?, last_seen_at = ? WHERE room_id = ? AND session_id = ?',
      time + $seconds, time, $room->{id}, $session_id);
    1;
  } or do { $self->log->warn("chat: hold failed (carrying on): $@") if $self->log };
  return;
}

sub release ($self, $room, $session_id) {
  return unless defined $session_id && length $session_id;
  eval {
    $self->sql->db->query(
      'UPDATE chat_members SET waiting_until = 0, last_seen_at = ? WHERE room_id = ? AND session_id = ?',
      time, $room->{id}, $session_id);
    1;
  } or do { $self->log->warn("chat: release failed (carrying on): $@") if $self->log };
  return;
}
```

`join_room` clears `left_at` when an existing member rejoins. `member_public`
gains `presence`, `online` (a boolean for the browser: `listening` or `idle`) and
`read_cursor` — which is BOB-4 §7's delivery receipt for free, and is what would
have told one agent to stop waiting on another hours before it did.

In `share.pl`: call `$chat->hold(...)` before parking and `$chat->release(...)`
in the promise's `finally`, plus on the `tx` `finish` handler so a caller that
hangs up does not stay "listening" until its deadline.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "A room where two of five are dead sessions looked like a room where everyone listened"
```

---

### Task 10: A room says when it is going, and when it has gone

**Files:**
- Modify: `lib/Share/Chat.pm` (`warn_expiring`, the reaper hook)
- Modify: `share.pl` (`chat_await` liveness re-check, adaptive interval, waiter cap, config)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 1's `warned_at`, Task 2's system actor.
- Produces: `Share::Chat::warn_expiring($now)` writing `room.expiring`;
  a parked read resolving with a synthesized `room.destroyed` and `closed: true`;
  config `chat_expiry_warning` (default 7200) and `chat_max_waiters` (default 32).

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a room warns while it is still standing' => sub {
  my $id   = _room(topic => 'closing time', ttl_days => 0.05)->{room}{id};
  _join($id, session_id => 'sess-c', name => 'planner', about => 'expiry test');

  my $wrote = $t->app->chat->warn_expiring;
  is $wrote, 1, 'a room inside the warning window gets one';

  my $ev = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  is $ev->{events}[-1]{type}, 'room.expiring', 'and it is an ordinary event';
  is $ev->{events}[-1]{name}, 'system', 'written by nobody in particular';
  like $ev->{events}[-1]{body}, qr/deleted/, 'saying what is about to happen';

  # Once, however many times the reaper passes.
  is $t->app->chat->warn_expiring, 0, 'and never twice';
};

subtest 'a parked reader is told the room is over, not left hanging' => sub {
  my $id = _room(topic => 'doomed')->{room}{id};
  my $pw = $t->tx->res->json->{delete_password};
  _join($id, session_id => 'sess-d', name => 'planner', about => 'destruction test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  # The room is destroyed while somebody is parked on it. Before this, the poll
  # kept asking a room that no longer existed and settled empty AT THE DEADLINE
  # -- fifteen minutes of a held connection for nothing.
  Mojo::IOLoop->timer(0.3 => sub { $t->app->chat->remove_room($id, $pw) });

  my $started = time;
  $t->get_ok("/api/v1/chatrooms/$id/events?since=$cursor&wait=10")->status_is(200)
    ->json_is('/closed' => Mojo::JSON->true)
    ->json_is('/count' => 1)
    ->json_is('/events/0/type' => 'room.destroyed')
    ->json_is('/events/0/name' => 'system')
    ->json_is('/events/0/why'  => 'closed');
  ok time - $started < 5, 'released when it happened, not at the deadline';

  # A cold read of a room that is not live is still a 404: we genuinely cannot
  # tell "destroyed an hour ago" from "never existed", and claiming 410 Gone
  # would be inventing knowledge we do not have.
  $t->get_ok("/api/v1/chatrooms/$id/events")->status_is(404);
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — no `warn_expiring`; the parked read hangs to its deadline.

- [ ] **Step 3: Implement**

```perl
# The only warning anyone gets that a fortnight of coordination is about to be
# reaped. Written once -- `warned_at` is the guard -- by the same hourly pass
# that does the deleting, so there is no second timer and no second worker.
sub warn_expiring ($self, $now = time) {
  my $lead = $self->expiry_warning;
  my $rooms = $self->sql->db->query(
    'SELECT * FROM chat_rooms WHERE warned_at IS NULL AND expires_at > ? AND expires_at <= ?',
    $now, $now + $lead)->hashes->to_array;

  for my $room (@$rooms) {
    $self->_write($room, undef, 'system', 'room.expiring' =>
        sprintf 'This room, its roster and every message in it are **deleted %s** '
          . '(%s). Anything worth keeping should be moved somewhere that outlives it.',
        human_duration($room->{expires_at} - $now), iso8601($room->{expires_at}));
    $self->sql->db->query('UPDATE chat_rooms SET warned_at = ? WHERE id = ?', $now, $room->{id});
  }
  return scalar @$rooms;
}

# The one event never read from the stored sequence, because by definition the
# sequence it belongs to is being deleted in the same breath. Synthesized at
# delivery, for a caller that was demonstrably here when the room still was.
sub destroyed_event ($self, $why) {
  return {
    id => 0, type => 'room.destroyed', name => 'system', session_id => undef,
    why => $why, created_at => iso8601(time),
    body => $why eq 'expired'
      ? 'This room reached its expiry. Everything in it has been deleted.'
      : 'This room was closed. Everything in it has been deleted.',
  };
}
```

Hook `warn_expiring` into the reaper in `share.pl`, in the same claimed pass as
`$chat->reap`, **before** it — a room should be warned on one pass and reaped on
a later one, never both in the same breath.

In `chat_await`, the recurring callback re-checks liveness first:

```perl
      # The room may have gone while this caller was parked on it. Re-checking is
      # one indexed lookup on a secret, and the alternative is holding the
      # connection to a deadline that can now be a quarter of an hour away.
      unless ($chat->find_room($room->{secret})) {
        return $settle->({closed => 1});
      }
```

`$settle` learns to carry that, and `_chat_messages_json` renders it as `closed`
plus the single synthesized event. Add the adaptive interval and the waiter cap
in the same commit:

```perl
  # 0.5s while somebody might still be watching the page, then out to 5s. A
  # browser still feels instant; an agent parked for fifteen minutes costs about
  # two hundred lookups instead of eighteen hundred. Tidiness rather than
  # necessity -- the arithmetic says even the naive version is noise -- but a
  # constant that scales with the wait is one less thing to revisit.
  my $interval = sub ($elapsed) { $elapsed < 5 ? 0.5 : $elapsed < 60 ? 2 : 5 };
```

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "A room should say when it is going, and say when it has gone"
```

---

### Task 11: Member tokens

**Files:**
- Modify: `lib/Share/Chat.pm` (issue and check), `share.pl` (write routes, config)
- Modify: `share.pl` (`chat_message.html.ep` — stop rendering session ids)
- Test: `t/chat.t`

**Interfaces:**
- Consumes: Task 1's `token_salt` / `token_hash`.
- Produces: `join` returning `member_token` **once**;
  `Share::Chat::token_ok($room, $session_id, $token)`; config
  `chat_require_token` (env `SHARE_CHAT_REQUIRE_TOKEN`, default 0).

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a member gets a credential, once, and the wall stops leaking them' => sub {
  my $id  = _room(topic => 'identity')->{room}{id};
  my $me  = _join($id, session_id => 'sess-t', name => 'planner', about => 'token test');
  my $tok = $me->{member_token};
  ok length($tok // ''), 'join hands one over';

  # The only disclosure. Nothing else ever returns it.
  my $again = _join($id, session_id => 'sess-t', name => 'planner', about => 'token test');
  ok !exists $again->{member_token} || !defined $again->{member_token},
    'and never again, on the same terms as a delete password';
  my $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  ok !grep { exists $_->{member_token} } @{$room->{members}}, 'the roster never carries it';

  ok $t->app->chat->token_ok($t->app->chat->find_room($id), 'sess-t', $tok),
    'the right token checks out';
  ok !$t->app->chat->token_ok($t->app->chat->find_room($id), 'sess-t', 'wrong'),
    'and a wrong one does not';

  # A session id is a claim, not a credential, and it used to be printed on the
  # wall for anyone reading the room to reuse.
  $t->get_ok("/c/$id")->status_is(200);
};

subtest 'posting can be made to require the token' => sub {
  local $t->app->config->{chat_require_token} = 1;
  my $id  = _room(topic => 'guarded')->{room}{id};
  my $tok = _join($id, session_id => 'sess-q', name => 'planner', about => 'guard test')
    ->{member_token};

  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'no token'})->status_is(403);
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'with token', member_token => $tok})->status_is(201);
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `member_token` is not returned.

- [ ] **Step 3: Implement**

Reuse `password_hash` / `password_ok` from `Share::Store`, which the room's delete
password already uses — no new mechanism and no new dependency:

```perl
# Issued once, on the same terms as a room's delete password: this is the only
# moment the plaintext exists outside the caller's hand.
#
# The room URL stays the READ credential -- anyone holding it can still read the
# room, which is what a room URL has always meant. What this adds is a WRITE
# credential, because "your own message" has to mean something before anyone can
# edit or delete one. Until now a session id was a claim, and it was printed on
# the wall for anyone reading the room to copy.
sub issue_token ($self, $member) {
  my $token = token(24);
  my ($salt, $hash) = password_hash($token);
  $self->sql->db->query('UPDATE chat_members SET token_salt = ?, token_hash = ? WHERE id = ?',
    $salt, $hash, $member->{id});
  return $token;
}

sub token_ok ($self, $room, $session_id, $token) {
  my $member = $self->member($room, $session_id) or return 0;
  return 0 unless defined $member->{token_hash};
  return password_ok($token, $member->{token_salt}, $member->{token_hash}) ? 1 : 0;
}
```

`join_room` issues one on first join only, and returns it as a third value so
`member_public` never has to carry it. In `share.pl`, a guard used by every write
route:

```perl
# The browser's own session is signed and lives in one browser, so a human who
# joined through the page needs no token -- the cookie IS one.
sub _chat_may_write ($c, $room, $session_id, $token) {
  return 1 if !$c->app->config->{chat_require_token};
  return 1 if ($c->session('chat') // {})->{sid} && ($c->session('chat')->{sid} eq ($session_id // ''));
  return $chat->token_ok($room, $session_id, $token);
}
```

Add `chat_require_token => _bool(SHARE_CHAT_REQUIRE_TOKEN => 0)` to config, and
remove `<span class="msg-session">` from `chat_message.html.ep` — keep the
`title` attribute off too; it is the same string.

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/Chat.pm share.pl t/chat.t
git commit -m "A session id was a claim, and it was printed on the wall"
```

---

### Task 12: The MCP surface

**Files:**
- Modify: `lib/Share/MCP.pm`
- Test: `t/chat.t`

**Interfaces:**
- Consumes: everything above.
- Produces: `get_room_events` (renamed from `get_chat_messages`, old name kept as
  an alias), `fetch_chat_event`, `leave_chatroom`; `join_chatroom` returning
  presence and `member_token`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'MCP: the tools an agent needs to be a cheap listener' => sub {
  my $tools = _mcp('tools/list')->{result}{tools};
  my %have  = map { $_->{name} => $_ } @$tools;

  ok $have{get_room_events},   'reading the sequence has the name the sequence has';
  ok $have{get_chat_messages}, 'and the old name still answers, for one release';
  ok $have{fetch_chat_event},  'a headers reader can get one body';
  ok $have{leave_chatroom},    'and say when it is done';

  like $have{get_room_events}{description}, qr/900|fifteen minutes/i,
    'the description says how long it can park, or no agent will park';
  like $have{get_room_events}{description}, qr/headers/i,
    'and that a cheap read exists, or nobody will use it';
};

subtest 'MCP: park, be woken by a mention, then leave' => sub {
  my $id = _room(topic => 'mcp watcher')->{room}{id};
  my $joined = _call(join_chatroom => {room => $id, session_id => 'sess-mcp',
    name => 'watcher', about => 'mcp test'});
  ok length($joined->{structuredContent}{member_token} // ''), 'join issues a token';

  _join($id, session_id => 'sess-mate', name => 'mate', about => 'the other one');

  Mojo::IOLoop->timer(0.2 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-mate', body => 'ignore me') });
  Mojo::IOLoop->timer(0.5 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-mate', body => 'yours @watcher') });

  my $res = _call(get_room_events => {room => $id, session_id => 'sess-mcp',
    since => 'unread', wait => 10, mentions_me => 1, format => 'headers'});
  my $out = $res->{structuredContent};
  is $out->{count}, 1, 'woken once, by the one that concerned it';
  like $out->{events}[0]{preview}, qr/yours/, 'and handed a header, not an essay';

  my $left = _call(leave_chatroom => {room => $id, session_id => 'sess-mcp'});
  ok !$left->{isError}, 'leaving is a call now';
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — the tools do not exist.

- [ ] **Step 3: Implement**

Register `get_room_events` with the full parameter set from §4 of the spec, then
register the old name against the same code reference with a description saying
it is the previous name for the same call. Add `fetch_chat_event` and
`leave_chatroom`. Extend `join_chatroom`'s result with `member_token` and the
roster's presence, and add the sentence BOB-6 supplies for free:

```perl
      . 'Calling this again with the SAME session_id and a different name renames '
      . 'you in the room and tells everyone -- it is how you keep one identity '
      . 'across a rename rather than becoming a second member.',
```

- [ ] **Step 4: Run the tests**

Expected: PASS.

- [ ] **Step 5: `make test`, then commit**

```bash
make test
git add lib/Share/MCP.pm t/chat.t
git commit -m "The tools an agent needs to be a listener that costs nothing"
```

---

### Task 13: Say all of this where an agent will actually read it

**Files:**
- Modify: `lib/Share/Chat.pm` (`briefing`), `lib/Share/MCP.pm` (`_instructions`)
- Modify: `docs/DESIGN.md`, `README.md`, `docs/api.html.ep` in `share.pl`, `lib/Share/OpenAPI.pm`
- Modify: `docker-compose.yml`, `docker-compose.local.yml`, `docker-compose.traefik.yml`, `docker-compose.tsdproxy.yml`
- Test: `t/chat.t`

**Interfaces:**
- Consumes: everything above.
- Produces: no code behaviour; the briefing is what an agent arriving by URL is
  taught, and it matters more than any single tool description.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the URL still explains the whole of how to take part' => sub {
  my $id  = _room(topic => 'briefing')->{room}{id};
  my $how = $t->get_ok("/c/$id" => {Accept => 'application/json'})->status_is(200)
    ->tx->res->json->{how_to};

  like $how, qr/events/,        'the sequence is named';
  like $how, qr/wait=900|wait=/,'and how to park on it';
  like $how, qr/unread/,        'and that the server keeps your place';
  like $how, qr/headers/,       'and that a cheap read exists';
  like $how, qr/\@agents/,      'and how to reach the fleet';
  like $how, qr/markdown/i,     'and what the person on the other end sees';
  # BOB-3's closing note: it is a bearer token and it was carrying key
  # fingerprints and infrastructure layout.
  like $how, qr/anyone (who )?hold|treat (this|the) URL/i, 'and that the URL is the secret';
};
```

- [ ] **Step 2: Run it and watch it fail**

- [ ] **Step 3: Rewrite the briefing and the instructions**

Rewrite `Share::Chat::briefing`'s `how_to` around the watcher loop, because that
is now the thing an agent most needs to be told and the one it will never invent:

```
  4. FOLLOW IT WITHOUT SITTING STILL. Run this in the background; it returns
     ONLY when something happens, or after fifteen minutes:

       curl -fsS --max-time 960 '<api>/events?since=<cursor>&wait=900&format=headers'

     Re-arm it with the "cursor" it hands back. `timed_out` tells you which
     happened. Add `&mentions_me=1&session_id=<you>` and it wakes you only when
     somebody actually addressed you.
```

Answer BOB-5 §7 in `_instructions`, which is the question nobody could answer
from the tool descriptions: markdown **is** rendered, mermaid is **not**, and the
cap is 16 KB. Add `@agents`. Say the URL is a bearer token granting read *and*
post.

In `docs/DESIGN.md`, record the decisions and — as the file's own convention
requires — what went wrong with the obvious version: why one sequence rather than
a message list plus side channels, why no Valkey (with the arithmetic), why
`room.destroyed` is synthesized rather than stored.

Add all six settings to every compose file. The existing files carry a comment
saying exactly why this is not optional: **without the line in the compose file,
setting it in `.env` does nothing at all, silently.**

- [ ] **Step 4: `make test` and `make coverage`**

```bash
make test
make coverage
```

Expected: both green; coverage at or above 90%.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "An agent at the end of a room URL has only what the URL tells it"
```

---

## Self-Review

**Spec coverage.** §3 → Tasks 1, 2, 10. §4 → Tasks 3, 4, 9 (`roster`). §5 →
Task 6. §6 → Task 5. §7 → Task 7. §8 → Task 8. §9 → Tasks 3, 10. §10 → Task 11.
§11 → Task 9. §19 → Task 1. §20 → Tasks 3, 10, 11, 13. §21 → Task 13. §22 → every
task. **§12–§18 and §23's phases 3–6 are deliberately absent** — message
operations, files in a room, the room page, the rooms list and notifications are
Phases 3–6 and get their own plans.

**Known gaps, stated rather than hidden:**

- **Phase 0, the proxy measurement, cannot be done from here.** It needs a
  request held through the real `tailscale serve` deployment for 300s and 900s.
  This plan therefore ships `chat_max_wait` as a **configured** value defaulting
  to 900 rather than a constant, so a deployment that cuts long responses is a
  one-line `.env` change and not a code change. Task 13 must say so in
  MAINTAINING.md.
- **`member.presence` events are not written by this plan.** Presence is exposed
  on the roster (Task 9) and `member.left` is an event, but the debounced
  online/offline transitions of §11 need a timer that only pays for itself once
  the browser is consuming them, which is Phase 4. The `waiting_until` column
  they need exists from Task 1.

**Type consistency.** `event_public($row, $mentions)` and
`header_public($row, $mentions)` take the same two arguments in Tasks 5 and 8 —
Task 5 introduces the one-argument form and Task 8 adds the second; the plan says
so at both ends. `messages()` keeps its name throughout and gains options rather
than being renamed to `events()`, because it is called from six places and a
rename buys nothing. `mark_read`, `read_cursor` and `unread_count` are named
identically in Tasks 6, 7 and 9.
