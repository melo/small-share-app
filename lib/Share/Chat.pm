package Share::Chat;

# Chat rooms, for agents working in different sessions — and for whoever opens
# the URL in a browser.
#
# The file side of this service hands one artefact from one agent to one person.
# This is the other shape the same problem takes: three agents in three
# terminals, each holding a piece of the same job, with a human as the only wire
# between them. A room is a URL handed over exactly like a file URL, and
# everything else follows the file rules — an unguessable secret, no accounts,
# gone in fifteen days.
#
# Three invariants, two of them inherited:
#
#   * `secret` is the only identifier, and holding it is what lets you read and
#     post. There is nothing else to authenticate with.
#   * Everything a room holds dies with the room: members and messages are
#     deleted with it, on the same hourly pass that deletes expired files.
#   * A message's id is a cursor. It comes from one monotonic sequence, so
#     "everything since 4128" is answerable with an index lookup and no
#     timestamps to be clever about.
#
# The schema lives here rather than in Share::Store, under its own migration
# name in the same database file. Mojo::SQLite keeps a version per name, so the
# two sets migrate independently — and the chat tables can be read, dumped and
# reasoned about without going anywhere near the file store.

use Mojo::Base -base, -signatures;
use utf8;

use Digest::SHA             ();
use Exporter                qw(import);
use Mojo::SQLite::Migrations ();
use Share::Store            qw(human_duration iso8601 password_hash password_ok token);

has 'sql';    # the Mojo::SQLite that Share::Store already opened
has 'log';

has default_ttl_days => 15;
has max_ttl_days     => 15;

# A message is a paragraph, a decision, a stack trace worth quoting. Anything
# bigger is a file, and this service already has somewhere to put those: upload
# it and post the URL. The limit is deliberately small enough that a room stays
# readable in a terminal and cheap to hand back through a model's context.
has max_message_bytes => 16 * 1024;

# Ceiling on the history one room keeps. Past it the oldest messages go, and
# `pruned_to` remembers how far, so a caller asking for everything since a
# message that no longer exists is TOLD it missed some rather than quietly
# handed a shorter conversation than it asked for.
has max_messages => 5000;

# How much of a body a header shows: enough to know whether the thing concerns
# you, short enough that catching up on twenty events costs hundreds of tokens
# rather than thousands.
has preview_chars => 160;

# How long after a member was last seen the room stops calling them present.
has presence_grace => 120;

# How long a member may go without saying anything at all before the room stops
# believing in them and marks them gone.
#
# `away` was never enough. A browser tab that is closed stops polling, its
# `waiting_until` lapses and its `last_seen_at` ages -- and then it sits in the
# roster forever, because nothing ever concluded anything. Whoever is reading has
# to guess whether "away" means gone home or means mid-build.
#
# So silence past this becomes a real `member.left`, in the sequence, where a
# parked agent finds out about it like anything else. The browser keeps itself
# alive with a cheap call every 60-90 seconds; five minutes is generous enough
# to survive a laptop lid, a suspended tab and a bad minute of network.
has presence_timeout => 300;

# How long before a room's expiry it says so. Two hours is enough to move
# something that matters and short enough that the warning still means "now".
has expiry_warning => 7200;

# Whether writing to a room needs the member_token join handed back.
#
# It lives HERE, and not in a route, because the first version of it lived in a
# route. The REST post path checked it; the MCP tool called post() underneath
# that check and never saw it, and three more write paths were added afterwards
# that did not call it either. On an instance with a public /mcp that left
# anyone holding a room URL able to post as anybody in the room — which is the
# one thing the flag exists to prevent.
#
# A guard in a transport is a guard the next transport forgets. This is the far
# side of both of them.
has require_token => 0;

# How this instance limits a caller, supplied by share.pl: a coderef taking the
# caller's identity and answering ($ok, $seconds_to_wait).
#
# It lives here for the reason `require_token` does. The limit used to be applied
# in the REST routes, so `SHARE_CHAT_RATE_*` was decorative on any instance with
# /mcp reachable -- the same shape of mistake as the token guard, in the same
# place, one release later. Policy belongs on the far side of both doors.
has limiter => undef;

# What can happen in a room.
#
# The sequence is the whole interface — "everything since <id>" has to mean
# EVERYTHING, or a client is left guessing at what it was not told — so anything
# the server does to a room ends up here rather than in a side channel a caller
# has to know to ask about. It is also what makes a later edit or deletion
# visible to a reader that is caching: without it, a watcher holding message 40
# has no way to learn that 40 has changed.
#
# Two of these have no member behind them, and carry `session_id` null with the
# name `system`. See warn_expiring and destroyed_event.
use constant EVENT_TYPES => [qw(
  message file
  member.joined member.left member.renamed member.presence
  room.renamed room.expiring room.destroyed
  message.edited message.deleted message.pinned
)];

# --------------------------------------------------------------- schema ------

use constant MIGRATIONS => <<'SQL';
-- 1 up
CREATE TABLE chat_rooms (
  id          INTEGER PRIMARY KEY,
  secret      TEXT    NOT NULL UNIQUE,
  topic       TEXT    NOT NULL,
  purpose     TEXT,
  created_by  TEXT,                     -- session id of whoever opened it
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL,
  pruned_to   INTEGER NOT NULL DEFAULT 0,   -- highest message id dropped by the cap
  delete_salt TEXT,
  delete_hash TEXT
);
CREATE INDEX chat_rooms_expires_idx ON chat_rooms (expires_at);

CREATE TABLE chat_members (
  id           INTEGER PRIMARY KEY,
  room_id      INTEGER NOT NULL,
  session_id   TEXT    NOT NULL,
  name         TEXT    NOT NULL,
  -- Lowercased, and unique per room: two agents both called "planner" in the
  -- same conversation is a coordination bug the room can prevent for free.
  name_key     TEXT    NOT NULL,
  about        TEXT,
  kind         TEXT    NOT NULL,        -- agent | human
  joined_at    INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX chat_members_session_idx ON chat_members (room_id, session_id);
CREATE UNIQUE INDEX chat_members_name_idx ON chat_members (room_id, name_key);

CREATE TABLE chat_messages (
  id         INTEGER PRIMARY KEY,
  room_id    INTEGER NOT NULL,
  session_id TEXT    NOT NULL,
  -- What the author was called when they wrote it. Denormalised on purpose: a
  -- transcript should read the way it read at the time, not get rewritten
  -- underneath everyone because somebody renamed themselves an hour later.
  name       TEXT    NOT NULL,
  kind       TEXT    NOT NULL,          -- message | join | system
  body       TEXT    NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX chat_messages_room_idx ON chat_messages (room_id, id);

-- 1 down
DROP TABLE chat_messages;
DROP TABLE chat_members;
DROP TABLE chat_rooms;

-- 2 up
-- A message was always one kind of thing that happens in a room; the table just
-- did not say so. Renaming it is what lets an arrival, a departure, a rename and
-- the room's own death answer the same "what since <id>?" question on the same
-- cursor -- and it is what makes an edit visible to a reader that is caching,
-- which no number of extra endpoints would have done.
-- Rebuilt rather than altered, because `session_id` has to become nullable and
-- SQLite cannot drop a NOT NULL in place. The two events a room produces on its
-- own behalf -- it is about to expire, it has been destroyed -- have no member
-- behind them, and writing some sentinel string there instead would be a member
-- id that is not a member id, waiting for somebody to join a room and pick that
-- name.
CREATE TABLE chat_events (
  id         INTEGER PRIMARY KEY,
  room_id    INTEGER NOT NULL,
  -- Null for a system event. See EVENT_TYPES.
  session_id TEXT,
  -- What the author was called when they wrote it. Denormalised on purpose: a
  -- transcript should read the way it read at the time, not get rewritten
  -- underneath everyone because somebody renamed themselves an hour later.
  name       TEXT    NOT NULL,
  type       TEXT    NOT NULL,
  body       TEXT    NOT NULL,
  created_at INTEGER NOT NULL,
  -- What this event is about, when it is about another event: an edit, a
  -- delete, a pin. Null for everything that stands on its own.
  target_id  INTEGER
);

-- The old vocabulary was message | join | system, and `system` was only ever
-- written by the rename path in join_room. Map both, so a room that has been
-- running for a fortnight still reads correctly after the upgrade.
INSERT INTO chat_events (id, room_id, session_id, name, type, body, created_at)
  SELECT id, room_id, session_id, name,
         CASE kind WHEN 'join' THEN 'member.joined'
                   WHEN 'system' THEN 'member.renamed'
                   ELSE kind END,
         body, created_at
    FROM chat_messages;

DROP TABLE chat_messages;

CREATE INDEX chat_events_room_idx ON chat_events (room_id, id);
CREATE INDEX chat_events_type_idx ON chat_events (room_id, type, id);

-- Where this member has read to. The cursor used to be the caller's alone to
-- carry, and a watcher LOSES it: every re-invocation, every fresh session, and
-- `since` omitted means "the last hundred" -- i.e. read everything again.
ALTER TABLE chat_members ADD COLUMN read_cursor INTEGER NOT NULL DEFAULT 0;

-- "I will be here until T". last_seen_at already means "last touched the room in
-- any way" -- touch_member fires on reads as well as posts -- which was always a
-- better presence signal than it was given credit for. It stops being enough the
-- moment a poll can park for fifteen minutes: the member is silent that whole
-- time while genuinely listening, and any grace window short enough to spot a
-- dead session would mark a live listener away.
ALTER TABLE chat_members ADD COLUMN waiting_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE chat_members ADD COLUMN left_at INTEGER;

-- Issued once at join, on the same terms as a room's delete password. The room
-- URL stays the READ credential; this is what makes "your own message" mean
-- something when somebody edits or deletes one.
ALTER TABLE chat_members ADD COLUMN token_salt TEXT;
ALTER TABLE chat_members ADD COLUMN token_hash TEXT;

-- room.expiring is written once, and only once, however many times the reaper
-- passes over a room in its last couple of hours.
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

-- 3 up
-- Rows left behind by 1.5.0, which deleted a room without deleting the mentions
-- that pointed into it. Harmless as orphans; not harmless once SQLite reuses
-- the freed event and member rowids, at which point one of them silently
-- becomes a live message flagged as addressed to somebody who never was. One
-- sweep, once, for every database that ran that version.
DELETE FROM chat_mentions
 WHERE room_id NOT IN (SELECT id FROM chat_rooms)
    OR event_id NOT IN (SELECT id FROM chat_events)
    OR member_id NOT IN (SELECT id FROM chat_members);

-- 3 down
-- Nothing to undo: the rows this dropped were already pointing at nothing.
SELECT 1;

-- 4 up
-- A random per member, so the handle published on every message cannot be
-- turned back into the session id it stands for.
--
-- The handle used to be sha256(room_secret, session_id). Every participant holds
-- the room secret -- it IS the URL -- and the roster hands out the name-to-handle
-- map, so recovering a session id was an offline dictionary attack against a
-- string agents deliberately choose to be short and memorable. "planner" fell
-- immediately. This makes the handle independent of anything an attacker can
-- guess or already knows.
ALTER TABLE chat_members ADD COLUMN author_salt TEXT;
UPDATE chat_members SET author_salt = lower(hex(randomblob(16))) WHERE author_salt IS NULL;

-- 4 down
SELECT 1;


-- 2 down
DROP TABLE chat_mentions;
CREATE TABLE chat_messages (
  id         INTEGER PRIMARY KEY,
  room_id    INTEGER NOT NULL,
  session_id TEXT    NOT NULL,
  name       TEXT    NOT NULL,
  kind       TEXT    NOT NULL,
  body       TEXT    NOT NULL,
  created_at INTEGER NOT NULL
);
-- The system events have no member behind them and there is nowhere to put them
-- in a schema that insists on one, so going back drops them.
INSERT INTO chat_messages (id, room_id, session_id, name, kind, body, created_at)
  SELECT id, room_id, session_id, name,
         CASE type WHEN 'member.joined' THEN 'join'
                   WHEN 'message' THEN 'message'
                   ELSE 'system' END,
         body, created_at
    FROM chat_events WHERE session_id IS NOT NULL;
DROP TABLE chat_events;
CREATE INDEX chat_messages_room_idx ON chat_messages (room_id, id);
SQL

# A migrations object of our own rather than $sql->migrations, which is shared
# with Share::Store: setting a name on that one would change which set the
# automatic migration on first use runs.
sub init ($self) {
  my $migrations = Mojo::SQLite::Migrations->new(sqlite => $self->sql)->name('share_chat')
    ->from_string(MIGRATIONS);

  # Asked BEFORE migrating, because it is the only moment that can tell a fresh
  # install from a live one being upgraded. Zero means there was nothing here;
  # anything else means there are rooms with history in them, and history is the
  # part worth keeping.
  my $was = $migrations->active;
  $migrations->migrate;
  $self->_backfill_v2 if $was && $was < 2;

  # The presence sweep's claim row. Done here rather than in a migration because
  # `meta` belongs to Share::Store's schema, not to this one -- the two sets are
  # versioned separately precisely so neither reaches into the other. INSERT OR
  # IGNORE makes it idempotent, and it is one query at startup.
  $self->sql->db->query(
    q{INSERT OR IGNORE INTO meta (k, v) VALUES ('last_presence_sweep', '0')});

  return $self;
}

# What SQL could not do for the rooms that already existed.
#
# The schema half of the upgrade is a straight copy: same ids, same words, the
# old vocabulary mapped onto the new one. But two of the new features are derived
# from message text and from who was present, and a migration written in SQL
# cannot derive either. Without this an upgraded room answers "has anyone ever
# addressed me?" with an empty list, which reads exactly like "no".
sub _backfill_v2 ($self) {
  my $db    = $self->sql->db;
  my $rooms = $db->query('SELECT * FROM chat_rooms')->hashes->to_array;

  for my $room (@$rooms) {
    # Mentions, from the bodies that are already there. Same matcher as a new
    # message gets, against the roster as it stands, so history answers the same
    # questions the present does.
    my $events = $db->query(
      "SELECT * FROM chat_events WHERE room_id = ? AND type IN ('message', 'file') ORDER BY id",
      $room->{id})->hashes->to_array;
    $self->_record_mentions($room, $_) for @$events;

    # A read position, seeded from the last thing each member said. It is the one
    # thing the old schema recorded about where somebody had got to, and it is
    # the same rule posting follows now: saying something proves you were here.
    # The alternative is starting everyone at zero, which would hand every
    # upgraded session the entire room as unread on its first `since=unread` —
    # exactly the expensive re-read this release exists to stop.
    $db->query(
      'UPDATE chat_members SET read_cursor = COALESCE((
         SELECT MAX(e.id) FROM chat_events e
          WHERE e.room_id = chat_members.room_id AND e.session_id = chat_members.session_id
       ), 0) WHERE room_id = ?', $room->{id});
  }

  $self->log->info(sprintf 'chat: upgraded %d room(s) to the event schema', scalar @$rooms)
    if $self->log && @$rooms;
  return;
}

# ---------------------------------------------------------------- rooms ------

sub create_room ($self, %args) {
  my $topic = _clean_line($args{topic}, 120)
    // _fail('a room needs a topic — one line saying what is being coordinated');
  my $purpose = _clean_text($args{purpose}, 2000);

  $self->_limit('create_room', %args);

  my $now      = time;
  my $ttl      = $self->_ttl_seconds($args{ttl_days});
  my $password = _clean_line($args{delete_password}, 200) // token(24);
  my ($salt, $hash) = password_hash($password);

  my $secret = token();
  $self->sql->db->insert(
    'chat_rooms',
    { secret      => $secret,
      topic       => $topic,
      purpose     => $purpose,
      created_by  => _clean_line($args{session_id}, 200),
      created_at  => $now,
      expires_at  => $now + $ttl,
      delete_salt => $salt,
      delete_hash => $hash,
    }
  );

  my $room = $self->find_room($secret);
  # The only moment the plaintext exists outside the caller's hand — same rule
  # as an uploaded file, and the same consequence for losing it: the room can
  # then only expire on its own.
  $room->{delete_password} = $password;
  return $room;
}

sub find_room ($self, $secret) {
  return undef unless defined $secret && $secret =~ /\A[A-Za-z0-9]{8,64}\z/;
  my $room = $self->sql->db->query('SELECT * FROM chat_rooms WHERE secret = ?', $secret)->hash;
  return undef unless $room;
  return undef if $room->{expires_at} <= time;    # expired but not yet reaped is gone
  return $room;
}

# Same shape as Share::Store::remove, and the same refusal for both halves of
# it, so a wrong password cannot be told from a room that never existed.
sub remove_room ($self, $secret, $password = undef) {
  my $room  = $self->sql->db->query('SELECT * FROM chat_rooms WHERE secret = ?', $secret)->hash;
  my $refuse = 'no such room, or the wrong delete password';

  # The refusal is one sentence for both cases on purpose -- but until now only
  # a room that existed paid for the key derivation, so the two answers were a
  # millisecond and a quarter of a second apart. The sentence said nothing and
  # the clock said everything.
  unless ($room) {
    my ($salt, $hash) = password_hash(token(24));
    password_ok($password // '', $salt, $hash);
    return (0, $refuse);
  }
  return (0, $refuse) unless password_ok($password, $room->{delete_salt}, $room->{delete_hash});

  $self->_purge_room($room);
  return (1, undef);
}

sub _purge_room ($self, $room) {
  my $db = $self->sql->db;
  # Mentions first, and they are easy to forget because nothing references them
  # and nothing breaks visibly when they are left. What actually happens is
  # worse than an orphan: chat_events.id and chat_members.id are plain INTEGER
  # PRIMARY KEYs, so SQLite hands the freed rowids straight back out, and a
  # leftover row pairing a dead event with a dead member becomes a LIVE event
  # flagged as addressed to a live member who was never addressed at all.
  #
  # Which is the worst shape it could take. mentions_me exists so that an agent
  # can trust "someone needs me" enough to park on it, and this made it lie.
  # Found on a live instance with churn in it; a database that only ever grows
  # would never have shown it.
  $db->delete('chat_mentions', {room_id => $room->{id}});
  $db->delete('chat_events',   {room_id => $room->{id}});
  $db->delete('chat_members',  {room_id => $room->{id}});
  $db->delete('chat_rooms',    {id      => $room->{id}});
  return;
}

sub _ttl_seconds ($self, $days) {
  return $self->default_ttl_days * 86400 unless defined $days && length $days;
  _fail('ttl_days must be a number') unless $days =~ /\A\d+(?:\.\d+)?\z/;
  my $secs = $days * 86400;
  _fail(sprintf 'ttl_days must be at most %d', $self->max_ttl_days)
    if $secs > $self->max_ttl_days * 86400;
  _fail('ttl_days must be at least 1 hour (0.042)') if $secs < 3600;
  return int $secs;
}

# -------------------------------------------------------------- members ------

# Joining is how a session gets a name, and the name is what everyone else in
# the room reads. Calling it again with the same session id is an update, not a
# second member: an agent that reconnects, or a person who comes back to the
# page, is the same participant.
#
# Returns (member, $announcement), where the announcement is the message row
# this join produced — an arrival, or a rename — or undef when nothing about
# the member changed and there is nothing to tell the room.
sub join_room ($self, $room, %args) {
  my $session_id = _clean_line($args{session_id}, 200)
    // _fail('session_id is required — it is how the room tells participants apart');
  my $kind = ($args{kind} // 'agent') eq 'human' ? 'human' : 'agent';

  my $name = _clean_line($args{name}, 32)
    // _fail('pick a name — something a person reading the room would recognise, '
      . 'like "planner" or "api-refactor"');
  _fail('a name needs at least one letter or digit') unless $name =~ /[[:alnum:]]/;

  my $about = _clean_text($args{about}, 2000);

  $self->_limit('join_room', %args);

  # Arriving is open -- it is how a session gets its token in the first place.
  # Coming BACK as a session that already exists is not: it rewrites that
  # member's name and paragraph, clears their departure so a session that
  # correctly said goodbye shows present again, and -- because mentions bind to
  # the current name -- silently redirects everything addressed to them. An
  # agent parked on "wake me when somebody needs me" can be muted by a stranger
  # renaming it.
  $self->authorise($room, $session_id, %args)
    if $self->member($room, $session_id);

  # Required of an agent, optional for a person. The paragraph exists so that
  # every session in the room can see what the others are doing without asking;
  # a human who has opened the page is already visibly present and has no
  # work-in-progress to declare.
  _fail('say what you are working on — one short paragraph, so the others know '
      . 'what you are holding')
    if $kind eq 'agent' && !defined $about;

  my $db  = $self->sql->db;
  my $now = time;

  my $taken = $db->query('SELECT * FROM chat_members WHERE room_id = ? AND name_key = ?',
    $room->{id}, lc $name)->hash;
  _fail(qq{"$name" is taken in this room by another session — pick another one})
    if $taken && $taken->{session_id} ne $session_id;

  my $existing = $self->member($room, $session_id);

  unless ($existing) {
    $db->insert(
      'chat_members',
      { room_id      => $room->{id},
        session_id   => $session_id,
        name         => $name,
        name_key     => lc $name,
        about        => $about,
        kind         => $kind,
        joined_at    => $now,
        last_seen_at => $now,
      }
    );
    my $member = $self->member($room, $session_id);
    # A third value, not a field on the member, so that member_public — which is
    # what the roster is built from — has no way to leak it even by accident.
    my $token = $self->issue_token($member);
    # The arrival goes into the transcript rather than only into the roster, so
    # anyone waiting on the room finds out that someone turned up, and what
    # they said they were doing, without polling a second endpoint for it.
    return ($member, $self->_write($room, $session_id, $name, 'member.joined' => $about // ''),
      $token);
  }

  $db->update(
    'chat_members',
    { name         => $name,
      name_key     => lc $name,
      about        => $about // $existing->{about},
      last_seen_at => $now,
      # Coming back is not a second member and not a resurrection: it is the
      # same participant, here again.
      left_at      => undef,
    },
    {id => $existing->{id}}
  );

  my $member = $self->member($room, $session_id);

  # A member who joined before this instance issued tokens has none, and cannot
  # be given one out of band — the plaintext exists for exactly one moment. So
  # reconnecting is the upgrade path, and reconnecting is what an agent does.
  my $token = defined $existing->{token_hash} ? undef : $self->issue_token($member);

  return ($member, undef, $token) if $existing->{name} eq $name;
  return ($member,
    $self->_write($room, $session_id, $name,
      'member.renamed' => "$existing->{name} is now **$name**"),
    $token);
}

# A write credential, issued once, on the same terms as a room's delete
# password: this is the only moment the plaintext exists outside the caller's
# hand.
#
# The room URL stays the READ credential — anyone holding it can read the room,
# which is what a room URL has always meant. What this adds is the other half,
# because "your own message" has to mean something before anybody can edit or
# delete one. Until now a session id was a claim, and it was rendered on every
# message in the transcript for anyone reading the room to copy.
sub issue_token ($self, $member) {
  my $token = token(24);
  my ($salt, $hash) = password_hash($token);
  $self->sql->db->query('UPDATE chat_members SET token_salt = ?, token_hash = ? WHERE id = ?',
    $salt, $hash, $member->{id});
  return $token;
}

# Refuses unless this caller may write as this member. `trusted` is how a
# browser says so: its session cookie is signed and lives in one browser, so it
# already IS a credential and there is no token to carry.
sub authorise ($self, $room, $session_id, %args) {
  return 1 if $self->may_write($room, $session_id, %args);
  _fail('this room requires the member_token that join returned — it is the only copy '
      . 'of it you were ever given, and no other call will tell you it again');
}

# The same question without the exception, for the writes that must never fail a
# read -- presence bookkeeping. Those silently do nothing rather than 403.
sub may_write ($self, $room, $session_id, %args) {
  return 1 unless $self->require_token;
  return 1 if $args{trusted};
  return 1 if $self->token_ok($room, $session_id, $args{member_token});
  return 0;
}

# Every state-changing call passes through here.
#
# `client` is REQUIRED when a limiter is configured, and its absence is a die
# rather than a pass. That asymmetry is deliberate: a caller that forgets to
# identify itself is exactly how the limit came to be missing from one transport
# for two releases, and a loud failure in the test suite is cheaper than a quiet
# bypass in production.
sub _limit ($self, $what, %args) {
  my $limiter = $self->limiter or return 1;
  _fail("internal: $what reached the store without a client identity")
    unless defined $args{client} && length $args{client};

  my ($ok, $wait) = $limiter->($args{client});
  return 1 if $ok;
  die {share_error => "too many requests; try again in ${wait}s", retry_after => $wait};
}

sub token_ok ($self, $room, $session_id, $token) {
  my $member = $self->member($room, $session_id) or return 0;
  return 0 unless defined $member->{token_hash};
  return password_ok($token, $member->{token_salt}, $member->{token_hash}) ? 1 : 0;
}

sub member ($self, $room, $session_id) {
  return undef unless defined $session_id && length $session_id;
  return $self->sql->db->query('SELECT * FROM chat_members WHERE room_id = ? AND session_id = ?',
    $room->{id}, $session_id)->hash;
}

# What the roster can honestly say about somebody.
#
# `last_seen_at` was never "last spoke" — touch_member fires on every READ as
# well as every post, from five call sites — so it was always a better presence
# signal than it was given credit for. What it cannot survive is a fifteen-minute
# park: the member is silent that whole time while genuinely listening, and any
# grace window short enough to spot a dead session would mark a live listener
# away. So a waiter records how long it means to be there, and holding an open
# poll IS the presence signal. Nobody has to remember to say anything.
sub presence ($self, $member, $now = time) {
  return 'gone'      if $member->{left_at};
  return 'listening' if ($member->{waiting_until} // 0) > $now;
  return 'idle'      if $member->{last_seen_at} > $now - $self->presence_grace;
  return 'away';
}

# Dropping out was posting a goodbye and hoping. Two agents did exactly that in
# one afternoon, and the roster went on listing both as present -- which looks
# identical to two that are listening, and is how you end up addressing nobody.
sub leave_room ($self, $room, $session_id, %args) {
  # BEFORE the lookup. The comment that used to sit here argued the opposite --
  # look first, so a stranger gets a 404 rather than a 403 "that confirms the id
  # exists". It has it exactly backwards: 404-for-a-stranger and
  # 403-for-a-member is precisely what makes a room URL a way to test whether a
  # guessed session id is real, and session ids are guessable. One answer for
  # both, the way remove_room has always done it.
  $self->authorise($room, $session_id, %args);
  my $member = $self->member($room, $session_id) or return undef;
  return $member if $member->{left_at};

  $self->sql->db->query('UPDATE chat_members SET left_at = ?, waiting_until = 0 WHERE id = ?',
    time, $member->{id});
  $self->_write($room, $session_id, $member->{name}, 'member.left' => '');
  return $self->member($room, $session_id);
}

# "I will be here until T", and "I have let go". Both are bookkeeping and neither
# is ever a reason to fail a read -- the same rule, and the same reason, as
# touch_member.
sub hold ($self, $room, $session_id, $seconds, %args) {
  return unless defined $session_id && length $session_id;
  return unless $self->may_write($room, $session_id, %args);
  eval {
    $self->sql->db->query(
      'UPDATE chat_members SET waiting_until = ?, last_seen_at = ? '
        . 'WHERE room_id = ? AND session_id = ?',
      time + $seconds, time, $room->{id}, $session_id);
    1;
  } or do {
    $self->log->warn("chat: hold failed (carrying on): " . ($@ // '')) if $self->log;
  };
  return;
}

sub release ($self, $room, $session_id, %args) {
  return unless defined $session_id && length $session_id;
  return unless $self->may_write($room, $session_id, %args);
  eval {
    $self->sql->db->query(
      'UPDATE chat_members SET waiting_until = 0, last_seen_at = ? '
        . 'WHERE room_id = ? AND session_id = ?',
      time, $room->{id}, $session_id);
    1;
  } or do {
    $self->log->warn("chat: release failed (carrying on): " . ($@ // '')) if $self->log;
  };
  return;
}

sub members ($self, $room) {
  # By id after the timestamp: two sessions can join in the same second, and a
  # roster that reshuffles between two reads for no reason is a roster nobody
  # trusts.
  return $self->sql->db->query(
    'SELECT * FROM chat_members WHERE room_id = ? ORDER BY joined_at, id', $room->{id})
    ->hashes->to_array;
}

# Where this member has read to, and how to move it.
#
# The asymmetry is the whole design: carry your own cursor and the server stays
# out of it; ask for `unread` and the server keeps it for you. A watcher that
# picks `unread` is stateless, and stateless is the only kind that survives being
# re-invoked — which is exactly what a backgrounded curl does to it, every time
# it fires.
sub read_cursor ($self, $room, $session_id) {
  my $member = $self->member($room, $session_id) or return undef;
  return 0 + $member->{read_cursor};
}

sub mark_read ($self, $room, $session_id, $cursor, %args) {
  return unless defined $cursor && $cursor =~ /\A\d+\z/;
  # Before the lookup, for the same reason as leave_room: a silent 200 for a
  # stranger and a 403 for a member is a membership oracle.
  $self->authorise($room, $session_id, %args);
  my $member = $self->member($room, $session_id) or return;
  # The quiet one. Set somebody's cursor forward and they skip exactly the
  # message another agent needed them to see — no error anywhere, and the room
  # looks fine.
  $self->authorise($room, $session_id, %args);
  # Never backwards. Two reads can overlap, and the later one landing first must
  # not un-read what the earlier one already delivered.
  return if $cursor <= $member->{read_cursor};
  $self->sql->db->query('UPDATE chat_members SET read_cursor = ? WHERE id = ?',
    $cursor, $member->{id});
  return;
}

# How far behind this member is. Zero for somebody who never joined, because a
# stranger is not behind — there is nothing they were meant to have read.
sub unread_count ($self, $room, $session_id) {
  my $member = $self->member($room, $session_id) or return 0;
  return 0 + $self->sql->db->query(
    'SELECT COUNT(*) FROM chat_events WHERE room_id = ? AND id > ?',
    $room->{id}, $member->{read_cursor})->array->[0];
}

# Bookkeeping only, and never a reason to fail a read — the same rule, and for
# the same reason, as Share::Store::touch.
# Presence is a write, and it decides whether the others go on addressing this
# session at all. Forging it re-creates the exact failure the feature exists to
# prevent -- everyone talking to somebody who is not there, or nobody talking to
# somebody who is. It refuses silently rather than raising: these are called from
# the read path, and a read must never fail because of bookkeeping.
sub touch_member ($self, $room, $session_id, %args) {
  return unless defined $session_id && length $session_id;
  return unless $self->may_write($room, $session_id, %args);
  eval {
    $self->sql->db->query(
      'UPDATE chat_members SET last_seen_at = ? WHERE room_id = ? AND session_id = ?',
      time, $room->{id}, $session_id);
    1;
  } or do {
    my $err = $@ || 'unknown error';
    # The rowid, never the secret. A room's secret IS its bearer credential, and
    # `warn` is on in production -- one transient database hiccup would have put
    # a live room credential into a log nobody treats as secret material.
    $self->log->warn("chat: touch failed for room $room->{id} (carrying on): $err")
      if $self->log;
  };
  return;
}

# ------------------------------------------------------------- messages ------

sub post ($self, $room, %args) {
  my $session_id = _clean_line($args{session_id}, 200) // _fail('session_id is required');
  $self->authorise($room, $session_id, %args);
  $self->_limit('post', %args);
  my $member     = $self->member($room, $session_id)
    or _fail('join the room before posting: send your session_id, a name and one '
      . 'paragraph about what you are working on');

  my $body = _clean_text($args{body}, undef) // _fail('a message needs something in it');

  # Measured in bytes, because that is what is stored and what everything
  # downstream carries. A limit counted in characters would let an emoji-heavy
  # message through at four times the size a plain one is allowed.
  my $bytes = $body;
  utf8::encode($bytes);
  _fail(sprintf 'that message is %d bytes and the limit is %d — put the long thing in a '
      . 'file, share it, and post the URL', length $bytes, $self->max_message_bytes)
    if length $bytes > $self->max_message_bytes;

  $self->touch_member($room, $session_id);
  return $self->_write($room, $session_id, $member->{name}, message => $body);
}

sub _write ($self, $room, $session_id, $name, $type, $body, %extra) {
  my $db = $self->sql->db;
  $db->insert(
    'chat_events',
    { room_id    => $room->{id},
      # Null for the two events a room produces on its own behalf. A room ends
      # whether or not anybody made it happen.
      session_id => $session_id,
      name       => $name,
      type       => $type,
      body       => $body,
      created_at => time,
      (defined $extra{target_id} ? (target_id => $extra{target_id}) : ()),
    }
  );

  my $id  = $db->dbh->sqlite_last_insert_rowid;
  my $row = $db->query('SELECT * FROM chat_events WHERE id = ?', $id)->hash;
  $self->_record_mentions($room, $row);
  $self->_prune($room);
  return $row;
}

# Who this event addressed.
#
# Matched against the roster, never against a caller-supplied pattern — the same
# discipline the room's search already follows, and for the same reason: one
# nested quantifier over a few thousand messages takes a worker out of service,
# and Perl's engine has no timeout to stop it. A name is a name.
#
# The row binds to the MEMBER and not to the text, so renaming yourself does not
# orphan every message that ever addressed you — which matters here, because
# renaming mid-run is a thing sessions actually do.
sub _record_mentions ($self, $room, $row) {
  my $body = $row->{body} // '';
  return unless length $body;

  # One message to the whole fleet. It earns its place on the use it was asked
  # for — one instruction reaching four sessions at once, which is exactly what
  # happened in the room these changes come from — and it reaches AGENTS only.
  # Not pinging the people who are reading anyway is the difference between a
  # broadcast and a megaphone.
  my $fleet = $body =~ /(?:\A|[^\w\@])\@agents(?![\w-])/i;

  my %wanted;
  for my $member (@{$self->members($room)}) {
    next if $member->{left_at};
    $wanted{$member->{id}} = 1, next if $fleet && $member->{kind} eq 'agent';

    # (?![\w-]) rather than a plain word boundary: a hyphen is part of a name as
    # far as this room is concerned, and \b would find "@drac" inside "@drac-e1"
    # and address the wrong agent — quietly, in the one place that would matter.
    $wanted{$member->{id}} = 1
      if $body =~ /(?:\A|[^\w\@])\@\Q$member->{name}\E(?![\w-])/i;
  }

  my $db = $self->sql->db;
  $db->query('INSERT OR IGNORE INTO chat_mentions (event_id, member_id, room_id) VALUES (?,?,?)',
    $row->{id}, $_, $room->{id})
    for sort keys %wanted;
  return;
}

# Names by event id, for a whole page in one query rather than one per event —
# a hundred events would otherwise be a hundred round trips. The name is read
# from the member now, not from the text then, which is what makes a rename
# harmless.
sub mentions_for ($self, $room, $ids) {
  return {} unless @$ids;
  my $in   = join ',', ('?') x @$ids;
  my $rows = $self->sql->db->query(
    "SELECT n.event_id, m.name FROM chat_mentions n
       JOIN chat_members m ON m.id = n.member_id
      WHERE n.room_id = ? AND n.event_id IN ($in) ORDER BY m.name",
    $room->{id}, @$ids)->hashes;

  my %by;
  push @{$by{$_->{event_id}}}, $_->{name} for @$rows;
  return \%by;
}

# The per-room ceiling, enforced after the fact like the disk one: a room that
# has been running for a fortnight sheds its oldest exchanges rather than
# refusing the next message.
sub _prune ($self, $room) {
  my $cap = $self->max_messages or return;
  my $db  = $self->sql->db;

  my $count = $db->query('SELECT COUNT(*) FROM chat_events WHERE room_id = ?', $room->{id})
    ->array->[0];
  return if $count <= $cap;

  my $cut = $db->query(
    'SELECT id FROM chat_events WHERE room_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?',
    $room->{id}, $cap)->array->[0];
  return unless defined $cut;

  $db->query('DELETE FROM chat_events WHERE room_id = ? AND id <= ?', $room->{id}, $cut);
  # Remembered so that a caller polling from an id that has since been dropped
  # can be told it missed something, instead of being handed a gap it has no way
  # to notice.
  $db->query('UPDATE chat_rooms SET pruned_to = ? WHERE id = ?', $cut, $room->{id});
  $room->{pruned_to} = $cut;
  return;
}

# Always oldest-first, which is the order a transcript is read in.
#
#   since    everything after that message id
#   q        case-insensitive substring match — grep, not a regex; see below
#   limit    at most this many, defaulting to a hundred
#
# Without `since` the newest `limit` are returned, so opening a busy room hands
# over the tail of the conversation rather than all of it.
sub messages ($self, $room, %opt) {
  my $limit = $opt{limit};
  $limit = 100 unless defined $limit && $limit =~ /\A\d+\z/ && $limit > 0;
  $limit = 500 if $limit > 500;

  my @where = ('room_id = ?');
  my @bind  = ($room->{id});

  my $since = $opt{since};
  if (defined $since && $since =~ /\A\d+\z/) {
    push @where, 'id > ?';
    push @bind,  $since;
  }
  else { $since = undef }

  # Substring, deliberately, and the tool descriptions say so. A regular
  # expression supplied by a caller is a hang waiting to happen — one nested
  # quantifier over a few thousand messages takes a worker out of service, and
  # there is no timeout in Perl's engine to put a stop to it. Everything grep is
  # actually reached for here ("who mentioned the migration?") is a substring.
  # "Has anyone addressed me?" — and, combined with `wait`, the difference
  # between parking on "someone needs me" and parking on "someone spoke". An
  # agent will leave the first one running and will turn the second one off.
  if (my $me = $opt{mentions_me}) {
    # Scoped to the room as well as the member. Belt as well as braces: without
    # it this trusts every id in the table to be the id it thinks it is, and one
    # stray row -- from rowid reuse, from a bug not yet written -- can address
    # somebody who was never addressed. One clause, and an orphan from any
    # source reaches nobody.
    push @where,
      'id IN (SELECT event_id FROM chat_mentions WHERE member_id = ? AND room_id = ?)';
    push @bind, $me, $room->{id};
  }

  if (defined $opt{q} && length $opt{q}) {
    push @where, 'instr(lower(body), lower(?)) > 0';
    push @bind,  $opt{q};
  }

  my $sql = 'SELECT * FROM chat_events WHERE ' . join(' AND ', @where);

  # With a cursor the caller wants the NEXT hundred; without one it wants the
  # LAST hundred. Same query, opposite ends, reversed back on the way out.
  my $rows
    = defined $since
    ? $self->sql->db->query("$sql ORDER BY id ASC LIMIT ?",  @bind, $limit)->hashes->to_array
    : [reverse @{$self->sql->db->query("$sql ORDER BY id DESC LIMIT ?", @bind, $limit)
        ->hashes->to_array}];

  return $rows;
}

# The id to poll from next. The newest message when there is one, and otherwise
# whatever the caller already had — never zero, or a client that opens an empty
# room would be handed the whole history on its next call.
sub cursor ($self, $room, $rows, $since = undef) {
  # Numeric, always. `since` arrives from a query string as a string, and a
  # cursor that comes back as "999" one call and 999 the next is a difference
  # somebody's client will eventually compare on.
  return 0 + $rows->[-1]{id} if @$rows;
  return 0 + $since if defined $since && $since =~ /\A\d+\z/;
  return 0 + $self->last_id($room);
}

sub last_id ($self, $room) {
  return $self->sql->db->query('SELECT COALESCE(MAX(id), 0) FROM chat_events WHERE room_id = ?',
    $room->{id})->array->[0];
}

# Did this caller ask for messages the cap has already deleted?
sub missed ($self, $room, $since) {
  return 0 unless defined $since && $since =~ /\A\d+\z/;
  return $since < $room->{pruned_to} ? 1 : 0;
}

# ------------------------------------------------------- housekeeping --------

sub stats ($self) {
  my $now = time;
  my $r   = $self->sql->db->query(
    'SELECT COUNT(*) AS rooms FROM chat_rooms WHERE expires_at > ?', $now)->hash;
  my $m = $self->sql->db->query(
    'SELECT COUNT(*) AS messages FROM chat_events WHERE room_id IN '
      . '(SELECT id FROM chat_rooms WHERE expires_at > ?)', $now)->hash;
  return {rooms => $r->{rooms}, messages => $m->{messages}};
}

# The only warning anybody gets that a fortnight of coordination is about to be
# reaped.
#
# Written once — `warned_at` is the guard — by the same hourly pass that does the
# deleting, so there is no second timer and no second worker. And written while
# the room is still standing, which is the whole point: a room that only
# announces itself by disappearing has told you nothing you can act on.
sub warn_expiring ($self, $now = time) {
  my $rooms = $self->sql->db->query(
    'SELECT * FROM chat_rooms WHERE warned_at IS NULL AND expires_at > ? AND expires_at <= ?',
    $now, $now + $self->expiry_warning)->hashes->to_array;

  for my $room (@$rooms) {
    $self->_write($room, undef, 'system', 'room.expiring' => sprintf
        'This room, its roster and every message in it are **deleted in %s** (%s). '
      . 'Anything worth keeping should be moved somewhere that outlives it.',
      human_duration($room->{expires_at} - $now), iso8601($room->{expires_at}));
    $self->sql->db->query('UPDATE chat_rooms SET warned_at = ? WHERE id = ?',
      $now, $room->{id});
  }
  return scalar @$rooms;
}

# The one event that is never read from the stored sequence, because by
# definition the sequence it would belong to is being deleted in the same breath.
#
# Synthesized at delivery, and only for a caller that was demonstrably here while
# the room still was — a parked reader. A cold read of a dead id still gets a
# 404, because we cannot tell "destroyed an hour ago" from "never existed" and
# saying otherwise would be inventing knowledge we do not have.
# Live, expired, or gone entirely. find_room answers undef for the last two
# because from a caller's point of view they are the same thing -- but a parked
# reader is owed the difference, and it cannot be read off the room hashref it
# started with, which still says what it said fifteen minutes ago.
sub room_state ($self, $secret) {
  my $row = $self->sql->db->query('SELECT expires_at FROM chat_rooms WHERE secret = ?',
    $secret)->hash;
  return 'closed' unless $row;
  return $row->{expires_at} <= time ? 'expired' : 'live';
}

sub destroyed_event ($self, $why) {
  return {
    id         => 0,
    type       => 'room.destroyed',
    kind       => 'room.destroyed',
    session_id => undef,
    name       => 'system',
    why        => $why,
    mentions   => [],
    created_at => iso8601(time),
    body       => $why eq 'expired'
      ? 'This room reached its expiry. Everything in it has been deleted.'
      : 'This room was closed. Everything in it has been deleted.',
  };
}

# Members who have stopped saying anything at all.
#
# Runs far more often than the reaper -- a five-minute timeout needs a sweep in
# minutes, not hours -- so it takes its own claim rather than riding on that one.
# Anyone still holding a long poll is by definition present and is skipped, which
# is what stops a fifteen-minute park being mistaken for silence.
sub sweep_idle ($self, $now = time, %opt) {
  # The same conditional-UPDATE claim the file reaper uses, under a key of its
  # own: every prefork worker holds this timer and exactly one wins the round.
  unless ($opt{force}) {
    my $claimed = $self->sql->db->query(
      q{UPDATE meta SET v = ? WHERE k = 'last_presence_sweep' AND CAST(v AS INTEGER) <= ?},
      $now, $now - ($opt{every} // 60))->rows;
    return 0 unless $claimed;
  }

  my $stale = $self->sql->db->query(
    'SELECT m.*, r.secret FROM chat_members m JOIN chat_rooms r ON r.id = m.room_id
      WHERE m.left_at IS NULL AND m.waiting_until <= ? AND m.last_seen_at < ?
        AND r.expires_at > ?',
    $now, $now - $self->presence_timeout, $now)->hashes->to_array;

  for my $member (@$stale) {
    $self->sql->db->query('UPDATE chat_members SET left_at = ?, waiting_until = 0 WHERE id = ?',
      $now, $member->{id});
    $self->_write({id => $member->{room_id}, secret => $member->{secret}},
      $member->{session_id}, $member->{name}, 'member.left' => '');
  }

  return scalar @$stale;
}

# Called from the file reaper's hourly pass, once it has won the claim, so there
# is one timer and one worker doing all of the deleting.
sub reap ($self, $now = time) {
  my $rooms = $self->sql->db->query('SELECT * FROM chat_rooms WHERE expires_at <= ?', $now)
    ->hashes->to_array;
  my $messages = 0;
  for my $room (@$rooms) {
    $messages += $self->sql->db->query('SELECT COUNT(*) FROM chat_events WHERE room_id = ?',
      $room->{id})->array->[0];
    $self->_purge_room($room);
  }
  return {rooms => scalar(@$rooms), messages => $messages};
}

# ------------------------------------------- the public view of the rows -----

# One representation for the REST API, the MCP tools and the templates alike, so
# an agent and a person are never told different things about the same room.
sub room_public ($self, $room, $base_url, %opt) {
  my $left = $room->{expires_at} - time;
  return {
    id      => $room->{secret},
    # Two URLs again, and for the same reason as a file's: one is the page a
    # person opens, the other is what a machine talks to.
    url     => "$base_url/c/$room->{secret}",
    api_url => "$base_url/api/v1/chatrooms/$room->{secret}",
    topic   => $room->{topic},
    purpose => $room->{purpose},
    created_at => iso8601($room->{created_at}),
    expires_at => iso8601($room->{expires_at}),
    expires_in => human_duration($left),
    ($opt{members}
      ? (members => [map { $self->member_public($_, $room) } @{$self->members($room)}]) : ()),
  };
}

sub member_public ($self, $member, $room = undef) {
  my $presence = $self->presence($member);
  return {
    author       => $self->_author_key_for($member),
    name         => $member->{name},
    about        => $member->{about},
    kind         => $member->{kind},
    joined_at    => iso8601($member->{joined_at}),
    last_seen_at => iso8601($member->{last_seen_at}),
    presence     => $presence,
    online       => ($presence eq 'listening' || $presence eq 'idle') ? \1 : \0,
    # How far they have read. A crude "has not read anything since 7" in the
    # roster is what would have told one agent to stop waiting on another and ask
    # the human instead -- which is what it eventually did, hours later.
    read_cursor  => 0 + ($member->{read_cursor} // 0),
  };
}

# A stable per-room handle for whoever wrote something, which is NOT their
# session id.
#
# The session id is what authenticates a write, and it was rendered on every
# message and returned with every event — so anyone who could read a room could
# read an id off the wall and post as its owner. It is derived rather than
# stored so that nothing had to migrate, and it is salted with the room secret so
# the same session in two rooms does not link them.
# A stable per-room handle for whoever wrote something, which is NOT their
# session id and cannot be turned back into one.
#
# It used to be sha256(room_secret, session_id) truncated. That is reversible by
# anybody in the room: the room secret is the URL they were handed, the roster
# publishes the name-to-handle map, and a session id is a short string an agent
# chose to be readable. The audit recovered "victim" from its handle and posted
# as them.
#
# The salt is random, per member, and never published, so the handle now stands
# for an identity without describing it. It is still stable -- the page uses it to
# mark your own messages -- and still per room, so one session cannot be followed
# from one room to another.
sub author_key ($self, $room, $session_id) {
  return undef unless defined $session_id;
  my $member = $self->member($room, $session_id) or return undef;
  return $self->_author_key_for($member);
}

sub _author_key_for ($self, $member) {
  my $salt = $member->{author_salt};

  # A member row that predates the column. Filled in on sight rather than in the
  # migration alone, so a row created by a mid-upgrade write is covered too.
  unless (defined $salt && length $salt) {
    $salt = unpack 'H*', token(16);
    $self->sql->db->query('UPDATE chat_members SET author_salt = ? WHERE id = ?',
      $salt, $member->{id});
  }

  return substr Digest::SHA::sha256_hex("$salt\0$member->{session_id}"), 0, 12;
}

sub event_public ($self, $row, $mentions = [], $room = undef) {
  return {
    id         => 0 + $row->{id},
    author     => $room ? $self->author_key($room, $row->{session_id}) : undef,
    name       => $row->{name},
    type       => $row->{type},
    # The name this field had before a room had an event stream. It costs one key
    # on the wire, and it is the whole reason /messages can go on meaning what it
    # meant yesterday — assets/chat.js switches on it, and so does every caller
    # written against the shape this endpoint had last week.
    kind       => $row->{type},
    body       => $row->{body},
    created_at => iso8601($row->{created_at}),
    mentions   => $mentions,
    (defined $row->{target_id} ? (target_id => 0 + $row->{target_id}) : ()),
  };
}

# The name the rest of the app still calls it by.
sub message_public ($self, $row) { return $self->event_public($row) }

# The same event, with everything expensive left out.
#
# A real catch-up on nineteen messages cost about SIX THOUSAND tokens in one tool
# result, and the agent that paid it drew the obvious conclusion: it stopped
# re-reading the room to check facts. That is how a room fills up with agents
# restating stale values at each other. Enough here to know whether something
# concerns you, and a second call for the ones that do.
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
    # Back to a word boundary. A preview that stops mid-word is how a truncated
    # notification announced itself in the field — and the ones that happened to
    # stop on a boundary read as complete and got acted on, which is worse. Hence
    # `truncated` as well: never leave it to the shape of the text to say.
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

# One event, by id, and only from the room that holds it.
sub event ($self, $room, $id) {
  return undef unless defined $id && $id =~ /\A\d+\z/;
  return $self->sql->db->query('SELECT * FROM chat_events WHERE room_id = ? AND id = ?',
    $room->{id}, $id)->hash;
}

# ------------------------------------------------------------- briefing ------

# What a session is told when it arrives — from `join_chatroom`, from the REST
# join, and from fetching the room URL itself with anything that is not a
# browser. An agent is handed this URL by a human who was handed it by another
# agent, with no other context at all, so it has to be the whole of how to take
# part: join, post, read, wait, grep, and where a file goes.
#
# It is one text and one table of endpoints rather than prose per tool, because
# the alternative — each tool explaining a third of the protocol — is how a
# session ends up polling in a loop when there is a `wait` parameter sitting
# right there.
sub briefing ($self, $room, $base_url) {
  my $api = "$base_url/api/v1/chatrooms/$room->{secret}";
  my $ttl = int(($room->{expires_at} - $room->{created_at}) / 86400);

  my $how_to = sprintf <<'TXT', $api, $self->max_message_bytes, $api, $api, $api, $api, $base_url, $ttl;
This is a chat room. Agents working in different sessions coordinate here, and a
person can open the same URL in a browser and take part.

Everything that happens in the room is one sequence of EVENTS on one cursor:
somebody speaking, somebody arriving or leaving, a rename, the room itself
expiring. "What has happened since I last looked?" is one question.

  1. JOIN FIRST. POST %s/members with your session_id, a
     short name nobody else in the room has taken, and one paragraph saying what
     you are working on. Everyone reads that paragraph; it is how the others
     find out what you are holding without asking.

     The answer contains a "member_token". It is shown ONCE. Keep it: on an
     instance that requires it, it is what lets you post. Calling this again with
     the SAME session_id and a different name renames you, and tells the room.

  2. POST a message: POST .../messages with your session_id and "body".
     Markdown, up to %d bytes of it. The answer tells you what landed while you
     were not looking -- "unread", and the headers of what you missed.

  3. READ: GET %s/events?since=<id>. Every event
     carries an id; keep the last one and hand it back. Or send
     since=unread and the server reads from where IT remembers you got to, which
     is what lets a session that has just restarted remember nothing at all.

  4. FOLLOW THE ROOM WITHOUT SITTING STILL. This is the important one. Run it in
     the background; it returns ONLY when something happens, or after fifteen
     minutes:

       curl -fsS --max-time 960 '%s/events?since=<cursor>&wait=900&format=headers'

     Re-arm it with the "cursor" it hands back. "timed_out" tells you which of
     the two happened, so you never have to guess from an empty list. Add
     &mentions_me=1&session_id=<you> and it wakes you only when somebody
     actually addressed you -- by name, or the whole fleet at once with @agents.

  5. READ CHEAPLY. format=headers gives id, author, time, mentions and a short
     preview instead of whole bodies; catching up costs hundreds of tokens
     rather than thousands. GET %s/events/<id> when one
     of them turns out to matter.

  6. GREP: GET %s/events?q=migration -- case-insensitive
     substring over everything the room still holds. A substring, not a regular
     expression.

  7. SAY WHEN YOU ARE DONE: DELETE .../members/<your session_id>. A member who
     has gone quiet looks exactly like one who is listening, and the others will
     go on addressing you. What you said stays in the room.

WHAT THE PERSON READING THIS SEES. Markdown is rendered, properly: headings,
tables, bold, lists, block quotes, code fences, emoji. Mermaid is NOT drawn in a
room -- put the diagram in a shared file and post its URL.

NO ATTACHMENTS. Put the file on this same instance and post the URL:

    curl -fsS -F 'file=@diagram.png' %s/api/v1/files

The JSON that prints contains "url" -- paste that into a message and anyone in
the room, human or agent, can open it.

THE URL IS THE SECRET. It is a bearer token: anyone who holds it can read this
room and post to it, and it gets pasted between sessions by a human. Rooms carry
host names, key fingerprints and infrastructure layout, so treat it the way you
would treat any other credential you were handed.

The room, its messages and its roster are deleted %d days after the room was
created, and the URL dies with them. The room says so itself, in the sequence,
a couple of hours before it goes.
TXT

  return {
    how_to    => $how_to,
    room_url  => "$base_url/c/$room->{secret}",
    api_url   => $api,
    endpoints => {
      join    => "POST $api/members",
      leave   => "DELETE $api/members/<session_id>",
      post    => "POST $api/messages",
      read    => "GET $api/events?since=<id>",
      unread  => "GET $api/events?since=unread&session_id=<you>",
      watch   => "GET $api/events?since=<id>&wait=900&format=headers",
      wanted  => "GET $api/events?since=<id>&wait=900&mentions_me=1&session_id=<you>",
      one     => "GET $api/events/<id>",
      search  => "GET $api/events?q=<text>",
      roster  => "GET $api",
    },
    curl => {
      join => sprintf(
        q{curl -fsS -X POST -H content-type:application/json '%s/members' }
          . q{-d '{"session_id":"$SESSION","name":"planner","about":"what I am working on"}'},
        $api),
      post => sprintf(
        q{curl -fsS -X POST -H content-type:application/json '%s/messages' }
          . q{-d '{"session_id":"$SESSION","body":"**done**: the migration is green"}'},
        $api),
      # The whole feature in one line: run it in the background and it returns
      # only when the room needs you.
      watch => qq{curl -fsS --max-time 960 '$api/events?since=<id>&wait=900&format=headers'},
    },
    max_message_bytes => 0 + $self->max_message_bytes,
  };
}

# --------------------------------------------------------------- helpers -----

sub _fail ($msg) { die {share_error => $msg} }    ## no critic (RequireCarping)

# One line: control characters out, whitespace collapsed, trimmed, cut to size.
# Returns undef for anything that had no content to begin with, so a caller can
# tell "not given" from "given and empty" with one `//`.
sub _clean_line ($value, $max) {
  return undef unless defined $value;
  $value =~ s/[\x00-\x1f\x7f]/ /g;
  $value =~ s/\s+/ /g;
  $value =~ s/\A\s+|\s+\z//g;
  return undef unless length $value;
  return substr $value, 0, $max;
}

# Prose or markdown: newlines survive, everything else that a terminal would
# choke on does not. $max is a character count and undef means no cut here —
# messages are limited in bytes by `post`, which is what the caller is told.
sub _clean_text ($value, $max) {
  return undef unless defined $value;
  $value =~ s/\r\n?/\n/g;
  $value =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
  $value =~ s/\A\s+|\s+\z//g;
  return undef unless length $value;
  return defined $max ? substr($value, 0, $max) : $value;
}

1;
