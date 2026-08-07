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
use Share::Store ();
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

# Configured but effectively unlimited for the bulk of the suite, which uploads
# far more often than any real client would. NOT zero: zero means "no limit" and
# the pages and the OpenAPI document then correctly say nothing about limits,
# which leaves the parts of this suite that check that wording with nothing to
# check. The limits themselves get their own subtests.
$ENV{SHARE_RATE_PER_SECOND} = 1000;
$ENV{SHARE_RATE_PER_MINUTE} = 1000;
delete $ENV{SHARE_TTL_DAYS};

my $t = Test::Mojo->new(curfile->dirname->sibling('share.pl'));

my $SESSION = 'session-under-test';

# 1x1 transparent PNG.
my $PNG_B64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8'
  . 'BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

# The smallest thing that is unambiguously a PDF.
my $PDF_B64 = b64_encode("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n", '');

# Protocol revision 2026-07-28: no handshake, and every request declares its
# version in _meta. MCP::Server::Transport::HTTP enforces that, so a call
# without it is answered with UnsupportedProtocolVersionError rather than being
# quietly served.
my $PROTOCOL = '2026-07-28';
my $META     = 'io.modelcontextprotocol/protocolVersion';
my $CAPS     = 'io.modelcontextprotocol/clientCapabilities';
my $INFO     = 'io.modelcontextprotocol/clientInfo';

# One MCP call, unwrapped. The suite makes a lot of these and the JSON-RPC
# envelope adds nothing to a test's meaning.
sub _mcp ($method, $params = undef, %opt) {
  state $id = 1000;
  my $version = $opt{version} // $PROTOCOL;
  # _meta carries what the initialize handshake used to: the protocol version,
  # the client's capabilities and its identity, on every single request.
  my $p = {
    %{$params // {}},
    _meta => {$META => $version, $CAPS => {}, $INFO => {name => 'share-tests', version => '1'}},
  };

  # The 2026-07-28 HTTP binding requires routing headers that restate what the
  # body says, so a gateway routing on headers alone can never disagree with the
  # server about what was called. Mismatched or missing ones are a 400 before
  # anything is dispatched. Mcp-Param-* would be needed too, but only for schema
  # properties that opt in with x-mcp-header, and none of ours do.
  my %headers = ('MCP-Protocol-Version' => $version, 'Mcp-Method' => $method);
  $headers{'Mcp-Name'} = $params->{name}
    if $method eq 'tools/call' && defined $params->{name};

  $t->post_ok('/mcp' => \%headers => json =>
      {jsonrpc => '2.0', id => ++$id, method => $method, params => $p});
  $t->status_is($opt{status} // 200);
  return $t->tx->res->json;
}

# Deleting needs the password from the upload response — the share URL alone
# grants only reading. Every teardown in this suite goes through here.
sub _delete ($id, $password) {
  $t->delete_ok("/api/v1/files/$id" => {'X-Delete-Password' => $password // ''});
  return $t->tx->res;
}

# Upload and keep both secrets: the id for the URL, the password for the
# cleanup.
sub _upload ($filename, $content, %extra) {
  my $url = Mojo::URL->new('/api/v1/files')->query({filename => $filename, %extra});
  $t->post_ok($url->to_string => $content)->status_is(201);
  my $json = $t->tx->res->json;
  return ($json->{id}, $json->{delete_password});
}

# ------------------------------------------------------------------ pages ----

subtest 'the home page is the uploader, and nothing else' => sub {
  $t->get_ok('/')->status_is(200)
    ->content_like(qr{<a class="brand" href="/">.*<span>share</span>}s)
    ->content_like(qr{<a href="/how-to">How to use it</a>})
    ->content_like(qr{<a href="/api">API</a>})
    ->content_like(qr{github\.com/melo/small-share-app})
    # The burger is a checkbox and a label, so the menu costs no script source.
    ->content_like(qr{<input class="nav-toggle" type="checkbox"})
    ->content_like(qr{<label class="nav-burger"})
    ->content_like(qr{<section class="uploader">})
    ->content_like(qr{<section class="recent" hidden>})
    ->header_like('Content-Security-Policy' => qr/default-src 'none'/);

  # The explanatory material lives at /how-to. The pitch panel carries the one
  # `claude mcp add` line on purpose — that is the whole point of it — but the
  # rules, the REST examples and the rest must stay one click away, or the drop
  # zone stops being the point of the page.
  my $home = $t->tx->res->text;
  unlike $home, qr/The rules/,           'no rules dump on the home page';
  unlike $home, qr/curl --data-binary/,  'and no REST tutorial either';
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
    ->content_like(qr{/assets/upload\.[0-9a-f]{12}\.js});

  $t->get_ok('/')->content_like(qr{<link rel="icon" href="/assets/share-icon\.[0-9a-f]{12}\.svg"});
  my ($icon) = $t->tx->res->text =~ m{href="(/assets/share-icon\.[0-9a-f]{12}\.svg)"};
  $t->get_ok($icon)->status_is(200)->content_type_like(qr{image/svg});

  # Script is granted by name, per route, and nothing is granted that is not
  # asked for. The uploader needs connect-src too, for the progress bar's XHR;
  # the viewer does not, and does not get it.
  $t->get_ok('/')->header_like('Content-Security-Policy' => qr/script-src 'self'/)
    ->header_like('Content-Security-Policy' => qr/connect-src 'self'/);
  $t->get_ok('/f/' . ('z' x 32))->header_unlike('Content-Security-Policy' => qr/script-src/);
};

subtest 'assets are fingerprinted, and served immutable' => sub {
  # Cloudflare cached a stylesheet from an earlier deploy for two days and there
  # was nothing on our side that could expire it. Only a different URL can, and
  # the only URL that is guaranteed to change with the file is one named after
  # its contents.
  $t->get_ok('/')->status_is(200);
  my ($css) = $t->tx->res->text =~ m{href="(/assets/share\.[0-9a-f]{12}\.css)"};
  ok $css, 'the stylesheet URL carries a content hash';

  my ($js) = $t->tx->res->text =~ m{src="(/assets/upload\.[0-9a-f]{12}\.js)"};
  ok $js, 'and so does the script';

  $t->get_ok($css)->status_is(200)->content_type_like(qr{text/css})
    ->header_like('Cache-Control' => qr/immutable/)
    ->header_like('Cache-Control' => qr/max-age=31536000/)
    ->content_like(qr/\.dropzone/);

  # mermaid.min.js and github-markdown.css are fetched during the image build
  # and copied into the RUNTIME stage only, so they are legitimately absent here
  # — this suite runs in the builder. The helper must degrade to the plain path
  # rather than emitting a broken URL, which is what keeps the preview page
  # working in exactly this situation. The fingerprinted form of those two is
  # asserted by the browser suite, which runs against the real image.
  my $c = $t->app->build_controller;
  is $c->asset('mermaid.min.js'), '/assets/mermaid.min.js',
    'an asset that is not present falls back to its plain path';

  # Only URLs this app minted are served. An invented hash must not pin today's
  # bytes under a URL promised immutable for a year.
  $t->get_ok('/assets/share.000000000000.css')->status_is(404);
  $t->get_ok('/assets/nope.000000000000.css')->status_is(404);
  $t->get_ok('/assets/..%2f..%2fshare.000000000000.pl')->status_is(404);
};

subtest 'the first-visit pitch' => sub {
  # Rendered visible for everyone; assets/upload.js hides it once dismissed. The
  # other way round would flash it on every visit and hide it forever from
  # anyone without JavaScript.
  $t->get_ok('/')->status_is(200)
    ->content_like(qr{<aside class="pitch">})
    ->content_like(qr/from inside your chat/)
    ->content_like(qr{claude mcp add --transport http share https://share\.example\.test/mcp})
    # Dead controls are worse than missing ones: the button waits for the script.
    ->content_like(qr{<button class="pitch-dismiss"[^>]*hidden>});

  # ...and it points at the page we were told nobody finds.
  $t->get_ok('/')->content_like(qr{<a href="/how-to">How to use it</a>[^<]*·});
};

subtest 'the API page, and the OpenAPI document behind it' => sub {
  $t->get_ok('/api')->status_is(200)->content_type_like(qr{text/html})
    ->content_like(qr/The API/)->content_like(qr{/api\?openapi=1})
    ->content_like(qr{x-delete-password})
    # Limits a caller will actually hit belong where the limits are listed.
    ->content_like(qr/Uploads are rate limited/)
    ->content_like(qr/1000 per second, and 1000 per minute/)
    # \s+ because the template wraps mid-sentence; matching a literal space
    # here has bitten this suite twice already.
    ->content_like(qr/holds at most\s+50\.0 GB in total/);

  # ?openapi=1 always wins, whatever the Accept header says.
  $t->get_ok('/api?openapi=1' => {Accept => 'text/html'})->status_is(200)
    ->content_type_like(qr{application/json})
    ->json_is('/openapi' => '3.1.0')->json_is('/info/title' => 'share')
    ->json_has('/paths/~1files/post')->json_has('/paths/~1files~1{id}/delete')
    ->json_has('/components/schemas/UploadedFile');

  # Built from the running config, so the limits it advertises are the limits
  # that are actually enforced.
  $t->json_is('/components/schemas/File/properties/size/maximum' => 32 * 1024 * 1024);
  $t->json_like('/info/description' => qr/15 days/);
  $t->json_like('/servers/0/url' => qr{\Ahttps://share\.example\.test/api/v1\z});

  # Content negotiation by convention — the spec defines none, and nothing is
  # registered with IANA. When a client names an openapi type, that exact type
  # comes back.
  for my $type (qw(application/openapi+json application/vnd.oai.openapi+json)) {
    $t->get_ok('/api' => {Accept => $type})->status_is(200)
      ->content_type_is($type)->json_is('/openapi' => '3.1.0');
  }
  $t->get_ok('/api' => {Accept => 'application/json'})->status_is(200)
    ->content_type_like(qr{application/json})->json_is('/openapi' => '3.1.0');

  # A browser sends text/html first and gets the page, not a JSON download.
  $t->get_ok('/api' => {Accept => 'text/html,application/xhtml+xml,application/json;q=0.9'})
    ->status_is(200)->content_type_like(qr{text/html});

  # The delete password must not leak into the description of the read side.
  my $doc = $t->get_ok('/api?openapi=1')->tx->res->json;

  # A caller reading the document must be told about the limits it will hit,
  # written from the running configuration rather than from a guess. These run
  # AFTER the fetch above on purpose — the previous request in this subtest is
  # the HTML page, and json_has against an HTML body simply fails.
  $t->json_has('/paths/~1files/post/responses/429')
    ->json_has('/paths/~1files/post/responses/429/headers/Retry-After')
    ->json_like('/info/description' => qr/rate limited to 1000 per second/);
  ok !exists $doc->{components}{schemas}{File}{properties}{delete_password},
    'File does not carry a delete password, in the schema either';
};

subtest 'health says it is alive and nothing more' => sub {
  # Reachable by anyone on a public instance, so it must not report how many
  # files are held or how much disk is in play. That tells a stranger how busy
  # the box is and whether something of theirs is still on it.
  $t->get_ok('/api/v1/health')->status_is(200)->json_is('/status' => 'ok')
    ->json_has('/version')->json_hasnt('/files')->json_hasnt('/bytes');

  # A private deployment can turn the inventory back on for its collector...
  my $was = $t->app->config->{health_detail};
  $t->app->config->{health_detail} = 1;
  $t->get_ok('/api/v1/health')->status_is(200)->json_has('/files')->json_has('/bytes');

  # ...but that setting must NOT be able to put it on a page a human opens. It
  # used to say "Right now it is holding N files" here.
  $t->get_ok('/how-to')->status_is(200)
    ->content_unlike(qr/it is holding/)->content_unlike(qr/\bholding \d+ file/);
  $t->app->config->{health_detail} = $was;

  # Nothing else a stranger can reach reports the inventory either. This is a
  # sweep rather than a spot check, because the leak was added twice: once on
  # the health endpoint and once, separately, in prose.
  for my $path ('/', '/how-to', '/api', '/api?openapi=1') {
    $t->get_ok($path)->status_is(200);
    my $body = $t->tx->res->text;
    unlike $body, qr/\bholding \d+ file/i, "$path does not say how many files are held";
    unlike $body, qr/"files"\s*:\s*\d/,   "$path does not report a file count";
    unlike $body, qr/"bytes"\s*:\s*\d/,   "$path does not report bytes held";
  }
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

my ($id, $delete_password);

subtest 'raw-body upload' => sub {
  $t->post_ok("/api/v1/files?filename=report.md&session_id=$SESSION&note=have+a+look"
      => {'Content-Type' => 'text/markdown'} => $MARKDOWN)->status_is(201)
    ->json_is('/filename' => 'report.md')->json_is('/kind' => 'markdown')
    ->json_is('/session_id' => $SESSION)->json_is('/note' => 'have a look')
    ->json_like('/url' => qr{\Ahttps://share\.example\.test/f/[A-Za-z0-9]{32}\z})
    ->json_like('/expires_in' => qr/^(?:14|15) days$/);

  $id = $t->tx->res->json('/id');
  $delete_password = $t->tx->res->json('/delete_password');
  like $id, qr/\A[A-Za-z0-9]{32}\z/, 'the id is 32 base62 characters';
  like $delete_password, qr/\A[A-Za-z0-9]{24}\z/,
    'and a delete password came back with it, once';
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
  my $heic_id       = $t->tx->res->json('/id');
  my $heic_password = $t->tx->res->json('/delete_password');

  # Accepted, but honest about it: outside Safari the <img> will not decode, and
  # a broken image icon with no explanation is a worse answer than a refusal.
  $t->get_ok("/f/$heic_id/view")->status_is(200)
    ->content_like(qr/HEIC images only display in Safari/)
    ->content_like(qr/Use Download to save it/);

  # An MP4 shares the container but not the brand.
  $t->post_ok('/api/v1/files?filename=clip.heic' => "\0\0\0\x18ftypmp42\0\0\0\0")
    ->status_is(400)->json_like('/error' => qr/claims to be \.heic/);

  _delete($heic_id, $heic_password);
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
  my $pdf_id       = $t->tx->res->json('/id');
  my $pdf_password = $t->tx->res->json('/delete_password');

  # No sandbox attribute at all: it breaks the built-in PDF viewer in several
  # browsers, and the browser already sandboxes that viewer itself.
  $t->get_ok("/f/$pdf_id")->status_is(200)->content_unlike(qr/sandbox=/);

  $t->get_ok("/f/$pdf_id/view")->status_is(302)
    ->header_like(Location => qr{/f/\Q$pdf_id\E/raw\z});

  # ...and PDF raw bytes are the one case that does NOT get CSP: sandbox, for
  # the same reason.
  $t->get_ok("/f/$pdf_id/raw")->status_is(200)->content_type_is('application/pdf')
    ->header_is('Content-Security-Policy' => undef);

  _delete($pdf_id, $pdf_password);
  $t->status_is(200);
};

subtest 'office documents and archives are held, and never previewed' => sub {
  # Both families are containers and the container is all we check: OOXML and
  # OpenDocument are zips, pre-2007 Office is an OLE2 compound document.
  my $zip  = "PK\x03\x04" . ("\0" x 26);
  my $ole2 = "\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" . ("\0" x 40);

  my %expect = (
    'notes.docx' => ['document', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', $zip],
    'sums.xlsx'  => ['document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',       $zip],
    'deck.pptx'  => ['document', 'application/vnd.openxmlformats-officedocument.presentationml.presentation', $zip],
    'notes.odt'  => ['document', 'application/vnd.oasis.opendocument.text',         $zip],
    'sums.ods'   => ['document', 'application/vnd.oasis.opendocument.spreadsheet',  $zip],
    'deck.odp'   => ['document', 'application/vnd.oasis.opendocument.presentation', $zip],
    'plan.odg'   => ['document', 'application/vnd.oasis.opendocument.graphics',     $zip],
    'old.doc'    => ['document', 'application/msword',                 $ole2],
    'old.xls'    => ['document', 'application/vnd.ms-excel',           $ole2],
    'old.ppt'    => ['document', 'application/vnd.ms-powerpoint',      $ole2],
    'bundle.zip' => ['archive',  'application/zip',                    $zip],
  );

  for my $filename (sort keys %expect) {
    my ($kind, $type, $bytes) = @{$expect{$filename}};
    $t->post_ok("/api/v1/files?filename=$filename" => $bytes)->status_is(201)
      ->json_is('/kind' => $kind)->json_is('/content_type' => $type);
    _delete($t->tx->res->json('/id'), $t->tx->res->json('/delete_password'));
  }

  # An empty archive is nothing but the end-of-central-directory record, and it
  # is still a valid zip.
  $t->post_ok('/api/v1/files?filename=empty.zip' => "PK\x05\x06" . ("\0" x 18))->status_is(201);
  my ($zip_id, $zip_password) = ($t->tx->res->json('/id'), $t->tx->res->json('/delete_password'));

  # No frame at all: a browser cannot render a zip, and an iframe that would
  # only ever say so is worse than saying it here.
  $t->get_ok("/f/$zip_id")->status_is(200)
    ->content_unlike(qr{<iframe})
    ->content_like(qr{class="no-preview"})
    ->content_like(qr{<a class="btn primary" href="/f/$zip_id/download">Download</a>});

  # ...and the preview route, if anyone navigates straight to it, goes back to
  # the page that has the download button rather than 404ing or framing bytes.
  $t->get_ok("/f/$zip_id/view")->status_is(302)->header_like(Location => qr{/f/\Q$zip_id\E\z});

  $t->get_ok("/f/$zip_id/download")->status_is(200)->content_type_is('application/zip')
    ->header_like('Content-Disposition' => qr/attachment; filename="empty\.zip"/);

  # The extension still has to match the bytes, in both directions.
  $t->post_ok('/api/v1/files?filename=trick.docx' => "%PDF-1.4\n")->status_is(400)
    ->json_like('/error' => qr/claims to be \.docx/);
  $t->post_ok('/api/v1/files?filename=trick.doc' => $zip)->status_is(400)
    ->json_like('/error' => qr/looks? like a zip archive/);
  $t->post_ok('/api/v1/files?filename=trick.png' => $ole2)->status_is(400)
    ->json_like('/error' => qr/old-style Office document/);

  # Macro-enabled Office is deliberately not on the list.
  $t->post_ok('/api/v1/files?filename=macros.docm' => $zip)->status_is(400)
    ->json_like('/error' => qr/not something this service holds/);

  _delete($zip_id, $zip_password);
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
  my $made          = $t->tx->res->json('/id');
  my $made_password = $t->tx->res->json('/delete_password');

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

  _delete($made, $made_password);
  $t->status_is(200);
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
  my @made;
  for (1 .. 2) {
    $t->post_ok('/api/v1/files?filename=twin.md' => "# twin\n")->status_is(201);
    push @made, $t->tx->res->json;
  }
  isnt $made[0]{id}, $made[1]{id}, 'two uploads, two ids, no overwrite';
  isnt $made[0]{delete_password}, $made[1]{delete_password}, 'and two passwords';
  _delete($_->{id}, $_->{delete_password})->code == 200 or die 'cleanup failed' for @made;
};

subtest 'rate limiting, and the disk ceiling' => sub {
  # A store of its own, so the limits can be tiny without the rest of the suite
  # tripping over them.
  my $dir = File::Temp->newdir;
  my $s   = Share::Store->new(root => "$dir", rate_per_second => 1, rate_per_minute => 3,
    max_total_bytes => 300)->init;

  # Counted in SQLite, not in process memory: the app runs prefork, and an
  # in-memory counter would hand every client the limit times the worker count.
  my ($ok, $wait) = $s->rate_check('10.0.0.1');
  ok $ok, 'the first attempt goes through';

  # The hit is planted rather than made by calling rate_check twice: two live
  # calls can land either side of a second boundary, and then the per-second
  # rule legitimately does not fire. That is a flaky test, not a bug.
  $s->sql->db->query('DELETE FROM upload_hits');
  $s->sql->db->insert('upload_hits', {client => '10.0.0.1', at => time});
  ($ok, $wait) = $s->rate_check('10.0.0.1');
  ok !$ok, 'a second attempt within the same second does not';
  is $wait, 1, 'and is told to wait a second';

  # Another client is unaffected — the limit is per caller, not global.
  ok +($s->rate_check('10.0.0.2'))[0], 'a different client is not blocked';
  $s->sql->db->query('DELETE FROM upload_hits');

  # Attempts, not successes: hammering with rejects has to count too.
  $s->sql->db->insert('upload_hits', {client => '10.0.0.3', at => time - 30}) for 1 .. 3;
  ($ok, $wait) = $s->rate_check('10.0.0.3');
  ok !$ok, 'the per-minute limit bites even when nothing was stored';
  ok $wait > 1 && $wait <= 60, "and says when the window frees up ({$wait}s)";

  # Turning them off is a supported state, not an accident.
  my $unlimited = Share::Store->new(root => "$dir", rate_per_second => 0, rate_per_minute => 0);
  $unlimited->sql($s->sql);
  ok +($unlimited->rate_check('10.0.0.1'))[0], 'zero disables the limit';

  # The ceiling sheds the OLDEST rather than refusing the newest: a public box
  # that fills its disk goes down, which is worse than losing old files.
  my @made;
  for my $n (1 .. 4) {
    my $row = $s->add(bytes => ('x' x 100), filename => "f$n.md");
    # add() stamps created_at from time(), so nudge them apart deliberately
    # rather than depending on the clock ticking during a fast test.
    $s->sql->db->query('UPDATE files SET created_at = ? WHERE id = ?', time - (10 - $n), $row->{id});
    push @made, $row;
  }

  my $evicted = $s->enforce_total_limit;
  is scalar @$evicted, 1, 'exactly one file evicted — no more than needed';
  is $evicted->[0]{filename}, 'f1.md', 'and it is the oldest';
  ok !$s->find($made[0]{secret}), 'which is really gone';
  ok $s->find($made[3]{secret}),  'while the newest survives';
  ok $s->stats->{bytes} <= 300,   'and the total is under the ceiling';

  # No ceiling means no eviction.
  $s->max_total_bytes(0);
  is_deeply $s->enforce_total_limit, [], 'zero disables the ceiling';
};

subtest 'a hammering client is refused, in both dialects' => sub {
  # Turned on for this subtest only, on the running app's own store.
  #
  # NOT by building a second Test::Mojo: Mojolicious::Lite's app is a singleton
  # in `main`, so loading share.pl twice re-runs its routes against a NEW store
  # and every earlier file in this file's other subtests vanishes underneath
  # them. That cost half an hour to work out; do not reintroduce it.
  # Both set to 1, deliberately: with a per-minute allowance of 2 the second
  # request is only refused if it lands in the same SECOND as the first, and two
  # HTTP round trips straddle a second boundary often enough to make that a
  # flaky test. One-per-minute is refused either way.
  my $s = $t->app->store;
  $s->rate_per_second(1);
  $s->rate_per_minute(1);
  $s->sql->db->query('DELETE FROM upload_hits');

  $t->post_ok('/api/v1/files?filename=fast-a.md' => '# a')->status_is(201);
  my $made = $t->tx->res->json;

  $t->post_ok('/api/v1/files?filename=fast-b.md' => '# b')->status_is(429)
    ->json_like('/error' => qr/too many uploads/)
    ->header_like('Retry-After' => qr/\A\d+\z/);

  # The browser path is limited too, and answers in words rather than JSON.
  $t->post_ok('/upload' => form => {file => {content => '# c', filename => 'fast-c.md'}})
    ->status_is(429)->content_like(qr/too fast/);

  $s->rate_per_second(0);
  $s->rate_per_minute(0);
  $s->sql->db->query('DELETE FROM upload_hits');
  _delete($made->{id}, $made->{delete_password})->code == 200 or die 'cleanup failed';
};

# ----------------------------------------------------------------- viewer ----

subtest 'the viewer offers no Delete it cannot honour' => sub {
  # Whoever opens a link they were sent does not have the delete password, so a
  # Delete button there is a door they can never open. Download is the only
  # action on a page reached from a shared link.
  $t->get_ok("/f/$id")->status_is(200)
    ->content_like(qr{<a class="btn primary" href="/f/$id/download">Download</a>})
    ->content_unlike(qr{class="btn danger"})
    ->content_unlike(qr{/delete"});

  # The page itself still works for whoever DOES have the password — it is how
  # the no-JavaScript path deletes anything at all.
  $t->get_ok("/f/$id/delete")->status_is(200)->content_like(qr/Delete this file/);
};

subtest 'the viewer frames the file and never leaks the secret' => sub {
  $t->get_ok("/f/$id")->status_is(200)->content_like(qr/report\.md/)
    # Arriving from a link someone sent you is the common case, so the viewer
    # carries the same header as everything else rather than suppressing it.
    ->content_like(qr{<header class="topbar">})
    ->content_like(qr{<a class="brand" href="/">})
    ->content_like(qr/have a look/)->content_like(qr/sandbox="allow-scripts"/)
    ->header_is('Referrer-Policy' => 'no-referrer')
    ->header_like('X-Robots-Tag'  => qr/noindex/)
    ->header_like('Cache-Control' => qr/no-store/);
};

subtest 'the file bar folds, and hands over both URLs' => sub {
  $t->get_ok("/f/$id")->status_is(200)
    # A checkbox and a label, so the fold works with scripting off — the same
    # trick as the burger in the topbar.
    ->content_like(qr{<input class="filebar-toggle" type="checkbox" id="filebar-toggle">})
    ->content_like(qr{<label class="btn filebar-fold" for="filebar-toggle"})
    # The description sits beside the name rather than under it, which is a
    # whole row of somebody else's document given back to them.
    ->content_like(qr{<div class="facts-head">.*<h1>.*<p class="note">}s)

    # Both URLs, absolute: they are for pasting somewhere else, so a path would
    # be useless.
    ->content_like(qr{data-copy="https://share\.example\.test/f/$id">Copy preview URL</button>})
    ->content_like(
      qr{data-copy="https://share\.example\.test/f/$id/download">Copy download URL</button>})
    # ...and shipped hidden, so with scripting off there is no dead control.
    ->content_like(qr{<p class="copy-links" hidden>});

  # The one page carrying a secret that is allowed a script source, and it says
  # what for: a clipboard, and a bar that folds itself. Still no connect-src.
  $t->get_ok("/f/$id")->header_like('Content-Security-Policy' => qr/script-src 'self'/)
    ->header_unlike('Content-Security-Policy' => qr/connect-src/)
    ->content_like(qr{<script src="/assets/viewer\.[0-9a-f]{12}\.js"></script>});

  # The frame reports its scroll position back to the bar; nothing else does,
  # because nothing else can see inside it.
  $t->get_ok("/f/$id/view")->status_is(200)
    ->content_like(qr{<script src="/assets/preview-scroll\.[0-9a-f]{12}\.js"></script>});
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
    ->content_like(qr{<li data-record="[^"]*expires_at[^"]*">})
    # The password is shown once here, so this is also the one place a
    # no-JavaScript uploader can be handed a route to deleting it.
    ->content_like(qr{delete password: <code>[A-Za-z0-9]{24}</code>})
    ->content_like(qr{>delete it early</a>});

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

subtest 'MCP: server/discover replaces the handshake' => sub {
  my $res = _mcp('server/discover');

  # Identity moved into _meta with the rest of the per-request metadata; there
  # is no handshake left to carry it in a result body.
  is $res->{result}{_meta}{'io.modelcontextprotocol/serverInfo'}{name}, 'share',
    'it names itself';
  like $res->{result}{instructions}, qr/hands a file from you to a human/,
    'and explains itself before a single tool call';
  ok $res->{result}{capabilities}{tools}, 'advertising tools';

  # The instructions are built from the running config, not frozen: an operator
  # who changes the retention or the size cap must not have the MCP server
  # telling every agent the old numbers.
  my $instructions = $res->{result}{instructions};
  like $instructions, qr/deleted 15 days after upload/,  'the real retention';
  like $instructions, qr/up to 32\.0 MB each/,           'the real size cap';
  like $instructions, qr/Office network only — ask #infra for access\./,
    'and the deployment notice the operator set, decoded exactly once';
  # The text wraps, so the phrase spans a newline — match across it rather than
  # assuming where the line breaks fall.
  like $instructions, qr/delete_password.*ONLY\s+time\s+you\s+will\s+ever\s+be\s+shown\s+it/s,
    'and it warns that the delete password is shown once';
};

subtest 'the routing headers must agree with the body' => sub {
  # A gateway that routes on Mcp-Method alone must never be able to disagree
  # with the server about which method was called.
  $t->post_ok('/mcp' => {'MCP-Protocol-Version' => $PROTOCOL, 'Mcp-Method' => 'tools/list'} =>
      json => {jsonrpc => '2.0', id => 1, method => 'server/discover',
        params => {_meta => {$META => $PROTOCOL, $CAPS => {}}}})->status_is(400);

  # But a request with NO MCP-Protocol-Version at all is not an error: revisions
  # before 2025-06-18 predate the header, so the transport reads it as a legacy
  # client and answers it as one. Dropping that would break every old client in
  # the field, which is exactly what MCP::Server::Legacy exists to avoid.
  $t->post_ok('/mcp' => json => {jsonrpc => '2.0', id => 1, method => 'tools/list'})
    ->status_is(200)->json_has('/result/tools');
};

subtest 'MCP: an unsupported protocol version is refused, with a list' => sub {
  # _meta carrying a version is what makes a request modern, whatever the header
  # says — so this is answered as a modern request with a version we do not
  # speak, not mistaken for a legacy one.
  my $res = _mcp('server/discover', undef, version => '1999-01-01', status => 400);
  ok $res->{error}, 'refused';
  is $res->{error}{code}, -32022, 'UnsupportedProtocolVersionError';
  is_deeply $res->{error}{data}{supported}, ['2026-07-28'], 'saying what it does speak';
};

subtest 'MCP: the legacy handshake still works' => sub {
  # Clients on the older initialize-based revisions have not all caught up, and
  # MCP::Server::Transport::HTTP answers them. Dropping this would break every
  # agent in the field today.
  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 1, method => 'initialize',
    params  => {protocolVersion => '2025-06-18', capabilities => {}, clientInfo => {name => 't'}},
  })->status_is(200)->json_is('/result/protocolVersion' => '2025-06-18')
    ->json_is('/result/serverInfo/name' => 'share');

  # ...and a legacy client can go on to list and call tools.
  $t->post_ok('/mcp' => {'MCP-Protocol-Version' => '2025-06-18'} => json =>
      {jsonrpc => '2.0', id => 2, method => 'tools/list'})->status_is(200);
  ok @{$t->tx->res->json('/result/tools')}, 'legacy tools/list still answers';
};

subtest 'MCP: tools/list' => sub {
  my $res = _mcp('tools/list');
  my $tools = $res->{result}{tools};
  is_deeply [sort map { $_->{name} } @$tools],
    [qw(delete_shared_file get_shared_file get_upload_url list_shared_files)],
    'four tools, and not one of them moves bytes';

  # The whole point of this server's shape, asserted structurally rather than by
  # grepping prose — the descriptions legitimately talk about bytes and content.
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

  # structured_result gives both the JSON text and structuredContent, so a
  # client can parse it without going through prose.
  my $out = $res->{result}{structuredContent};
  is $out->{method}, 'POST', 'POST';
  like $out->{upload_url}, qr{\Ahttps://share\.example\.test/api/v1/files\?},
    'pointing at the ordinary REST endpoint';
  like $out->{upload_url}, qr/filename=report\.md/,    'with the filename baked in';
  like $out->{upload_url}, qr/session_id=$SESSION/,     'and the session';
  like $out->{upload_url}, qr/title=A(?:%20|\+)report/, 'and the title, encoded';
  like $out->{command}, qr{\Acurl -fsS -F 'file=\@/tmp/report\.md'}, 'a runnable command';
  like $out->{next}, qr/delete_password/, 'and it says to keep the delete password';

  # Nothing was written: an abandoned call must cost nothing, because there is
  # deliberately no reservation to expire and reap.
  $t->get_ok("/api/v1/files?session_id=$SESSION")->status_is(200)->json_is('/count' => 2);

  # And the URL it produced actually works — this is the contract.
  my $upload = Mojo::URL->new($out->{upload_url});
  $t->post_ok($upload->path_query => form => {file => {content => "# a report\n",
      filename => 'report.md'}})->status_is(201)->json_is('/session_id' => $SESSION)
    ->json_is('/title' => 'A report')->json_like('/expires_in' => qr/^(?:2|3) days$/);
  my $made = $t->tx->res->json;

  # A missing required argument is caught by the library's JSON Schema check,
  # before our code runs at all.
  my $bad = _mcp('tools/call', {name => 'get_upload_url', arguments => {}});
  ok $bad->{error} || $bad->{result}{isError}, 'a missing filename is refused';

  _delete($made->{id}, $made->{delete_password})->code == 200 or die 'cleanup failed';
};

subtest 'MCP: reading a file back means being told where it is' => sub {
  my $res  = _mcp('tools/call', {name => 'get_shared_file', arguments => {id => $id}});
  my $info = $res->{result}{structuredContent};

  is $info->{id}, $id, 'the right file';
  is $info->{kind}, 'markdown', 'described fully';
  like $info->{url}, qr{/f/\Q$id\E\z}, 'the page for the human';
  like $info->{content_url}, qr{/api/v1/files/\Q$id\E/content\z}, 'the bytes for the agent';

  # The contents themselves are NOT in the response, at any size, and neither is
  # the delete password. Those are the two properties the design turns on.
  my $whole = to_json($res->{result});
  unlike $whole, qr/# Report/,       'the markdown never crosses the MCP boundary';
  unlike $whole, qr/delete_password/, 'and the delete password is never handed out again';

  $t->get_ok("/api/v1/files/$id/content")->status_is(200)->content_like(qr/# Report/);
};

subtest 'MCP: listing gives both URLs, and no passwords' => sub {
  my $res = _mcp('tools/call',
    {name => 'list_shared_files', arguments => {session_id => $SESSION}});
  my $out = $res->{result}{structuredContent};
  is $out->{count}, 2, 'both files';
  ok $_->{url} && $_->{content_url}, 'each carries a page URL and a content URL'
    for @{$out->{files}};
  unlike to_json($out), qr/delete_password/, 'and not one password among them';

  $res = _mcp('tools/call',
    {name => 'list_shared_files', arguments => {session_id => 'nobody at all'}});
  like $res->{result}{content}[0]{text}, qr/Nothing shared under that session id/,
    'an empty session says so plainly';
};

subtest 'MCP: deleting needs the password' => sub {
  my ($doomed, $password) = _upload('doomed-by-mcp.md', "# doomed\n");

  # The share URL is not enough, and the refusal does not say which half was
  # wrong — so this cannot be used to find out which ids exist.
  my $res = _mcp('tools/call',
    {name => 'delete_shared_file', arguments => {id => $doomed, delete_password => 'guess'}});
  ok $res->{result}{isError}, 'a wrong password is refused';
  like $res->{result}{content}[0]{text}, qr/no such file, or the wrong delete password/,
    'in the same words as a missing file';
  $t->get_ok("/f/$doomed")->status_is(200);

  $res = _mcp('tools/call',
    {name => 'delete_shared_file', arguments => {id => $doomed, delete_password => $password}});
  ok !$res->{result}{isError}, 'the right password works';
  $t->get_ok("/f/$doomed")->status_is(404);

  # A missing id is the same sentence again.
  $res = _mcp('tools/call',
    {name => 'delete_shared_file', arguments => {id => 'n' x 32, delete_password => 'x'}});
  ok $res->{result}{isError}, 'and a missing id too';
};

subtest 'MCP: an unknown tool is an error, not a crash' => sub {
  my $res = _mcp('tools/call', {name => 'no_such_tool', arguments => {}});
  ok $res->{error} || $res->{result}{isError}, 'refused';
};

subtest 'deleting from the browser takes two clicks, a password, and no JavaScript' => sub {
  # Reached from the upload result page, or by knowing the URL — not from the
  # viewer, which no longer offers it.
  $t->get_ok("/f/$id/delete")->status_is(200)->content_like(qr/Delete this file/)
    ->content_like(qr{name="delete_password"})->content_unlike(qr/<script/);

  # Knowing the share URL is not enough. Whoever was merely sent the link gets a
  # read-only page; only whoever uploaded it holds the password.
  $t->post_ok("/f/$id/delete" => form => {delete_password => 'not it'})->status_is(200)
    ->content_like(qr/no such file, or the wrong delete password/)
    ->content_like(qr/Delete this file/);
  $t->get_ok("/f/$id")->status_is(200);

  $t->post_ok("/f/$id/delete" => form => {delete_password => $delete_password})
    ->status_is(200)->content_like(qr/is gone/);
  $t->get_ok("/f/$id")->status_is(404);
  _delete($id, $delete_password)->code == 403 or die 'a deleted file must stay deleted';
};

subtest 'the delete password is disclosed exactly once' => sub {
  my ($once, $password) = _upload('once.md', "# once\n", session_id => 'disclosure');

  # Not in the metadata, not in the listing, not on the page a human opens.
  $t->get_ok("/api/v1/files/$once")->status_is(200);
  unlike to_json($t->tx->res->json), qr/delete_password/, 'not in the metadata';

  $t->get_ok('/api/v1/files?session_id=disclosure')->status_is(200);
  unlike to_json($t->tx->res->json), qr/delete_password/, 'not in the listing';

  $t->get_ok("/f/$once")->status_is(200)->content_unlike(qr/\Q$password\E/);

  _delete($once, $password)->code == 200 or die 'cleanup failed';
};

done_testing;
