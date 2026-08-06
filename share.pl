#!/usr/bin/env perl

# share — hand a file from an agent to a human.
#
# An agent uploads a markdown report, an image or a PDF and gets back one random
# URL. It gives that URL to a person, who opens it in a browser and reads the
# thing properly. Fifteen days later the file is gone and so is the URL.
#
# Four faces on the same app:
#
#   /            an explanation, for whoever lands here by accident
#   /f/<id>      the human's page: a header of facts, the file rendered below
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
use Mojo::Util    qw(decode url_escape);
use Share::MCP     ();
use Share::OpenAPI qw(openapi_type);
use Share::Render qw(render_markdown);
use Share::Store  qw(human_size payload_bytes);

our $VERSION = '1.1.0';

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
  max_total_bytes => defined $ENV{SHARE_MAX_TOTAL_BYTES}
  ? 0 + $ENV{SHARE_MAX_TOTAL_BYTES}
  : 50 * 1024 * 1024 * 1024,
  rate_per_second => defined $ENV{SHARE_RATE_PER_SECOND} ? 0 + $ENV{SHARE_RATE_PER_SECOND} : 1,
  rate_per_minute => defined $ENV{SHARE_RATE_PER_MINUTE} ? 0 + $ENV{SHARE_RATE_PER_MINUTE} : 10,

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
);

sub _decoded ($value) {
  return '' unless defined $value && length $value;
  return decode('UTF-8', $value) // $value;
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
  root             => $CFG{root},
  max_bytes        => $CFG{max_bytes},
  default_ttl_days => $CFG{ttl_days},
  max_ttl_days     => $CFG{ttl_days},
  max_total_bytes  => $CFG{max_total_bytes},
  rate_per_second  => $CFG{rate_per_second},
  rate_per_minute  => $CFG{rate_per_minute},
)->init;

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
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1));
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
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1));

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

# The human's page: a header of facts and buttons, and the file itself in a
# frame below — so an untrusted document cannot reach the chrome, and so the
# facts stay put while the file scrolls.
get '/f/<secret:id>' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $store->touch($row);

  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('viewer', file => $store->public($row, $c->base_url), kind => $row->{kind});
} => 'viewer';

# The framed preview. Everything about this response assumes the document is
# hostile: the per-kind CSP below, and the sandbox attribute on the iframe.
get '/f/<secret:id>/view' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  $c->secret_headers;

  my $origin = $c->base_url;

  # Hand PDFs to the browser's own viewer. It is better than anything we would
  # build, and the browser already sandboxes it.
  return $c->redirect_to($c->url_for('raw')) if $row->{kind} eq 'pdf';

  if ($row->{kind} eq 'image') {
    $c->res->headers->header('Content-Security-Policy' => join '; ',
      "default-src 'none'", "img-src $origin", "style-src $origin",
      "frame-ancestors $origin", "base-uri 'none'");
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

# Every page that carries a secret runs with no script source at all. The two
# pages that hold the uploader are the exceptions, and they ask for it by name —
# `scripts => 1` — rather than the whole app being loosened to suit two routes.
sub _chrome_csp (%opt) {
  my @csp = (
    "default-src 'none'", "style-src 'self'", "img-src 'self' data:",
    "frame-src 'self'",   "form-action 'self'", "frame-ancestors 'none'",
    "base-uri 'none'",
  );
  push @csp, "script-src 'self'", "connect-src 'self'" if $opt{scripts};
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

sub _gone ($c) {
  return _api_error($c, 404, 'no such file') if $c->req->url->path =~ m{\A/api/};
  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('gone', status => 404);
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
        accept=".md,.markdown,.mdown,.mkd,.txt,.png,.jpg,.jpeg,.gif,.webp,.svg,.heic,.heif,.pdf">
      <p class="dropzone-hint">
        Markdown, images and PDFs, up to <%= Share::Store::human_size($cfg->{max_bytes}) %> each.
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
      conversation — and read back whatever you drop here.</p>
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

  <p><strong>Files are deleted <%= $cfg->{ttl_days} %> days after upload</strong> and the URL dies
  with them. This is a hand-off, not storage.</p>

  <h2>Sending one to an agent</h2>
  <p>Use the drop zone on the <a href="/">home page</a>. You get a URL back; paste
  it into the conversation and the agent can read the file. Same rules, same
  expiry — it is one pipe, pointing both ways.</p>

  <h2>For agents</h2>
  <p>The easy way is MCP. Register it once:</p>
  <pre><code>claude mcp add --transport http share <%= $c->base_url %>/mcp</code></pre>
  <p>then call <code>get_upload_url</code>. The tools are
  <code>get_upload_url</code>, <code>list_shared_files</code>,
  <code>get_shared_file</code> and <code>delete_shared_file</code>, and the
  server explains itself on connect.</p>

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

  <h2>The rules</h2>
  <ul>
    <li>Markdown (<code>.md</code>), images (<code>.png .jpg .gif .webp .svg .heic</code>)
      and <code>.pdf</code>. Nothing else, and the extension has to match the bytes.</li>
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

  <h2>Limits</h2>
  <ul>
    <li>Markdown (<code>.md</code>), images (<code>.png .jpg .gif .webp .svg .heic</code>)
      and <code>.pdf</code>. The extension must match the actual bytes.</li>
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
% layout 'chrome', title => $file->{filename}, body_class => 'viewing';
<header class="filebar">
  <div class="facts">
    <h1><%= $file->{title} // $file->{filename} %></h1>
    % if (defined $file->{title}) {
    <p class="sub"><%= $file->{filename} %></p>
    % }
    % if (defined $file->{note}) {
    <p class="note"><%= $file->{note} %></p>
    % }
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
  <nav class="actions">
    <a class="btn primary" href="<%= url_for 'download' %>">Download</a>
  </nav>
</header>
%# The preview is a separate document in a frame: it keeps an untrusted file's
%# styles and scripts away from this page, and it keeps the header in place
%# while the file scrolls. Markdown needs allow-scripts for mermaid; images need
%# nothing at all; PDFs get no sandbox attribute, because it breaks the
%# browser's built-in viewer.
% my $sandbox = $kind eq 'pdf' ? '' : $kind eq 'markdown' ? ' sandbox="allow-scripts"' : ' sandbox=""';
<iframe class="preview" title="<%= $file->{filename} %>" src="<%= url_for 'view' %>"<%== $sandbox %>></iframe>

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
  <p>That link does not point at anything. Either the file expired — nothing here
  lasts longer than <%= $ttl_days %> days — or somebody deleted it, or the URL got mangled
  on its way to you.</p>
  <p>Ask whoever sent it to share the file again.</p>
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
