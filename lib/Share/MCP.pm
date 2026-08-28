package Share::MCP;

# The MCP server: four tools for handing a file to a human, and six for talking
# to the other agents working on the same thing.
#
# Built on the CPAN MCP distribution (MCP::Server, by the
# Mojolicious author). It speaks protocol revision 2026-07-28 — stateless, no
# initialize handshake, `server/discover` in its place — and the HTTP transport
# answers the older initialize-based handshake for clients that have not caught
# up. Both eras, one endpoint, none of it our code.
#
# This file used to be 330 lines of hand-rolled JSON-RPC against the 2025-06-18
# revision. Version negotiation, Origin validation, the 405s on GET and DELETE,
# batching, error codes and schema validation of tool arguments all belong to
# the library now. What is left is the tools and what they say.
#
# NO TOOL CARRIES FILE BYTES, in either direction. Uploading means calling
# get_upload_url and running the curl command it returns; reading a file back
# means fetching its content_url. MCP is the control plane, HTTP is the data
# plane, and the two never mix.
#
# The reason is arithmetic. A tool argument or result passes through the model's
# context verbatim, and base64 inflates by a third: a 20 KB screenshot costs
# thousands of tokens to send and thousands more to read back, and a 3 MB PDF
# does not fit at all. Meanwhile `curl -F file=@…` moves it off disk for
# nothing. This was not theoretical — an agent using an earlier version of this
# server hit the tool-output cap reading back a 20 KB PNG it had just shared,
# and fell back to curl on its own.
#
# The cost, stated plainly: an MCP client with no shell and no HTTP tool cannot
# upload through this server at all. That is the trade, and it is the right one
# for a coding agent, which has both.

use Mojo::Base -strict, -signatures;
use utf8;

use MCP::Server  ();
use Mojo::URL    ();
use Scalar::Util ();
use Share::Store qw(human_size);

# Built once at startup. The tools reach the request through their own context,
# so nothing here is per-request state — which is what lets the whole thing be
# stateless under prefork.
sub server ($class, $app) {
  my $server = MCP::Server->new(
    name         => 'share',
    version      => $app->config->{version} // '1.0.0',
    instructions => _instructions($app->config),
  );

  _tools($server);
  return $server;
}

# The controller for the request a tool is being called in. MCP::Server::Context
# carries it, which is how a tool reaches the store and the base URL without
# either being smuggled through a global.
sub _c ($tool) { $tool->context->controller }

# ------------------------------------------------------- when a tool dies ----

# Counts failures within one worker. Paired with the pid it makes a reference
# that is unique across a prefork server without any shared state.
my $FAILURES = 0;

# Every tool is registered through here rather than straight onto the server,
# and the whole reason is what a failure looks like from the far end.
#
# A tool body that dies becomes a bare -32603 "Internal error" and an HTTP 500.
# That is all the caller gets: not which tool, not which argument, nothing to
# quote. A real report — "the MCP server on beebop is giving 500 errors" — was
# exactly that content-free, and the actual cause (an em dash in a title, see
# Share::Store::_signature) took a log dig to find rather than a glance.
#
# So the failure is written down with the tool that raised it and the argument
# names it was called with, under a short reference; and the caller is handed
# that reference instead of an opaque 500, so a complaint and a log line can be
# laid side by side.
#
# Argument NAMES only. A note or a title is the user's text and a delete
# password is a credential; which arguments were present is what narrows a bug,
# and their contents are not ours to copy into a log file.
sub _tool ($server, %spec) {
  my ($name, $code) = @spec{qw(name code)};

  $spec{code} = sub ($tool, $args) {
    my $result = eval { $code->($tool, $args) };
    my $failed = sub ($err) { _failure($tool, $name, $args, $err) };

    # One tool waits — get_chat_messages, when it is asked to — and a waiting
    # tool answers with a promise. A die inside one of those never reaches the
    # eval above, so the same report is attached to its rejection: an agent
    # should get the same sentence and the same reference whichever way the
    # tool it called happened to be written.
    return $result->catch($failed)
      if !$@ && Scalar::Util::blessed($result) && $result->isa('Mojo::Promise');

    return $result unless my $err = $@;
    return $failed->($err);
  };

  return $server->tool(%spec);
}

sub _failure ($tool, $name, $args, $err) {
  # A refusal is not a crash. Share::Chat says no to plenty of things on purpose
  # — no token, no such member, a message over the size cap — and every one of
  # them used to come back as "this is a bug in the server, quote reference
  # 12.3", which is both wrong and actively unhelpful: the caller goes looking
  # for an operator instead of reading the sentence that tells it what to fix.
  return $tool->text_result($err->{share_error}, 1)
    if ref $err eq 'HASH' && defined $err->{share_error};

  my $ref = sprintf '%d.%d', $$, ++$FAILURES;
  my $log = eval { _c($tool)->app->log };
  $log->error(sprintf 'MCP tool %s failed [ref %s] with arguments (%s): %s',
    $name, $ref, join(', ', sort keys %$args), $err)
    if $log;

  return $tool->text_result(
    "$name failed inside the share server — this is a bug in the server, not "
      . "something to work around. Quote reference $ref to whoever runs it; the "
      . 'error itself is in its log under that reference.', 1);
}

# ----------------------------------------------------------------- prose -----

# What an agent is told before it has made a single tool call. Anything wrong
# here shows up later as an agent misusing the service, so it says what the URL
# is for, who can open it, and how long it lasts.
#
# Built from the running configuration rather than frozen into a constant: an
# operator who sets a 3-day retention should not have an MCP server telling
# every agent it is 15.
sub _instructions ($cfg) {
  my $notice = $cfg->{notice};
  $notice = defined $notice && length $notice ? "  * $notice\n" : '';

  return sprintf <<'TXT', human_size($cfg->{max_bytes}), $cfg->{ttl_days}, $notice;
This server hands a file from you to a human being, and back.

IT NEVER CARRIES THE FILE ITSELF. Every tool here deals in URLs; you move the
bytes yourself with curl, straight off disk. That keeps a 3 MB PDF out of your
context entirely.

To give a human a file:

  1. Call get_upload_url with the filename, and your session_id.
  2. Run the "command" it hands back. It is a one-line curl.
  3. The JSON that curl prints contains "url". Give THAT to the person you are
     talking to, in plain text.

That JSON also contains "delete_password". It is the ONLY time you will ever be
shown it — no other call returns it — and it is the only way to delete the file
before it expires. Keep it if you might want to; the share URL alone cannot
delete anything.

They open the URL in a browser and see the file's name, size and expiry at the
top, with the file itself rendered below: markdown gets real typography and
mermaid diagrams get drawn, images are displayed, PDFs open in the browser's own
viewer. An Office document, an OpenDocument file or a zip is held and handed
over as a download instead — there is nothing a browser can render.

Use it whenever the answer is something to LOOK at rather than to read in a
terminal: a long report, a generated diagram, a screenshot, a PDF.

To read a file back, including one a human uploaded and sent you: call
get_shared_file for its metadata, then fetch the "content_url" it returns. Do
not ask this server for the contents; it will only ever give you the URL.

TALKING TO OTHER AGENTS. This server also holds chat rooms, for when the work is
split across sessions and the only wire between them is the person you are both
talking to. Call create_chatroom, give the human the URL it returns, and they
paste it into the other sessions; each one calls join_chatroom with a name and a
paragraph saying what it is working on. The same URL opened in a browser is a
room the human can read and take part in, live.

A room is ONE SEQUENCE OF EVENTS on one cursor — somebody speaking, somebody
arriving or leaving, a rename, the room expiring — so "what has happened since I
last looked?" is a single question with a single answer.

BEING IN A ROOM SHOULD NOT MEAN SITTING IN IT. This is the part agents get
wrong, at real cost: two sessions in one afternoon went hours without reading a
room they were in, because reading was expensive and not reading was free. So:

  * get_room_events with `wait` HOLDS for up to fifteen minutes and answers the
    moment something happens. Better still, run the same thing as a backgrounded
    shell command — it exits when the room needs you, which makes it a wake-up
    rather than a poll:

      curl -fsS --max-time 960 '<api_url>/events?since=<cursor>&wait=900&format=headers'

  * `mentions_me` narrows that to events which actually addressed you, so you
    park on "someone needs me" instead of "someone spoke".
  * `format: "headers"` catches you up for hundreds of tokens instead of
    thousands; fetch_chat_event gets the one body that mattered.
  * `since: "unread"` reads from where the server remembers you got to, so a
    session that has just been re-invoked need not have remembered anything.
  * leave_chatroom when you stop watching. A member who has gone quiet looks
    exactly like one who is listening, and the others will keep addressing you.

WHAT THE PERSON IN THE ROOM SEES. Markdown is rendered properly — headings,
tables, bold, lists, block quotes, code fences, emoji. Mermaid is NOT drawn in a
room: put the diagram in a shared file and post its URL. A message may be up to
16 KB; anything longer is a file. Write @name to address somebody, or @agents to
address every agent in the room at once and no human.

No attachments — share the file and post its URL. And treat the room URL as the
secret it is: anyone holding it can read the room and post to it.

Things worth knowing:

  * Markdown (.md), images (.png .jpg .gif .webp .svg .heic) and .pdf are
    rendered on the page. Office and OpenDocument files (.doc .docx .xls .xlsx
    .ppt .pptx .odt .ods .odp .odg) and .zip are held and handed over as a
    download — no preview, because a browser cannot draw one. Nothing else is
    accepted, files are at most %s each, and the extension on the filename must
    match the actual bytes or the upload is refused.
  * Files are deleted %s days after upload and the URL dies with them. Pass
    ttl_days for something shorter. Nothing here is durable storage.
  * The share URL is unguessable, but treat it as a secret: anyone holding it
    can read the file.
%s  * Pass your session_id every time. It costs nothing, and it is the only way
    list_shared_files can later tell you what you shared in this conversation.
TXT
}

sub _str ($desc, %extra) { {type => 'string', description => $desc, %extra} }

# ----------------------------------------------------------------- tools -----

sub _tools ($server) {

  # Stateless on purpose: no reservation is created, nothing is written, and
  # there is no half-finished upload to expire and reap. The URL returned is the
  # ordinary REST endpoint with the metadata already encoded into it and signed,
  # so an abandoned call costs exactly nothing.
  _tool(
    $server,
    name        => 'get_upload_url',
    description => 'Hand back a URL, and a ready-to-run curl command, for putting a '
      . 'file where a human can read it. Run the command; the JSON it prints contains '
      . '"url" (give that to the person) and "delete_password" (the only copy you will '
      . 'ever get). This server never accepts the file itself — that is what keeps a '
      . 'large PDF or screenshot out of your context.',
    input_schema => {
      type       => 'object',
      required   => ['filename'],
      properties => {
        filename => _str('The name to store it under, WITH an extension: .md, .png, '
            . '.jpg, .gif, .webp, .svg, .heic or .pdf, which get rendered on the page; '
            . 'or .doc/.docx/.xls/.xlsx/.ppt/.pptx/.odt/.ods/.odp/.odg/.zip, which are '
            . 'download-only. The extension must match the actual bytes or the upload '
            . 'is refused.'),
        path => _str('Where the file is on your disk. Only used to write the example '
            . 'command for you; this server never sees it.'),
        session_id => _str('Your session id, so list_shared_files can find this later.'),
        title      => _str('A short heading shown to the human above the file.'),
        note       => _str('One or two sentences of context shown to the human.'),
        ttl_days   => {
          type => 'number',
          description =>
            'Delete after this many days. Default and maximum 15; minimum 0.042 (one hour).',
        },
      },
    },
    code => sub ($tool, $args) {
      my $c        = _c($tool);
      my $filename = $args->{filename};

      my @pairs = (filename => $filename);
      for my $key (qw(session_id title note ttl_days)) {
        push @pairs, $key => $args->{$key} if defined $args->{$key} && length $args->{$key};
      }

      # Signed and time-limited. Not access control — with no authentication
      # anyone can POST to the endpoint directly — but it makes the parameters
      # an agent was handed tamper-evident, and stops a ticket being hoarded.
      # See the long note in Share::Store above sign_query.
      my $url = Mojo::URL->new($c->base_url . '/api/v1/files');
      $url->query($c->store->sign_query(\@pairs));

      my $path    = $args->{path} // "/path/to/$filename";
      my $command = sprintf q{curl -fsS -F 'file=@%s' '%s'}, $path, $url;

      return $tool->structured_result({
        upload_url => "$url",
        method     => 'POST',
        command    => $command,
        body       => 'multipart/form-data with a part named "file"; or the raw bytes as '
          . 'the request body, since the filename is already in the query string',
        max_bytes  => 0 + $c->app->config->{max_bytes},
        expires_in => 'one hour — get a fresh URL if you wait longer than that',
        next       => 'The JSON response contains "url" (give it to the human), '
          . '"content_url" (to read the file back), and "delete_password" — keep that '
          . 'one, it is never shown again and nothing else can delete the file.',
      });
    },
  );

  _tool(
    $server,
    name        => 'list_shared_files',
    description => 'List the files still live for a session id, newest first. Each one '
      . 'carries "url" (the page to give a human) and "content_url" (the bytes, for you '
      . 'to fetch). Delete passwords are never included. Expired files are gone and are '
      . 'not listed.',
    input_schema => {
      type       => 'object',
      required   => ['session_id'],
      properties => {session_id => _str('The session id used when the files were uploaded.')},
    },
    code => sub ($tool, $args) {
      my $c    = _c($tool);
      my $rows = $c->store->for_session($args->{session_id});
      my @info = map { $c->store->public($_, $c->base_url) } @$rows;
      return $tool->text_result('Nothing shared under that session id is still live.')
        unless @info;
      return $tool->structured_result({count => scalar @info, files => \@info});
    },
  );

  _tool(
    $server,
    name        => 'get_shared_file',
    description => 'Everything known about one shared file — name, kind, size, checksum, '
      . 'expiry, view count — plus "url" for the human and "content_url" for you. To '
      . 'read the contents, fetch content_url; this tool will not return them, and it '
      . 'will not return the delete password either.',
    input_schema => {
      type       => 'object',
      required   => ['id'],
      properties => {id => _str('The file id — the random part of its URL.')},
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my $row = $c->store->find($args->{id})
        or return $tool->text_result(_gone($args->{id}), 1);

      my $info   = $c->store->public($row, $c->base_url);
      my $result = $tool->structured_result($info);
      push @{$result->{content}},
        { type => 'text',
          text => "$info->{filename} is a $info->{kind} of $info->{size_human}, expiring in "
            . "$info->{expires_in}.\n\n"
            . "Give the human:  $info->{url}\n"
            . "Read it yourself: curl -fsS '$info->{content_url}'\n",
        };
      return $result;
    },
  );

  # ------------------------------------------------------------ chat rooms ---
  #
  # Six tools over the six REST endpoints in share.pl, and nothing an agent
  # could not do with curl against the room URL. They exist for the same reason
  # get_upload_url does: they fill in the base URL and the shape of the call, so
  # the one thing an agent has to get right is what it says.

  _tool(
    $server,
    name        => 'create_chatroom',
    description => 'Open a chat room for coordinating with agents in other sessions, and '
      . 'get back the URL to hand over. Give that URL to the person you are talking to; '
      . 'they paste it into the other sessions, and each one joins with a name and a '
      . 'note about what it is working on. The same URL opened in a browser is a room '
      . 'the human can read and post in. Use it when work is split across sessions and '
      . 'relaying every message through a person is the bottleneck.',
    input_schema => {
      type       => 'object',
      required   => ['topic'],
      properties => {
        topic   => _str('One line saying what is being coordinated here. Everyone sees it.'),
        purpose => _str('A paragraph of context for whoever arrives: the goal, the '
            . 'constraints, what "done" looks like.'),
        session_id => _str('Your session id, recorded as the room\'s opener.'),
        ttl_days   => {
          type        => 'number',
          description => 'Delete the room after this many days. Default and maximum 15.',
        },
      },
    },
    code => sub ($tool, $args) {
      my $c    = _c($tool);
      my $room = $c->chat->create_room(
        # Every write names its caller. The limit lives in Share::Chat now,
        # because it lived in the REST routes and this transport walked straight
        # past it -- the same shape of mistake as the token guard, one release
        # later, in the same place.
        client     => $c->chat_client,
        topic      => $args->{topic},
        purpose    => $args->{purpose},
        session_id => $args->{session_id},
        ttl_days   => $args->{ttl_days},
      );

      my $info     = $c->chat->room_public($room, $c->base_url);
      my $briefing = $c->chat->briefing($room, $c->base_url);

      my $result = $tool->structured_result({
        room            => $info,
        delete_password => $room->{delete_password},
        %$briefing,
        next => 'Give the human the "url". Join it yourself with join_chatroom, and say '
          . 'in this conversation what the room is for so they can pass that on.',
      });

      # Said in plain text as well as in the structure, because this is the one
      # sentence the agent has to act on: hand the URL over.
      push @{$result->{content}},
        { type => 'text',
          text => "The room is open.\n\nGive the human this URL:  $info->{url}\n\n"
            . "They paste it into the other sessions. Each one calls join_chatroom with a "
            . "name and one paragraph about what it is working on.\n\n"
            . "delete_password: $room->{delete_password} — the only copy, and the only "
            . "way to close the room before it expires in $info->{expires_in}.\n",
        };
      return $result;
    },
  );

  _tool(
    $server,
    name        => 'join_chatroom',
    description => 'Join a chat room you were given the URL for. Say who you are: a short '
      . 'name the others will see on every message, and one paragraph about what you are '
      . 'working on. You get back the roster, the recent messages and a cursor to read on '
      . 'from, plus a member_token you will only ever be shown once. Do this before '
      . 'posting — a room where nobody says what they are holding is a room that '
      . 'coordinates nothing. Call it AGAIN with the same session_id and a different name '
      . 'to RENAME yourself: the room is told, and you stay one member instead of '
      . 'becoming two.',
    input_schema => {
      type       => 'object',
      required   => [qw(room session_id name about)],
      properties => {
        room       => _str('The room URL you were given, or just the id out of it.'),
        session_id => _str('Your session id. It is shown on every message you post.'),
        name       => _str('A short name a person would recognise — "planner", '
            . '"api-refactor". It has to be one nobody else in the room has taken. '
            . 'Calling join_chatroom again with the SAME session_id and a different name '
            . 'RENAMES you and tells the room — that is how to keep one identity across a '
            . 'rename rather than becoming a second member.'),
        about => _str('One paragraph: what you are working on, and what you need from '
            . 'the others. Everyone in the room reads this.'),
        member_token => _str('Only needed to call this again for a session that has '
            . 'already joined — renaming yourself, or updating your paragraph. Arriving '
            . 'for the first time needs nothing.'),
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      my ($member, undef, $token) = $c->chat->join_room($room,
        client       => $c->chat_client,
        session_id   => $args->{session_id},
        name         => $args->{name},
        about        => $args->{about},
        member_token => $args->{member_token},
        kind         => 'agent');

      my $rows = $c->chat->messages($room);
      return $tool->structured_result({
        room     => $c->chat->room_public($room, $c->base_url, members => 1),
        member   => $c->chat->member_public($member, $room),
        # Issued once, and this is the once. Keep it: nothing else returns it,
        # and on an instance that requires it you cannot post without it.
        (defined $token ? (member_token => $token) : ()),
        count    => scalar @$rows,
        cursor   => $c->chat->cursor($room, $rows),
        messages => [map { $c->chat->event_public($_, [], $room) } @$rows],
        %{$c->chat->briefing($room, $c->base_url)},
      });
    },
  );

  _tool(
    $server,
    name        => 'post_chat_message',
    description => 'Say something in a room you have joined. Markdown. The result '
      . 'tells you what landed while you were not looking — "unread", and the headers '
      . 'of what you missed — because the moment you post is the one moment you are '
      . 'provably listening. No attachments: share the file with get_upload_url and put '
      . 'its URL in the message, which is how the human reading along gets to see it too.',
    input_schema => {
      type       => 'object',
      required   => [qw(room session_id body)],
      properties => {
        room       => _str('The room URL, or its id.'),
        session_id => _str('The session id you joined with.'),
        body       => _str('The message, as markdown.'),
        member_token => _str('The token join_chatroom returned. Required on an instance '
            . 'that sets SHARE_CHAT_REQUIRE_TOKEN; it is the only copy you were given.'),
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      my $row = $c->chat->post($room,
        client       => $c->chat_client,
        session_id   => $args->{session_id},
        body         => $args->{body},
        member_token => $args->{member_token});

      # Exactly the accounting the REST endpoint does, from the one helper, so
      # the two cannot drift: `unread` is the whole gap, `truncated` says when
      # the headers are only a page of it, and the cursor moves no further than
      # the last header actually shown.
      my %gap = $c->chat_gap($room, $args->{session_id}, $row);

      return $tool->structured_result({
        message => $c->chat->event_public($row, [], $room),
        cursor  => 0 + $row->{id},
        %gap,
      });
    },
  );

  # One sequence per room, and everything that happens to it is in there:
  # somebody speaking, somebody arriving or leaving, a rename, the room's own
  # death. So there is one question — "what since <id>?" — and one cursor.
  my %read_schema = (
      type       => 'object',
      required   => ['room'],
      properties => {
        room  => _str('The room URL, or its id.'),
        # Either shape, because it is genuinely two things: a number the caller
        # is carrying, or the word "unread" asking the server for the one it
        # keeps. Refusing the integer here would break every caller that has ever
        # handed back a cursor.
        since => {type => ['integer', 'string'],
          description => 'Event id to read on from — the "cursor" from your last call. '
            . 'Or the literal "unread", which reads from where the SERVER remembers you '
            . 'got to and then moves it, so a session that has just been re-invoked need '
            . 'not have remembered anything.'},
        limit => {type => 'integer', description => 'At most this many, up to 500. '
            . 'Default 100.'},
        wait => {type => 'integer', description => 'Seconds to HOLD the call open '
            . 'waiting for the next thing to happen, up to 900. Default 0, which answers '
            . 'at once. The answer carries "timed_out" so a loop can tell a quiet room '
            . 'from a room that said something.'},
        session_id => _str('Your session id, so the room can show you as still here, '
            . 'and so "unread" and mentions_me mean anything.'),
        format => _str('"full" (default) or "headers" — id, author, time, mentions and a '
            . 'short preview instead of whole bodies. Catching up in headers costs '
            . 'hundreds of tokens where full bodies cost thousands; fetch_chat_event '
            . 'gets the one you actually care about.'),
        # Boolean or 1, because a model writing a tool call produces either and a
        # schema that accepts only one of them fails the call outright — with a
        # validation error rather than anything that reads like "wrong shape".
        mentions_me => {type => ['boolean', 'integer'], description => 'Only events that addressed '
            . 'you by name, or the whole fleet with @agents. Combined with "wait" this is '
            . 'how you park on "someone needs me" rather than on "someone spoke".'},
        member_token => _str('The token join_chatroom returned. Required on an instance '
            . 'that sets SHARE_CHAT_REQUIRE_TOKEN; it is the only copy you were given.'),
      },
  );

  my $read_code = sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      $c->chat->touch_member($room, $args->{session_id},
        member_token => $args->{member_token});

      # "unread" reads from the position the server keeps for this member, so a
      # watcher that has just been re-invoked does not have to have remembered
      # anything. Only this form advances it; a caller passing a number is
      # carrying its own place.
      my $since = $args->{since};
      my $by_cursor = defined $since && $since eq 'unread';
      $since = $c->chat->read_cursor($room, $args->{session_id}) // 0 if $by_cursor;

      my %query = (since => $since, limit => $args->{limit});

      if ($args->{mentions_me}) {
        return $tool->text_result('mentions_me needs a session_id: it means '
            . '"addressed to me", and the room has to know who that is', 1)
          unless defined $args->{session_id} && length $args->{session_id};
        my $me = $c->chat->member($room, $args->{session_id});
        $query{mentions_me} = $me ? $me->{id} : -1;
      }
      my $wait  = $args->{wait} // 0;
      # The SECOND ceiling. share.pl has its own, and for a long time this one
      # sat here quietly holding every MCP caller to sixty seconds no matter what
      # that one said. Both come from the same configured number now, and a test
      # drives that number down and checks this call honours it.
      my $max = $c->app->config->{chat_max_wait};
      $wait = $max if $wait > $max;
      $wait = 0    if $wait < 0;

      my $answer = sub ($rows, $closed = undef) {
        # The room went while this call was parked on it. Same answer the REST
        # endpoint gives, and for the same reason: the last thing anybody reads
        # from a room is the room saying it is over.
        if ($closed) {
          my $event = $c->chat->destroyed_event($closed);
          return $tool->structured_result({
            closed => \1, count => 1, cursor => 0 + ($since // 0),
            timed_out => \0, missed => \0, unread => 0,
            events => [$event], messages => [$event],
          });
        }

        # Same as the REST read: reading is open, moving somebody's position is
        # not. An unauthorised caller gets the events and the cursor stays put.
        eval { $c->chat->mark_read($room, $args->{session_id}, $rows->[-1]{id},
            member_token => $args->{member_token}); 1 }
          if $by_cursor && @$rows;

        my $mentions = $c->chat->mentions_for($room, [map { $_->{id} } @$rows]);
        my $headers  = ($args->{format} // '') eq 'headers';
        my @public   = map {
          $headers
            ? $c->chat->header_public($_, $mentions->{$_->{id}} // [])
            : $c->chat->event_public($_,  $mentions->{$_->{id}} // [], $room)
        } @$rows;

        $tool->structured_result({
          count    => scalar @public,
          cursor   => $c->chat->cursor($room, $rows, $since),
          missed   => $c->chat->missed($room, $since) ? \1 : \0,
          unread   => $c->chat->unread_count($room, $args->{session_id}),
          events   => \@public,
          # Same reason as the REST endpoint: a loop that re-arms itself must be
          # able to tell "the room was quiet" from "I never waited" without
          # inspecting a count that means neither on its own.
          timed_out => ($wait && !@$rows) ? \1 : \0,
          # Both names for one list, exactly as the REST endpoint does it.
          messages => \@public,
        });
      };

      # An ordinary read answers here and now, with a single JSON body, which is
      # all this server has ever done. Only a caller that asked to WAIT gets the
      # other shape: a promise, which MCP::Server awaits and delivers over an SSE
      # stream. Nothing blocks either way — the same helper backs the REST long
      # poll, and a worker holds as many waiting callers as it has connections.
      return $answer->($c->chat->messages($room, %query)) unless $wait;

      # The transport holds the request open for as long as this takes, so the
      # connection has to be told to stop being impatient: Mojolicious hangs up
      # on an idle one after fifteen seconds.
      $c->inactivity_timeout($wait + 15);

      # An open poll is what says this member is listening, and this path did
      # not say it -- so an agent parked here for a quarter of an hour was
      # reported `away, online: false` while its REST twin showed `listening`.
      # The precise inverse of what presence is for: a live listener looked
      # dead, the others stopped addressing it, and it never found out.
      # The same ceiling the REST read enforces. A park costs the same whichever
      # door it came through, and a limit on one door is not a limit.
      return $tool->text_result('too many callers are already waiting on this '
          . 'room; read without `wait`, or try again in a moment', 1)
        unless $c->chat_take_slot($room);

      $c->chat->hold($room, $args->{session_id}, $wait,
        member_token => $args->{member_token});

      return $c->chat_await($room, \%query, $wait)->then(sub (@args) {
        $c->chat_free_slot($room);
        $c->chat->release($room, $args->{session_id},
          member_token => $args->{member_token});
        return $answer->(@args);
      });
  };

  my $read_description =
      'Read a room: one sequence of everything that has happened in it — somebody '
    . 'speaking, somebody arriving or leaving, a rename, the room going. With "since" '
    . 'you get everything after that event id; with since:"unread" you get what the '
    . 'SERVER remembers you have not read, which is what lets a restarted watcher '
    . 'remember nothing at all. Set "wait" and the call HOLDS for up to 900 seconds — '
    . 'fifteen minutes — answering the moment something happens, and "timed_out" says '
    . 'which it was. Use format:"headers" to catch up for hundreds of tokens instead of '
    . 'thousands, and mentions_me together with wait to be woken only when somebody '
    . 'actually wants you.';

  _tool(
    $server,
    name         => 'get_room_events',
    description  => $read_description,
    input_schema => {%read_schema},
    code         => $read_code,
  );

  # The name this call had before a room had an event stream. Same code, same
  # answer; kept for one release so a session holding an older tool list is not
  # simply broken.
  _tool(
    $server,
    name         => 'get_chat_messages',
    description  => "The previous name for get_room_events. $read_description",
    input_schema => {%read_schema},
    code         => $read_code,
  );

  _tool(
    $server,
    name        => 'fetch_chat_event',
    description => 'One event, in full. The other half of format:"headers" — read the '
      . 'room cheaply, then fetch only the bodies that turn out to matter. If you find '
      . 'yourself calling this for everything, you wanted format:"full".',
    input_schema => {
      type       => 'object',
      required   => [qw(room id)],
      properties => {
        room => _str('The room URL, or its id.'),
        id   => {type => 'integer', description => 'The event id, from a header.'},
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      my $row = $c->chat->event($room, $args->{id})
        or return $tool->text_result("no event $args->{id} in this room", 1);
      return $tool->structured_result({event => $c->chat->event_public($row, [], $room)});
    },
  );

  _tool(
    $server,
    name        => 'leave_chatroom',
    description => 'Say you are done, so the roster stops showing you as present. Do this '
      . 'when you stop watching a room: a member who has gone quiet looks exactly like one '
      . 'who is listening, and the others will go on addressing somebody who is not there. '
      . 'What you said stays in the room, and rejoining later with the same session id is '
      . 'fine.',
    input_schema => {
      type       => 'object',
      required   => [qw(room session_id)],
      properties => {
        room       => _str('The room URL, or its id.'),
        session_id => _str('The session id you joined with.'),
        member_token => _str('The token join_chatroom returned. Required on an instance '
            . 'that sets SHARE_CHAT_REQUIRE_TOKEN; it is the only copy you were given.'),
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      my $member = $c->chat->leave_room($room, $args->{session_id},
        member_token => $args->{member_token})
        or return $tool->text_result('nobody in that room joined with that session id', 1);
      return $tool->text_result("Left as $member->{name}. What you said is still in the "
          . 'room, and you can rejoin with the same session id.');
    },
  );

  _tool(
    $server,
    name        => 'search_chat_messages',
    description => 'Grep a room: every message containing this text, oldest first, case '
      . 'insensitive. It is a substring and not a regular expression — a pattern from a '
      . 'caller is a way to hang the server, and "who mentioned the migration" is a '
      . 'substring anyway.',
    input_schema => {
      type       => 'object',
      required   => [qw(room q)],
      properties => {
        room  => _str('The room URL, or its id.'),
        q     => _str('The text to look for.'),
        limit => {type => 'integer', description => 'At most this many matches, up to '
            . '500. The most recent ones. Default 100.'},
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($room, $id) = _room($c, $args->{room});
      return $tool->text_result(_no_room($id), 1) unless $room;

      my $rows = $c->chat->messages($room, q => $args->{q}, limit => $args->{limit});
      return $tool->text_result(qq{Nothing in this room matches "$args->{q}".})
        unless @$rows;
      return $tool->structured_result({
        count    => scalar @$rows,
        query    => $args->{q},
        messages => [map { $c->chat->event_public($_, [], $room) } @$rows],
      });
    },
  );

  _tool(
    $server,
    name        => 'delete_chatroom',
    description => 'Close a room now, before it expires, taking every message in it. '
      . 'Needs the delete_password from create_chatroom — the room URL alone cannot '
      . 'delete anything, and no other call will tell you the password.',
    input_schema => {
      type       => 'object',
      required   => [qw(room delete_password)],
      properties => {
        room            => _str('The room URL, or its id.'),
        delete_password => _str('The delete_password create_chatroom returned.'),
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my (undef, $id) = _room($c, $args->{room});
      my ($ok, $why) = $c->chat->remove_room($id, $args->{delete_password});
      return $tool->text_result($why, 1) unless $ok;
      return $tool->text_result("Closed $id. The URL no longer works, and the messages "
          . 'are gone.');
    },
  );

  _tool(
    $server,
    name        => 'delete_shared_file',
    description => 'Delete a shared file now, before its expiry. Needs the '
      . 'delete_password that came back from the upload — the share URL alone cannot '
      . 'delete anything, and no other call will tell you the password. Without it the '
      . 'file simply expires on its own.',
    input_schema => {
      type       => 'object',
      required   => [qw(id delete_password)],
      properties => {
        id              => _str('The file id — the random part of its URL.'),
        delete_password => _str('The delete_password from the JSON the upload printed.'),
      },
    },
    code => sub ($tool, $args) {
      my $c = _c($tool);
      my ($ok, $why) = $c->store->remove($args->{id} // '', $args->{delete_password});
      return $tool->text_result($why, 1) unless $ok;
      return $tool->text_result("Deleted $args->{id}. The URL no longer works.");
    },
  );

  return;
}

sub _gone ($id) {
  $id = '' unless defined $id;
  return qq{no live file with id "$id" — it was deleted, or it expired};
}

# A room is handed to an agent as a URL, because a URL is what a person can
# paste into a conversation. Taking the id out of one here means no tool ever
# answers "that is not an id" to something that plainly names the room.
sub _room ($c, $value) {
  my $id = defined $value ? "$value" : '';
  $id =~ s{[?#].*\z}{};
  $id =~ s{/+\z}{};
  $id =~ s{.*/}{};
  return ($c->chat->find_room($id), $id);
}

sub _no_room ($id) {
  return qq{no live chat room with id "$id" — it was closed, or it expired. Ask whoever }
    . q{sent you the URL for a new one.};
}

1;
