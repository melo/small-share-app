#!/usr/bin/env perl

# The build runs this before assembling the runtime image, so a broken
# sanitiser, a broken upload path or a broken MCP handshake never gets deployed.
#
# Run it by hand with:  cd app && SHARE_ROOT=$(mktemp -d) prove -lv t/share.t

use Mojo::Base -strict, -signatures;
use utf8;

use File::Temp   ();
use Mojo::File   qw(curfile);
# from_json, not decode_json, for anything read out of an MCP result: those
# fields have already been decoded from the response, so they are characters.
# decode_json expects BYTES and dies with "Wide character" on the first
# non-ASCII one — which is a landmine that only goes off once a filename or a
# note happens to contain an em-dash.
use Mojo::JSON   qw(encode_json from_json to_json);
use Mojo::URL    ();
use Mojo::Util   qw(b64_encode);
use Test::Mojo   ();
use Test::More;

my $tmp = File::Temp->newdir;
$ENV{SHARE_ROOT}     = "$tmp";
$ENV{SHARE_BASE_URL} = 'https://share.example.test';
# Deliberately non-ASCII: %ENV is bytes, and this is the one setting a human
# writes prose into. Left undecoded by the app it renders as "â€”" on the page
# and in the MCP instructions alike.
#
# Spelled out as literal UTF-8 bytes, which is what a shell or a compose file
# hands over. Do NOT write the character here and utf8::encode it: assigning a
# wide character to %ENV latin-1-encodes it on the way in, so that route stores
# already-double-encoded bytes and tests the wrong thing.
$ENV{SHARE_NOTICE} = "Office network only \xe2\x80\x94 ask #infra for access.";
delete $ENV{SHARE_TTL_DAYS};

my $t = Test::Mojo->new(curfile->dirname->sibling('share.pl'));

my $SESSION = 'session-under-test';

# 1x1 transparent PNG.
my $PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
  . 'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

# The smallest thing that is unambiguously a PDF.
my $PDF_B64 = b64_encode("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n", '');

# One MCP call, unwrapped. The suite makes a lot of these and the JSON-RPC
# envelope adds nothing to a test's meaning.
sub _mcp ($method, $params = undef) {
  state $id = 1000;
  $t->post_ok('/mcp' => json =>
      {jsonrpc => '2.0', id => ++$id, method => $method, ($params ? (params => $params) : ())})
    ->status_is(200);
  return $t->tx->res->json;
}

# ------------------------------------------------------------------ pages ----

subtest 'the home page is the uploader, and nothing else' => sub {
  $t->get_ok('/')->status_is(200)
    ->content_like(qr{<a class="brand" href="/">share</a>})
    ->content_like(qr{<nav><a href="/how-to">How to use it</a></nav>})
    ->content_like(qr{<section class="uploader">})
    ->content_like(qr{<section class="recent" hidden>})
    ->header_like('Content-Security-Policy' => qr/default-src 'none'/);

  # The explanatory material moved to /how-to. If it creeps back onto the home
  # page, the widget stops being the point of the page.
  my $home = $t->tx->res->text;
  unlike $home, qr/claude mcp add/, 'no setup instructions on the home page';
  unlike $home, qr/The rules/,      'and no rules dump either';
};

subtest 'how-to carries what the home page used to' => sub {
  $t->get_ok('/how-to')->status_is(200)->content_like(qr/How to use it/)
    ->content_like(qr{claude mcp add --transport http share})
    ->content_like(qr/get_upload_url/)
    ->content_like(qr/Office network only — ask #infra for access\./)
    ->content_unlike(qr/Ã|â€/)    # double-encoded UTF-8, what a bytes bug looks like
    # No uploader here, so no script source is granted.
    ->header_unlike('Content-Security-Policy' => qr/script-src/);
};

subtest 'the uploader is a plain form that works without JavaScript' => sub {
  $t->get_ok('/')->status_is(200)
    ->content_like(qr{<form action="/upload" method="POST" enctype="multipart/form-data">})
    ->content_like(qr{type="file" name="file" multiple})
    ->content_like(qr{/assets/upload\.js});

  $t->get_ok('/')->content_like(qr{<link rel="icon" href="/assets/share-icon\.svg"});
  $t->get_ok('/assets/share-icon.svg')->status_is(200)->content_type_like(qr{image/svg});

  # The two pages holding the uploader are the only ones allowed a script
  # source, and they still deny everything they do not need.
  $t->get_ok('/')->header_like('Content-Security-Policy' => qr/script-src 'self'/)
    ->header_like('Content-Security-Policy' => qr/connect-src 'self'/);
  $t->get_ok('/f/' . ('z' x 32))->header_unlike('Content-Security-Policy' => qr/script-src/);
};

subtest 'health' => sub {
  $t->get_ok('/api/v1/health')->status_is(200)->json_is('/status' => 'ok');
};

# ----------------------------------------------------------------- upload ----

my $MARKDOWN = <<'MD';
# Report

Some **bold** text and a [link](https://example.com).

<script>alert('pwned')</script>

<img src="x" onerror="alert(1)">

[bad](javascript:alert(1))

| a | b |
|---|---|
| 1 | 2 |

```mermaid
graph TD;
  A-->B;
```
MD

my $id;

subtest 'raw-body upload' => sub {
  $t->post_ok("/api/v1/files?filename=report.md&session_id=$SESSION&note=have+a+look"
      => {'Content-Type' => 'text/markdown'} => $MARKDOWN)->status_is(201)
    ->json_is('/filename' => 'report.md')->json_is('/kind' => 'markdown')
    ->json_is('/session_id' => $SESSION)->json_is('/note' => 'have a look')
    ->json_like('/url' => qr{\Ahttps://share\.example\.test/f/[A-Za-z0-9]{32}\z})
    ->json_like('/expires_in' => qr/^(?:14|15) days$/);

  $id = $t->tx->res->json('/id');
  like $id, qr/\A[A-Za-z0-9]{32}\z/, 'the id is 32 base62 characters';
};

subtest 'raw-body upload without a filename is refused' => sub {
  $t->post_ok('/api/v1/files' => {'Content-Type' => 'text/markdown'} => '# hi')->status_is(400)
    ->json_like('/error' => qr/filename/);
};

subtest 'the declared type has to match the bytes' => sub {
  $t->post_ok('/api/v1/files?filename=trick.png' => {'Content-Type' => 'application/json'} =>
      encode_json({filename => 'trick.png', content => "not a png at all"}))->status_is(400)
    ->json_like('/error' => qr/claims to be \.png/);
};

subtest 'HEIC, because that is what phones produce' => sub {
  # An ISO base media box: 4-byte length, 'ftyp', then the brand. The brand is
  # what distinguishes HEIC from an MP4 in the same container.
  my $heic = "\0\0\0\x18ftypheic\0\0\0\0heicmif1" . ("\0" x 32);

  $t->post_ok('/api/v1/files?filename=photo.heic' => $heic)->status_is(201)
    ->json_is('/kind' => 'image')->json_is('/content_type' => 'image/heic');
  my $heic_id = $t->tx->res->json('/id');

  # Accepted, but honest about it: outside Safari the <img> will not decode, and
  # a broken image icon with no explanation is a worse answer than a refusal.
  $t->get_ok("/f/$heic_id/view")->status_is(200)
    ->content_like(qr/HEIC images only display in Safari/)
    ->content_like(qr/Use Download to save it/);

  # An MP4 shares the container but not the brand.
  $t->post_ok('/api/v1/files?filename=clip.heic' => "\0\0\0\x18ftypmp42\0\0\0\0")
    ->status_is(400)->json_like('/error' => qr/claims to be \.heic/);

  $t->delete_ok("/api/v1/files/$heic_id")->status_is(200);
};

subtest 'unknown extensions are refused' => sub {
  $t->post_ok('/api/v1/files?filename=payload.exe' => 'MZ...')->status_is(400)
    ->json_like('/error' => qr/not something this service holds/);
};

subtest 'JSON + base64 upload' => sub {
  $t->post_ok('/api/v1/files' => {'Content-Type' => 'application/json'} => encode_json(
      {filename => 'shot.png', content_base64 => $PNG_B64, session_id => $SESSION}))
    ->status_is(201)->json_is('/kind' => 'image')->json_is('/content_type' => 'image/png');
};

subtest 'PDFs go to the browser own viewer' => sub {
  $t->post_ok('/api/v1/files' => {'Content-Type' => 'application/json'} =>
      encode_json({filename => 'doc.pdf', content_base64 => $PDF_B64}))->status_is(201)
    ->json_is('/kind' => 'pdf')->json_is('/content_type' => 'application/pdf');
  my $pdf_id = $t->tx->res->json('/id');

  # No sandbox attribute at all: it breaks the built-in PDF viewer in several
  # browsers, and the browser already sandboxes that viewer itself.
  $t->get_ok("/f/$pdf_id")->status_is(200)->content_unlike(qr/sandbox=/);

  $t->get_ok("/f/$pdf_id/view")->status_is(302)
    ->header_like(Location => qr{/f/\Q$pdf_id\E/raw\z});

  # ...and PDF raw bytes are the one case that does NOT get CSP: sandbox, for
  # the same reason.
  $t->get_ok("/f/$pdf_id/raw")->status_is(200)->content_type_is('application/pdf')
    ->header_is('Content-Security-Policy' => undef);

  $t->delete_ok("/api/v1/files/$pdf_id")->status_is(200);
};

subtest 'signed upload tickets' => sub {
  my $res = _mcp('tools/call', {name => 'get_upload_url',
    arguments => {filename => 'signed.md', session_id => 'tickets', title => 'Signed'}});
  my $url = Mojo::URL->new(from_json($res->{result}{content}[0]{text})->{upload_url});

  my $q = $url->query;
  ok $q->param('sig'), 'the URL is signed';
  ok $q->param('exp') > time, 'and carries an expiry';

  # Untouched: it works.
  $t->post_ok($url->path_query => form => {file => {content => "# ok\n", filename => 'signed.md'}})
    ->status_is(201)->json_is('/title' => 'Signed');
  my $made = $t->tx->res->json('/id');

  # Every parameter is covered. Editing any of them invalidates the whole thing,
  # which is the point: an agent cannot be handed a ticket for one session and
  # quietly spend it on another.
  for my $tamper (
    [title      => 'Something else'],
    [session_id => 'someone-else'],
    [ttl_days   => '15'],
    [filename   => 'other.md'],
    [exp        => time + 86_400],
  ) {
    my $bad = $url->clone;
    $bad->query->param(@$tamper);
    $t->post_ok($bad->path_query => form => {file => {content => "x\n", filename => 'signed.md'}})
      ->status_is(403)->json_like('/error' => qr/altered since it was issued/);
  }

  # An expired ticket is refused even though its signature is perfectly valid.
  # Signed correctly, but for a moment that has passed. `sig` must be dropped
  # before signing: the digest covers every OTHER parameter, so leaving the old
  # one in would produce a signature over the wrong input and the request would
  # be refused as tampered rather than as expired.
  my $stale = Mojo::URL->new($url);
  $stale->query->param(exp => time - 1);
  my %fresh = %{$stale->query->to_hash};
  delete $fresh{sig};
  $stale->query->param(sig => $t->app->store->_signature(\%fresh));
  $t->post_ok($stale->path_query => form => {file => {content => "x\n", filename => 'signed.md'}})
    ->status_is(403)->json_like('/error' => qr/expired/);

  $t->delete_ok("/api/v1/files/$made")->status_is(200);
};

subtest 'no route lets a client choose or overwrite an id' => sub {
  # The worry a signed ticket is often reaching for is "can someone PUT to an id
  # they picked". There is no PUT at all, and no route that modifies an existing
  # file: every accepted upload mints a fresh secret from /dev/urandom.
  my $mine = 'a' x 32;
  $t->put_ok("/api/v1/files/$mine" => 'hello')->status_is(404);
  $t->put_ok("/f/$mine" => 'hello')->status_is(404);
  $t->put_ok('/api/v1/files' => 'hello')->status_is(404);

  # The same bytes uploaded twice are two separate files with two ids.
  my @ids;
  for (1 .. 2) {
    $t->post_ok('/api/v1/files?filename=twin.md' => "# twin\n")->status_is(201);
    push @ids, $t->tx->res->json('/id');
  }
  isnt $ids[0], $ids[1], 'two uploads, two ids, no overwrite';
  $t->delete_ok("/api/v1/files/$_")->status_is(200) for @ids;
};

# ----------------------------------------------------------------- viewer ----

subtest 'the viewer frames the file and never leaks the secret' => sub {
  $t->get_ok("/f/$id")->status_is(200)->content_like(qr/report\.md/)
    ->content_like(qr/have a look/)->content_like(qr/sandbox="allow-scripts"/)
    ->header_is('Referrer-Policy' => 'no-referrer')
    ->header_like('X-Robots-Tag'  => qr/noindex/)
    ->header_like('Cache-Control' => qr/no-store/);
};

subtest 'the preview renders markdown and drops everything dangerous' => sub {
  $t->get_ok("/f/$id/view")->status_is(200)->content_like(qr{<h1[^>]*>Report</h1>})
    ->content_like(qr{<strong>bold</strong>})->content_like(qr{<table>})
    ->content_like(qr{<pre class="mermaid">})->content_like(qr{mermaid\.min\.js})
    ->header_like('Content-Security-Policy' => qr/default-src 'none'/);

  my $body = $t->tx->res->text;
  unlike $body, qr/alert\('pwned'\)/, 'the inline script is gone, contents and all';
  unlike $body, qr/onerror/,          'the event handler attribute is gone';
  unlike $body, qr/javascript:/,      'the javascript: href is gone';
  like $body, qr{href="https://example\.com"}, 'an ordinary link survives';
};

subtest 'raw bytes come back as themselves, sandboxed' => sub {
  $t->get_ok("/f/$id/raw")->status_is(200)->content_type_like(qr{text/markdown})
    ->header_is('Content-Security-Policy' => 'sandbox')
    ->header_like('Content-Disposition' => qr/inline/)->content_like(qr/# Report/);
};

subtest 'download is an attachment' => sub {
  $t->get_ok("/f/$id/download")->status_is(200)
    ->header_like('Content-Disposition' => qr/attachment; filename="report\.md"/);
};

subtest 'an unknown id is a 404, in both dialects' => sub {
  my $nope = 'z' x 32;
  $t->get_ok("/f/$nope")->status_is(404)->content_like(qr/Nothing here/);
  $t->get_ok("/api/v1/files/$nope")->status_is(404)->json_like('/error' => qr/no such file/);
};

# ----------------------------------------------- the human-to-agent direction -

subtest 'the browser upload path' => sub {
  # Exactly what the plain <form> posts when JavaScript is off.
  $t->post_ok('/upload' => form =>
      {file => {content => "# from a human\n", filename => 'handover.md'}, note => 'for the agent'})
    ->status_is(200)->content_like(qr/Uploaded/)->content_like(qr/handover\.md/)
    ->content_like(qr{https://share\.example\.test/f/[A-Za-z0-9]{32}})
    ->content_like(qr/Give this URL to the agent/)
    # One click to copy, and hidden until upload.js wakes it up so that with
    # scripting off there is no dead button on the page.
    ->content_like(qr{<button class="btn result-copy" type="button" data-copy="https://share\.example\.test/f/[A-Za-z0-9]{32}" hidden>Copy</button>})
    # ...and enough metadata for upload.js to fold a no-JavaScript upload into
    # the same localStorage history the scripted path writes.
    ->content_like(qr{<li data-record="[^"]*expires_at[^"]*">});

  # Several at once, one of them bad: the good ones still land and the bad one
  # says why, rather than the whole batch failing.
  $t->post_ok('/upload' => form => {
    file => [
      {content => "# one\n",  filename => 'one.md'},
      {content => 'nonsense', filename => 'two.png'},
    ],
  })->status_is(200)->content_like(qr/one\.md/)->content_like(qr/two\.png/)
    ->content_like(qr/claims to be \.png/);

  $t->post_ok('/upload' => form => {})->status_is(200)->content_like(qr/No file was chosen/);
};

subtest 'what the browser uploader actually calls' => sub {
  # upload.js POSTs multipart to the same API an agent uses. Same endpoint, same
  # answer — there is only one upload path in this app.
  $t->post_ok('/api/v1/files' => form =>
      {file => {content => "# pasted\n", filename => 'pasted.md'}})->status_is(201)
    ->json_like('/url' => qr{/f/[A-Za-z0-9]{32}\z});
};

# ------------------------------------------------------------------- list ----

subtest 'listing a session' => sub {
  $t->get_ok("/api/v1/files?session_id=$SESSION")->status_is(200)->json_is('/count' => 2)
    ->json_like('/files/0/url' => qr{/f/});
  $t->get_ok('/api/v1/files')->status_is(400);
  $t->get_ok('/api/v1/files?session_id=nobody')->status_is(200)->json_is('/count' => 0);
};

# -------------------------------------------------------------------- MCP ----

subtest 'MCP: only POST' => sub {
  $t->get_ok('/mcp')->status_is(405);
  $t->delete_ok('/mcp')->status_is(405);
};

subtest 'MCP: initialize' => sub {
  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 1, method => 'initialize',
    params  => {protocolVersion => '2025-06-18', capabilities => {}, clientInfo => {name => 't'}},
  })->status_is(200)->json_is('/result/protocolVersion' => '2025-06-18')
    ->json_is('/result/serverInfo/name' => 'share')
    ->json_like('/result/instructions' => qr/hands a file from you to a human/)
    ->json_has('/result/capabilities/tools');

  # The instructions are built from the running config, not frozen: an operator
  # who changes the retention or the size cap must not have the MCP server
  # telling every agent the old numbers.
  my $instructions = $t->tx->res->json('/result/instructions');
  like $instructions, qr/deleted 15 days after upload/, 'the real retention';
  like $instructions, qr/up to 32\.0 MB each/,          'the real size cap';
  like $instructions, qr/Office network only — ask #infra for access\./,
    'and the deployment notice the operator set, decoded exactly once';

  # An unknown version is answered with ours, not with an error.
  $t->post_ok('/mcp' => json =>
      {jsonrpc => '2.0', id => 2, method => 'initialize', params => {protocolVersion => '1999-01-01'}})
    ->status_is(200)->json_is('/result/protocolVersion' => '2025-06-18');
};

subtest 'MCP: notifications get a 202 and no body' => sub {
  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', method => 'notifications/initialized'})
    ->status_is(202)->content_is('');
};

subtest 'MCP: tools/list' => sub {
  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', id => 3, method => 'tools/list'})
    ->status_is(200);
  my $tools = $t->tx->res->json('/result/tools');
  is_deeply [sort map { $_->{name} } @$tools],
    [qw(delete_shared_file get_shared_file get_upload_url list_shared_files)],
    'four tools, and not one of them moves bytes';

  # The whole point of this server's shape, asserted structurally rather than by
  # grepping prose — the descriptions legitimately talk about bytes and content.
  # If a tool ever grows a parameter that carries a file, it belongs on the HTTP
  # side instead.
  my @carriers = grep { /\A(?:content|content_base64|data|bytes|body|file)\z/ }
    map { keys %{$_->{inputSchema}{properties} // {}} } @$tools;
  is_deeply \@carriers, [], 'no tool takes file contents as an argument';
};

subtest 'MCP: get_upload_url hands back a command, not a byte sink' => sub {
  my $res = _mcp('tools/call', {
    name      => 'get_upload_url',
    arguments => {filename => 'report.md', path => '/tmp/report.md',
      session_id => $SESSION, title => 'A report', ttl_days => 3},
  });
  ok !$res->{result}{isError}, 'it succeeded';

  my $out = from_json($res->{result}{content}[0]{text});
  is $out->{method}, 'POST', 'POST';
  like $out->{upload_url}, qr{\Ahttps://share\.example\.test/api/v1/files\?},
    'pointing at the ordinary REST endpoint';
  like $out->{upload_url}, qr/filename=report\.md/,     'with the filename baked in';
  like $out->{upload_url}, qr/session_id=$SESSION/,      'and the session';
  like $out->{upload_url}, qr/title=A(?:%20|\+)report/,  'and the title, encoded';
  like $out->{upload_url}, qr/ttl_days=3/,               'and the ttl';
  like $out->{command}, qr{\Acurl -fsS -F 'file=\@/tmp/report\.md'}, 'a runnable command';
  like $res->{result}{content}[1]{text}, qr/give the human the "url"/i,
    'and prose telling the model what to do with the output';

  # Nothing was written: an abandoned call must cost nothing, because there is
  # deliberately no reservation to expire and reap.
  $t->get_ok("/api/v1/files?session_id=$SESSION")->status_is(200)->json_is('/count' => 2);

  # And the URL it produced actually works — this is the contract.
  my $upload = Mojo::URL->new($out->{upload_url});
  $t->post_ok($upload->path_query => form => {file => {content => "# a report\n",
      filename => 'report.md'}})->status_is(201)->json_is('/session_id' => $SESSION)
    ->json_is('/title' => 'A report')->json_like('/expires_in' => qr/^(?:2|3) days$/);
  my $made = $t->tx->res->json('/id');

  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', id => 41, method => 'tools/call',
    params => {name => 'get_upload_url', arguments => {}}})->status_is(200)
    ->json_is('/result/isError' => 1)->json_like('/result/content/0/text' => qr/filename is required/);

  $t->delete_ok("/api/v1/files/$made")->status_is(200);
};

subtest 'MCP: reading a file back means being told where it is' => sub {
  my $res = _mcp('tools/call', {name => 'get_shared_file', arguments => {id => $id}});
  my $info = from_json($res->{result}{content}[0]{text});

  is $info->{id}, $id, 'the right file';
  is $info->{kind}, 'markdown', 'described fully';
  like $info->{url}, qr{/f/\Q$id\E\z}, 'the page for the human';
  like $info->{content_url}, qr{/api/v1/files/\Q$id\E/content\z}, 'the bytes for the agent';
  like $res->{result}{content}[1]{text}, qr/curl -fsS '.*\/content'/, 'with the command spelled out';

  # The contents themselves are NOT in the response, at any size. That is the
  # property the whole design turns on. to_json, not encode_json: the result
  # holds characters, and encoding it to UTF-8 bytes here just to grep it warns
  # and dies under -w.
  unlike to_json($res->{result}), qr/# Report/,
    'the markdown itself never crosses the MCP boundary';

  # And content_url is real.
  $t->get_ok("/api/v1/files/$id/content")->status_is(200)->content_like(qr/# Report/);
};

subtest 'MCP: listing gives both URLs for every file' => sub {
  my $res = _mcp('tools/call',
    {name => 'list_shared_files', arguments => {session_id => $SESSION}});
  my $out = from_json($res->{result}{content}[0]{text});
  is $out->{count}, 2, 'both files';
  ok $_->{url} && $_->{content_url}, 'each carries a page URL and a content URL'
    for @{$out->{files}};

  $res = _mcp('tools/call',
    {name => 'list_shared_files', arguments => {session_id => 'nobody at all'}});
  like $res->{result}{content}[0]{text}, qr/Nothing shared under that session id/,
    'and an empty session says so plainly';
};

subtest 'MCP: the missing-id paths' => sub {
  for my $tool (qw(get_shared_file delete_shared_file)) {
    my $res = _mcp('tools/call', {name => $tool, arguments => {id => 'n' x 32}});
    ok $res->{result}{isError}, "$tool on a missing id is a tool error";
    like $res->{result}{content}[0]{text}, qr/no live file/, "$tool says why";
  }
};

subtest 'MCP: ping, and a batch from an older client' => sub {
  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', id => 50, method => 'ping'})
    ->status_is(200)->json_is('/result' => {});

  # Batches were dropped in 2025-06-18 but older clients still send them.
  $t->post_ok('/mcp' => json => [
    {jsonrpc => '2.0', id => 51, method => 'ping'},
    {jsonrpc => '2.0', id => 52, method => 'tools/list'},
    {jsonrpc => '2.0', method => 'notifications/initialized'},
  ])->status_is(200)->json_is('/0/id' => 51)->json_is('/1/id' => 52);

  # A batch of nothing but notifications has nothing to answer with.
  $t->post_ok('/mcp' => json => [{jsonrpc => '2.0', method => 'notifications/initialized'}])
    ->status_is(202);

  $t->post_ok('/mcp' => {'Content-Type' => 'application/json'} => 'not json at all')
    ->status_is(400)->json_is('/error/code' => -32700);

  $t->post_ok('/mcp' => json => {id => 53, method => 'ping'})->status_is(200)
    ->json_is('/error/code' => -32600);
};

subtest 'MCP: a bad call is a tool error, not a protocol error' => sub {
  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 7, method => 'tools/call',
    params  => {name => 'get_upload_url', arguments => {}},
  })->status_is(200)->json_is('/result/isError' => 1)
    ->json_like('/result/content/0/text' => qr/filename is required/);

  $t->post_ok('/mcp' => json =>
      {jsonrpc => '2.0', id => 8, method => 'tools/call', params => {name => 'no_such_tool'}})
    ->status_is(200)->json_is('/error/code' => -32602);

  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', id => 9, method => 'no/such/method'})
    ->status_is(200)->json_is('/error/code' => -32601);
};

subtest 'MCP: a hostile Origin is refused' => sub {
  $t->post_ok('/mcp' => {Origin => 'https://evil.example'} => json =>
      {jsonrpc => '2.0', id => 10, method => 'ping'})->status_is(403);
  $t->post_ok('/mcp' => {Origin => 'https://share.example.test'} => json =>
      {jsonrpc => '2.0', id => 11, method => 'ping'})->status_is(200);
};

subtest 'MCP: an unsupported protocol version is a 400' => sub {
  $t->post_ok('/mcp' => {'MCP-Protocol-Version' => '1999-01-01'} => json =>
      {jsonrpc => '2.0', id => 12, method => 'ping'})->status_is(400);
  $t->post_ok('/mcp' => {'MCP-Protocol-Version' => '2025-06-18'} => json =>
      {jsonrpc => '2.0', id => 13, method => 'ping'})->status_is(200);
};

# ----------------------------------------------------------------- delete ----

subtest 'deleting from the browser takes two clicks and no JavaScript' => sub {
  $t->get_ok("/f/$id/delete")->status_is(200)->content_like(qr/Delete this file/)
    ->content_unlike(qr/<script/);
  $t->post_ok("/f/$id/delete")->status_is(200)->content_like(qr/is gone/);
  $t->get_ok("/f/$id")->status_is(404);
  $t->delete_ok("/api/v1/files/$id")->status_is(404);
};

done_testing;
