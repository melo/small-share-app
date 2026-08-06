package Share::MCP;

# A Streamable HTTP MCP server, stateless, and deliberately WITHOUT a data path.
#
# No tool here carries file bytes in either direction. Uploading means calling
# get_upload_url and then running the command it hands back; reading a file back
# means fetching its content_url. MCP is the control plane, HTTP is the data
# plane, and the two never mix.
#
# The reason is arithmetic. A tool argument or result passes through the model's
# context verbatim, and base64 inflates by a third: a 20 KB screenshot costs
# thousands of tokens to send and thousands more to read back, and a 3 MB PDF
# does not fit at all. Meanwhile `curl -F file=@…` moves it off disk for nothing.
# Once uploads work that way, having downloads work differently would just be an
# inconsistency for an agent to trip over.
#
# The cost, stated plainly: an MCP client with no shell and no HTTP tool can no
# longer upload through this server at all. That is the trade — it is the right
# one for a coding agent, which has both.
#
# "Stateless" is doing real work here: we never issue an Mcp-Session-Id, so
# there is nothing to expire, nothing pinning a client to a particular worker,
# and prefork needs no shared session store. Every POST is self-contained. The
# transport spec explicitly allows answering a request with a single
# application/json body instead of opening an SSE stream, and since no tool here
# streams progress or asks the client anything, that is all we ever do.
#
# The HTTP framing — Origin check, protocol-version header, 405 on GET/DELETE —
# is in share.pl. This module is the JSON-RPC layer and the tools.

use Mojo::Base -strict, -signatures;
use utf8;

use JSON::PP     ();
use Mojo::JSON   qw(false true);
use Mojo::URL    ();
use Share::Store qw(human_size);

our $VERSION = '1.0.0';

# Versions we know how to speak, newest first. An `initialize` asking for one of
# these is answered with that same version; anything else is answered with our
# newest, and the client decides whether it can live with that.
use constant VERSIONS => [qw(2025-06-18 2025-03-26 2024-11-05)];
use constant LATEST   => VERSIONS->[0];

# Pretty and key-ordered: this JSON is read by a model, and by a human reading
# the model's transcript.
my $JSON = JSON::PP->new->pretty->canonical->allow_nonref;

# What an agent is told before it has made a single tool call. Anything wrong
# here shows up later as an agent misusing the service, so it says what the URL
# is for, who can open it, and how long it lasts.
#
# Built from the running configuration rather than frozen into a constant: an
# operator who sets a 3-day retention should not have an MCP server telling
# every agent it is 15.
sub _instructions ($c) {
  my $cfg = $c->app->config;

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

They open it in a browser and see the file's name, size and expiry at the top,
with the file itself rendered below: markdown gets real typography and mermaid
diagrams get drawn, images are displayed, PDFs open in the browser's own viewer.

Use it whenever the answer is something to LOOK at rather than to read in a
terminal: a long report, a generated diagram, a screenshot, a PDF.

To read a file back, including one a human uploaded and sent you: call
get_shared_file for its metadata, then fetch the "content_url" it returns. Do
not ask this server for the contents; it will only ever give you the URL.

Things worth knowing:

  * Only markdown (.md), images (.png .jpg .gif .webp .svg .heic) and .pdf are
    accepted, up to %s each. The extension on the filename must match the
    actual bytes, or the upload is refused.
  * Files are deleted %s days after upload and the URL dies with them. Pass
    ttl_days for something shorter. Nothing here is durable storage.
  * The URL is the only credential. It is unguessable, but treat it as a
    secret: anyone holding it can read and delete the file.
%s  * Pass your session_id every time. It costs nothing, and it is the only way
    list_shared_files can later tell you what you shared in this conversation.
TXT
}

# ------------------------------------------------------------------ tools ----

sub _str ($desc, %extra) { {type => 'string', description => $desc, %extra} }

sub tools {
  return [
    { name        => 'get_upload_url',
      title       => 'Get a URL to upload a file to',
      description => 'Hand back a URL, and a ready-to-run curl command, for putting a '
        . 'file where a human can read it. Run the command; the JSON it prints contains '
        . '"url", which is what you give the person. This server never accepts the file '
        . 'itself — that is what keeps a large PDF or screenshot out of your context.',
      inputSchema => {
        type       => 'object',
        required   => ['filename'],
        properties => {
          filename => _str('The name to store it under, WITH an extension: .md, .png, '
              . '.jpg, .gif, .webp, .svg, .heic or .pdf. The extension must match the '
              . 'actual bytes or the upload is refused.'),
          path       => _str('Where the file is on your disk. Only used to write the '
              . 'example command for you; this server never sees it.'),
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
    },

    { name        => 'list_shared_files',
      title       => 'List what I have shared',
      description => 'List the files still live for a session id, newest first. Each one '
        . 'carries "url" (the page to give a human) and "content_url" (the bytes, for '
        . 'you to fetch). Expired files are gone and are not listed.',
      inputSchema => {
        type       => 'object',
        required   => ['session_id'],
        properties => {session_id => _str('The session id used when the files were uploaded.')},
      },
    },

    { name        => 'get_shared_file',
      title       => 'Describe a shared file and say where to fetch it',
      description => 'Everything known about one shared file — name, kind, size, '
        . 'checksum, expiry, view count — plus "url" for the human and "content_url" '
        . 'for you. To read the contents, fetch content_url; this tool will not return '
        . 'them.',
      inputSchema => {
        type       => 'object',
        required   => ['id'],
        properties => {id => _str('The file id — the random part of its URL.')},
      },
    },

    { name        => 'delete_shared_file',
      title       => 'Delete a shared file',
      description => 'Delete a shared file now, before its expiry. The URL stops working '
        . 'immediately. Use this once the human has confirmed they are done with it, or '
        . 'if you shared something by mistake.',
      inputSchema => {
        type       => 'object',
        required   => ['id'],
        properties => {id => _str('The file id — the random part of its URL.')},
      },
    },
  ];
}

# Built FROM the declared tool list rather than from `can("_tool_$name")`, so a
# client cannot reach a helper that merely happens to be named like a tool.
my %TOOL = map { $_->{name} => __PACKAGE__->can("_tool_$_->{name}") } @{tools()};

# ---------------------------------------------------------------- jsonrpc ----

# Returns a JSON-RPC response hashref, or undef for anything the client is not
# expecting an answer to (notifications, and responses to us).
sub respond ($class, $c, $msg) {
  return _error(undef, -32600, 'not a JSON-RPC 2.0 message')
    unless ref $msg eq 'HASH' && ($msg->{jsonrpc} // '') eq '2.0';

  my $method = $msg->{method};
  my $id     = $msg->{id};
  return undef unless defined $method && defined $id;

  my $res = $class->_dispatch($c, $msg->{method},
    ref $msg->{params} eq 'HASH' ? $msg->{params} : {});
  return undef unless defined $res;

  $res->{jsonrpc} = '2.0';
  $res->{id}      = $id;
  return $res;
}

sub _dispatch ($class, $c, $method, $params) {
  if ($method eq 'initialize') {
    my $want = $params->{protocolVersion} // '';
    my $version = (grep { $_ eq $want } @{+VERSIONS}) ? $want : LATEST;
    return _result(
      { protocolVersion => $version,
        capabilities    => {tools => {listChanged => false}},
        serverInfo   => {name => 'share', title => 'Share a file with a human', version => $VERSION},
        instructions => _instructions($c),
      });
  }

  return _result({})                 if $method eq 'ping';
  return _result({tools => tools()}) if $method eq 'tools/list';

  if ($method eq 'tools/call') {
    my $name = $params->{name} // '';
    my $tool = $TOOL{$name} or return _fail(-32602, qq{no such tool: "$name"});
    my $args = ref $params->{arguments} eq 'HASH' ? $params->{arguments} : {};

    my $res = eval { $class->$tool($c, $args) };
    return $res unless $@;
    return _tool_failed(_message($@));
  }

  return _fail(-32601, qq{method not found: "$method"});
}

sub _result ($result) { {result => $result} }
sub _fail   ($code, $message) { {error => {code => $code, message => $message}} }
sub _error  ($id, $code, $message) {
  return {jsonrpc => '2.0', id => $id, error => {code => $code, message => $message}};
}

# A tool that fails is NOT a protocol error: the model needs to see what went
# wrong so it can fix its call, which means an ordinary result carrying isError.
sub _tool_failed ($message) {
  return _result({isError => true, content => [{type => 'text', text => $message}]});
}
sub _text ($text, @more) { _result({content => [{type => 'text', text => $text}, @more]}) }
sub _data ($data, @more) { _text($JSON->encode($data), @more) }

sub _message ($err) {
  return $err->{share_error} if ref $err eq 'HASH' && $err->{share_error};
  my $msg = "$err";
  chomp $msg;
  return $msg;
}

# -------------------------------------------------------------- the tools ----

# Stateless on purpose: no reservation is created, nothing is written, and there
# is no half-finished upload to expire and reap later. The URL this returns is
# just the ordinary REST endpoint with the metadata already encoded into it, so
# an abandoned call costs exactly nothing.
#
# If authentication ever arrives, THIS is where a one-time ticket would be
# minted — which is the other reason the flow goes through a tool at all rather
# than the instructions simply naming the endpoint.
sub _tool_get_upload_url ($class, $c, $args) {
  my $filename = $args->{filename};
  return _tool_failed('filename is required, and it needs an extension so the type can '
      . 'be checked against the bytes')
    unless defined $filename && length $filename;

  my $url = Mojo::URL->new($c->base_url . '/api/v1/files');
  my %query = (filename => $filename);
  for my $key (qw(session_id title note ttl_days)) {
    $query{$key} = $args->{$key} if defined $args->{$key} && length $args->{$key};
  }
  $url->query(\%query);

  my $path = $args->{path} // "/path/to/$filename";
  my $command = sprintf q{curl -fsS -F 'file=@%s' '%s'}, $path, $url;

  return _data(
    { upload_url => "$url",
      method     => 'POST',
      command    => $command,
      body       => 'multipart/form-data with a part named "file"; or the raw bytes as '
        . 'the request body, since the filename is already in the query string',
      max_bytes  => 0 + $c->app->config->{max_bytes},
      next       => 'The JSON response contains "url" — give that to the human, and '
        . '"content_url" if you need to read the file back yourself.',
    },
    { type => 'text',
      text => "Run this, then give the human the \"url\" from the JSON it prints:\n\n"
        . "  $command\n",
    });
}

sub _tool_list_shared_files ($class, $c, $args) {
  my $rows = $c->store->for_session($args->{session_id});
  my @info = map { $c->store->public($_, $c->base_url) } @$rows;
  return _text('Nothing shared under that session id is still live.') unless @info;
  return _data({count => scalar @info, files => \@info});
}

sub _tool_get_shared_file ($class, $c, $args) {
  my $row = $c->store->find($args->{id}) or return _tool_failed(_gone($args->{id}));
  my $info = $c->store->public($row, $c->base_url);

  return _data($info,
    { type => 'text',
      text => "$info->{filename} is a $info->{kind} of $info->{size_human}, expiring in "
        . "$info->{expires_in}.\n\n"
        . "Give the human:  $info->{url}\n"
        . "Read it yourself: curl -fsS '$info->{content_url}'\n",
    });
}

sub _tool_delete_shared_file ($class, $c, $args) {
  my $id = $args->{id} // '';
  return _tool_failed(_gone($id)) unless $c->store->remove($id);
  return _text("Deleted $id. The URL no longer works.");
}

sub _gone ($id) {
  $id = '' unless defined $id;
  return qq{no live file with id "$id" — it was deleted, or it expired};
}

1;
