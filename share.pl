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

use Mojo::IOLoop  ();
use Mojo::Util    qw(decode url_escape);
use Share::MCP    ();
use Share::Render qw(render_markdown);
use Share::Store  qw(human_size payload_bytes);

our $VERSION = '1.0.0';

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
)->init;

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

# ------------------------------------------------------------------ pages ----

get '/' => sub ($c) {
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp(scripts => 1));
  $c->render('index', stats => $store->stats, cfg => \%CFG);
} => 'index';

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
      : {file     => $store->public($row, $c->base_url)};
  }

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
  $c->render('confirm_delete', file => $store->public($row, $c->base_url));
} => 'confirm_delete';

post '/f/<secret:id>/delete' => sub ($c) {
  my $row = $store->find($c->stash('secret')) or return _gone($c);
  my $filename = $row->{filename};
  $store->remove($row->{secret});

  $c->secret_headers;
  $c->res->headers->header('Content-Security-Policy' => _chrome_csp());
  $c->render('deleted', filename => $filename);
};

# ------------------------------------------------------------------- API -----
#
# This `under` is the seam. If authentication is ever needed it goes here and
# nowhere else; no route below assumes anonymity.

my $api = app->routes->under('/api/v1' => sub ($c) {1});

$api->get('/health' => sub ($c) {
  my $stats = $store->stats;
  $c->render(json =>
      {status => 'ok', version => $VERSION, files => $stats->{files}, bytes => $stats->{bytes}});
});

$api->post('/files' => sub ($c) {
  my $args = eval { _upload_args($c) };
  return _api_error($c, 400, $@) if $@;

  my $row = eval { $store->add(%$args) };
  return _api_error($c, 400, $@) if $@;

  my $info = $store->public($row, $c->base_url);
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

$api->delete('/files/<secret:id>' => sub ($c) {
  return _api_error($c, 404, 'no such file') unless $store->remove($c->stash('secret'));
  $c->render(json => {deleted => $c->stash('secret')});
});

# ------------------------------------------------------------------- MCP -----

post '/mcp' => sub ($c) {
  if (my $err = _mcp_preflight($c)) { return $c->render(json => $err->[1], status => $err->[0]) }

  my $msg = eval { $c->req->json };
  return $c->render(
    status => 400,
    json   => {jsonrpc => '2.0', id => undef, error => {code => -32700, message => 'invalid JSON'}})
    unless defined $msg;

  # Batches were dropped in 2025-06-18, but older clients still send them and
  # answering one costs nothing.
  if (ref $msg eq 'ARRAY') {
    my @out = grep { defined } map { Share::MCP->respond($c, $_) } @$msg;
    return @out ? $c->render(json => \@out) : $c->rendered(202);
  }

  my $res = Share::MCP->respond($c, $msg);
  return $c->rendered(202) unless defined $res;    # a notification: nothing to say
  $c->render(json => $res);
};

# We hold no per-client state, so there is no server-initiated stream to open
# and no session to delete. The transport spec's answer to both is 405.
any [qw(GET DELETE)] => '/mcp' => sub ($c) {
  $c->res->headers->allow('POST');
  $c->render(status => 405, json => {error => 'this MCP endpoint only accepts POST'});
};

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
    <link rel="icon" href="/assets/share-icon.svg" type="image/svg+xml">
    <link rel="stylesheet" href="/assets/share.css">
  </head>
  <body class="<%= stash('body_class') // '' %>">
%= content
    % if (stash 'uploader') {
    <script src="/assets/upload.js"></script>
    % }
  </body>
</html>

@@ uploader.html.ep
%# The button IS the disclosure control: <details>/<summary> expands the box in
%# place with no navigation and no JavaScript. assets/upload.js then upgrades the
%# form inside it — drag-and-drop, paste, progress, inline results — without
%# changing what happens when scripting is off.
<details class="uploader">
  <summary class="btn primary">Share a file with an agent</summary>

  <form action="<%= url_for 'upload' %>" method="POST" enctype="multipart/form-data">
    <div class="dropzone">
      <p class="dropzone-headline">Drop files here</p>
      <p class="dropzone-or">or paste a screenshot, or</p>
      <label class="btn" for="upload-files">Choose files</label>
      <input id="upload-files" type="file" name="file" multiple
        accept=".md,.markdown,.mdown,.mkd,.txt,.png,.jpg,.jpeg,.gif,.webp,.svg,.pdf">
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
</details>

@@ index.html.ep
% layout 'chrome', title => 'share — hand a file to a human', uploader => 1;
<main class="prose">
  <h1>share</h1>
  <p class="lede">An agent has something you should <em>look</em> at. This is where it puts it.
  It works the other way round too.</p>

%= include 'uploader', cfg => $cfg

  <p>An agent uploads a markdown report, an image or a PDF and gets back one
  random URL. It gives you that URL; you open it and read the thing properly —
  markdown with real typography and drawn mermaid diagrams, images shown, PDFs
  in your browser's own viewer.</p>

  <p><strong>Files are deleted <%= $cfg->{ttl_days} %> days after upload</strong> and the URL dies
  with them. This is a hand-off, not storage. Right now it is holding
  <%= $stats->{files} %> file<%= $stats->{files} == 1 ? '' : 's' %>.</p>

  <h2>Sending one the other way</h2>
  <p>Use the button above. You get a URL back; paste it into the conversation and
  the agent can read the file with <code>get_shared_file</code>, or just fetch
  the URL. Same rules, same expiry — it is one pipe, pointing both ways.</p>

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
    <li>Markdown (<code>.md</code>), images (<code>.png .jpg .gif .webp .svg</code>)
      and <code>.pdf</code>. Nothing else, and the extension has to match the bytes.</li>
    <li>At most <%= Share::Store::human_size($cfg->{max_bytes}) %> per file.</li>
    <li>The URL is the only credential. It is unguessable — treat it as a secret,
      because anyone holding it can read the file and delete it.</li>
    % if (length $cfg->{notice}) {
    <li><%= $cfg->{notice} %></li>
    % }
  </ul>
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
  <nav class="actions">
    <a class="btn primary" href="<%= url_for 'download' %>">Download</a>
    <a class="btn danger" href="<%= url_for 'confirm_delete' %>">Delete</a>
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
    <link rel="stylesheet" href="/assets/github-markdown.css">
    <link rel="stylesheet" href="/assets/preview.css">
  </head>
  <body>
    <article class="markdown-body"><%== $body_html %></article>
    % if ($mermaid) {
    <script src="/assets/mermaid.min.js"></script>
    <script src="/assets/mermaid-init.js"></script>
    % }
  </body>
</html>

@@ preview_image.html.ep
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <link rel="stylesheet" href="/assets/preview.css">
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
  <form method="POST" action="<%= url_for 'confirm_delete' %>">
    <button class="btn danger" type="submit">Yes, delete it</button>
    <a class="btn" href="<%= url_for 'viewer' %>">Keep it</a>
  </form>
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
  % }
  <ul class="results">
    % for my $r (@$results) {
      % if (my $f = $r->{file}) {
    <li>
      <span class="result-name"><%= $f->{filename} %></span>
      <span class="result-meta"><%= $f->{kind} %>, <%= $f->{size_human} %>, expires in <%= $f->{expires_in} %></span>
      <a class="result-url" href="<%= $f->{url} %>"><%= $f->{url} %></a>
      %# Shipped hidden and woken up by assets/upload.js. With scripting off
      %# there is no dead button on the page, just the URL to select.
      <button class="btn result-copy" type="button" data-copy="<%= $f->{url} %>" hidden>Copy</button>
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
