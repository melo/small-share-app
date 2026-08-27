#!/usr/bin/env perl

# The chat rooms: the store, the six REST endpoints, the six MCP tools and the
# three pages a person sees. Run by the same build stage as t/share.t, and for
# the same reason — a room that cannot be joined, or one whose messages reach
# the page holding the identity cookie, must never get as far as an image.
#
# A file of its own rather than more subtests in t/share.t, because
# Mojolicious::Lite's app is a singleton in `main`: two Test::Mojo instances in
# one process are two apps over two stores, and the second one pulls the rug out
# from under the first. Separate processes have no such argument.
#
# Run it by hand with:  cd app && SHARE_ROOT=$(mktemp -d) prove -lv t/chat.t

use Mojo::Base -strict, -signatures;
use utf8;

use File::Temp  ();
use Mojo::File  qw(curfile);
use Mojo::IOLoop ();
# from_json, not decode_json: anything read out of an MCP result has already
# been decoded from the response and is characters. See t/share.t.
use Mojo::JSON  qw(from_json);
use Mojo::SQLite ();
use Share::Chat  ();
use Test::Mojo  ();
use Test::More;

my $tmp = File::Temp->newdir;
$ENV{SHARE_ROOT}     = "$tmp";
$ENV{SHARE_BASE_URL} = 'https://share.example.test';

# Generous for the bulk of the file, which posts far faster than any room ever
# will. The limit gets a subtest of its own, against the running app.
$ENV{SHARE_CHAT_RATE_PER_SECOND} = 1000;
$ENV{SHARE_CHAT_RATE_PER_MINUTE} = 1000;

# So the health subtest below has something to look at. It is off by default
# everywhere else, deliberately — see share.pl.
$ENV{SHARE_HEALTH_DETAIL} = 1;
delete $ENV{SHARE_TTL_DAYS};

{ # Destroyed exactly when the last reference to it goes. A reference cycle
  # keeps it alive forever, which is the whole assertion above.
  package Share::Test::Sentinel;
  sub new ($class, $cb) { return bless {cb => $cb}, $class }
  sub DESTROY ($self) { $self->{cb}->() }
}

my $t = Test::Mojo->new(curfile->dirname->sibling('share.pl'));

my $PROTOCOL = '2026-07-28';
my $META     = 'io.modelcontextprotocol/protocolVersion';
my $CAPS     = 'io.modelcontextprotocol/clientCapabilities';
my $INFO     = 'io.modelcontextprotocol/clientInfo';

sub _mcp ($method, $params = undef, %opt) {
  state $id = 2000;
  my $p = {
    %{$params // {}},
    _meta => {$META => $PROTOCOL, $CAPS => {}, $INFO => {name => 'chat-tests', version => '1'}},
  };

  my %headers = ('MCP-Protocol-Version' => $PROTOCOL, 'Mcp-Method' => $method);
  $headers{'Mcp-Name'} = $params->{name}
    if $method eq 'tools/call' && defined $params->{name};

  # A tool that WAITS answers with a promise, and MCP::Server delivers a promise
  # over an SSE stream rather than as one JSON body. get_chat_messages with a
  # `wait` is the only call in this suite shaped that way.
  #
  # Mojo parses an event stream into `sse` events and never fills the response
  # body, so there is nothing in ->text to read afterwards: the events have to be
  # collected as they arrive, which means subscribing before the request goes.
  my @events;
  $t->ua->once(start => sub ($ua, $tx) {
    # The first `sse` carries no event at all — it is the stream announcing
    # itself — so the payload is the only thing collected here.
    $tx->res->content->on(sse => sub { push @events, $_[1] if $_[1] });
  });

  $t->post_ok('/mcp' => \%headers => json =>
      {jsonrpc => '2.0', id => ++$id, method => $method, params => $p});
  $t->status_is($opt{status} // 200);

  my $res = $t->tx->res;
  return $res->json unless ($res->headers->content_type // '') =~ m{text/event-stream};
  return @events ? from_json($events[-1]{text}) : {};
}

# One tool call, unwrapped to the structured content it answered with.
sub _call ($name, $args) {
  my $res = _mcp('tools/call', {name => $name, arguments => $args});
  return $res->{result};
}

# A room, made the way an agent makes one.
sub _room (%args) {
  $t->post_ok('/api/v1/chatrooms' => json => {topic => 'a room', %args})->status_is(201);
  return $t->tx->res->json;
}

sub _join ($id, %args) {
  $t->post_ok("/api/v1/chatrooms/$id/members" => json => {%args});
  return $t->tx->res->json;
}

sub _post ($id, $session, $body) {
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => $session, body => $body});
  return $t->tx->res->json;
}

# A person in the room. The API deliberately will not make one -- it hardcodes
# kind => 'agent', because the paragraph saying what you are working on is
# required of an agent and optional for somebody who has just opened the page --
# so a human arrives the way a human really does, through the model behind the
# browser's join form.
sub _human ($id, $session, $name) {
  my $room = $t->app->chat->find_room($id);
  my ($member) = $t->app->chat->join_room($room,
    session_id => $session, name => $name, kind => 'human');
  return $member;
}

# ------------------------------------------------------------ the briefing ---

subtest 'a room is one URL, and the URL explains itself to whoever fetches it' => sub {
  my $made = _room(topic => 'ship 1.4', purpose => 'three sessions, one release',
    session_id => 'sess-a');

  my $id = $made->{room}{id};
  like $id, qr/\A[A-Za-z0-9]{32}\z/, 'the id is 32 base62 characters, like a file id';
  is $made->{room}{url}, "https://share.example.test/c/$id", 'the URL a human is given';
  is $made->{room}{api_url}, "https://share.example.test/api/v1/chatrooms/$id",
    'and the one a machine talks to';
  like $made->{delete_password}, qr/\A\S{8,}\z/, 'a delete password, once';

  # The whole protocol, in the answer, because the agent on the other end of
  # this URL may have no MCP server registered and nothing else to read.
  like $made->{how_to}, qr/JOIN FIRST/,               'the briefing says to join first';
  like $made->{how_to}, qr/wait=900/, 'and that parking beats polling';
  like $made->{how_to}, qr/case-insensitive\s+substring/s, 'and what grep means here';
  like $made->{how_to}, qr/NO ATTACHMENTS/,           'and that files go through the file side';
  like $made->{how_to}, qr{https://share\.example\.test/api/v1/files},
    'with the upload URL spelled out — not the room URL with /api/v1/files stuck on it';
  like $made->{how_to}, qr/deleted 15 days after/, 'and the retention, as configured';
  is $made->{max_message_bytes}, 16 * 1024, 'the message limit, as a number';

  # Fetching the room URL itself with anything that has not asked for HTML is
  # the same briefing. This is the path an agent takes when a person pastes the
  # URL into its conversation.
  $t->get_ok("/c/$id")->status_is(200)->content_type_like(qr{application/json})
    ->json_is('/room/id' => $id)->json_has('/how_to')->json_has('/endpoints/watch')
    ->json_has('/curl/post');

  # …and it does NOT carry the delete password, which was disclosed once.
  ok !exists $t->tx->res->json->{delete_password}, 'the briefing never repeats the password';

  # A browser asks for HTML and gets the room instead.
  $t->get_ok("/c/$id" => {Accept => 'text/html,application/xhtml+xml'})->status_is(200)
    ->content_type_like(qr{text/html})->content_like(qr/Join the room/);

  # ?json=1 for when you do not control the headers.
  $t->get_ok("/c/$id?json=1" => {Accept => 'text/html'})->status_is(200)
    ->content_type_like(qr{application/json});

  $t->get_ok('/api/v1/chatrooms/nosuchroomnosuchroom12345678')->status_is(404)
    ->json_like('/error' => qr/no such room/);
  $t->get_ok('/c/nosuchroomnosuchroom12345678' => {Accept => 'text/html'})->status_is(404)
    ->content_like(qr/does not point at a chat room/);

  # …and an agent that curled a room which has since expired is told so in the
  # JSON it came for, rather than being handed a page written for a person.
  $t->get_ok('/c/nosuchroomnosuchroom12345678')->status_is(404)
    ->content_type_like(qr{application/json})->json_like('/error' => qr/no such room/);
};

subtest 'a room can be opened just by asking for one' => sub {
  # `curl …/c` is the whole ceremony: an agent gets a room and the briefing in
  # one call, a person gets a room and lands at its door. It is a GET that
  # creates something, which buys a URL short enough to type from memory.
  $t->get_ok('/c')->status_is(201)->header_like(Location => qr{/c/[A-Za-z0-9]{32}\z})
    ->json_is('/room/topic' => 'Untitled room')
    ->json_has('/how_to')->json_has('/delete_password');

  my $first = $t->tx->res->json;
  ok $first->{delete_password}, 'and the one copy of the password to close it early';

  # A second call is a second room. Nothing is reused and nothing is guessed.
  $t->get_ok('/c')->status_is(201);
  isnt $t->tx->res->json->{room}{id}, $first->{room}{id}, 'each call opens its own room';

  $t->get_ok('/c?topic=ship+1.4&purpose=three+sessions,+one+release')->status_is(201)
    ->json_is('/room/topic' => 'ship 1.4')
    ->json_is('/room/purpose' => 'three sessions, one release');

  # An uptime probe pointed at /c must not open a room a minute.
  my $before = $t->app->chat->stats->{rooms};
  $t->head_ok('/c')->status_is(200);
  is $t->app->chat->stats->{rooms}, $before, 'HEAD creates nothing';

  # The room it made is an ordinary room in every other way.
  my $id = $first->{room}{id};
  ok _join($id, session_id => 'sess-a', name => 'planner', about => 'opened it with curl'),
    'and it can be joined and posted to like any other';
  _post($id, 'sess-a', 'first thing said in it');
  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)->json_is('/count' => 2);
};

subtest 'the door drops a person at a room, and tells them once how to close it' => sub {
  $t->reset_session;

  my %html = (Accept => 'text/html');
  $t->get_ok('/c?topic=opened+in+a+browser' => \%html)->status_is(302);
  my $location = $t->tx->res->headers->location;
  like $location, qr{/c/[A-Za-z0-9]{32}\z}, 'a browser is redirected to the room itself';

  # The password is carried across the redirect and shown on the door — the same
  # rule a file's delete password follows: the only copy, and never again.
  $t->get_ok($location => \%html)->status_is(200)
    ->content_like(qr/You opened this room/)
    ->content_like(qr{Delete password: <code>\S+</code>})
    ->content_like(qr/opened in a browser/)
    ->content_like(qr/Join the room/);

  $t->get_ok($location => \%html)->status_is(200)
    ->content_unlike(qr/You opened this room/)
    ->content_unlike(qr/Delete password/);
};

subtest 'opening rooms is rate limited too, in both dialects' => sub {
  my $cfg = $t->app->config;
  my @was = @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)};
  @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)} = (1, 1);
  $t->app->store->sql->db->query('DELETE FROM upload_hits');

  $t->get_ok('/c')->status_is(201);
  $t->get_ok('/c')->status_is(429)->json_like('/error' => qr/too many requests/)
    ->header_like('Retry-After' => qr/\A\d+\z/);

  # A browser is told the same thing in words rather than handed JSON.
  $t->get_ok('/c' => {Accept => 'text/html'})->status_is(429)
    ->content_like(qr/Not just yet/)->content_like(qr/few new rooms a minute/);

  @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)} = @was;
  $t->app->store->sql->db->query('DELETE FROM upload_hits');
};

# ---------------------------------------------------------------- joining ----

subtest 'joining means a name nobody else has, and what you are working on' => sub {
  my $id = _room(topic => 'joining')->{room}{id};

  $t->post_ok("/api/v1/chatrooms/$id/members" => json => {session_id => 'a'})->status_is(400)
    ->json_like('/error' => qr/pick a name/);
  $t->post_ok("/api/v1/chatrooms/$id/members" => json => {name => 'a'})->status_is(400)
    ->json_like('/error' => qr/session_id is required/);

  # An agent that will not say what it is holding is the one thing a
  # coordination room cannot have in it.
  $t->post_ok("/api/v1/chatrooms/$id/members" => json => {session_id => 'a', name => 'planner'})
    ->status_is(400)->json_like('/error' => qr/say what you are working on/);

  my $joined = _join($id, session_id => 'sess-a', name => 'planner',
    about => 'holding the release checklist');
  $t->status_is(200);
  is $joined->{member}{name}, 'planner', 'joined under the name it asked for';
  is $joined->{member}{kind}, 'agent',   'as an agent';
  is $joined->{count}, 1, 'and the arrival is in the transcript, not only in the roster';
  is $joined->{messages}[0]{type}, 'member.joined', 'as an arrival';
  is $joined->{messages}[0]{body}, 'holding the release checklist',
    'carrying the paragraph, so anyone waiting on the room reads it at once';
  is $joined->{cursor}, $joined->{messages}[0]{id}, 'with a cursor to read on from';

  # Two agents called "planner" in one conversation is a coordination bug the
  # room can refuse for free.
  $t->post_ok("/api/v1/chatrooms/$id/members" => json =>
      {session_id => 'sess-b', name => 'PLANNER', about => 'also planning'})
    ->status_is(400)->json_like('/error' => qr/is taken in this room/);

  # The same session calling again is an update, not a second member.
  my $again = _join($id, session_id => 'sess-a', name => 'planner', about => 'now tagging');
  is scalar @{$again->{room}{members}}, 1, 'rejoining does not clone the member';
  is $again->{room}{members}[0]{about}, 'now tagging', 'and it updates the paragraph';
  is $again->{count}, 1, 'with nothing new said about it';

  # A rename is worth a line in the transcript: everyone else has been reading
  # the old name all afternoon.
  my $renamed = _join($id, session_id => 'sess-a', name => 'releaser', about => 'now tagging');
  is $renamed->{member}{name}, 'releaser', 'renamed';
  is $renamed->{count}, 2, 'and the room was told';
  is $renamed->{messages}[-1]{type}, 'member.renamed', 'as a rename';
  like $renamed->{messages}[-1]{body}, qr/planner is now \*\*releaser\*\*/, 'saying so';

  # The freed name is available again.
  ok _join($id, session_id => 'sess-b', name => 'planner', about => 'took the old name')
    ->{member}, 'a name released by a rename can be taken';
};

# --------------------------------------------------------------- posting ----

subtest 'posting is for members, and a message is markdown and nothing else' => sub {
  my $id = _room(topic => 'posting')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'planner', about => 'the checklist');

  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'stranger', body => 'hello'})
    ->status_is(400)->json_like('/error' => qr/join the room before posting/);

  $t->post_ok("/api/v1/chatrooms/$id/messages" => json => {session_id => 'sess-a', body => ''})
    ->status_is(400)->json_like('/error' => qr/a message needs something in it/);

  my $said = _post($id, 'sess-a', "**staging is green**\n\n- ran the migration");
  $t->status_is(201);
  is $said->{message}{name}, 'planner', 'the message carries the name at the time';
  # NOT the session id: that is what authenticates a write, and publishing it on
  # every message let anyone who could read the room post as anybody in it. The
  # author key is derived from it, is stable within one room, and is useless.
  ok !exists $said->{message}{session_id}, 'and never the session that sent it';
  like $said->{message}{author}, qr/\A[0-9a-f]{12}\z/, 'but a handle for who did';
  like $said->{message}{created_at}, qr/\AZ?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, 'and a timestamp';
  is $said->{cursor}, $said->{message}{id}, 'and the cursor is its id';

  # Big things are files. This service has somewhere to put those already.
  my $chat = $t->app->chat;
  my $was  = $chat->max_message_bytes;
  $chat->max_message_bytes(64);
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-a', body => 'x' x 100})
    ->status_is(400)->json_like('/error' => qr/put the long thing in a file/);

  # Bytes, not characters: an emoji must not buy four times the room.
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-a', body => "\x{1f680}" x 20})
    ->status_is(400)->json_like('/error' => qr/\A那?that message is 80 bytes/i);
  $chat->max_message_bytes($was);

  # Form parameters work as well as JSON, because both are one line of curl.
  $t->post_ok("/api/v1/chatrooms/$id/messages" => form =>
      {session_id => 'sess-a', body => 'posted as a form'})->status_is(201)
    ->json_is('/message/body' => 'posted as a form');
};

# --------------------------------------------------------------- reading ----

subtest 'reading from a cursor, and grepping what was said' => sub {
  my $id = _room(topic => 'reading')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'planner', about => 'reading test');
  my $first = _post($id, 'sess-a', 'one about the migration')->{message}{id};
  _post($id, 'sess-a', 'two');
  my $third = _post($id, 'sess-a', 'three, also migration')->{message}{id};

  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)
    ->json_is('/count' => 4)->json_is('/cursor' => $third)->json_is('/missed' => Mojo::JSON->false)
    ->json_is('/room/id' => $id)
    ->json_is('/messages/0/type' => 'member.joined')
    ->json_is('/messages/3/body' => 'three, also migration');

  # Oldest first, always: that is the order a transcript is read in.
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$first")->status_is(200)
    ->json_is('/count' => 2)->json_is('/messages/0/body' => 'two')
    ->json_is('/cursor' => $third);

  # Nothing new is an empty answer that still moves nothing.
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$third")->status_is(200)
    ->json_is('/count' => 0)->json_is('/cursor' => $third);

  # Watching a busy room brings the tail, not the history.
  $t->get_ok("/api/v1/chatrooms/$id/messages?limit=2")->status_is(200)
    ->json_is('/count' => 2)->json_is('/messages/1/body' => 'three, also migration');

  # grep: a substring, case-insensitively, oldest first.
  $t->get_ok("/api/v1/chatrooms/$id/messages?q=MIGRATION")->status_is(200)
    ->json_is('/count' => 2)->json_is('/messages/0/id' => $first);
  $t->get_ok("/api/v1/chatrooms/$id/messages?q=nothing-said-that")->status_is(200)
    ->json_is('/count' => 0);

  # A pattern is not a regular expression here, and must not behave like one.
  $t->get_ok("/api/v1/chatrooms/$id/messages?q=.*")->status_is(200)->json_is('/count' => 0);
};

subtest 'a room keeps only so much, and says when a reader missed some' => sub {
  my $id   = _room(topic => 'pruning')->{room}{id};
  my $chat = $t->app->chat;
  _join($id, session_id => 'sess-a', name => 'planner', about => 'pruning test');

  my $was = $chat->max_messages;
  $chat->max_messages(3);
  my $early = _post($id, 'sess-a', 'the first thing')->{message}{id};
  _post($id, 'sess-a', "message $_") for 1 .. 4;

  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)->json_is('/count' => 3)
    ->json_is('/messages/2/body' => 'message 4');

  # A caller polling from a message that has since been dropped is TOLD, rather
  # than handed a shorter conversation than it asked for and left to notice.
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$early")->status_is(200)
    ->json_is('/missed' => Mojo::JSON->true);
  $chat->max_messages($was);
};

# ------------------------------------------------------------ long polling ---

subtest 'a caller can wait for the next thing said instead of asking again' => sub {
  my $id = _room(topic => 'waiting')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'planner', about => 'waiting test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/messages")->tx->res->json->{cursor};

  # Posted from a timer, so the request really is parked while nothing has
  # happened yet and really is woken by the write.
  Mojo::IOLoop->timer(
    0.3 => sub { $t->app->chat->post($t->app->chat->find_room($id),
        session_id => 'sess-a', body => 'woke you') });

  my $started = time;
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=10")->status_is(200)
    ->json_is('/count' => 1)->json_is('/messages/0/body' => 'woke you');
  my $took = time - $started;
  ok $took < 5, "answered as soon as it was posted, not at the deadline (${took}s)";

  # With something already waiting, `wait` costs nothing at all.
  $t->get_ok("/api/v1/chatrooms/$id/messages?wait=10")->status_is(200)->json_is('/count' => 2);

  # And a wait that expires is an ordinary empty answer with the cursor intact.
  my $latest = $t->tx->res->json->{cursor};
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$latest&wait=1")->status_is(200)
    ->json_is('/count' => 0)->json_is('/cursor' => $latest);

  # A search answers about what has been said, so it never waits.
  $t->get_ok("/api/v1/chatrooms/$id/messages?q=nothing&wait=30")->status_is(200)
    ->json_is('/count' => 0);
};

# ------------------------------------------------------------- the human -----

subtest 'a person is asked who they are before the room opens' => sub {
  my $id = _room(topic => 'the human', purpose => 'a person and an agent')->{room}{id};
  _join($id, session_id => 'agent-1', name => 'planner', about => 'holding the checklist');
  $t->app->chat->post($t->app->chat->find_room($id),
    session_id => 'agent-1', body => "# Plan\n\n<script>alert(1)</script>");

  my %html = (Accept => 'text/html');
  $t->get_ok("/c/$id" => \%html)->status_is(200)
    ->content_like(qr/the human/)
    ->content_like(qr/<label for="join-name">/)
    # The roster is shown before joining: who is already in there is exactly
    # what someone deciding whether to join wants to know.
    ->content_like(qr/roster-name">planner/)
    ->content_like(qr/holding the checklist/)
    # Nothing said in the room is on this page. A name first.
    ->content_unlike(qr/Plan/)
    ->header_like('Content-Security-Policy' => qr/default-src 'none'/)
    ->header_is('X-Robots-Tag' => 'noindex, nofollow, noarchive');

  # A name is required, and the paragraph is not: a person who has opened the
  # page is already visibly present.
  $t->post_ok("/c/$id/join" => form => {name => '', about => ''})->status_is(400)
    ->content_like(qr/pick a name/);
  $t->post_ok("/c/$id/join" => form => {name => 'planner'})->status_is(400)
    ->content_like(qr/is taken in this room/);

  $t->post_ok("/c/$id/join" => form => {name => 'Pedro', about => 'deciding on the tag'})
    ->status_is(302)->header_like(Location => qr{/c/$id\z});

  # The identity cookie is this browser's, signed, and holds a name and a
  # session id — there is no account behind it.
  my $cookie = $t->tx->res->cookie('share');
  ok $cookie, 'a session cookie was set';

  $t->get_ok("/c/$id" => \%html)->status_is(200)
    ->content_like(qr/<iframe class="transcript"/)
    ->content_like(qr/data-cursor="\d+"/)
    ->content_like(qr/data-me="human-[A-Za-z0-9]{12}"/)
    ->content_like(qr/You are <strong>Pedro/)
    ->content_like(qr/<form class="composer"/);

  # The messages are in the frame, not in the page holding the cookie.
  my $page = $t->tx->res->text;
  unlike $page, qr/alert\(1\)/, 'no message text reaches the chrome page';

  $t->get_ok("/c/$id/transcript" => \%html)->status_is(200)
    ->content_like(qr/<li class="msg msg-member-joined"/)
    ->content_like(qr/<li class="msg msg-message"/)
    ->content_like(qr{<h1>Plan</h1>})
    # Rendered by the same sanitiser that renders an uploaded file, and framed
    # by the same kind of sandbox. Neither is trusted alone.
    ->content_unlike(qr/<script>alert/)
    ->header_like('Content-Security-Policy' => qr/frame-ancestors https:/);

  # Posting with scripting off is a form post that lands back on the room.
  $t->post_ok("/c/$id/messages" => form => {body => 'from the browser'})->status_is(302);
  $t->get_ok("/c/$id/transcript" => \%html)->status_is(200)
    ->content_like(qr/from the browser/);

  # Searching is a GET aimed at the frame, so it works with scripting off too.
  $t->get_ok("/c/$id/transcript?q=browser" => \%html)->status_is(200)
    ->content_like(qr/Messages matching/)->content_like(qr/from the browser/)
    ->content_unlike(qr{<h1>Plan</h1>});

  # The markup the browser is handed for a message that arrives while the page
  # is open is the same template — one renderer, not two.
  $t->get_ok("/api/v1/chatrooms/$id/messages?html=1&limit=1")->status_is(200)
    ->json_like('/messages/0/markup' => qr/<li class="msg msg-/)
    ->json_like('/messages/0/markup' => qr/data-author=/);
  $t->get_ok("/api/v1/chatrooms/$id/messages?limit=1")->status_is(200);
  ok !exists $t->tx->res->json->{messages}[0]{markup},
    'and an agent asking for the same messages is not sent HTML it has no use for';
};

subtest 'somebody who has not joined sees the door, not the room' => sub {
  my $id = _room(topic => 'strangers')->{room}{id};

  # A fresh browser: no cookie for this room, whatever the last subtest left.
  $t->reset_session;
  $t->get_ok("/c/$id/transcript" => {Accept => 'text/html'})->status_is(302)
    ->header_like(Location => qr{/c/$id\z});
  $t->post_ok("/c/$id/messages" => form => {body => 'sneaking in'})->status_is(302);
  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)->json_is('/count' => 0);
};

# ---------------------------------------------------------------- limits -----

subtest 'a hammering caller is refused, and it does not cost an upload' => sub {
  # The chat bucket and the upload bucket are separate on purpose: a busy room
  # must not stop anybody sharing a file.
  my $cfg = $t->app->config;
  my @was = @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)};
  @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)} = (1, 1);
  $t->app->store->sql->db->query('DELETE FROM upload_hits');

  my $made = _room(topic => 'fast');
  $t->post_ok('/api/v1/chatrooms' => json => {topic => 'too fast'})->status_is(429)
    ->json_like('/error' => qr/too many requests/)->header_like('Retry-After' => qr/\A\d+\z/);

  # …while an upload is unaffected, because it is counted somewhere else.
  $t->post_ok('/api/v1/files?filename=alongside.md' => '# fine')->status_is(201);
  my $file = $t->tx->res->json;
  $t->delete_ok("/api/v1/files/$file->{id}" =>
      {'X-Delete-Password' => $file->{delete_password}})->status_is(200);

  @{$cfg}{qw(chat_rate_per_second chat_rate_per_minute)} = @was;
  $t->app->store->sql->db->query('DELETE FROM upload_hits');

  # A room that was made before the limit bit is still perfectly usable.
  ok _join($made->{room}{id}, session_id => 's', name => 'n', about => 'a')->{member},
    'and the room made before the limit still works';
};

subtest 'health counts rooms and messages only where it is turned on' => sub {
  $t->get_ok('/api/v1/health')->status_is(200)->json_is('/status' => 'ok')
    ->json_has('/files')->json_has('/rooms')->json_has('/messages');
  ok $t->tx->res->json->{rooms} > 0, 'and the rooms it is holding are counted';
};

# ------------------------------------------------------------------- MCP -----

subtest 'MCP: the room tools are there, and they are about coordination' => sub {
  my $res   = _mcp('tools/list');
  my %tools = map { $_->{name} => $_ } @{$res->{result}{tools}};
  ok $tools{$_}, "$_ is registered" for
    qw(create_chatroom join_chatroom post_chat_message get_chat_messages
    search_chat_messages delete_chatroom);

  like $tools{create_chatroom}{description}, qr/other sessions/, 'create says what it is for';
  like $tools{get_chat_messages}{description}, qr/HOLDS for up to/, 'and reading says it can wait';
  like $tools{post_chat_message}{description}, qr/No attachments/,
    'and posting says where a file goes';

  # The server-level instructions mention the rooms, because an agent reads
  # those before it has called anything.
  my $discover = _mcp('server/discover');
  like $discover->{result}{instructions}, qr/TALKING TO OTHER AGENTS/,
    'the instructions introduce the rooms';
};

subtest 'MCP: open a room, hand over the URL, and talk in it' => sub {
  my $made = _call('create_chatroom',
    {topic => 'release 1.4', purpose => 'two agents', session_id => 'sess-a'});
  my $info = $made->{structuredContent};
  my $url  = $info->{room}{url};

  like $url, qr{\Ahttps://share\.example\.test/c/[A-Za-z0-9]{32}\z}, 'a room URL to hand over';
  like $made->{content}[-1]{text}, qr/Give the human this URL:\s+\Q$url\E/,
    'said in words too, because handing it over is the whole action';
  like $info->{how_to}, qr/JOIN FIRST/, 'with the same briefing the REST side gives';

  # Every tool takes the URL as it was pasted, or just the id out of it.
  my $joined = _call('join_chatroom',
    {room => $url, session_id => 'sess-a', name => 'planner', about => 'the checklist'});
  is $joined->{structuredContent}{member}{name}, 'planner', 'joined by URL';

  my $id = $info->{room}{id};
  ok _call('join_chatroom',
    {room => $id, session_id => 'sess-b', name => 'builder', about => 'the container builds'})
    ->{structuredContent}{member}, 'and joined by bare id';

  my $said = _call('post_chat_message', {room => $url, session_id => 'sess-b',
    body => 'image is up'})->{structuredContent};
  is $said->{message}{name}, 'builder', 'posted';

  my $read = _call('get_chat_messages', {room => $url})->{structuredContent};
  is $read->{count}, 3, 'and read back — two arrivals and the message';
  is $read->{cursor}, $said->{message}{id}, 'with a cursor to carry on from';

  my $found = _call('search_chat_messages', {room => $url, q => 'IMAGE'})->{structuredContent};
  is $found->{count}, 1, 'grep finds it, case insensitively';

  is_deeply _call('search_chat_messages', {room => $url, q => 'nothing here'})->{content}[0]
    {text} =~ /matches/ ? 1 : 0, 1, 'and says so plainly when nothing matches';

  # An unknown room is an error the agent can read, not a crash.
  my $missing = _call('get_chat_messages', {room => 'nosuchroomnosuchroom12345678'});
  ok $missing->{isError}, 'an expired or closed room is an error result';
  like $missing->{content}[0]{text}, qr/no live chat room/, 'and says which';

  # Closing needs the password from create_chatroom.
  ok _call('delete_chatroom', {room => $url, delete_password => 'wrong'})->{isError},
    'a wrong password will not close a room';
  my $closed = _call('delete_chatroom',
    {room => $url, delete_password => $info->{delete_password}});
  ok !$closed->{isError}, 'the right one does';
  like $closed->{content}[0]{text}, qr/no longer works/, 'and says the URL is dead';

  $t->get_ok("/api/v1/chatrooms/$id")->status_is(404);
};

subtest 'MCP: reading can wait, and waiting does not block the worker' => sub {
  my $info = _call('create_chatroom', {topic => 'waiting over MCP'})->{structuredContent};
  my $url  = $info->{room}{url};
  my $id   = $info->{room}{id};
  _call('join_chatroom',
    {room => $url, session_id => 'sess-a', name => 'planner', about => 'waiting'});

  my $cursor = _call('get_chat_messages', {room => $url})->{structuredContent}{cursor};

  Mojo::IOLoop->timer(
    0.3 => sub { $t->app->chat->post($t->app->chat->find_room($id),
        session_id => 'sess-a', body => 'over here') });

  my $waited = _call('get_chat_messages', {room => $url, since => $cursor, wait => 10});
  is $waited->{structuredContent}{count}, 1, 'the tool answered when the message landed';
  is $waited->{structuredContent}{messages}[0]{body}, 'over here', 'with the message';

  # A wait that expires is an ordinary empty answer.
  my $latest = $waited->{structuredContent}{cursor};
  is _call('get_chat_messages', {room => $url, since => $latest, wait => 1})
    ->{structuredContent}{count}, 0, 'and an empty one when nothing was said';
};

# ---------------------------------------------------------------- expiry -----

subtest 'a room and everything in it goes when it expires' => sub {
  my $made = _room(topic => 'expiring');
  my $id   = $made->{room}{id};
  _join($id, session_id => 'sess-a', name => 'planner', about => 'about to expire');
  _post($id, 'sess-a', 'said before the end');

  my $chat = $t->app->chat;
  my $room = $chat->find_room($id);
  $chat->sql->db->query('UPDATE chat_rooms SET expires_at = ? WHERE id = ?',
    time - 1, $room->{id});

  # Expired but not yet reaped is gone as far as anybody asking is concerned —
  # the same rule a file follows.
  ok !$chat->find_room($id), 'the store will not hand back an expired room';
  $t->get_ok("/api/v1/chatrooms/$id")->status_is(404);

  my $reaped = $chat->reap;
  is $reaped->{rooms}, 1, 'the reaper takes the room';
  ok $reaped->{messages} >= 2, 'and every message in it';
  is $chat->sql->db->query('SELECT COUNT(*) FROM chat_members WHERE room_id = ?',
    $room->{id})->array->[0], 0, 'and the roster with them';
};

subtest 'closing a room early needs the password it was made with' => sub {
  my $made = _room(topic => 'closing');
  my $id   = $made->{room}{id};
  _join($id, session_id => 'sess-a', name => 'planner', about => 'closing');

  # A wrong password and a room that never existed get the same answer, so this
  # cannot be used to find out which ids exist.
  $t->delete_ok("/api/v1/chatrooms/$id" => {'X-Delete-Password' => 'nope'})->status_is(403)
    ->json_like('/error' => qr/no such room, or the wrong delete password/);
  $t->delete_ok('/api/v1/chatrooms/nosuchroomnosuchroom12345678' =>
      {'X-Delete-Password' => 'nope'})->status_is(403)
    ->json_like('/error' => qr/no such room, or the wrong delete password/);

  $t->delete_ok("/api/v1/chatrooms/$id" =>
      {'X-Delete-Password' => $made->{delete_password}})->status_is(200)
    ->json_is('/deleted' => $id);
  $t->get_ok("/api/v1/chatrooms/$id")->status_is(404);
};

# ------------------------------------------------------------ the sequence ---

subtest 'the sequence is events, and the old rows kept their meaning' => sub {
  my $id = _room(topic => 'migrating')->{room}{id};
  _join($id, session_id => 'sess-m', name => 'planner', about => 'schema test');
  _post($id, 'sess-m', 'hello');

  my $db = $t->app->chat->sql->db;

  ok $db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_events'})
    ->array, 'chat_events exists';
  ok !$db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_messages'})
    ->array, 'chat_messages is gone';

  my $room  = $t->app->chat->find_room($id);
  my $types = $db->query('SELECT type FROM chat_events WHERE room_id = ? ORDER BY id',
    $room->{id})->arrays->flatten->to_array;
  is_deeply $types, ['member.joined', 'message'], 'join became member.joined';

  # A member who has only arrived: posting is what moves a read cursor, and
  # sess-m has posted.
  _join($id, session_id => 'sess-m2', name => 'lurker', about => 'joined and said nothing');
  my $m = $db->query('SELECT * FROM chat_members WHERE session_id = ?', 'sess-m2')->hash;
  is $m->{read_cursor},   0, 'read_cursor starts at zero';
  is $m->{waiting_until}, 0, 'waiting_until starts at zero';
  is $m->{left_at},   undef, 'nobody has left';

  ok $db->query(q{SELECT 1 FROM sqlite_master WHERE type='table' AND name='chat_mentions'})
    ->array, 'chat_mentions exists';
};

subtest 'a park that ends in silence says so' => sub {
  my $id = _room(topic => 'patience')->{room}{id};
  _join($id, session_id => 'sess-w', name => 'watcher', about => 'wait test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/messages")->tx->res->json->{cursor};

  # Nothing happens, so the answer says why it is empty. A re-arming loop must
  # never have to infer this from count == 0 -- which is indistinguishable from
  # a filter that matched nothing.
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=1")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->true)
    ->json_is('/count' => 0)
    ->json_is('/cursor' => $cursor);

  Mojo::IOLoop->timer(0.2 => sub {
    $t->app->chat->post($t->app->chat->find_room($id), session_id => 'sess-w', body => 'oi') });
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=10")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->false)
    ->json_is('/count' => 1);

  # An immediate read never waited, so it did not time out either.
  $t->get_ok("/api/v1/chatrooms/$id/messages")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->false);
};

subtest 'both wait ceilings move together' => sub {
  # There are TWO, and they are independent: share.pl has its own constant and
  # lib/Share/MCP.pm clamps again on the way past. Changing one and shipping was
  # the bug this exists to prevent -- and it cannot be caught by posting into the
  # park, because a write at 0.3s returns quickly whichever ceiling applied.
  #
  # So the ceiling is driven DOWN instead, and the park is left to expire. If the
  # MCP tool is still clamping to its own hard-coded sixty, this takes a minute
  # rather than three seconds.
  is $t->app->config->{chat_max_wait}, 900, 'the HTTP ceiling is configuration now';

  local $t->app->config->{chat_max_wait} = 3;

  my $id = _room(topic => 'mcp patience')->{room}{id};
  _call(join_chatroom => {room => $id, session_id => 'sess-mw',
    name => 'mcpwatcher', about => 'ceiling test'});
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/messages")->tx->res->json->{cursor};

  my $started = time;
  my $out = _call(get_chat_messages =>
    {room => $id, session_id => 'sess-mw', since => $cursor, wait => 600})
    ->{structuredContent};
  my $took = time - $started;

  is $out->{count}, 0, 'nothing was said';
  is $out->{timed_out}, Mojo::JSON->true, 'and the park reports that it expired';
  ok $took < 20, "the tool honoured the configured ceiling, not its own (${took}s)";

  # The plain endpoint honours the same number.
  $started = time;
  $t->get_ok("/api/v1/chatrooms/$id/messages?since=$cursor&wait=600")->status_is(200)
    ->json_is('/timed_out' => Mojo::JSON->true);
  ok time - $started < 20, 'and so does the HTTP endpoint';
};

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

  # Every parameter works on both paths, including the ones that park.
  $t->get_ok("/api/v1/chatrooms/$id/events?q=first")->status_is(200)->json_is('/count' => 1);
  $t->get_ok("/api/v1/chatrooms/$id/events?since=" . $ev->{cursor} . "&wait=1")
    ->status_is(200)->json_is('/timed_out' => Mojo::JSON->true);

  # And a room that is not live answers the same way on both.
  $t->get_ok('/api/v1/chatrooms/nosuchroomnosuchroom12345678/events')->status_is(404);
};

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
  is $head->{bytes}, length("the first line\n\n$long"), 'and says how much it did not send';
  is $head->{name}, 'planner', 'the author is a header field, not a body field';
  is $head->{type}, 'message', 'and so is the kind of thing it was';

  # The whole point, in one number: headers are an order of magnitude smaller.
  my $full = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  ok length(Mojo::JSON::encode_json($got)) * 5 < length(Mojo::JSON::encode_json($full)),
    'and the answer really is much smaller than the bodies it stands for';

  # The body is one call away when it turns out to matter.
  $t->get_ok("/api/v1/chatrooms/$id/events/$ev")->status_is(200)
    ->json_is('/event/body' => "the first line\n\n$long")
    ->json_is('/event/type' => 'message');

  my $short = _post($id, 'sess-h', 'brief')->{message}{id};
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?format=headers&since=" . ($short - 1))
    ->tx->res->json;
  is $got->{events}[0]{truncated}, Mojo::JSON->false, 'nothing was cut';
  is $got->{events}[0]{preview}, 'brief', 'so the preview is the whole of it';

  # An event id that is not in this room is not readable through it.
  $t->get_ok("/api/v1/chatrooms/$id/events/999999")->status_is(404);
};

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

  # A watcher that reads with its OWN cursor acknowledges separately, and can
  # acknowledge only as far as it actually got. That is the whole reason the two
  # are different calls: a session that dies between reading and acting should
  # come back to the work it did not finish, not to the messages it merely
  # received.
  _post($id, 'sess-p', 'four');
  _post($id, 'sess-p', 'five');
  my $mine = $t->app->chat->read_cursor($t->app->chat->find_room($id), 'sess-r');
  my $back = $t->get_ok("/api/v1/chatrooms/$id/events?since=$mine&session_id=sess-r")
    ->tx->res->json;
  is $back->{count},  2, 'two more arrived';
  is $back->{unread}, 2, 'and an explicit read did not silently mark them read';

  $t->post_ok("/api/v1/chatrooms/$id/members/sess-r/read" => json =>
      {cursor => $back->{events}[0]{id}})->status_is(200)->json_is('/unread' => 1);

  # A cursor never goes backwards: two reads can overlap, and the later one
  # landing first must not un-read what the earlier one already delivered.
  $t->post_ok("/api/v1/chatrooms/$id/members/sess-r/read" => json => {cursor => 1})
    ->status_is(200)->json_is('/unread' => 1);

  # Somebody who never joined has read nothing, so `unread` means the room. It is
  # not an error and it is not a leak: they could have asked for since=0 anyway,
  # and the URL is the read credential either way.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=nobody")
    ->status_is(200)->json_is('/count' => 7)->json_is('/unread' => 0);
};

subtest 'a park can start from where you left off' => sub {
  my $id = _room(topic => 'parked unread')->{room}{id};
  _join($id, session_id => 'sess-u', name => 'watcher', about => 'unread park');
  # Catch up so the park below genuinely has nothing waiting for it.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-u");

  Mojo::IOLoop->timer(0.3 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-u', body => 'arrived while parked') });

  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-u&wait=10")
    ->status_is(200)->json_is('/count' => 1)
    ->json_is('/events/0/body' => 'arrived while parked');

  # And the park advanced the stored cursor too, so re-arming is not a re-read.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-u")
    ->status_is(200)->json_is('/count' => 0);
};

subtest 'the moment you post is the moment you are provably listening' => sub {
  my $id = _room(topic => 'crossing')->{room}{id};
  _join($id, session_id => 'sess-x', name => 'talker', about => 'gap test');
  _join($id, session_id => 'sess-y', name => 'other',  about => 'gap test');

  # Catch up, so the gap below is unambiguous.
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-x");

  # Two things are said while sess-x is not looking. This is the exact failure
  # from the field: a cursor that went 11 -> 15 -> 21 and never said why.
  _post($id, 'sess-y', 'you missed this');
  _post($id, 'sess-y', 'and this');

  my $res = _post($id, 'sess-x', 'saying my piece');
  is $res->{unread}, 2, 'the acknowledgement says how far behind you were';
  is scalar @{$res->{missed}}, 2, 'and hands the gap over';
  is $res->{missed}[0]{preview}, 'you missed this', 'as headers, not as bodies';
  ok !exists $res->{missed}[0]{body}, 'because the whole point was to be cheap';
  ok !grep({ $_->{id} == $res->{message}{id} } @{$res->{missed}}),
    'and never the message just posted, which is in the answer already';

  # Posting caught you up, so the next one has nothing to report.
  my $next = _post($id, 'sess-x', 'again');
  is $next->{unread}, 0, 'posting marks you current';
  is_deeply $next->{missed}, [], 'so there is nothing to hand back';
};

subtest 'a mention is data, and an at-sign was decoration' => sub {
  my $id = _room(topic => 'mentions')->{room}{id};
  _join($id, session_id => 'sess-1', name => 'planner',  about => 'mention test');
  _join($id, session_id => 'sess-2', name => 'DRAC-E1',  about => 'mention test');
  _join($id, session_id => 'sess-d', name => 'drac',     about => 'the shorter name');
  _human($id, 'sess-3', 'melo');

  _post($id, 'sess-1', 'nothing for anybody here');
  my $direct = _post($id, 'sess-1', 'can @DRAC-E1 confirm the compose file?');

  my $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($direct->{message}{id} - 1))
    ->tx->res->json;
  is_deeply $got->{events}[0]{mentions}, ['DRAC-E1'], 'the mention is a field, not prose';

  # "@drac" must not be found inside "@DRAC-E1". A hyphen is a word character as
  # far as a name is concerned, and treating it as a boundary addresses the
  # wrong agent -- quietly, and in a room where that is the whole point.
  ok !grep({ $_ eq 'drac' } @{$got->{events}[0]{mentions}}), 'and it is the whole name';

  # Case-insensitive, because nobody types a name back exactly.
  _post($id, 'sess-1', 'and @drac-e1 again');

  my $noise = _post($id, 'sess-1', 'ping @nobody-here');
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($noise->{message}{id} - 1))
    ->tx->res->json;
  is_deeply $got->{events}[0]{mentions}, [], 'an at-sign that matches nobody is just an at-sign';

  # "Has anyone addressed me?" is one call.
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-2&since=0")
    ->status_is(200)->tx->res->json;
  is $got->{count}, 2, 'both, and none of the others';

  # A rename does not orphan what was already addressed to you: the row binds to
  # the member, and the name is looked up when it is asked for.
  _join($id, session_id => 'sess-2', name => 'E1', about => 'renamed mid-run');
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-2&since=0")
    ->tx->res->json;
  is $got->{count}, 2, 'still both';
  is_deeply $got->{events}[0]{mentions}, ['E1'], 'under the name they go by now';

  # Headers carry them too, which is the combination a watcher actually uses.
  $got = $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-2"
      . "&since=0&format=headers")->tx->res->json;
  is_deeply $got->{events}[0]{mentions}, ['E1'], 'in headers as well as in full';
};

subtest 'one message can reach the whole fleet, and no human' => sub {
  my $id = _room(topic => 'broadcast')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'alpha', about => 'fleet test');
  _join($id, session_id => 'sess-b', name => 'bravo', about => 'fleet test');
  _human($id, 'sess-h', 'melo');

  my $all = _post($id, 'sess-h', '@agents stop what you are doing and read BOB-6');
  my $got = $t->get_ok("/api/v1/chatrooms/$id/events?since=" . ($all->{message}{id} - 1))
    ->tx->res->json;
  is_deeply [sort @{$got->{events}[0]{mentions}}], ['alpha', 'bravo'],
    'every agent in the room';

  # Not the person who sent it, and not any other person. Steering the fleet
  # should not ping the people who are reading anyway -- that is the difference
  # between a broadcast and a megaphone.
  $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-h&since=0")
    ->json_is('/count' => 0);
  $t->get_ok("/api/v1/chatrooms/$id/events?mentions_me=1&session_id=sess-a&since=0")
    ->json_is('/count' => 1);
};

subtest 'a park on being wanted is not woken by ordinary chatter' => sub {
  my $id = _room(topic => 'selective')->{room}{id};
  _join($id, session_id => 'sess-a', name => 'alpha', about => 'park test');
  _join($id, session_id => 'sess-b', name => 'bravo', about => 'park test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  # Chatter first, then the thing that actually concerns bravo. If the filter is
  # applied to the read but not to the PARK, the first post ends the wait and
  # this comes back with the wrong message -- which is the difference between a
  # watcher an agent leaves running and one it turns off.
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

subtest 'leaving is a call, and the roster stops lying about it' => sub {
  my $id = _room(topic => 'presence')->{room}{id};
  _join($id, session_id => 'sess-s', name => 'stayer', about => 'presence test');
  _join($id, session_id => 'sess-g', name => 'goer',   about => 'presence test');
  _post($id, 'sess-g', 'something worth keeping');

  $t->delete_ok("/api/v1/chatrooms/$id/members/sess-g")->status_is(200)
    ->json_is('/left' => 'goer');

  my $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  my ($gone) = grep { $_->{name} eq 'goer' } @{$room->{members}};
  is $gone->{presence}, 'gone', 'the roster says so instead of leaving everyone to guess';
  is $gone->{online}, Mojo::JSON->false, 'and is plainly not here';

  # The departure is an event, so a parked watcher learns about it.
  my $ev = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  is $ev->{events}[-1]{type}, 'member.left', 'and it is in the sequence like everything else';

  # Their words stay. The author's name is denormalised onto every row precisely
  # so a transcript reads the way it read at the time.
  ok scalar(grep { ($_->{body} // '') eq 'something worth keeping' } @{$ev->{events}}),
    'what they said outlives them';

  # Leaving twice is not two events.
  my $before = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{count};
  $t->delete_ok("/api/v1/chatrooms/$id/members/sess-g")->status_is(200);
  is $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{count}, $before,
    'saying goodbye twice is still one goodbye';

  # Coming back clears it rather than making a second member.
  _join($id, session_id => 'sess-g', name => 'goer', about => 'back again');
  $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  ($gone) = grep { $_->{name} eq 'goer' } @{$room->{members}};
  isnt $gone->{presence}, 'gone', 'rejoining is not resurrection, it is just being here';
  is scalar @{$room->{members}}, 2, 'and it is still two people';

  # Somebody who was never here cannot leave.
  $t->delete_ok("/api/v1/chatrooms/$id/members/never-here")->status_is(404);
};

subtest 'holding a poll is what says you are listening' => sub {
  my $id = _room(topic => 'listening')->{room}{id};
  _join($id, session_id => 'sess-l', name => 'listener', about => 'poll presence');

  # Parked, with nothing to find, so the park is genuinely open while the roster
  # is read from underneath it.
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};
  my $seen;
  Mojo::IOLoop->timer(0.4 => sub {
    my $room = $t->app->chat->find_room($id);
    my ($me) = grep { $_->{session_id} eq 'sess-l' } @{$t->app->chat->members($room)};
    $seen = $t->app->chat->presence($me);
  });

  $t->get_ok("/api/v1/chatrooms/$id/events?since=$cursor&wait=2&session_id=sess-l")
    ->status_is(200);
  is $seen, 'listening', 'an open poll is the presence signal, with nobody saying anything';

  # And letting go of it stops the claim, rather than leaving it standing until
  # a deadline that can now be fifteen minutes away.
  my $room = $t->app->chat->find_room($id);
  my ($me) = grep { $_->{session_id} eq 'sess-l' } @{$t->app->chat->members($room)};
  is $t->app->chat->presence($me), 'idle', 'and the claim ends when the poll does';
};

subtest 'a roster comes with a read only when it is asked for' => sub {
  my $id = _room(topic => 'roster on reads')->{room}{id};
  _join($id, session_id => 'sess-o', name => 'planner', about => 'roster test');

  my $bare = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  ok !exists $bare->{members}, 'off by default, because headers exist to be cheap';

  my $with = $t->get_ok("/api/v1/chatrooms/$id/events?roster=1")->tx->res->json;
  is $with->{members}[0]{name}, 'planner', 'and on request it is the roster you know';
  is $with->{members}[0]{presence}, 'idle', 'with presence on it';
  ok exists $with->{members}[0]{read_cursor},
    'and how far they have read, which is what tells you to stop waiting on them';
};

subtest 'a room warns while it is still standing' => sub {
  my $id = _room(topic => 'closing time', ttl_days => 0.05)->{room}{id};
  _join($id, session_id => 'sess-c', name => 'planner', about => 'expiry test');

  is $t->app->chat->warn_expiring, 1, 'a room inside the warning window gets one';

  my $ev = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  is $ev->{events}[-1]{type}, 'room.expiring', 'and it is an ordinary event';
  is $ev->{events}[-1]{name}, 'system', 'written by nobody in particular';
  is $ev->{events}[-1]{session_id}, undef, 'because no member did it';
  like $ev->{events}[-1]{body}, qr/deleted/, 'saying what is about to happen';

  # Once, however many times the reaper passes over it.
  is $t->app->chat->warn_expiring, 0, 'and never twice';

  # A room with a fortnight left is not warned about anything.
  my $far = _room(topic => 'plenty of time')->{room}{id};
  is $t->app->chat->warn_expiring, 0, 'nor is one that is nowhere near going';
};

subtest 'a parked reader is told the room is over, not left hanging' => sub {
  my $made = _room(topic => 'doomed');
  my $id   = $made->{room}{id};
  my $pw   = $made->{delete_password};
  _join($id, session_id => 'sess-d', name => 'planner', about => 'destruction test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  # The room is destroyed while somebody is parked on it. Before this, the poll
  # went on asking a room that no longer existed and settled empty AT THE
  # DEADLINE -- which at sixty seconds was invisible and at fifteen minutes is a
  # held connection doing nothing for a quarter of an hour.
  Mojo::IOLoop->timer(0.3 => sub { $t->app->chat->remove_room($id, $pw) });

  my $started = time;
  $t->get_ok("/api/v1/chatrooms/$id/events?since=$cursor&wait=10")->status_is(200)
    ->json_is('/closed' => Mojo::JSON->true)
    ->json_is('/count' => 1)
    ->json_is('/events/0/type' => 'room.destroyed')
    ->json_is('/events/0/name' => 'system')
    ->json_is('/events/0/why'  => 'closed');
  my $took = time - $started;
  ok $took < 5, "released when it happened, not at the deadline (${took}s)";

  # A cold read of a room that is not live is still a 404: we genuinely cannot
  # tell "destroyed an hour ago" from "never existed" -- find_room returns undef
  # for both -- and claiming 410 Gone would be inventing knowledge.
  $t->get_ok("/api/v1/chatrooms/$id/events")->status_is(404);
};

subtest 'an expiry releases a parked reader too' => sub {
  my $id = _room(topic => 'about to lapse', ttl_days => 0.042)->{room}{id};
  _join($id, session_id => 'sess-l', name => 'planner', about => 'lapse test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  # Wound forward past its expiry. find_room treats an expired room as absent
  # from that moment, an hour or so before the reaper physically deletes it, so a
  # waiter is released at the true expiry and not at the next reaper pass.
  Mojo::IOLoop->timer(0.3 => sub {
    $t->app->chat->sql->db->query('UPDATE chat_rooms SET expires_at = ? WHERE secret = ?',
      time - 1, $id) });

  $t->get_ok("/api/v1/chatrooms/$id/events?since=$cursor&wait=10")->status_is(200)
    ->json_is('/closed' => Mojo::JSON->true)
    ->json_is('/events/0/why' => 'expired');
};

subtest 'a member gets a credential, once, and the wall stops handing it out' => sub {
  my $id  = _room(topic => 'identity')->{room}{id};
  my $me  = _join($id, session_id => 'sess-t', name => 'planner', about => 'token test');
  my $tok = $me->{member_token};
  ok length($tok // ''), 'join hands one over';

  # The only disclosure, on the same terms as a room's delete password.
  my $again = _join($id, session_id => 'sess-t', name => 'planner', about => 'token test');
  ok !length($again->{member_token} // ''), 'and never again';

  my $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  ok !grep({ length($_->{member_token} // '') } @{$room->{members}}),
    'the roster never carries it';

  my $r = $t->app->chat->find_room($id);
  ok $t->app->chat->token_ok($r, 'sess-t', $tok),  'the right token checks out';
  ok !$t->app->chat->token_ok($r, 'sess-t', 'no'), 'and a wrong one does not';
  ok !$t->app->chat->token_ok($r, 'nobody', $tok), 'and it is not a skeleton key';

  # A session id was a claim, not a credential, and it was printed on the wall
  # for anyone reading the room to copy.
  _post($id, 'sess-t', 'something');
  my $markup = $t->get_ok("/api/v1/chatrooms/$id/messages?html=1")->status_is(200)
    ->tx->res->json->{messages}[-1]{markup};
  like $markup, qr/planner/, 'the transcript names the author';
  unlike $markup, qr/sess-t/, 'and no longer prints the string that authenticates them';
};

subtest 'writing can be made to require the token' => sub {
  my $id  = _room(topic => 'guarded')->{room}{id};
  my $tok = _join($id, session_id => 'sess-q', name => 'planner', about => 'guard test')
    ->{member_token};

  # Off by default for one release, so nothing written last week breaks today.
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'no token, and that is fine for now'})
    ->status_is(201);

  # Both, because the flag is read once at startup into Share::Chat -- the guard
  # belongs to the model rather than to a route, so changing the app's config on
  # a running instance is no longer enough. In production this is a restart,
  # which setting it in a compose file requires anyway.
  local $t->app->config->{chat_require_token} = 1;
  local $t->app->chat->{require_token} = 1;

  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'no token'})->status_is(403)
    ->json_like('/error' => qr/member_token/);
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'wrong token', member_token => 'nope'})->status_is(403);
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-q', body => 'with token', member_token => $tok})->status_is(201);

  # Reading is not affected: the URL is still the read credential, which is what
  # a room URL has always meant.
  $t->get_ok("/api/v1/chatrooms/$id/events")->status_is(200);
};

subtest 'MCP: the tools an agent needs to be a listener that costs nothing' => sub {
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
  like $have{join_chatroom}{description}, qr/rename/i,
    'joining says that calling it again renames you, which it always did silently';
};

subtest 'MCP: park, be woken by a mention, then leave' => sub {
  my $id = _room(topic => 'mcp watcher')->{room}{id};
  my $joined = _call(join_chatroom => {room => $id, session_id => 'sess-mcp',
    name => 'watcher', about => 'mcp test'})->{structuredContent};
  ok length($joined->{member_token} // ''), 'join issues a token';

  _join($id, session_id => 'sess-mate', name => 'mate', about => 'the other one');

  Mojo::IOLoop->timer(0.2 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-mate', body => 'ignore me') });
  Mojo::IOLoop->timer(0.6 => sub {
    $t->app->chat->post($t->app->chat->find_room($id),
      session_id => 'sess-mate', body => 'yours @watcher') });

  my $out = _call(get_room_events => {room => $id, session_id => 'sess-mcp',
    since => 'unread', wait => 10, mentions_me => 1, format => 'headers'})
    ->{structuredContent};
  is $out->{count}, 1, 'woken once, by the one that concerned it';
  like $out->{events}[0]{preview}, qr/yours/, 'and handed a header, not an essay';
  ok !exists $out->{events}[0]{body}, 'which is the whole point';

  my $one = _call(fetch_chat_event => {room => $id, id => $out->{events}[0]{id}})
    ->{structuredContent};
  is $one->{event}{body}, 'yours @watcher', 'and the body when it turns out to matter';

  my $left = _call(leave_chatroom => {room => $id, session_id => 'sess-mcp'});
  ok !$left->{isError}, 'leaving is a call now';

  my $room = $t->get_ok("/api/v1/chatrooms/$id")->tx->res->json->{room};
  my ($gone) = grep { $_->{name} eq 'watcher' } @{$room->{members}};
  is $gone->{presence}, 'gone', 'and the roster believes it';
};

subtest 'the URL still explains the whole of how to take part' => sub {
  my $id  = _room(topic => 'briefing')->{room}{id};
  my $how = $t->get_ok("/c/$id" => {Accept => 'application/json'})->status_is(200)
    ->tx->res->json->{how_to};

  like $how, qr{/events},        'the sequence is named';
  like $how, qr/wait=900/,       'and how long you may park on it';
  like $how, qr/timed_out/,      'and how to tell a quiet room from a busy one';
  like $how, qr/since=unread/,   'and that the server keeps your place';
  like $how, qr/format=headers/, 'and that a cheap read exists';
  like $how, qr/\@agents/,       'and how to reach the whole fleet';
  like $how, qr/mentions_me/,    'and how to be woken only when wanted';
  like $how, qr/markdown/i,      'and what the person on the other end sees';
  like $how, qr/mermaid/i,       'and what they do not';
  like $how, qr/member_token/,   'and the credential it just handed out';
  # BOB-3's closing note: the room carried key fingerprints and host names, and
  # the URL that opens it is a bearer token being pasted between sessions.
  like $how, qr/bearer|anyone who holds/i, 'and that the URL is the secret';

  # An agent that arrived through a tool reads the same text as one that curled
  # the URL -- that is the whole reason there is one briefing and not three.
  my $viatool = _call(create_chatroom => {topic => 'same words'})->{structuredContent};
  is $viatool->{how_to}, $t->get_ok('/c/' . $viatool->{room}{id} => {Accept => 'application/json'})
    ->tx->res->json->{how_to}, 'and both doors hand over the same words';
};

subtest 'the MCP instructions answer what nobody could find out by trying' => sub {
  my $text = _mcp('server/discover')->{result}{instructions} // '';

  like $text, qr/markdown/i, 'markdown is rendered, which no description said';
  like $text, qr/mermaid/i,  'and mermaid is not, which none of them said either';
  like $text, qr/16 ?KB|16384|16 kilobytes/i, 'and how long a message may be';
  like $text, qr/\@agents/,  'and how one message reaches the fleet';
};

# ------------------------------------------------- upgrading a live room -----

# Everything above runs migration 1 and migration 2 together, against a database
# that never held a v1 row. That proves the schema is reachable; it does NOT
# prove that a room which has been running for a fortnight survives the upgrade,
# which is the case that actually matters -- there are rooms out there with
# history in them, and the whole point of migrating rather than starting over is
# that the history is the valuable part.
#
# So: build a real v1 database, with v1 rows in it, and open it with today's
# code. A plain Share::Chat over its own SQLite file, which is not the app
# singleton and so needs no second Test::Mojo.
subtest 'a room that has been running for a fortnight survives the upgrade' => sub {
  my $file = "$tmp/legacy.db";
  my $sql  = Mojo::SQLite->new("sqlite:$file");
  my $db   = $sql->db;

  $db->query($_) for split /;\s*\n/, <<'V1';
CREATE TABLE chat_rooms (
  id INTEGER PRIMARY KEY, secret TEXT NOT NULL UNIQUE, topic TEXT NOT NULL,
  purpose TEXT, created_by TEXT, created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL, pruned_to INTEGER NOT NULL DEFAULT 0,
  delete_salt TEXT, delete_hash TEXT
);
CREATE TABLE chat_members (
  id INTEGER PRIMARY KEY, room_id INTEGER NOT NULL, session_id TEXT NOT NULL,
  name TEXT NOT NULL, name_key TEXT NOT NULL, about TEXT, kind TEXT NOT NULL,
  joined_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL
);
CREATE TABLE chat_messages (
  id INTEGER PRIMARY KEY, room_id INTEGER NOT NULL, session_id TEXT NOT NULL,
  name TEXT NOT NULL, kind TEXT NOT NULL, body TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX chat_messages_room_idx ON chat_messages (room_id, id);
CREATE TABLE mojo_migrations (name TEXT PRIMARY KEY, version INTEGER NOT NULL)
V1

  # Where migration 1 left off, so init() runs migration 2 and only that.
  $db->query(q{INSERT INTO mojo_migrations VALUES ('share_chat', 1)});

  my $now = time;
  $db->query('INSERT INTO chat_rooms (id, secret, topic, created_at, expires_at) '
      . 'VALUES (1, ?, ?, ?, ?)', 'a' x 32, 'the Drac coordination run', $now - 86400,
    $now + 86400);
  $db->query('INSERT INTO chat_members (id, room_id, session_id, name, name_key, about, '
      . 'kind, joined_at, last_seen_at) VALUES (?,?,?,?,?,?,?,?,?)', @$_)
    for ([1, 1, 'sess-drac', 'claude-drac', 'claude-drac', 'the deploy system', 'agent',
        $now - 86400, $now - 3600],
      [2, 1, 'sess-e1', 'DRAC-E1', 'drac-e1', 'the monorepo', 'agent', $now - 86000, $now - 90],
      [3, 1, 'sess-melo', 'melo', 'melo', undef, 'human', $now - 85000, $now - 60]);

  # v1 vocabulary, including the empty-bodied join a human's arrival produces.
  $db->query('INSERT INTO chat_messages (id, room_id, session_id, name, kind, body, '
      . 'created_at) VALUES (?,?,?,?,?,?,?)', @$_)
    for ([10, 1, 'sess-drac', 'claude-drac', 'join', 'the deploy system', $now - 86400],
      [11, 1, 'sess-e1', 'DRAC-E1', 'join', 'the monorepo', $now - 86000],
      [12, 1, 'sess-melo', 'melo', 'join', '', $now - 85000],
      [13, 1, 'sess-drac', 'claude-drac', 'message',
        'compose dir, compose file, service name? @DRAC-E1', $now - 84000],
      [14, 1, 'sess-e1', 'DRAC-E1', 'system', 'DRAC-E1 is now **E1**', $now - 83000],
      [15, 1, 'sess-melo', 'melo', 'message', 'is everyone still alive?', $now - 3600]);

  my $chat = Share::Chat->new(sql => $sql, log => $t->app->log)->init;
  my $room = $chat->find_room('a' x 32);
  ok $room, 'the room is still there';
  is $room->{topic}, 'the Drac coordination run', 'under the name it had';

  my $events = $chat->messages($room);
  is scalar @$events, 6, 'with every message it ever held';

  # The ids are the cursors agents are carrying RIGHT NOW. Renumbering them would
  # silently rewind or skip every watcher in every live room.
  is_deeply [map { $_->{id} } @$events], [10, 11, 12, 13, 14, 15],
    'and the same ids, because those are cursors somebody is holding';

  is_deeply [map { $_->{type} } @$events],
    [qw(member.joined member.joined member.joined message member.renamed message)],
    'in the new vocabulary';
  is $events->[3]{body}, 'compose dir, compose file, service name? @DRAC-E1',
    'and the words are untouched';

  # Backfilled, so history answers the new questions too. An agent upgrading into
  # a running room can ask "what was ever addressed to me?" and get the truth
  # rather than an empty list that looks like the same thing.
  my $mentions = $chat->mentions_for($room, [map { $_->{id} } @$events]);
  is_deeply $mentions->{13}, ['DRAC-E1'], 'mentions in old messages are found';

  my $me = $chat->member($room, 'sess-e1');
  is_deeply $chat->messages($room, mentions_me => $me->{id}), [$events->[3]],
    'and are filterable, the same as a new one';

  # Seeded from what each member last said, which is the one thing the old schema
  # recorded about where they had got to. Starting everyone at zero would hand
  # every upgraded session the whole room as "unread".
  is $chat->read_cursor($room, 'sess-drac'), 13, 'a read cursor is seeded from your last post';
  is $chat->read_cursor($room, 'sess-melo'), 15, 'for everyone who ever said anything';
  is $chat->unread_count($room, 'sess-drac'), 2, 'so only what came after is unread';

  # Presence works off columns that did not exist an hour ago.
  is $chat->presence($chat->member($room, 'sess-melo')), 'idle', 'somebody seen a minute ago';
  is $chat->presence($chat->member($room, 'sess-drac')), 'away', 'and somebody seen an hour ago';

  # Nobody has a write credential yet, and rejoining is what issues one -- which
  # is what every agent does when it reconnects.
  ok !$chat->token_ok($room, 'sess-e1', 'anything'), 'no token survives the upgrade';
  my (undef, undef, $token) = $chat->join_room($room,
    session_id => 'sess-e1', name => 'E1', about => 'the monorepo', kind => 'agent');
  ok length($token // ''), 'and rejoining issues one to a member who has none';
  ok $chat->token_ok($room, 'sess-e1', $token), 'which then works';

  # Idempotent: init runs on every startup and must not backfill twice.
  Share::Chat->new(sql => $sql, log => $t->app->log)->init;
  is_deeply $chat->mentions_for($room, [13])->{13}, ['E1'],
    'a second startup does not double the backfill';
};

subtest 'a deleted room takes its mentions with it' => sub {
  # Found on a live instance, and it could not have been found on a fresh one.
  #
  # _purge_room deleted the events, the members and the room, and left the
  # mention rows behind. Orphans would be harmless if ids were never reused --
  # but chat_events.id and chat_members.id are plain INTEGER PRIMARY KEYs, so
  # SQLite hands the freed rowids straight back out. An orphan pairing a dead
  # event with a dead member then silently becomes a live event flagged as
  # addressed to a live member who was never addressed at all.
  #
  # Which is the worst shape this bug could take: mentions_me exists so an agent
  # can trust "someone needs me", and this made it lie.
  my $made = _room(topic => 'mentions outlive their room');
  my $id   = $made->{room}{id};
  _join($id, session_id => 'sess-a', name => 'alpha', about => 'purge test');
  _join($id, session_id => 'sess-b', name => 'bravo', about => 'purge test');
  _post($id, 'sess-a', 'over to you @bravo');

  my $db  = $t->app->chat->sql->db;
  my $rid = $t->app->chat->find_room($id)->{id};
  is $db->query('SELECT COUNT(*) FROM chat_mentions WHERE room_id = ?', $rid)->array->[0], 1,
    'the mention was recorded';

  $t->delete_ok("/api/v1/chatrooms/$id" => {'X-Delete-Password' => $made->{delete_password}})
    ->status_is(200);
  is $db->query('SELECT COUNT(*) FROM chat_mentions WHERE room_id = ?', $rid)->array->[0], 0,
    'and went with the room';

  # The same hole, reached the other way: a room that expires is purged by the
  # reaper through the same path.
  my $short = _room(topic => 'expiring with mentions', ttl_days => 0.042)->{room}{id};
  _join($short, session_id => 'sess-c', name => 'charlie', about => 'reap test');
  _join($short, session_id => 'sess-d', name => 'delta',   about => 'reap test');
  _post($short, 'sess-c', 'yours @delta');
  my $srid = $t->app->chat->find_room($short)->{id};
  is $db->query('SELECT COUNT(*) FROM chat_mentions WHERE room_id = ?', $srid)->array->[0], 1,
    'recorded there too';

  $t->app->chat->reap(time + 86400);
  is $db->query('SELECT COUNT(*) FROM chat_mentions WHERE room_id = ?', $srid)->array->[0], 0,
    'and the reaper takes them as well';
};

subtest 'being addressed in one room is not being addressed in another' => sub {
  # Belt as well as braces. Even with the purge fixed, a filter that asks only
  # "is there a row for this member?" trusts every id in the table to be the id
  # it thinks it is. Scoping it to the room costs one clause and makes an
  # orphan -- from any source, including one this code has not thought of --
  # unable to reach anybody.
  my $id = _room(topic => 'scoped')->{room}{id};
  _join($id, session_id => 'sess-x', name => 'xray', about => 'scope test');
  _post($id, 'sess-x', 'nothing addressed to anyone');

  my $chat = $t->app->chat;
  my $room = $chat->find_room($id);
  my $me   = $chat->member($room, 'sess-x');
  my $ev   = $chat->messages($room)->[-1];

  # Exactly the shape rowid reuse produces: real event, real member, wrong room.
  $chat->sql->db->query(
    'INSERT INTO chat_mentions (event_id, member_id, room_id) VALUES (?,?,?)',
    $ev->{id}, $me->{id}, $room->{id} + 9999);

  is scalar @{$chat->messages($room, mentions_me => $me->{id})}, 0,
    'a mention row belonging to another room reaches nobody';
};

subtest 'the sweep repairs a database that already ran 1.5.0' => sub {
  # An instance that ran 1.5.0 has orphans in it already, and they do not repair
  # themselves -- they wait for a rowid to be reused. So the fix has to reach
  # backwards, once, rather than only stopping new ones being made.
  my $file = "$tmp/orphans.db";
  my $sql  = Mojo::SQLite->new("sqlite:$file");
  Share::Chat->new(sql => $sql, log => $t->app->log)->init;

  my $db = $sql->db;
  $db->query('INSERT INTO chat_rooms (id, secret, topic, created_at, expires_at) '
      . 'VALUES (1, ?, ?, ?, ?)', 'b' x 32, 'still here', time, time + 86400);
  $db->query('INSERT INTO chat_members (id, room_id, session_id, name, name_key, kind, '
      . 'joined_at, last_seen_at) VALUES (1,1,?,?,?,?,?,?)',
    'sess-1', 'alpha', 'alpha', 'agent', time, time);
  $db->query('INSERT INTO chat_events (id, room_id, session_id, name, type, body, '
      . 'created_at) VALUES (1,1,?,?,?,?,?)', 'sess-1', 'alpha', 'message', 'hi', time);

  # One good row, and one orphan of each shape 1.5.0 could leave. The pairs are
  # distinct because (event_id, member_id) is unique -- an event addresses a
  # member once -- so the room is the only part that can vary freely.
  $db->query('INSERT INTO chat_mentions (event_id, member_id, room_id) VALUES (?,?,?)', @$_)
    for ([1, 1, 1],     # real
      [2, 1, 1],        # the event is gone
      [1, 2, 1],        # the member is gone
      [3, 3, 99]);      # the room is gone, and so is everything in it
  is $db->query('SELECT COUNT(*) FROM chat_mentions')->array->[0], 4, 'four rows to start';

  # Rewound to 2 so init runs migration 3 and only that, which is exactly what an
  # instance already on 1.5.0 does when it restarts on this version.
  $db->query(q{UPDATE mojo_migrations SET version = 2 WHERE name = 'share_chat'});
  Share::Chat->new(sql => $sql, log => $t->app->log)->init;

  my $left = $db->query('SELECT event_id, member_id, room_id FROM chat_mentions')
    ->hashes->to_array;
  is scalar @$left, 1, 'the orphans are gone';
  is_deeply $left->[0], {event_id => 1, member_id => 1, room_id => 1},
    'and the real one is untouched';
};

subtest 'the token guard is on the far side of both transports' => sub {
  # Reported by an ops session after deploying 1.5.0: SHARE_CHAT_REQUIRE_TOKEN
  # was enforced in the REST post route and nowhere else. The MCP tool called
  # Share::Chat::post underneath it and had no member_token in its schema at
  # all, so on an instance with a public /mcp anyone holding a room URL could
  # still post as anybody in the room -- the exact hole the flag exists to
  # close.
  #
  # The cause is not that one tool was missed. It is that the guard was written
  # in a route, and a guard in a route is a guard the next route forgets: three
  # more write paths were added after it and none of them called it. So it moves
  # to Share::Chat, which is the one place every write funnels through.
  my $id  = _room(topic => 'guarded everywhere')->{room}{id};
  my $tok = _join($id, session_id => 'sess-g', name => 'guarded', about => 'guard test')
    ->{member_token};
  my $vic = _join($id, session_id => 'sess-v', name => 'victim', about => 'guard test')
    ->{member_token};

  local $t->app->config->{chat_require_token} = 1;
  local $t->app->chat->{require_token} = 1;

  # 1. REST post -- the one that was already closed.
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-g', body => 'no token'})->status_is(403);

  # 2. MCP post -- impersonation, and the reported hole. Note the session id
  # being posted as is somebody else's, which is the whole point: it is readable
  # off nothing at all now, but a caller that knows it must still not be able to
  # speak as them.
  my $mcp = _call(post_chat_message => {room => $id, session_id => 'sess-v',
    body => 'posted as the victim, with no credential'});
  ok $mcp->{isError}, 'MCP posting without a token is refused';
  like $mcp->{content}[0]{text}, qr/member_token/, 'and says what is missing';

  my $ok = _call(post_chat_message => {room => $id, session_id => 'sess-v',
    body => 'and with one it goes through', member_token => $vic});
  ok !$ok->{isError}, 'the tool accepts a member_token';

  # 3. Leaving somebody else -- a nuisance rather than impersonation, but it
  # makes the roster say a live agent is gone and everyone stops addressing it.
  $t->delete_ok("/api/v1/chatrooms/$id/members/sess-v")->status_is(403);
  my $mleave = _call(leave_chatroom => {room => $id, session_id => 'sess-v'});
  ok $mleave->{isError}, 'and over MCP too';

  # 4. Moving somebody else's read cursor, which is the quiet one: set it
  # forward and they skip exactly the message somebody needed them to see.
  $t->post_ok("/api/v1/chatrooms/$id/members/sess-v/read" => json => {cursor => 99999})
    ->status_is(403);

  # Reading is untouched. The URL has always been the read credential and stays
  # one; what needed a credential was writing.
  $t->get_ok("/api/v1/chatrooms/$id/events")->status_is(200);

  # With the right token, all of them work.
  $t->post_ok("/api/v1/chatrooms/$id/messages" => json =>
      {session_id => 'sess-g', body => 'with a token', member_token => $tok})->status_is(201);
  $t->post_ok("/api/v1/chatrooms/$id/members/sess-v/read" => json =>
      {cursor => 1, member_token => $vic})->status_is(200);
  $t->delete_ok("/api/v1/chatrooms/$id/members/sess-v" =>
      json => {member_token => $vic})->status_is(200);
};

subtest 'an unauthorised reader may still read, it just cannot move the cursor' => sub {
  # since=unread advances a position on the member row, so a read carrying
  # somebody else's session id is a WRITE wearing a read's clothes -- and the
  # same forgery. Rather than making reading need a credential, which the URL
  # has always been, an unauthorised caller gets the events and the cursor stays
  # exactly where its owner left it.
  my $id  = _room(topic => 'read but do not move')->{room}{id};
  my $tok = _join($id, session_id => 'sess-r', name => 'reader', about => 'cursor guard')
    ->{member_token};
  _join($id, session_id => 'sess-s', name => 'speaker', about => 'cursor guard');
  _post($id, 'sess-s', 'something to be unread');

  local $t->app->config->{chat_require_token} = 1;
  local $t->app->chat->{require_token} = 1;

  my $before = $t->app->chat->read_cursor($t->app->chat->find_room($id), 'sess-r');
  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r")->status_is(200)
    ->json_is('/count' => 3);
  is $t->app->chat->read_cursor($t->app->chat->find_room($id), 'sess-r'), $before,
    'a stranger reading as me does not mark me caught up';

  $t->get_ok("/api/v1/chatrooms/$id/events?since=unread&session_id=sess-r&member_token=$tok")
    ->status_is(200);
  isnt $t->app->chat->read_cursor($t->app->chat->find_room($id), 'sess-r'), $before,
    'and with the token it advances as it should';
};

# ------------------------------------------------------ the 1.5.3 hotfixes ---

subtest 'the no-JavaScript path still works when the token is required' => sub {
  # CONTRIBUTING calls the no-JS form post "the real one" and the scripted path
  # an enhancement. 1.5.2 moved the guard into Share::Chat and the form route was
  # the one caller that never learned to say who it was -- so on an instance with
  # SHARE_CHAT_REQUIRE_TOKEN set, a person with scripting off could read a room
  # and never post to it. It failed silently: a 302 back to the room, and the
  # message simply absent.
  #
  # A browser carries no member_token and never will. Its signed cookie IS the
  # credential, which is exactly what _chat_credentials exists to say.
  local $t->app->config->{chat_require_token} = 1;
  local $t->app->chat->{require_token} = 1;

  $t->reset_session;
  my $id = _room(topic => 'no javascript here')->{room}{id};

  my %html = (Accept => 'text/html');
  $t->post_ok("/c/$id/join" => \%html => form =>
      {name => 'Pedro', about => 'reading in a browser'})->status_is(302);

  my $before = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{count};
  $t->post_ok("/c/$id/messages" => \%html => form => {body => 'posted with no script'})
    ->status_is(302);

  my $after = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json;
  is $after->{count}, $before + 1, 'the message landed';
  is $after->{events}[-1]{body}, 'posted with no script', 'and it is the one that was typed';

  $t->reset_session;
};

subtest 'a parked reader does not leak the request it parked on' => sub {
  # chat_await built its interval timer as `my $tick; $tick = sub { ... $tick->() }`,
  # a closure naming itself. Perl's refcounting cannot collect that cycle, and the
  # cycle captures the controller, its transaction, the promise, the query and the
  # rows -- so every park retained ~7KB for the life of the process, on a path that
  # is unauthenticated, deliberately not rate limited, and can be held for fifteen
  # minutes at a time.
  #
  # Asserted structurally rather than by measuring RSS, because a leak of a few
  # kilobytes is invisible in a test and obvious only after a thousand parks. The
  # promise is watched instead: if the closure cycle is still there, the guard
  # object it closes over is never destroyed.
  my $id = _room(topic => 'no leaks')->{room}{id};
  _join($id, session_id => 'sess-leak', name => 'parker', about => 'leak test');
  my $cursor = $t->get_ok("/api/v1/chatrooms/$id/events")->tx->res->json->{cursor};

  my $collected = 0;
  {
    # A sentinel with the same lifetime as the park: captured by the query hash
    # that chat_await holds, so it can only be freed once every closure in that
    # graph has been.
    my $room_obj = $t->app->chat->find_room($id);
    my $sentinel = Share::Test::Sentinel->new(sub { $collected++ });
    my %query    = (since => $cursor, sentinel => $sentinel);

    my $done = 0;
    $t->app->build_controller->chat_await($room_obj, \%query, 1)
      ->then(sub { $done = 1 })->wait;
    ok $done, 'the park settled';
  }

  is $collected, 1, 'and everything it held was freed when it did';
};

done_testing;
