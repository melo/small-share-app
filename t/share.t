#!/usr/bin/env perl

# The build runs this before assembling the runtime image, so a broken
# sanitiser, a broken upload path or a broken MCP handshake never gets deployed.
#
# Run it by hand with:  cd app && SHARE_ROOT=$(mktemp -d) prove -lv t/share.t

use Mojo::Base -strict, -signatures;
use utf8;

use File::Temp   ();
use Mojo::File   qw(curfile);
use Mojo::JSON   qw(decode_json encode_json);
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

subtest 'the home page explains itself' => sub {
  $t->get_ok('/')->status_is(200)->content_like(qr/hand a file/i)
    ->content_like(qr{/mcp})->header_like('Content-Security-Policy' => qr/default-src 'none'/)
    ->content_like(qr/Office network only — ask #infra for access\./)
    ->content_unlike(qr/Ã|â€/);    # double-encoded UTF-8, which is what a bytes bug looks like
};

subtest 'the uploader is a plain form that works without JavaScript' => sub {
  $t->get_ok('/')->status_is(200)
    ->content_like(qr{<details class="uploader">})
    ->content_like(qr{<summary class="btn primary">Share a file with an agent</summary>})
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
    ->content_like(qr{<button class="btn result-copy" type="button" data-copy="https://share\.example\.test/f/[A-Za-z0-9]{32}" hidden>Copy</button>});

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
  my @names = sort map { $_->{name} } @{$t->tx->res->json('/result/tools')};
  is_deeply \@names,
    [qw(delete_shared_file get_shared_file get_shared_file_metadata list_shared_files share_file)],
    'all five tools are advertised';
};

my $mcp_id;

subtest 'MCP: share_file' => sub {
  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 4, method => 'tools/call',
    params  => {
      name      => 'share_file',
      arguments => {filename => 'via-mcp.md', content => "# via mcp\n", session_id => $SESSION},
    },
  })->status_is(200)->json_hasnt('/result/isError');

  my $text = $t->tx->res->json('/result/content/0/text');
  my $info = decode_json($text);
  $mcp_id = $info->{id};
  like $info->{url}, qr{\Ahttps://share\.example\.test/f/\Q$mcp_id\E\z}, 'the URL is spelled out';
  like $t->tx->res->json('/result/content/1/text'), qr/Give this URL to the human/,
    'and it is repeated in prose the model will actually read';
};

subtest 'MCP: read it back, then delete it' => sub {
  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 5, method => 'tools/call',
    params  => {name => 'get_shared_file', arguments => {id => $mcp_id}},
  })->status_is(200)->json_like('/result/content/0/text' => qr/# via mcp/);

  $t->post_ok('/mcp' => json => {
    jsonrpc => '2.0', id => 6, method => 'tools/call',
    params  => {name => 'delete_shared_file', arguments => {id => $mcp_id}},
  })->status_is(200)->json_like('/result/content/0/text' => qr/Deleted/);

  $t->get_ok("/f/$mcp_id")->status_is(404);
};

subtest 'MCP: reading files back in each shape' => sub {
  # An image comes back as a real MCP image block — the point of an agent being
  # able to re-read a screenshot it shared — with the metadata alongside it.
  my $png = _mcp('tools/call',
    {name => 'share_file', arguments => {filename => 'inline.png', content_base64 => $PNG_B64}});
  my $png_id = decode_json($png->{result}{content}[0]{text})->{id};

  my $got = _mcp('tools/call', {name => 'get_shared_file', arguments => {id => $png_id}});
  is $got->{result}{content}[0]{type}, 'image', 'an image comes back as an image block';
  is $got->{result}{content}[0]{mimeType}, 'image/png', 'with its real mime type';
  is $got->{result}{content}[0]{data}, $PNG_B64, 'and the bytes round-trip exactly';

  # A PDF is described rather than inlined: nobody wants megabytes of base64 in
  # a context window.
  my $pdf = _mcp('tools/call', {name => 'share_file',
    arguments => {filename => 'doc.pdf', content_base64 => $PDF_B64}});
  my $pdf_id = decode_json($pdf->{result}{content}[0]{text})->{id};

  $got = _mcp('tools/call', {name => 'get_shared_file', arguments => {id => $pdf_id}});
  is $got->{result}{content}[0]{type}, 'text', 'a PDF is not inlined';
  like $got->{result}{content}[1]{text}, qr/not\s+returned inline/,
    'and it says so, with the URL to open';

  my $meta = _mcp('tools/call',
    {name => 'get_shared_file_metadata', arguments => {id => $pdf_id}});
  my $info = decode_json($meta->{result}{content}[0]{text});
  is $info->{kind}, 'pdf', 'metadata knows what it is';
  is $info->{content_type}, 'application/pdf', 'and its content type';

  # Every "no such thing" path answers the same way.
  for my $tool (qw(get_shared_file get_shared_file_metadata delete_shared_file)) {
    my $res = _mcp('tools/call', {name => $tool, arguments => {id => 'n' x 32}});
    ok $res->{result}{isError}, "$tool on a missing id is a tool error";
    like $res->{result}{content}[0]{text}, qr/no live file/, "$tool says why";
  }

  $t->post_ok('/mcp' => json =>
      {jsonrpc => '2.0', id => 90, method => 'tools/call',
        arguments => {}, params => {name => 'list_shared_files',
          arguments => {session_id => 'nobody at all'}}})->status_is(200)
    ->json_like('/result/content/0/text' => qr/Nothing shared under that session id/);

  $t->delete_ok("/api/v1/files/$png_id")->status_is(200);
  $t->delete_ok("/api/v1/files/$pdf_id")->status_is(200);
};

subtest 'MCP: base64 that is not base64, and text that is' => sub {
  my $res = _mcp('tools/call', {name => 'share_file',
    arguments => {filename => 'x.png', content_base64 => '!!! not base64 !!!'}});
  ok $res->{result}{isError}, 'a bad base64 payload is a tool error';
  like $res->{result}{content}[0]{text}, qr/not valid base64/, 'and says so';

  # base64url — '-' and '_' instead of '+' and '/' — is a common enough mistake
  # that it is simply accepted.
  my $url_safe = $PNG_B64 =~ tr{+/}{-_}r;
  $res = _mcp('tools/call',
    {name => 'share_file', arguments => {filename => 'urlsafe.png', content_base64 => $url_safe}});
  ok !$res->{result}{isError}, 'base64url is accepted rather than refused';
  $t->delete_ok('/api/v1/files/' . decode_json($res->{result}{content}[0]{text})->{id});
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
    params  => {name => 'share_file', arguments => {filename => 'nope.md'}},
  })->status_is(200)->json_is('/result/isError' => 1)
    ->json_like('/result/content/0/text' => qr/content/);

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
