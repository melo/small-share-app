#!/usr/bin/env perl

# share — hand a file from an agent to a human, and let agents talk to each other.
#
# An agent uploads a markdown report, an image or a PDF and gets back one random
# URL. It gives that URL to a person, who opens it in a browser and reads the
# thing properly. Office and OpenDocument files and zips are held too, and
# handed over as a download rather than rendered — see %PREVIEWABLE below.
# Fifteen days later the file is gone and so is the URL.
#
# Five faces on the same app:
#
#   /            an explanation, for whoever lands here by accident
#   /f/<id>      the human's page: a header of facts, the file rendered below
#   /c/<id>      a chat room: agents in different sessions, and whoever opens it
#   /api/v1/…    the REST API for agents
#   /mcp         the same API as MCP tools, which is how agents actually use it
#
# There is NO authentication by design: the network you put this on is the
# perimeter. See docs/DESIGN.md for why, and for the one place to add it if you
# need it (the `under '/api/v1'` seam below). Do not expose this to the open
# internet as it stands.

use Mojolicious::Lite -signatures;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/lib";

use Digest::SHA   ();
use Mojo::IOLoop  ();
use Mojo::Promise ();
use Mojo::Util    qw(decode url_escape);
use Share::Chat    ();
use Share::MCP     ();
use Share::OpenAPI qw(openapi_type);
use Share::Render qw(render_markdown);
use Share::Store  qw(human_size payload_bytes);

our $VERSION = '1.4.1';

# Where this came from. Linked in the header of every page: the whole point of a
# small self-hosted tool is that whoever lands on one can go and read it.
package Share { use constant SOURCE_URL => 'https://github.com/melo/small-share-app'; }

# --------------------------------------------------------------- config ------

my %CFG = (
  root      => $ENV{SHARE_ROOT}      || '/workspace',
  base_url  => $ENV{SHARE_BASE_URL}  || '',
  ttl_days  => $ENV{SHARE_TTL_DAYS}  || 15,
  max_bytes => $ENV{SHARE_MAX_BYTES} || 32 * 1024 * 1024,

  # One line of deployment truth the code cannot know: who can reach this, what
  # network it is on, who to ask for access. Shown on the home page and handed
  # to every agent in the MCP instructions. Empty is fine.
  #
  # Decoded, because %ENV is bytes and this is the one setting a human writes
  # prose into. Left as bytes, an em-dash renders as "â" — everything
  # downstream encodes to UTF-8 on the way out and would do it twice.
  # Mojo::Util::decode returns undef on malformed input; keep the raw bytes then
  # rather than silently blanking what the operator configured.
  notice => _decoded($ENV{SHARE_NOTICE}),

  # Off by default: the plain `curl --data-binary @f.md '…?filename=f.md'` form
  # is the documented path and should keep working out of the box. Turn it on
  # and every upload must carry a signed ticket from the MCP get_upload_url
  # tool. Only meaningful once there is something to authenticate.
  require_signed_uploads => !!$ENV{SHARE_REQUIRE_SIGNED_UPLOADS},

  version => $VERSION,

  # --- protections for an instance anyone can reach ------------------------
  #
  # All three are off with a 0. Defaults are chosen for a public box: generous
  # enough that a person or an agent never notices, tight enough that a loop
  # does.
  max_total_bytes => _number(SHARE_MAX_TOTAL_BYTES => 50 * 1024 * 1024 * 1024),
  rate_per_second => _number(SHARE_RATE_PER_SECOND => 1),
  rate_per_minute => _number(SHARE_RATE_PER_MINUTE => 10),

  # Lets /api/v1/health — and ONLY /api/v1/health — report how many files are
  # held and how many bytes. No page a human can open carries that at any
  # setting.
  #
  # It is inventory: on an instance a stranger can reach it says how busy the
  # box is, roughly how much disk is in play, and, watched for a few minutes,
  # whether something they uploaded is still there or has been evicted. So it is
  # OFF by default, and turning it on is a deliberate act on a private
  # deployment whose collector needs the numbers. Leave it off in public.
  health_detail => !!$ENV{SHARE_HEALTH_DETAIL},

  # --- chat rooms ---------------------------------------------------------
  #
  # A room costs what its messages cost, so the limits are on the messages: how
  # big one may be, how many a room keeps, and how fast one caller may post.
  # They are separate from the upload numbers because the right answers are
  # nothing alike — one file a second is generous, one message a second is a
  # conversation that has barely started.
  chat_max_message_bytes => _number(SHARE_CHAT_MAX_MESSAGE_BYTES => 16 * 1024),
  chat_max_messages      => _number(SHARE_CHAT_MAX_MESSAGES      => 5000),
  chat_rate_per_second   => _number(SHARE_CHAT_RATE_PER_SECOND   => 5),
  chat_rate_per_minute   => _number(SHARE_CHAT_RATE_PER_MINUTE   => 60),

  # The longest a caller may park on a room waiting for the next thing to
  # happen. Sixty seconds was chosen so that "a proxy in front of this — and
  # every MCP client's own patience — is still comfortably inside its own
  # timeout", and NEITHER of those assumptions was ever tested.
  #
  # Fifteen minutes is what turns a backgrounded curl into a wake-up instead of a
  # poll: the agent works, and the moment the room needs it the command exits
  # with the delta in hand. It is configuration rather than a constant precisely
  # because the untested assumption is still untested — a deployment whose proxy
  # cuts long responses lowers this in .env, and does not go back to asking in a
  # loop.
  chat_max_wait => _number(SHARE_CHAT_MAX_WAIT => 900),
);

sub _decoded ($value) {
  return '' unless defined $value && length $value;
  return decode('UTF-8', $value) // $value;
}

# A number out of the environment, or the default when nobody set one.
#
# `defined` alone is the wrong test, and the three settings above are the three
# where being wrong costs something. An empty string is defined; `0 + ''` is 0;
# and 0 means "no limit" for every one of them. So `SHARE_MAX_TOTAL_BYTES=` in
# a .env file — or a compose file forwarding `${SHARE_MAX_TOTAL_BYTES:-}` — read
# as *turn the disk ceiling off*, when what it looks like, and what anyone
# writing it means, is "leave this one alone". The same shape disabled both rate
# limits. These are the protections for an instance anyone can reach, and they
# are exactly the ones that must not be switchable by accident.
#
# Empty is unset. Turning one off is still available, and still has to be
# written out: `SHARE_MAX_TOTAL_BYTES=0`.
sub _number ($name, $default) {
  my $value = $ENV{$name};
  return $default unless defined $value && length $value;
  return 0 + $value;
}

# Reachable as $c->app->config, which is how Share::MCP builds its instructions
# from the running configuration instead of hardcoding someone else's numbers.
app->config(\%CFG);

# Multipart framing and base64 both cost more than the payload, so leave room
# above the file limit; the store enforces the real one, with a clear message.
app->max_request_size(int($CFG{max_bytes} * 1.4) + 65_536);
app->defaults(ttl_days => $CFG{ttl_days});

# Ids are 32 base62 characters. The wider range keeps hand-made and older ones
# working. Registered before any route so every pattern below can use it.
app->routes->add_type(id => qr/[A-Za-z0-9]{8,64}/);

my $store = Share::Store->new(
  log              => app->log,
  root             => $CFG{root},
  max_bytes        => $CFG{max_bytes},
  default_ttl_days => $CFG{ttl_days},
  max_ttl_days     => $CFG{ttl_days},
  max_total_bytes  => $CFG{max_total_bytes},
  rate_per_second  => $CFG{rate_per_second},
  rate_per_minute  => $CFG{rate_per_minute},
)->init;

# The rooms live in the same SQLite file, under their own set of migrations, and
# inherit the file store's retention: fifteen days from creation, then the room
# and everything said in it is gone.
my $chat = Share::Chat->new(
  log               => app->log,
  sql               => $store->sql,
  default_ttl_days  => $CFG{ttl_days},
  max_ttl_days      => $CFG{ttl_days},
  max_message_bytes => $CFG{chat_max_message_bytes},
  max_messages      => $CFG{chat_max_messages},
)->init;

# Signs the identity cookie a person gets when they join a room — the one piece
# of state a browser keeps here. Derived from the store's key rather than
# configured separately, so it survives a restart, is the same in every prefork
# worker, and is nobody's job to remember to set; the derivation keeps the HMAC
# that signs upload tickets out of the cookie's reach.
app->secrets([Digest::SHA::hmac_sha256_hex('share-chat-cookie', $store->key)]);
app->sessions->cookie_name('share')->default_expiration($CFG{ttl_days} * 86400)
  ->samesite('Lax');

# ------------------------------------------------------------- fingerprints --
#
# Every asset is served under a URL containing a hash of its contents, so a
# deploy changes the URL and no cache anywhere can hand out the old file.
#
# This is not theoretical tidiness. share.simplicidade.org sits behind
# Cloudflare, which caches .css and .js by default and was serving a stylesheet
# from an earlier deploy with two days left on it. Nothing on our side could
# expire that; only a different URL can.
#
# Computed once at startup: the files are baked into the image and cannot change
# under a running container.
my %ASSET = map {
  my $name = $_->basename;
  my ($stem, $ext) = $name =~ /\A(.+)\.([^.]+)\z/;
  my $hash = substr Digest::SHA::sha256_hex($_->slurp), 0, 12;
  ($name => "/assets/$stem.$hash.$ext");
} grep { -f } @{app->home->child('public', 'assets')->list};

# Falls back to the plain path for anything unhashed, so a missing asset is a
# 404 for that file rather than a broken template for the whole page.
helper asset => sub ($c, $name) { $ASSET{$name} // "/assets/$name" };

helper store => sub ($c) { $store };
helper chat  => sub ($c) { $chat };

# Every URL we hand out is built from this. Configured explicitly in production,
# because the value is what an agent pastes into a conversation and a request
# header is a poor thing to trust with that.
helper base_url => sub ($c) {
  return $CFG{base_url} if length $CFG{base_url};
  return $c->req->url->base->to_string =~ s{/\z}{}r;
};

# The secret travels in a URL, so close the three ways URLs leak: crawlers,
# Referer on outbound links inside a shared document, and shared caches.
helper secret_headers => sub ($c) {
  $c->res->headers->header('X-Robots-Tag' => 'noindex, nofollow, noarchive')
    ->header('Referrer-Policy'            => 'no-referrer')
    ->header('X-Content-Type-Options'     => 'nosniff')->cache_control('private, no-store');
  return;
};

# ---------------------------------------------------------------- reaping ----
#
# Every worker holds this timer; Store::reap takes an atomic claim, so exactly
# one of them does the work in any given hour.

my $reap = sub {
  my $result = eval { $store->reap };
  return app->log->error("reaper failed: $@") unless $result;
  app->log->info(sprintf 'reaped %d file(s), %s', $result->{files}, human_size($result->{bytes}))
    if $result->{files};

  # Rooms ride on the file reaper's claim rather than holding one of their own:
  # the worker that won the hour does all of the deleting, and a room and a file
  # that expire in the same minute go in the same pass.
  return unless $result->{claimed};
  my $rooms = eval { $chat->reap };
  return app->log->error("chat reaper failed: $@") unless $rooms;
  app->log->info(sprintf 'reaped %d chat room(s), %d message(s)',
    $rooms->{rooms}, $rooms->{messages})
    if $rooms->{rooms};
};
Mojo::IOLoop->next_tick($reap);
Mojo::IOLoop->recurring(600 => $reap);

# Serves the fingerprinted URLs. Unhashed paths never reach here — Mojolicious
# runs the static handler before the router, and those files exist on disk — so
# this only ever sees a URL that carries a content hash, which is precisely the
# case where `immutable` is safe to promise.
get '/assets/*name' => sub ($c) {
  my $name = $c->stash('name');

  # Only URLs this app actually minted are served, matched against the map
  # rather than parsed out of the request. That is stricter than stripping a
  # hash-shaped suffix: an invented hash would otherwise pin today's bytes under
  # a URL promised to be immutable for a year.
  my ($real) = grep { $ASSET{$_} eq "/assets/$name" } keys %ASSET;
  return $c->reply->not_found unless defined $real;

  my $file = app->home->child('public', 'assets', $real);
  return $c->reply->not_found unless -f $file;
  $name = $real;

  $c->res->headers->content_type($c->app->types->file_type($name) // 'application/octet-stream');
  # A year, and immutable: the URL cannot outlive its contents, because the
  # contents are what named it.
  $c->res->headers->cache_control('public, max-age=31536000, immutable');
  $c->reply->file($file);
};

# ------------------------------------------------------------------ pages ----

# The home page IS the uploader. Everything explanatory moved to /how-to, one
# click away, because the common visit is "I have a file to hand over" and not
# "tell me what this is".
get '/' => sub ($c) {
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1, connect => 1));
  $c->render('index', cfg => \%CFG);
} => 'index';

# The API, for humans and for machines, at one URL.
#
# ?openapi=1 always wins; otherwise Accept decides. See Share::OpenAPI for why
# this is convention rather than specification — the OpenAPI spec says nothing
# about how a description document should be served, and nothing is registered
# with IANA.
get '/api' => sub ($c) {
  if (my $type = openapi_type($c)) {
    $c->res->headers->content_type($type);
    # Whoever hands this to a code generator should be able to cache it.
    $c->res->headers->cache_control('public, max-age=300');
    return $c->render(data => Mojo::JSON::encode_json(Share::OpenAPI->document($c)));
  }

  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('api', cfg => \%CFG, openapi => Share::OpenAPI->document($c));
} => 'api';

get '/how-to' => sub ($c) {
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  # No inventory here, and no setting that can put it back. A page a stranger
  # can open is not the place for how many files exist or how much disk is in
  # play — see the note above SHARE_HEALTH_DETAIL. The one endpoint that may
  # report it is /api/v1/health, because a collector needs numbers and an
  # operator turns that on deliberately.
  $c->render('how_to', cfg => \%CFG);
} => 'how_to';

# The other direction: a human hands a file to an agent.
#
# This is the no-JavaScript path, and it is the real one — the uploader is a
# plain multipart form inside a <details>, so the button expands the box and the
# upload works with scripting switched off entirely. assets/upload.js only
# upgrades it in place with drag-and-drop, paste, progress and inline results.
post '/upload' => sub ($c) {
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1, connect => 1));

  # Mojolicious stops parsing a body that blew the limit, which would otherwise
  # look exactly like "no file was chosen".
  $c->stash(cfg => \%CFG);

  if (my $err = $c->req->error) {
    return $c->render('uploaded', results => [],
      error => "That did not fit: $err->{message}. The limit is "
        . human_size($CFG{max_bytes}) . ' per file.');
  }

  if (my $wait = _rate_limited($c)) {
    return $c->render('uploaded', results => [], status => 429,
      error => "That was too fast — this instance allows a few uploads a minute. "
        . "Try again in ${wait} seconds.");
  }

  my @chosen = grep { length $_->filename } @{$c->req->every_upload('file')};
  return $c->render('uploaded', results => [], error => 'No file was chosen.') unless @chosen;

  my @results;
  for my $upload (@chosen) {
    my $row = eval {
      $store->add(
        bytes      => $upload->slurp,
        filename   => $upload->filename,
        session_id => scalar $c->param('session_id'),
        note       => scalar $c->param('note'),
      );
    };
    push @results, $@
      ? {filename => $upload->filename, error => _error_text($@)}
      : {file => {%{$store->public($row, $c->base_url)},
          delete_password => $row->{delete_password}}};
  }

  _shed_over_limit($c);
  $c->render('uploaded', results => \@results, error => undef);
} => 'upload';

# What a browser can actually show inside the frame. An Office document or a
# zip is not on the list and never will be: rendering one means a converter,
# and this service hands files over rather than opening them. The viewer says
# so plainly instead of framing a page whose only content is an apology.
my %PREVIEWABLE = (markdown => 1, image => 1, pdf => 1);

# The human's page: a header of facts and buttons, and the file itself in a
# frame below — so an untrusted document cannot reach the chrome, and so the
# facts stay put while the file scrolls.
get '/f/<secret:id>' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $store->touch($row);

  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1));
  $c->render('viewer', file => $store->public($row, $c->base_url), kind => $row->{kind},
    previewable => $PREVIEWABLE{$row->{kind}} ? 1 : 0);
} => 'viewer';

# The framed preview. Everything about this response assumes the document is
# hostile: the per-kind CSP below, and the sandbox attribute on the iframe.
get '/f/<secret:id>/view' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $c->secret_headers;

  my $origin = $c->base_url;

  # Nothing to frame. Whoever navigated straight here goes back to the page
  # that has the Download button on it.
  return $c->redirect_to($c->url_for('viewer')) unless $PREVIEWABLE{$row->{kind}};

  # Hand PDFs to the browser's own viewer. It is better than anything we would
  # build, and the browser already sandboxes it.
  return $c->redirect_to($c->url_for('raw')) if $row->{kind} eq 'pdf';

  if ($row->{kind} eq 'image') {
    # script-src, for one script of ours: preview-scroll.js, which tells the
    # parent page whether this frame is at the top so the file bar can fold
    # itself away. The picture is drawn by an <img>, which never executes what
    # it is pointed at — an uploaded SVG cannot run here whatever it contains —
    # and this origin is the only place a script may come from.
    $c->res->headers->header('Content-Security-Policy' => join '; ',
      "default-src 'none'", "img-src $origin", "style-src $origin",
      "script-src $origin", "frame-ancestors $origin", "base-uri 'none'");
    return $c->render('preview_image', file => $store->public($row, $c->base_url),
      note => _preview_note($row));
  }

  my $text = $store->contents($row) // '';
  utf8::decode($text);
  my $doc = render_markdown($text);

  # 'unsafe-inline' for styles, because mermaid injects its own. NOT
  # 'unsafe-eval': the pinned bundle is a self-contained esbuild UMD with no
  # `new Function(`, no `eval(` and no dynamic import in it, so it does not need
  # the exemption its CSP reputation suggests. Re-check that when bumping it.
  #
  # Naming the host explicitly rather than 'self' is deliberate: the iframe has
  # no allow-same-origin, so this document lives in an opaque origin, where
  # 'self' matches nothing at all.
  $c->res->headers->header('Content-Security-Policy' => join '; ',
    "default-src 'none'",
    "img-src $origin data: https:",
    "style-src $origin 'unsafe-inline'",
    "script-src $origin",
    "font-src $origin data:",
    "frame-ancestors $origin",
    "base-uri 'none'",
    "form-action 'none'");

  $c->render('preview_markdown', body_html => $doc->{html}, mermaid => $doc->{mermaid});
} => 'view';

# Inline bytes. Everything but PDF also carries `Content-Security-Policy:
# sandbox`, which is what stops someone navigating straight here to an uploaded
# SVG and running script in our own origin. PDF is excluded because the sandbox
# directive breaks the built-in viewer in several browsers.
get '/f/<secret:id>/raw' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => 'sandbox') unless $row->{kind} eq 'pdf';
  _serve($c, $row, 'inline');
} => 'raw';

get '/f/<secret:id>/download' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $store->touch($row);
  $c->secret_headers;
  _serve($c, $row, 'attachment');
} => 'download';

# Deleting is two clicks and zero JavaScript: a GET that asks, a POST that does
# it. That is what lets every chrome page run under `default-src 'none'` with no
# script source at all.
get '/f/<secret:id>/delete' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('confirm_delete', file => $store->public($row, $c->base_url), error => undef);
} => 'confirm_delete';

post '/f/<secret:id>/delete' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  my $filename = $row->{filename};

  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());

  my ($ok, $why) = $store->remove($row->{secret}, scalar $c->param('delete_password'));
  return $c->render('confirm_delete', file => $store->public($row, $c->base_url), error => $why)
    unless $ok;

  $c->render('deleted', filename => $filename);
};

# ------------------------------------------------------------ chat rooms -----
#
# A room is a URL, handed over exactly like a file's. Two kinds of reader arrive
# at it: a person in a browser, who is asked who they are before they are shown
# anything, and an agent that was handed the URL by that person and has never
# seen this service before — which gets the whole protocol as JSON. Same URL,
# and Accept decides, the way /api already does for its OpenAPI document.

# Opening a room without having asked for one first.
#
#   curl https://share.…/c        an agent gets a room and the whole briefing
#   type /c into a browser        a person gets a room and lands at its door
#
# It is a GET that creates something, which is not what GET is for, and that is
# the trade: it buys a URL short enough to say out loud, type from memory or
# put in a README. The cost is bounded on purpose — the room it makes is empty,
# it is rate limited like any other, and it expires on its own like everything
# else here. Nothing links to /c and every page this app serves is noindex, so
# there is nothing for a crawler or a link prefetcher to follow into it; HEAD is
# answered without creating anything, so an uptime probe pointed here does not
# quietly open a room a minute.
#
# ?topic= and ?purpose= name it. Without them it is an untitled room, which is
# honest: whoever typed /c wanted a room, not a form.
get '/c' => sub ($c) {
  $c->secret_headers;

  return $c->rendered(200) if $c->req->method eq 'HEAD';

  if (my $wait = _chat_rate_limited($c)) {
    return _api_error($c, 429, "too many requests; try again in ${wait}s") if _wants_json($c);
    $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
    return $c->render('chat_busy', status => 429, wait => $wait);
  }

  my $topic = $c->param('topic');
  $topic = 'Untitled room' unless defined $topic && $topic =~ /\S/;

  my $room = eval {
    $chat->create_room(
      topic      => $topic,
      purpose    => scalar $c->param('purpose'),
      session_id => scalar $c->param('session_id'),
      ttl_days   => scalar $c->param('ttl_days'),
    );
  };
  return _api_error($c, 400, $@) if $@ && _wants_json($c);
  return _gone($c, 'room')       if $@;

  my $info = {%{_chat_briefing($c, $room)}, delete_password => $room->{delete_password}};

  if (_wants_json($c)) {
    $c->res->headers->location($info->{room}{url});
    return $c->render(json => $info, status => 201);
  }

  # Carried across the redirect and shown once on the door, which is the same
  # rule a file's delete password follows: it is the only copy, and no later
  # call or page will tell them it again.
  $c->flash(room_password => $room->{delete_password});
  $c->redirect_to('chat_room', room => $room->{secret});
} => 'chat_open';

get '/c/<room:id>' => sub ($c) {
  my $room = $chat->find_room($c->stash('room'));
  $c->secret_headers;

  # Whoever is asking decides what "gone" looks like too: an agent that curled a
  # room which has since expired should be told so in the JSON it can read, not
  # handed a page written for a person.
  return _api_error($c, 404, _no_room($c)) if !$room && _wants_json($c);
  return _gone($c, 'room') unless $room;

  return $c->render(json => _chat_briefing($c, $room)) if _wants_json($c);

  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1, connect => 1));

  # Asked who they are first, as the feature was asked for. It is not a login —
  # there are no accounts here and the URL is still the only credential — but a
  # room is a conversation, and a name is the least it can ask of somebody
  # walking into one.
  my $me = _chat_me($c, $room);
  return $c->render('chat_join',
    room     => $chat->room_public($room, $c->base_url, members => 1),
    error    => undef,
    name     => _chat_identity($c)->{name},
    # Set only for whoever just opened this room at /c, and only on the one
    # request that follows the redirect.
    password => scalar $c->flash('room_password'),
  ) unless $me;

  my $rows = $chat->messages($room);
  $chat->touch_member($room, $me->{session_id});
  $c->render('chat_room',
    room     => $chat->room_public($room, $c->base_url, members => 1),
    me       => $chat->member_public($me),
    cursor   => $chat->cursor($room, $rows),
    error    => scalar $c->flash('chat_error'),
  );
} => 'chat_room';

post '/c/<room:id>/join' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _gone($c, 'room');
  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1, connect => 1));

  my $identity = _chat_identity($c);
  my ($member) = eval {
    $chat->join_room($room,
      session_id => $identity->{sid},
      kind       => 'human',
      name       => scalar $c->param('name'),
      about      => scalar $c->param('about'));
  };

  if (my $err = $@) {
    return $c->render('chat_join', status => 400,
      room     => $chat->room_public($room, $c->base_url, members => 1),
      error    => _error_text($err),
      name     => scalar $c->param('name'),
      password => undef,
    );
  }

  # Signed, and this browser's alone. It holds a name and a session id and
  # nothing else: there is no account behind it to take over.
  $c->session(chat => {sid => $identity->{sid}, name => $member->{name}});
  $c->redirect_to('chat_room');
} => 'chat_join';

# The no-JavaScript path, and the real one: a plain form post that lands back on
# the room. assets/chat.js intercepts the same form and posts it over the API
# instead, so the page never reloads — but with scripting off the room still
# works, exactly like the uploader.
post '/c/<room:id>/messages' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _gone($c, 'room');
  $c->secret_headers;

  my $me = _chat_me($c, $room) or return $c->redirect_to('chat_room');

  if (my $wait = _chat_rate_limited($c)) {
    $c->flash(chat_error => "That was too fast for this instance. Try again in ${wait} seconds.");
    return $c->redirect_to('chat_room');
  }

  eval { $chat->post($room, session_id => $me->{session_id}, body => scalar $c->param('body')) };
  $c->flash(chat_error => _error_text($@)) if $@;
  $c->redirect_to('chat_room');
} => 'chat_post';

# The transcript, in its own document, for the same two reasons the file preview
# is in one: the messages are markdown written by agents and must not be able to
# reach the page holding the identity cookie, and the conversation should scroll
# under a header that stays put.
get '/c/<room:id>/transcript' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _gone($c, 'room');
  $c->secret_headers;

  my $me = _chat_me($c, $room) or return $c->redirect_to('chat_room');

  my $origin = $c->base_url;
  $c->res->headers->header('Content-Security-Policy' => join '; ',
    "default-src 'none'",
    "img-src $origin data: https:",
    "style-src $origin",
    "script-src $origin",
    "font-src $origin data:",
    "frame-ancestors $origin",
    "base-uri 'none'",
    "form-action 'none'");

  my $rows = $chat->messages($room, q => scalar $c->param('q'));
  $c->render('chat_transcript',
    messages => [map { _chat_view($c, $_) } @$rows],
    me       => $chat->member_public($me),
    query    => scalar $c->param('q'),
  );
} => 'chat_transcript';

# ------------------------------------------------------------------- API -----
#
# This `under` is the seam. If authentication is ever needed it goes here and
# nowhere else; no route below assumes anonymity.

my $api = app->routes->under('/api/v1' => sub ($c) {1});

# Liveness, and nothing else by default. A health endpoint on a public box is
# reachable by anyone, so it says only that it is alive and what it is running;
# the inventory is added back with SHARE_HEALTH_DETAIL for a private deployment
# whose collector needs it.
$api->get('/health' => sub ($c) {
  my $health = {status => 'ok', version => $VERSION};

  if ($c->app->config->{health_detail}) {
    my $stats = $store->stats;
    @{$health}{qw(files bytes)} = @{$stats}{qw(files bytes)};
    my $rooms = $chat->stats;
    @{$health}{qw(rooms messages)} = @{$rooms}{qw(rooms messages)};
  }

  $c->render(json => $health);
});

$api->post('/files' => sub ($c) {
  # A signed ticket from get_upload_url is verified if present. An unsigned
  # upload is still accepted by default — `curl --data-binary @f.md '…?filename=f.md'`
  # is the documented path and needs no ceremony — unless the operator has set
  # SHARE_REQUIRE_SIGNED_UPLOADS, which makes tickets mandatory.
  #
  # There is deliberately no way to influence the stored id from out here: it
  # comes from /dev/urandom inside Share::Store::add, and no route in this app
  # updates an existing file. Two uploads of the same bytes are two files.
  if (my $wait = _rate_limited($c)) {
    return _api_error($c, 429, "too many uploads; try again in ${wait}s");
  }

  if (my $reason = _bad_ticket($c)) { return _api_error($c, 403, $reason) }

  my $args = eval { _upload_args($c) };
  return _api_error($c, 400, $@) if $@;

  my $row = eval { $store->add(%$args) };
  return _api_error($c, 400, $@) if $@;

  # The one and only time the delete password is disclosed. It is not a column
  # anything else reads, `public` does not carry it, and no later call will
  # return it — losing it means the file simply expires on its own.
  my $info = {%{$store->public($row, $c->base_url)}, delete_password => $row->{delete_password}};
  _shed_over_limit($c);
  $c->res->headers->location($info->{url});
  $c->render(json => $info, status => 201);
});

$api->get('/files' => sub ($c) {
  my $session_id = $c->param('session_id');
  return _api_error($c, 400, 'session_id is required')
    unless defined $session_id && length $session_id;

  my @files = map { $store->public($_, $c->base_url) } @{$store->for_session($session_id)};
  $c->render(json => {count => scalar @files, files => \@files});
});

$api->get('/files/<secret:id>' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _api_error($c, 404, 'no such file');
  $c->render(json => $store->public($row, $c->base_url));
});

$api->get('/files/<secret:id>/content' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _api_error($c, 404, 'no such file');
  $c->res->headers->header('Content-Security-Policy' => 'sandbox') unless $row->{kind} eq 'pdf';
  _serve($c, $row, 'inline');
});

# Deleting is a separate capability from reading, and the share URL grants only
# reading. The password comes from the upload response; three places to put it,
# because a DELETE with a body is awkward in some clients and a query string
# ends up in logs.
$api->delete('/files/<secret:id>' => sub ($c) {
  my ($ok, $why) = $store->remove($c->stash('secret'), _delete_password($c));
  # 403, not 404: "no such file" and "wrong password" are the same sentence on
  # purpose — see Share::Store::remove — so this cannot be used to find out
  # which ids exist.
  return _api_error($c, 403, $why) unless $ok;
  $c->render(json => {deleted => $c->stash('secret')});
});

# --------------------------------------------------------- chat rooms API ----
#
# Everything a session needs, in six calls, and every one of them answerable
# with one line of curl — because the agent on the other end of a room URL may
# have no MCP server registered at all. The MCP tools in Share::MCP are a
# convenience over exactly these endpoints and add nothing they cannot do.

$api->post('/chatrooms' => sub ($c) {
  if (my $wait = _chat_rate_limited($c)) {
    return _api_error($c, 429, "too many requests; try again in ${wait}s");
  }

  my $args = eval { _chat_args($c, qw(topic purpose session_id ttl_days delete_password)) };
  return _api_error($c, 400, $@) if $@;

  my $room = eval { $chat->create_room(%$args) };
  return _api_error($c, 400, $@) if $@;

  # The one and only disclosure of the room's delete password, on the same terms
  # as a file's: nothing else returns it, and without it the room can only
  # expire on its own.
  my $info = {%{_chat_briefing($c, $room)}, delete_password => $room->{delete_password}};
  $c->res->headers->location($info->{room}{url});
  $c->render(json => $info, status => 201);
});

$api->get('/chatrooms/<room:id>' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));
  $chat->touch_member($room, scalar $c->param('session_id'));
  $c->render(json => _chat_briefing($c, $room));
});

$api->delete('/chatrooms/<room:id>' => sub ($c) {
  my ($ok, $why) = $chat->remove_room($c->stash('room'), _delete_password($c));
  # 403 rather than 404, and one sentence for both cases: see the file delete
  # above, and Share::Chat::remove_room.
  return _api_error($c, 403, $why) unless $ok;
  $c->render(json => {deleted => $c->stash('room')});
});

# Joining. Idempotent: the same session id calling again updates its name and
# its paragraph rather than arriving twice.
$api->post('/chatrooms/<room:id>/members' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));

  if (my $wait = _chat_rate_limited($c)) {
    return _api_error($c, 429, "too many requests; try again in ${wait}s");
  }

  my $args = eval { _chat_args($c, qw(session_id name about)) };
  return _api_error($c, 400, $@) if $@;

  my ($member) = eval { $chat->join_room($room, %$args, kind => 'agent') };
  return _api_error($c, 400, $@) if $@;

  # Everything a session that has just arrived needs in one answer: who else is
  # here, what has been said, where to carry on from, and how to do all of it.
  my $rows = $chat->messages($room);
  $c->render(json => {
    %{_chat_briefing($c, $room)},
    member   => $chat->member_public($member),
    count    => scalar @$rows,
    cursor   => $chat->cursor($room, $rows),
    messages => [map { $chat->message_public($_) } @$rows],
  });
});

# Reading, waiting and grepping are one endpoint, because they are one question
# asked with different patience — and now under two names.
#
# `/events` is what this is: one monotonic sequence per room, where a message is
# one kind of thing that happened and an arrival, a rename and the room's own
# death are others. `/messages` is what it was called yesterday, and it keeps
# working unchanged — it already returned arrivals and renames alongside speech,
# so nothing about its behaviour moves, only the name of the list it hands back.
my $read_events = sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));
  $chat->touch_member($room, scalar $c->param('session_id'));

  my $since = $c->param('since');
  my %query = (since => $since, limit => scalar $c->param('limit'), q => scalar $c->param('q'));

  # A search waits for nothing: `q` asks about what has already been said.
  my $wait = length($query{q} // '') ? 0 : _chat_wait_seconds($c);

  # Mojolicious closes an idle connection after fifteen seconds, which would
  # hang up on every long poll asking for more than that.
  $c->inactivity_timeout($wait + 15) if $wait;

  # Answered on the spot unless the caller asked to wait. The promise path costs
  # nothing here, but over MCP it is the difference between one JSON body and an
  # SSE stream — see the tool in Share::MCP — and the two sides should behave the
  # same way for the same request.
  return _chat_messages_json($c, $room, $chat->messages($room, %query), $since) unless $wait;

  $c->render_later;
  $c->chat_await($room, \%query, $wait)
    ->then(sub ($rows) { _chat_messages_json($c, $room, $rows, $since, waited => 1) });
};

# One event in full, for a caller reading headers that decided it wants the body
# after all. The whole point of a header is that this call is usually not made.
$api->get('/chatrooms/<room:id>/events/<event>' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));
  my $row = $chat->event($room, $c->stash('event'))
    or return _api_error($c, 404, 'no such event in this room');
  $c->render(json => {event => $chat->event_public($row)});
});

$api->get('/chatrooms/<room:id>/events'   => $read_events);
$api->get('/chatrooms/<room:id>/messages' => $read_events);

$api->post('/chatrooms/<room:id>/messages' => sub ($c) {
  my $room = $chat->find_room($c->stash('room')) or return _api_error($c, 404, _no_room($c));

  if (my $wait = _chat_rate_limited($c)) {
    return _api_error($c, 429, "too many messages; try again in ${wait}s");
  }

  my $args = eval { _chat_args($c, qw(session_id body)) };
  return _api_error($c, 400, $@) if $@;

  my $row = eval { $chat->post($room, %$args) };
  return _api_error($c, 400, $@) if $@;

  $c->render(json => {message => $chat->message_public($row), cursor => 0 + $row->{id}},
    status => 201);
});

# ------------------------------------------------------------------- MCP -----
#
# One line, because MCP::Server::Transport::HTTP owns the whole protocol now:
# revision 2026-07-28 (stateless, `server/discover`, no handshake), the legacy
# initialize handshake for clients that have not caught up, Origin validation,
# 405 on GET and DELETE, and JSON Schema validation of every tool argument.
#
# What used to live here — 330 lines of it — is in the library's hands. See
# lib/Share/MCP.pm for the four tools, which is all that is genuinely ours.

any '/mcp' => Share::MCP->server(app)->to_action;

# --------------------------------------------------------------- helpers -----

# Nothing is granted that a page does not ask for by name, so a route that needs
# script does not loosen the whole app.
#
# `scripts` is asked for by the two uploader pages and by the viewer. The viewer
# carries a secret, which used to be reason enough to give it no script source at
# all — but a Copy button cannot exist without one, and neither can a bar that
# folds itself away as you scroll. What it does NOT get is `connect`: the file
# being viewed lives in a sandboxed frame in an opaque origin and cannot reach
# this document, and the script on this side has nothing to fetch.
sub _chrome_csp (%opt) {
  my @csp = (
    "default-src 'none'", "style-src 'self'", "img-src 'self' data:",
    "frame-src 'self'",   "form-action 'self'", "frame-ancestors 'none'",
    "base-uri 'none'",
  );
  push @csp, "script-src 'self'"  if $opt{scripts};
  push @csp, "connect-src 'self'" if $opt{connect};
  return join '; ', @csp;
}

# HEIC is accepted because it is what phones produce, but outside Safari most
# browsers cannot decode one, and an <img> that fails renders as a broken icon
# with no explanation. Say so instead, and point at the download — the preview
# frame has no JavaScript, so this has to be in the markup.
sub _preview_note ($row) {
  return undef unless $row->{content_type} =~ m{\Aimage/hei[cf]\z};
  return 'HEIC images only display in Safari. Use Download to save it, or open '
    . 'this link on a Mac or an iPhone.';
}

sub _serve ($c, $row, $disposition) {
  my $bytes = $store->contents($row);
  return _gone($c) unless defined $bytes;

  $c->res->headers->content_type($row->{content_type});
  $c->res->headers->content_disposition(_disposition($disposition, $row->{filename}));
  $c->render(data => $bytes);
  return;
}

# Both forms, because the quoted one is all some clients read and the RFC 5987
# one is the only one that survives a non-ASCII filename.
sub _disposition ($kind, $filename) {
  my $ascii = $filename =~ s/[^\x20-\x7e]/_/gr =~ s/["\\]/_/gr;
  my $bytes = $filename;
  utf8::encode($bytes);
  my $encoded = url_escape $bytes, '^A-Za-z0-9\-\._~';
  return qq{$kind; filename="$ascii"; filename*=UTF-8''$encoded};
}

# Three ways in, in order of how pleasant they are to type:
#
#   curl --data-binary @r.md '…/api/v1/files?filename=r.md'   raw body
#   curl -F file=@r.md '…/api/v1/files'                       multipart
#   curl -H content-type:application/json -d '{…}' '…'        JSON + base64
sub _upload_args ($c) {
  my %args = map { $_ => scalar $c->param($_) } qw(session_id title note ttl_days);

  if (my $upload = $c->req->upload('file')) {
    return {%args, bytes => $upload->slurp,
      filename => $c->param('filename') // $upload->filename};
  }

  # Content-type gated on purpose: req->json would happily decode a markdown
  # file that happens to start with a brace and then upload the wrong thing.
  if (($c->req->headers->content_type // '') =~ m{\Aapplication/json\b}i) {
    my $json = $c->req->json;
    _bad('the body is not valid JSON') unless defined $json;
    _bad('the JSON body must be an object') unless ref $json eq 'HASH';
    return {
      (map { $_ => $json->{$_} } qw(filename session_id title note ttl_days)),
      bytes => payload_bytes($json),
    };
  }

  my $body = $c->req->body;
  _bad('no file in the request: send multipart "file", a JSON body, or raw bytes with ?filename=…')
    unless length $body;
  _bad('raw-body uploads need ?filename=… so the type can be worked out')
    unless defined $c->param('filename');

  return {%args, bytes => $body, filename => $c->param('filename')};
}

# Returns a reason string when the request must be refused, undef when it may
# proceed.
sub _bad_ticket ($c) {
  my %query = %{$c->req->url->query->to_hash};
  my $signed = defined $query{sig} && length $query{sig};

  return 'this deployment requires a signed upload URL; ask the MCP server for one '
    . 'with get_upload_url'
    if !$signed && $CFG{require_signed_uploads};

  return undef unless $signed;

  my ($ok, $reason) = $store->check_signature(\%query);
  return $ok ? undef : $reason;
}

# Header first: a query string lands in access logs and a browser's history,
# and the form field exists only for the no-JavaScript delete page.
sub _delete_password ($c) {
  my $header = $c->req->headers->header('X-Delete-Password');
  return $header if defined $header && length $header;

  my $json = $c->req->headers->content_type && $c->req->headers->content_type =~ m{\Aapplication/json\b}i
    ? $c->req->json : undef;
  return $json->{delete_password}
    if ref $json eq 'HASH' && defined $json->{delete_password} && length $json->{delete_password};

  my $param = $c->param('delete_password');
  return defined $param && length $param ? $param : undef;
}

# Who is being limited.
#
# Behind Cloudflare the honest answer is CF-Connecting-IP; behind Traefik alone
# it is the left-most X-Forwarded-For, which MOJO_REVERSE_PROXY already resolves
# into remote_address. Neither is forgeable by a client that is actually behind
# the proxy, and a deployment with nothing in front has no forwarded headers to
# be confused by.
sub _client ($c) {
  my $cf = $c->req->headers->header('CF-Connecting-IP');
  return $cf if defined $cf && length $cf;
  return $c->tx->remote_address // 'unknown';
}

# Returns a Retry-After value when the caller must wait, undef when it may go.
sub _rate_limited ($c) {
  my ($ok, $wait) = $store->rate_check(_client($c));
  return undef if $ok;

  $c->res->headers->header('Retry-After' => $wait);
  app->log->info(sprintf 'rate limited %s, retry in %ds', _client($c), $wait);
  return $wait;
}

# ------------------------------------------------------- chat room helpers ---

sub _chat_wait_seconds ($c) {
  my $wait = $c->param('wait') // 0;
  return 0 unless $wait =~ /\A\d+\z/;
  my $max = $c->app->config->{chat_max_wait};
  return $wait > $max ? $max : 0 + $wait;
}

# Wait for the next thing said in a room, without a worker sitting still for it.
#
# There is no notification bus here and there should not be one. The app runs
# prefork: a message posted through one worker has to reach a caller parked in
# another, and the only thing the two share is the database. So this polls it,
# twice a second, with one indexed lookup on (room_id, id) — cheaper by far than
# any of the machinery that would avoid the poll, and correct at any worker
# count, which is the same argument the reaper makes for its claim.
#
# It answers with a promise so that both callers can use the one implementation:
# the REST route renders from it, and the MCP tool returns it as its result,
# which MCP::Server already knows how to await.
helper chat_await => sub ($c, $room, $query, $wait) {
  my $chat    = $c->chat;
  my $promise = Mojo::Promise->new;

  my $rows = eval { $chat->messages($room, %$query) } // [];
  return $promise->resolve($rows) if @$rows || !$wait;

  my $deadline = time + $wait;
  my ($settled, $timer) = (0, undef);

  my $settle = sub ($found) {
    return if $settled++;
    Mojo::IOLoop->remove($timer) if defined $timer;
    $promise->resolve($found);
  };

  $timer = Mojo::IOLoop->recurring(
    0.5 => sub {
      my $found = eval { $chat->messages($room, %$query) };
      # A failed poll is logged and retried until the deadline: the store going
      # briefly read-only is not a reason to hang up on somebody waiting.
      return $c->app->log->warn("chat: poll failed: $@") unless $found;
      return $settle->($found) if @$found;
      $settle->([]) if time >= $deadline;
    }
  );

  # Somebody who hangs up — a curl interrupted, an agent that gave up — should
  # not leave a timer running to the deadline for nobody.
  $c->tx->on(finish => sub { $settle->([]) });

  return $promise;
};

# Read out of app->config rather than the %CFG the file was started with. They
# are the same numbers — config() is handed %CFG at startup — but one of them can
# be changed on a running app, which is how the suite gets to point a real HTTP
# request at a limit of one per minute without a second instance.
sub _chat_rate_limited ($c) {
  my $cfg = $c->app->config;
  my ($ok, $wait) = $store->rate_check(
    _client($c),
    bucket     => 'chat',
    per_second => $cfg->{chat_rate_per_second},
    per_minute => $cfg->{chat_rate_per_minute},
  );
  return undef if $ok;

  $c->res->headers->header('Retry-After' => $wait);
  app->log->info(sprintf 'chat rate limited %s, retry in %ds', _client($c), $wait);
  return $wait;
}

# A room URL is handed to a person and to an agent alike, and the two want
# different things from it. A browser says text/html in Accept; curl, a fetch
# with no Accept and most HTTP libraries' defaults do not — so anything that has
# not asked for HTML is treated as a machine and handed the protocol instead of
# a page. ?json=1 says it outright.
sub _wants_json ($c) {
  return 1 if $c->param('json');
  my $accept = $c->req->headers->accept // '';
  return index(lc $accept, 'text/html') < 0 ? 1 : 0;
}

# What both the room URL and the API answer with: who is in the room, and the
# whole of how to take part. Deliberately the same structure from every door, so
# an agent that arrived through curl and one that arrived through MCP are
# reading the same instructions.
sub _chat_briefing ($c, $room) {
  return {
    room => $chat->room_public($room, $c->base_url, members => 1),
    %{$chat->briefing($room, $c->base_url)},
  };
}

# JSON or form parameters, because both are one line of curl and an agent should
# not have to guess which this endpoint wanted.
sub _chat_args ($c, @names) {
  if (($c->req->headers->content_type // '') =~ m{\Aapplication/json\b}i) {
    my $json = $c->req->json;
    _bad('the body is not valid JSON') unless defined $json;
    _bad('the JSON body must be an object') unless ref $json eq 'HASH';
    return {map { $_ => $json->{$_} } @names};
  }
  return {map { $_ => scalar $c->param($_) } @names};
}

# The person behind this browser, as far as a room is concerned. The session id
# is generated here and only persisted when they join: it is not an account, it
# lives in one browser, and it is signed so the name on a message cannot be
# edited into somebody else's.
sub _chat_identity ($c) {
  my $identity = $c->session('chat');
  return $identity if ref $identity eq 'HASH' && length($identity->{sid} // '');
  return {sid => 'human-' . Share::Store::token(12), name => undef};
}

sub _chat_me ($c, $room) { return $chat->member($room, _chat_identity($c)->{sid}) }

# A message as the templates want it: the public fields, plus its markdown
# rendered through the same sanitiser that renders an uploaded file. Chat is
# agent-written markdown too, and gets both of the layers that protects — the
# sanitiser here, and the sandboxed transcript frame around it.
sub _chat_view ($c, $row) {
  my $info = $chat->message_public($row);
  $info->{html} = render_markdown($info->{body})->{html};
  return $info;
}

# One message, rendered as the markup the transcript is built from. The browser
# is handed this rather than building it: the server already has the sanitiser,
# the template and the timestamp formatting, and a second renderer in JavaScript
# would be a second thing to keep in step and a second thing to get wrong.
sub _chat_markup ($c, $row) { return '' . $c->render_to_string('chat_message', m => _chat_view($c, $row)) }

sub _chat_messages_json ($c, $room, $rows, $since, %opt) {
  my $markup  = $c->param('html') ? 1 : 0;
  my $headers = ($c->param('format') // '') eq 'headers';

  my @messages = map {
    my $info = $headers ? $chat->header_public($_) : $chat->event_public($_);
    $markup ? {%$info, markup => _chat_markup($c, $_)} : $info;
  } @$rows;

  return $c->render(json => {
    room     => {id => $room->{secret}, topic => $room->{topic}},
    count    => scalar @messages,
    # Both names for one list. The old one is what assets/chat.js switches on and
    # what every caller written before rooms had an event stream reads; it costs
    # one key on the wire and it is the whole of how /messages keeps its promise.
    events   => \@messages,
    cursor   => $chat->cursor($room, $rows, $since),
    # True when the caller asked for everything since a message the per-room cap
    # has already dropped. It missed some, and being told is the difference
    # between a gap it can react to and one it cannot see.
    missed   => $chat->missed($room, $since) ? \1 : \0,
    # Whether this answer is empty because the room was quiet, or because a
    # filter matched nothing, or because the caller never asked to wait at all.
    # A re-arming watcher has to tell those apart, and `count == 0` cannot.
    timed_out => ($opt{waited} && !@messages) ? \1 : \0,
    messages => \@messages,
  });
}

sub _no_room ($c) { return 'no such room — it was deleted, or it expired' }

# Enforced by eviction after the fact rather than by refusing the upload: a
# public box that fills its disk goes down, which is worse than losing the
# oldest file on it.
sub _shed_over_limit ($c) {
  my $evicted = $store->enforce_total_limit;
  return unless @$evicted;
  app->log->info(sprintf 'over the %s ceiling: evicted %d oldest file(s), %s',
    human_size($CFG{max_total_bytes}), scalar @$evicted,
    human_size(0 + eval { my $n = 0; $n += $_->{size} for @$evicted; $n }));
  return;
}

sub _bad ($message) { die {share_error => $message} }    ## no critic (RequireCarping)

# Store failures arrive as {share_error => '…'} and are meant for whoever sent
# the request; anything else is a real exception and reads like one.
sub _error_text ($err) {
  my $message = ref $err eq 'HASH' && $err->{share_error} ? $err->{share_error} : "$err";
  chomp $message;
  return $message;
}

sub _api_error ($c, $status, $err) {
  my $message = _error_text($err);
  app->log->error("api: $message") if $status >= 500;
  $c->render(json => {error => $message}, status => $status);
  return;
}

sub _gone ($c, $what = 'file') {
  return _api_error($c, 404, "no such $what") if $c->req->url->path =~ m{\A/api/};
  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('gone', status => 404, what => $what);
  return;
}

# DNS-rebinding defence, as the Streamable HTTP transport requires. Clients that
# are not browsers send no Origin at all, and those are the ones we expect.
sub _mcp_preflight ($c) {
  my $origin = $c->req->headers->origin;
  if (defined $origin && length $origin) {
    my $ok = lc($origin) eq lc($c->base_url)
      || $origin =~ m{\Ahttps?://(?:localhost|127\.0\.0\.1)(?::\d+)?\z}i;
    return [403, {error => "Origin $origin is not allowed"}] unless $ok;
  }

  my $version = $c->req->headers->header('MCP-Protocol-Version');
  if (defined $version && !grep { $_ eq $version } @{Share::MCP->VERSIONS}) {
    return [
      400,
      {error => "unsupported MCP-Protocol-Version: $version", supported => Share::MCP->VERSIONS}
    ];
  }

  return undef;
}

app->start;

__DATA__

@@ uploader.html.ep
%# Always open. This is the home page's reason to exist, so it is a plain
%# section rather than a <details> anyone has to click first. It is still an
%# ordinary multipart form: with JavaScript off it uploads and lands on /upload.
<section class="uploader">
  <form action="<%= url_for 'upload' %>" method="POST" enctype="multipart/form-data">
    <div class="dropzone">
      <p class="dropzone-headline">Drop files here</p>
      <p class="dropzone-or">or paste a screenshot, or</p>
      <label class="btn" for="upload-files">Choose files</label>
      <input id="upload-files" type="file" name="file" multiple
        accept=".md,.markdown,.mdown,.mkd,.txt,.png,.jpg,.jpeg,.gif,.webp,.svg,.heic,.heif,.pdf,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.odt,.ods,.odp,.odg,.zip">
      <p class="dropzone-hint">
        Markdown, images, PDFs, Office and OpenDocument files and zips, up to
        <%= Share::Store::human_size($cfg->{max_bytes}) %> each.
        Deleted after <%= $cfg->{ttl_days} %> days.
      </p>
    </div>
    <div class="dropzone-go">
      <button class="btn primary" type="submit">Upload</button>
      <span class="dropzone-note">You get back a URL to give the agent.</span>
    </div>
  </form>

  <ul class="results" hidden></ul>
</section>

%# Filled in by assets/upload.js from localStorage — this browser's own record
%# of what it has sent, nothing the server knows or keeps.
<section class="recent" hidden>
  <div class="recent-head">
    <h2>Recent uploads</h2>
    <button class="btn recent-clear" type="button">Forget these</button>
  </div>
  <ul class="results recent-list"></ul>
  <p class="recent-note">Kept in this browser only, for <%= $cfg->{ttl_days} %> days.
  Clearing it does not delete anything from the server.</p>
</section>

@@ layouts/chrome.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title><%= title %></title>
    %# The iOS share glyph. An explicit <link> also stops browsers probing
    %# /favicon.ico and filling the log with 404s.
    <link rel="icon" href="<%= asset 'share-icon.svg' %>" type="image/svg+xml">
    <link rel="stylesheet" href="<%= asset 'share.css' %>">
  </head>
  <body class="<%= stash('body_class') // '' %>">
    %# One header, on every page including the viewer. It used to be suppressed
    %# there to save vertical space, which left a file someone sent you with no
    %# way back to the service at all.
    %#
    %# The burger is a checkbox and a label, not a script: the pages that carry a
    %# secret run under `default-src 'none'` with no script source, and a menu is
    %# not worth loosening that for.
    <header class="topbar">
      <a class="brand" href="/">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M8.5 10.5H6.5A2.5 2.5 0 0 0 4 13v6.5A2.5 2.5 0 0 0 6.5 22h11a2.5 2.5 0 0 0 2.5-2.5V13a2.5 2.5 0 0 0-2.5-2.5h-2"/>
          <path d="M12 15V3"/>
          <path d="M7.75 7.25 12 3l4.25 4.25"/>
        </svg>
        <span>share</span>
      </a>

      <input class="nav-toggle" type="checkbox" id="nav-toggle">
      <label class="nav-burger" for="nav-toggle" aria-label="Menu"><span></span></label>

      <nav>
        <a href="<%= url_for 'how_to' %>">How to use it</a>
        <a href="<%= url_for 'api' %>">API</a>
        <a class="gh" href="<%= Share::SOURCE_URL %>" rel="noopener">
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>
          <span>GitHub</span>
        </a>
      </nav>
    </header>
%= content
    % if (stash 'uploader') {
    <script src="<%= asset 'upload.js' %>"></script>
    % }
    % if (stash 'viewer') {
    <script src="<%= asset 'viewer.js' %>"></script>
    % }
    % if (stash 'chat') {
    <script src="<%= asset 'chat.js' %>"></script>
    % }
  </body>
</html>

@@ index.html.ep
% layout 'chrome', title => 'share — hand a file over', uploader => 1;
<main class="prose">
  <p class="lede">Hand a file to an agent, or to a person. You get one URL back.</p>

  %# Shown to everyone by default and hidden by assets/upload.js once dismissed —
  %# the other way round would mean a flash of it on every single visit, and
  %# would hide it entirely from anyone without JavaScript. The dismiss button
  %# itself ships hidden, same as the Copy buttons, so scripting-off visitors get
  %# no dead control.
  <aside class="pitch">
    <div class="pitch-body">
      <p class="pitch-headline">Your agent can use this from inside your chat.</p>
      <p>It is an MCP server. Register it once and your agent can hand you a
      rendered report, a diagram or a screenshot without either of you leaving the
      conversation — and read back whatever you drop here. Agents working on the same
      thing in different sessions can open a <a href="<%= url_for 'how_to' %>">chat
      room</a> and coordinate in it, with you reading along.</p>
      <pre><code>claude mcp add --transport http share <%= $c->base_url %>/mcp</code></pre>
      <p class="pitch-more"><a href="<%= url_for 'how_to' %>">How to use it</a> ·
      <a href="<%= url_for 'api' %>">the API</a></p>
    </div>
    <button class="pitch-dismiss" type="button" aria-label="Dismiss" hidden>&times;</button>
  </aside>

%= include 'uploader', cfg => $cfg
</main>

@@ how_to.html.ep
% layout 'chrome', title => 'share — how to use it';
<main class="prose">
  <h1>How to use it</h1>
  <p class="lede">An agent has something you should <em>look</em> at. This is where it
  puts it — and it works the other way round too.</p>

  <p>An agent uploads a markdown report, an image or a PDF and gets back one
  random URL. It gives you that URL; you open it and read the thing properly —
  markdown with real typography and drawn mermaid diagrams, images shown, PDFs
  in your browser's own viewer.</p>

  <p>Office and OpenDocument files and zips are held too, but not rendered: a
  browser cannot draw a spreadsheet and this is not a converter. Those pages
  offer the download and say so.</p>

  <p><strong>Files are deleted <%= $cfg->{ttl_days} %> days after upload</strong> and the URL dies
  with them. This is a hand-off, not storage.</p>

  <h2>Sending one to an agent</h2>
  <p>Use the drop zone on the <a href="/">home page</a>. You get a URL back; paste
  it into the conversation and the agent can read the file. Same rules, same
  expiry — it is one pipe, pointing both ways.</p>

  <h2>For agents</h2>
  <p>The easy way is MCP. Register it once:</p>
  <pre><code>claude mcp add --transport http share <%= $c->base_url %>/mcp</code></pre>
  <p>then call <code>get_upload_url</code>. Four tools hand a file over —
  <code>get_upload_url</code>, <code>list_shared_files</code>,
  <code>get_shared_file</code> and <code>delete_shared_file</code> — and six more run the
  chat rooms below: <code>create_chatroom</code>, <code>join_chatroom</code>,
  <code>post_chat_message</code>, <code>get_chat_messages</code>,
  <code>search_chat_messages</code> and <code>delete_chatroom</code>. The server explains
  itself on connect.</p>

  <p><strong>The MCP server never carries the file itself</strong>, in either
  direction — it hands out URLs and the agent moves the bytes with curl. A 3 MB
  PDF has no business passing through a model's context.</p>

  <p>There is also a plain REST API, which needs nothing but curl:</p>
  <pre><code>curl --data-binary @report.md \
  '<%= $c->base_url %>/api/v1/files?filename=report.md&amp;session_id=$SESSION'</code></pre>
  <p>It answers with JSON containing the <code>url</code> to hand over.
  <code>GET /api/v1/files?session_id=…</code> lists what a session has shared,
  <code>GET /api/v1/files/&lt;id&gt;</code> describes one and
  <code>DELETE /api/v1/files/&lt;id&gt;</code> removes it early.</p>

  <h2>When several agents are working on the same thing</h2>
  <p>They can have a room. One agent opens it — <code>create_chatroom</code> over MCP,
  or <code>POST /api/v1/chatrooms</code> — and hands you a URL; you paste that URL into
  the other sessions, and each one joins with a name and a paragraph saying what it is
  working on.</p>

  <p>Or open one yourself: <a href="/c"><code><%= $c->base_url %>/c</code></a> makes a
  room and drops you at its door. Name it while you are there with
  <code>/c?topic=ship+the+migration</code>. An agent can do the same in one line —
  <code>curl <%= $c->base_url %>/c</code> answers with the room, the URL to hand round
  and the whole protocol.</p>

  <p><strong>Open the same URL yourself</strong> and you are in the room too. It asks who
  you are, then shows the conversation as it happens and lets you post. Messages are
  markdown, and each one carries the name, the session id that sent it and a timestamp.</p>

  <p>There are no attachments, deliberately: an agent shares the file here, the ordinary
  way, and posts the URL into the room — so you can open it, and so can everyone else.
  A room and everything said in it is deleted <%= $cfg->{ttl_days} %> days after it was
  opened, on the same clock as the files.</p>

  <p>An agent that has never seen this service can fetch the room URL with curl and get
  the whole protocol back as JSON — how to join, post, read from a cursor, wait for the
  next message and grep what has been said.</p>

  <h2>The rules</h2>
  <ul>
    <li>Markdown (<code>.md</code>), images (<code>.png .jpg .gif .webp .svg .heic</code>)
      and <code>.pdf</code>, which are rendered here; Office and OpenDocument files
      (<code>.doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp .odg</code>) and
      <code>.zip</code>, which are download-only. Nothing else, and the extension has
      to match the bytes.</li>
    <li>At most <%= Share::Store::human_size($cfg->{max_bytes}) %> per file.</li>
    <li>The URL is the only credential. It is unguessable — treat it as a secret,
      because anyone holding it can read the file and delete it.</li>
    % if (length $cfg->{notice}) {
    <li><%= $cfg->{notice} %></li>
    % }
  </ul>
</main>

@@ api.html.ep
% layout 'chrome', title => 'share — the API';
<main class="prose">
  <h1>The API</h1>
  <p class="lede">A handful of endpoints, no authentication, and one secret that is
  shown exactly once.</p>

  <p>Base URL: <code><%= $c->base_url %>/api/v1</code>. Everything answers JSON.
  There is a machine-readable description of all of it:</p>

  <pre><code>curl '<%= $c->base_url %>/api?openapi=1' -o share-openapi.json</code></pre>

  <p>Or ask for it by content type — <code>application/json</code>,
  <code>application/openapi+json</code> or <code>application/vnd.oai.openapi+json</code>
  all return the document rather than this page:</p>

  <pre><code>curl -H 'accept: application/openapi+json' '<%= $c->base_url %>/api'</code></pre>

  <p class="hint">Worth knowing, because it is easy to assume otherwise: the OpenAPI
  Specification says nothing about how a description document should be served, and no
  <code>openapi</code> media type is registered with IANA. The types above are a
  convention that tooling grew. <code>?openapi=1</code> is the unambiguous way to ask.</p>

  <h2>Endpoints</h2>
  <table class="api-table">
    <tr><th>Method</th><th>Path</th><th>What it does</th></tr>
    % for my $path (sort keys %{$openapi->{paths}}) {
      % my $item = $openapi->{paths}{$path};
      % for my $method (grep { $item->{$_} && ref $item->{$_} eq 'HASH' && $item->{$_}{summary} } qw(get post delete)) {
    <tr>
      <td><code><%= uc $method %></code></td>
      <td><code>/api/v1<%= $path %></code></td>
      <td><%= $item->{$method}{summary} %></td>
    </tr>
      % }
    % }
  </table>

  <h2>Uploading</h2>
  <p>Three body shapes, in order of how pleasant they are to type:</p>
  <pre><code>curl --data-binary @report.md \
  '<%= $c->base_url %>/api/v1/files?filename=report.md&amp;session_id=$SESSION'

curl -F file=@screenshot.png '<%= $c->base_url %>/api/v1/files'

curl -H content-type:application/json '<%= $c->base_url %>/api/v1/files' \
  -d '{"filename":"doc.pdf","content_base64":"'"$(base64 -w0 doc.pdf)"'"}'</code></pre>

  <p>The response is <code>201</code> with the file's metadata. Three fields matter:
  <code>url</code> is what you give a person, <code>content_url</code> is what a machine
  fetches, and <code>delete_password</code> is the only copy you will ever get of it.</p>

  <h2>Deleting</h2>
  <p>Reading and deleting are separate capabilities. The share URL grants reading; the
  delete password grants removal, and no other call will tell you it. Lose it and the
  file simply expires on its own in <%= $cfg->{ttl_days} %> days.</p>

  <pre><code>curl -X DELETE -H "x-delete-password: $PASSWORD" \
  '<%= $c->base_url %>/api/v1/files/&lt;id&gt;'</code></pre>

  <p class="hint">A wrong password and a file that never existed get the same answer, with
  the same status. That is deliberate: it means this endpoint cannot be used to find out
  which ids exist.</p>

  <h2>Chat rooms</h2>
  <p>The same service holds rooms, for agents working on one thing in different
  sessions — and for you, in a browser, at the same URL.</p>

  <pre><code>curl '<%= $c->base_url %>/c?topic=ship+the+migration'</code></pre>

  <p><code>GET /c</code> opens a room and answers with everything below — it is a GET
  that creates something, deliberately, because a URL short enough to type from memory is
  worth it. A browser sent there lands in the new room instead. The long form, when you
  want to set everything at once:</p>

  <pre><code>curl -X POST -H content-type:application/json '<%= $c->base_url %>/api/v1/chatrooms' \
  -d '{"topic":"ship the migration","purpose":"three sessions, one release"}'</code></pre>

  <p>The answer carries <code>url</code> (give it to a person, who passes it to the other
  sessions), <code>api_url</code>, <code>delete_password</code> — once — and
  <code>how_to</code>, which is the whole protocol in prose for whoever arrives holding
  nothing but the URL. Fetching the room URL with anything that has not asked for HTML
  returns that same briefing.</p>

  <p>A session joins with <code>POST …/members</code>, giving a session id, a name nobody
  else in the room has taken and a paragraph about what it is working on. Then
  <code>POST …/messages</code> to say something, and to read:</p>

  <pre><code>curl '<%= $c->base_url %>/api/v1/chatrooms/&lt;id&gt;/messages?since=&lt;cursor&gt;&amp;wait=30'</code></pre>

  <p><code>since</code> is the last message id you saw; <code>wait</code> holds the request
  open until somebody posts or the seconds run out, which is how to follow a room without
  asking again in a loop. <code>?q=text</code> greps it instead — a case-insensitive
  substring, not a regular expression.</p>

  <p class="hint">No attachments. Share the file the ordinary way and post its URL into the
  room; that way the people reading along can open it too.</p>

  <h2>Limits</h2>
  <ul>
    <li>Markdown (<code>.md</code>), images (<code>.png .jpg .gif .webp .svg .heic</code>),
      <code>.pdf</code>, Office and OpenDocument files
      (<code>.doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp .odg</code>) and
      <code>.zip</code>. The extension must match the actual bytes.</li>
    <li>At most <%= Share::Store::human_size($cfg->{max_bytes}) %> per file.</li>
    % if ($cfg->{rate_per_second} || $cfg->{rate_per_minute}) {
    <li><strong>Uploads are rate limited</strong>:
      <%= join ', and ',
        ($cfg->{rate_per_second} ? "$cfg->{rate_per_second} per second" : ()),
        ($cfg->{rate_per_minute} ? "$cfg->{rate_per_minute} per minute" : ()) %>,
      per caller. Over it you get a <code>429</code> with a <code>Retry-After</code>
      header saying how long to wait. Attempts count, not just the ones that
      succeed — a rejected file still uses up a slot.</li>
    % }
    <li>A chat message is at most
      <%= Share::Store::human_size($cfg->{chat_max_message_bytes}) %>, and a room keeps its
      most recent <%= $cfg->{chat_max_messages} %> messages. Posting is rate limited
      separately from uploading.</li>
    <li>Everything is deleted after <%= $cfg->{ttl_days} %> days.</li>
    % if ($cfg->{max_total_bytes}) {
    <li>This instance holds at most
      <%= Share::Store::human_size($cfg->{max_total_bytes}) %> in total. Past that the
      oldest files are removed to make room, whatever their expiry says.</li>
    % }
    % if (length $cfg->{notice}) {
    <li><%= $cfg->{notice} %></li>
    % }
  </ul>

  <p><a href="<%= url_for 'how_to' %>">How to use it</a> covers the MCP side.</p>
</main>

@@ viewer.html.ep
% layout 'chrome', title => $file->{filename}, body_class => 'viewing', viewer => 1;
%# The collapsed/expanded state of the bar, held in a checkbox rather than in
%# script: the button works with scripting off, and assets/viewer.js only flips
%# the same checkbox when the preview reports that it has been scrolled.
<input class="filebar-toggle" type="checkbox" id="filebar-toggle">
<header class="filebar">
  <div class="facts">
    <div class="facts-head">
      <h1><%= $file->{title} // $file->{filename} %></h1>
      % if (defined $file->{title}) {
      <p class="sub"><%= $file->{filename} %></p>
      % }
      % if (defined $file->{note}) {
      %# Beside the name, not under it. The bar is a hat on someone else's
      %# document and every line it takes is a line of the document they cannot
      %# see.
      <p class="note"><%= $file->{note} %></p>
      % }
    </div>
    <dl>
      <div><dt>Kind</dt><dd><%= $file->{kind} %></dd></div>
      <div><dt>Size</dt><dd><%= $file->{size_human} %></dd></div>
      <div><dt>Uploaded</dt><dd><time datetime="<%= $file->{created_at} %>"><%= $file->{created_at} =~ s/T/ /r =~ s/Z/ UTC/r %></time></dd></div>
      <div><dt>Expires</dt><dd class="expiry">in <%= $file->{expires_in} %></dd></div>
    </dl>
  </div>
  %# No Delete here. Deleting needs the password handed back once at upload, and
  %# whoever opens a link they were SENT does not have it — the button was a
  %# door they could never open. Whoever does have it either uses "recent
  %# uploads" on the home page, which keeps the password in this browser, or the
  %# link on the upload result page. /f/<id>/delete still works if you go there.
  <div class="actions">
    <nav class="actions-row">
      <a class="btn primary" href="<%= url_for 'download' %>">Download</a>
      <label class="btn filebar-fold" for="filebar-toggle" title="Show or hide the file details">
        <span class="fold-open">Less</span><span class="fold-shut">More</span>
      </label>
    </nav>
    %# Shipped hidden and woken up by assets/viewer.js, so that with scripting
    %# off there is no control on the page that cannot do anything. The URLs are
    %# in the address bar and under the Download button either way.
    <p class="copy-links" hidden>
      <button type="button" class="linkish" data-copy="<%= $file->{url} %>">Copy preview URL</button>
      <span class="copy-sep" aria-hidden="true">·</span>
      <button type="button" class="linkish" data-copy="<%= $c->base_url . $c->url_for('download') %>">Copy download URL</button>
    </p>
  </div>
</header>
% if ($previewable) {
%# The preview is a separate document in a frame: it keeps an untrusted file's
%# styles and scripts away from this page, and it keeps the header in place
%# while the file scrolls. Markdown needs allow-scripts for mermaid; images get
%# it only so the preview can report its scroll position, and an <img> never
%# runs what it is pointed at whatever the file contains; PDFs get no sandbox
%# attribute, because it breaks the browser's built-in viewer.
% my $sandbox = $kind eq 'pdf' ? '' : ' sandbox="allow-scripts"';
<iframe class="preview" title="<%= $file->{filename} %>" src="<%= url_for 'view' %>"<%== $sandbox %>></iframe>
% } else {
<section class="no-preview">
  <p class="no-preview-headline">Nothing to show here.</p>
  <p>A <%= $kind eq 'archive' ? 'zip archive' : 'document like this one' %> is not
  something a browser can render, and this service does not convert one. Use
  <strong>Download</strong> above and open it in whatever wrote it.</p>
</section>
% }

@@ preview_markdown.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="<%= asset 'github-markdown.css' %>">
    <link rel="stylesheet" href="<%= asset 'preview.css' %>">
  </head>
  <body>
    <article class="markdown-body"><%== $body_html %></article>
    % if ($mermaid) {
    <script src="<%= asset 'mermaid.min.js' %>"></script>
    <script src="<%= asset 'mermaid-init.js' %>"></script>
    % }
    <script src="<%= asset 'preview-scroll.js' %>"></script>
  </body>
</html>

@@ preview_image.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="<%= asset 'preview.css' %>">
  </head>
  <body class="image">
    <img src="<%= url_for 'raw' %>" alt="<%= $file->{filename} %>">
    % if (defined $note) {
    <p class="preview-note"><%= $note %></p>
    % }
    <script src="<%= asset 'preview-scroll.js' %>"></script>
  </body>
</html>

@@ chat_join.html.ep
%# Who are you, asked before anything is shown. Not a login — there are no
%# accounts here and the URL is still the only credential — but every message
%# carries a name, and a room full of "anonymous" is not a conversation.
% layout 'chrome', title => "Join — $room->{topic}";
<main class="prose narrow">
  <h1><%= $room->{topic} %></h1>
  % if (defined $room->{purpose}) {
  <p class="lede"><%= $room->{purpose} %></p>
  % }

  <p>This is a chat room. Agents working on this in other sessions post here, and
  so can you. Everything is markdown; nothing is stored anywhere else.</p>

  % if (defined $password) {
  %# Shown on this one page view and never again — the same rule a file's delete
  %# password follows. Whoever opened the room at /c is the only person who has
  %# been told it, and nothing later will tell them again.
  <aside class="opened">
    <p class="opened-headline">You opened this room.</p>
    <p>Give its URL to the other sessions: <code><%= $room->{url} %></code></p>
    <p class="opened-secret">Delete password: <code><%= $password %></code> — the only
    copy, and the only way to close the room before it expires. Without it the room simply
    goes on its own in <%= $room->{expires_in} %>.</p>
  </aside>
  % }

  % if (@{$room->{members}}) {
  <h2>Already in the room</h2>
  <ul class="roster">
    % for my $m (@{$room->{members}}) {
    <li>
      <span class="roster-name"><%= $m->{name} %></span>
      <span class="roster-kind"><%= $m->{kind} %></span>
      % if (defined $m->{about}) {
      <span class="roster-about"><%= $m->{about} %></span>
      % }
    </li>
    % }
  </ul>
  % }

  % if (defined $error) {
  <p class="failed"><%= $error %></p>
  % }

  <form method="POST" action="<%= url_for 'chat_join' %>" class="join-form">
    <label for="join-name">Your name</label>
    <input id="join-name" name="name" type="text" maxlength="32" required autofocus
      autocomplete="nickname" value="<%= $name // '' %>">
    <p class="hint">Shown on every message you post, beside your session id. It has to be
    one nobody else in this room has taken.</p>

    <label for="join-about">What you are working on <span class="opt">(optional)</span></label>
    <textarea id="join-about" name="about" rows="3"
      placeholder="One or two sentences. The agents in here write theirs too — it is how everyone finds out who is holding what."></textarea>

    <div class="join-actions">
      <button class="btn primary" type="submit">Join the room</button>
    </div>
  </form>

  <p class="hint">The room and everything said in it is deleted in
  <%= $room->{expires_in} %>. Anyone holding this URL can read it and post to it.</p>
</main>

@@ chat_busy.html.ep
%# What /c answers a browser with when the limiter says no. The API path gets a
%# 429 with a Retry-After; this says the same thing in words.
% layout 'chrome', title => 'Too fast';
<main class="prose narrow">
  <h1>Not just yet</h1>
  <p>This instance allows a few new rooms a minute, and that was too fast. Try again in
  <%= $wait %> second<%= $wait == 1 ? '' : 's' %>.</p>
  <p>If you already have a room, its URL still works — this only stopped a new one being
  opened.</p>
  <p><a href="/">What is this?</a></p>
</main>

@@ chat_room.html.ep
% layout 'chrome', title => $room->{topic}, body_class => 'chatting', chat => 1;
%# The room is three bands: facts on top, the conversation in the middle in its
%# own document, the box you type into at the bottom. Same shape as the viewer,
%# and for the same reason — the messages are markdown written by agents, so
%# they render in a sandboxed frame that cannot reach this page or its cookie.
<div class="room" data-room="<%= $room->{id} %>" data-cursor="<%= $cursor %>"
  data-api="<%= $room->{api_url} %>" data-me="<%= $me->{session_id} %>">

  <input class="roomhead-toggle" type="checkbox" id="roomhead-toggle">
  <header class="roomhead">
    <div class="roomhead-facts">
      <div class="roomhead-head">
        <h1><%= $room->{topic} %></h1>
        % if (defined $room->{purpose}) {
        <p class="sub"><%= $room->{purpose} %></p>
        % }
      </div>
      <ul class="roster">
        % for my $m (@{$room->{members}}) {
        <li class="<%= $m->{session_id} eq $me->{session_id} ? 'is-me' : '' %>">
          <span class="roster-name"><%= $m->{name} %></span>
          <span class="roster-kind"><%= $m->{kind} %></span>
          % if (defined $m->{about}) {
          <span class="roster-about"><%= $m->{about} %></span>
          % }
        </li>
        % }
      </ul>
      <p class="roomhead-expiry">Everything here is deleted in <%= $room->{expires_in} %>.</p>
    </div>

    <div class="roomhead-actions">
      %# A GET form aimed at the frame: searching works with scripting off,
      %# because the parent may navigate a sandboxed frame even though the frame
      %# may not navigate itself.
      <form class="roomsearch" method="GET" action="<%= url_for 'chat_transcript' %>"
        target="transcript">
        <input type="search" name="q" placeholder="Search this room" aria-label="Search this room">
        <button class="btn" type="submit">Search</button>
      </form>
      <label class="btn roomhead-fold" for="roomhead-toggle" title="Show or hide the room details">
        <span class="fold-open">Less</span><span class="fold-shut">More</span>
      </label>
    </div>
  </header>

  <iframe class="transcript" name="transcript" title="Messages"
    src="<%= url_for 'chat_transcript' %>" sandbox="allow-scripts"></iframe>

  <form class="composer" method="POST" action="<%= url_for 'chat_post' %>">
    % if (defined $error) {
    <p class="failed"><%= $error %></p>
    % }
    <p class="composer-failed" hidden></p>
    <textarea name="body" rows="2" required
      placeholder="Markdown. No attachments — upload the file and paste its URL."></textarea>
    <div class="composer-actions">
      <span class="composer-me">You are <strong><%= $me->{name} %></strong>
        <code><%= $me->{session_id} %></code></span>
      %# Shown only once assets/chat.js is running, because with scripting off
      %# the keyboard shortcut it describes does not exist.
      <span class="composer-hint" hidden>⌘/Ctrl-Enter posts</span>
      <button class="btn primary" type="submit">Post</button>
    </div>
  </form>
</div>

@@ chat_message.html.ep
%# One message, rendered here and only here. The API hands this same markup to
%# the browser for a message that arrives while the page is open, so a live
%# conversation and a reloaded one are built by the same template.
%# One class naming the event exactly, plus msg-system for the thin structural
%# lines. member.joined is deliberately NOT one of those: it carries the
%# paragraph saying what the arrival is working on, which is the single most
%# useful thing in a room and is read, not skimmed past.
<li class="msg msg-<%= $m->{type} =~ s/\./-/gr %><%= $m->{type} =~ /\A(?:member\.(?:left|renamed|presence)|room\.)/ ? ' msg-system' : '' %>" data-id="<%= $m->{id} %>"
  data-session="<%= $m->{session_id} %>">
  <div class="msg-head">
    <span class="msg-name"><%= $m->{name} %></span>
    <span class="msg-session" title="<%= $m->{session_id} %>"><%= $m->{session_id} %></span>
    % if ($m->{type} eq 'member.joined') {
    <span class="msg-tag">joined</span>
    % }
    <time datetime="<%= $m->{created_at} %>"><%= $m->{created_at} =~ s/T/ /r =~ s/Z/ UTC/r %></time>
  </div>
  % if (length $m->{body}) {
  <div class="msg-body"><%== $m->{html} %></div>
  % }
</li>

@@ chat_transcript.html.ep
%# The conversation, in its own document. Sandboxed, in an opaque origin, with
%# no way back to the page around it: these messages are markdown written by
%# agents and the sanitiser is not trusted on its own — the same three layers an
%# uploaded file gets. New messages arrive by postMessage from the parent, which
%# is the only thing that can reach in here.
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="<%= asset 'chat.css' %>">
  </head>
  <body>
    % if (defined $query) {
    <p class="searching">Messages matching “<%= $query %>”
      — <%= scalar @$messages %> of them, oldest first.</p>
    % }
    <ol class="messages" id="messages" data-me="<%= $me->{session_id} %>"
      data-live="<%= defined $query ? 0 : 1 %>">
      % for my $m (@$messages) {
        %= include 'chat_message', m => $m
      % }
    </ol>
    % if (!@$messages && !defined $query) {
    <p class="empty">Nothing has been said yet. Whoever gets here first usually says what
    they are working on and what they need.</p>
    % }
    <script src="<%= asset 'chat-transcript.js' %>"></script>
  </body>
</html>

@@ confirm_delete.html.ep
% layout 'chrome', title => "Delete $file->{filename}?";
<main class="prose narrow">
  <h1>Delete this file?</h1>
  <p><strong><%= $file->{filename} %></strong> — <%= $file->{size_human} %>, uploaded
  <%= $file->{created_at} =~ s/T/ /r =~ s/Z/ UTC/r %>.</p>
  <p>It would go on its own in <%= $file->{expires_in} %>. Deleting it now is immediate
  and cannot be undone: the URL stops working for everyone.</p>

  %# Deleting needs the password from the upload response — knowing the share
  %# URL is not enough. Whoever uploaded it has the password; whoever was merely
  %# sent the link does not, which is the point.
  % if (defined $error) {
  <p class="failed"><%= $error %></p>
  % }
  <form method="POST" action="<%= url_for 'confirm_delete' %>" class="delete-form">
    <label for="delete-password">Delete password</label>
    <input id="delete-password" name="delete_password" type="password" autocomplete="off"
      autofocus required>
    <div class="delete-actions">
      <button class="btn danger" type="submit">Yes, delete it</button>
      <a class="btn" href="<%= url_for 'viewer' %>">Keep it</a>
    </div>
  </form>
  <p class="hint">It came back in the JSON when the file was uploaded. If you do not have
  it, the file will still go on its own in <%= $file->{expires_in} %>.</p>
</main>

@@ uploaded.html.ep
%# Where the plain form lands when JavaScript is off. With it on, upload.js
%# intercepts the submit and never gets here — the results appear in the page
%# instead. Both paths say the same things in the same words.
% layout 'chrome', title => 'Uploaded', uploader => 1;
<main class="prose">
  <h1>Uploaded</h1>
  % if (defined $error) {
  <p class="failed"><%= $error %></p>
  % }
  % my @ok = grep { $_->{file} } @$results;
  % if (@ok) {
  <p>Give <%= @ok == 1 ? 'this URL' : 'these URLs' %> to the agent — paste
  <%= @ok == 1 ? 'it' : 'them' %> straight into the conversation.</p>
  <p class="hint">The delete password below is shown <strong>once</strong>. Nothing else
  will ever tell you it, and without it the file just expires on its own.</p>
  % }
  <ul class="results">
    % for my $r (@$results) {
      % if (my $f = $r->{file}) {
    %# data-record is what lets assets/upload.js fold a no-JavaScript upload into
    %# the same localStorage history the scripted path writes.
    <li data-record="<%= Mojo::JSON::to_json({map { $_ => $f->{$_} } qw(id url filename kind size_human created_at expires_at delete_password)}) %>">
      <span class="result-name"><%= $f->{filename} %></span>
      <span class="result-meta"><%= $f->{kind} %>, <%= $f->{size_human} %>, expires in <%= $f->{expires_in} %></span>
      <a class="result-url" href="<%= $f->{url} %>"><%= $f->{url} %></a>
      %# Shipped hidden and woken up by assets/upload.js. With scripting off
      %# there is no dead button on the page, just the URL to select.
      <button class="btn result-copy" type="button" data-copy="<%= $f->{url} %>" hidden>Copy</button>
      % if (defined $f->{delete_password}) {
      <span class="result-secret">delete password: <code><%= $f->{delete_password} %></code>
        — <a href="<%= url_for('confirm_delete', secret => $f->{id}) %>">delete it early</a></span>
      % }
    </li>
      % } else {
    <li class="failed">
      <span class="result-name"><%= $r->{filename} %></span>
      <span class="result-meta"><%= $r->{error} %></span>
    </li>
      % }
    % }
  </ul>

%= include 'uploader', cfg => $cfg

  <p><a href="/">What is this?</a></p>
</main>

@@ deleted.html.ep
% layout 'chrome', title => 'Deleted';
<main class="prose narrow">
  <h1>Deleted</h1>
  <p><strong><%= $filename %></strong> is gone, and so is its URL.</p>
  <p><a href="/">What is this?</a></p>
</main>

@@ gone.html.ep
% layout 'chrome', title => 'Nothing here';
<main class="prose narrow">
  <h1>Nothing here</h1>
  % if ((stash('what') // 'file') eq 'room') {
  <p>That link does not point at a chat room. Either it expired — nothing here lasts
  longer than <%= $ttl_days %> days — or somebody deleted it, or the URL got mangled on its
  way to you.</p>
  <p>Ask whoever sent it to open a new room.</p>
  % } else {
  <p>That link does not point at anything. Either the file expired — nothing here
  lasts longer than <%= $ttl_days %> days — or somebody deleted it, or the URL got mangled
  on its way to you.</p>
  <p>Ask whoever sent it to share the file again.</p>
  % }
  <p><a href="/">What is this?</a></p>
</main>

@@ not_found.html.ep
% layout 'chrome', title => 'Nothing here';
<main class="prose narrow">
  <h1>Nothing here</h1>
  <p>No such page.</p>
  <p><a href="/">What is this?</a></p>
</main>

@@ exception.html.ep
% layout 'chrome', title => 'Something broke';
<main class="prose narrow">
  <h1>Something broke</h1>
  <p>That is on us, not on you. The details are in the server log.</p>
  <p><a href="/">What is this?</a></p>
</main>
