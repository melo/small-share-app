package Share::MCP;

# A Streamable HTTP MCP server, stateless.
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

use JSON::PP    ();
use Mojo::JSON  qw(false true);
use Mojo::Util  qw(b64_encode);
use Share::Store qw(human_size payload_bytes);

our $VERSION = '1.0.0';

# Versions we know how to speak, newest first. An `initialize` asking for one of
# these is answered with that same version; anything else is answered with our
# newest, and the client decides whether it can live with that.
use constant VERSIONS => [qw(2025-06-18 2025-03-26 2024-11-05)];
use constant LATEST   => VERSIONS->[0];

# Images come back as a real MCP image block — that is the point of an agent
# being able to re-read a screenshot it shared. Past this size it is a link
# instead, because nobody wants 20 MB of base64 in a context window.
use constant MAX_INLINE => 5 * 1024 * 1024;

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
This server hands a file from you to a human being.

Upload with share_file and you get back a URL. Give that URL to the person you
are talking to, in plain text, and they open it in a browser. They see a page
with the file's name, size and expiry at the top, and the file itself rendered
below: markdown gets real typography and mermaid diagrams get drawn, images are
displayed, PDFs open in the browser's own viewer.

Use it whenever the answer is something to LOOK at rather than to read in a
terminal: a long report, a generated diagram, a screenshot, a PDF.

It works the other way too. A human can upload through the same web page and
hand you a URL; read what they sent with get_shared_file.

Things worth knowing:

  * Only markdown (.md), images (.png .jpg .gif .webp .svg) and .pdf are
    accepted, up to %s each. The extension on the filename must match the
    actual bytes.
  * Files are deleted %s days after upload and the URL dies with them. Pass
    ttl_days for something shorter. Nothing here is durable storage.
  * The URL is the only credential. It is unguessable, but treat it as a
    secret: anyone holding it can read and delete the file.
%s  * Pass your session_id on every upload. It costs nothing, and it is the only
    way list_shared_files can later tell you what you shared in this
    conversation.
TXT
}

# ------------------------------------------------------------------ tools ----

sub _str ($desc, %extra) { {type => 'string', description => $desc, %extra} }

sub tools {
  return [
    { name        => 'share_file',
      title       => 'Share a file with a human',
      description => 'Upload a markdown document, an image or a PDF and get back a '
        . 'URL to give to a human. Send text files in "content"; send binary files '
        . '(images, PDFs) base64-encoded in "content_base64". The extension on '
        . '"filename" decides how the file is rendered and must match the bytes.',
      inputSchema => {
        type       => 'object',
        required   => ['filename'],
        properties => {
          filename => _str('Filename with an extension: .md, .png, .jpg, .gif, .webp, .svg or .pdf'),
          content  => _str('The file as text. Use this for markdown and SVG.'),
          content_base64 =>
            _str('The file base64-encoded. Use this for PNG, JPEG, GIF, WebP and PDF.'),
          session_id => _str('Your session id, so list_shared_files can find this again later.'),
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
      description => 'List the files still live for a session id, newest first, each '
        . 'with the URL to hand to the human. Expired files are gone and are not listed.',
      inputSchema => {
        type       => 'object',
        required   => ['session_id'],
        properties => {session_id => _str('The session id used when the files were uploaded.')},
      },
    },

    { name        => 'get_shared_file_metadata',
      title       => 'Describe a shared file',
      description => 'Name, kind, size, checksum, expiry and view count for one shared '
        . 'file. Does not return the contents.',
      inputSchema => {
        type       => 'object',
        required   => ['id'],
        properties => {id => _str('The file id — the random part of its URL.')},
      },
    },

    { name        => 'get_shared_file',
      title       => 'Read a shared file back',
      description => 'Return the contents of a file you shared. Markdown comes back as '
        . 'text and images come back as images; PDFs and anything oversized come back '
        . 'as metadata plus the URL.',
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

sub _tool_share_file ($class, $c, $args) {
  my $row = $c->store->add(bytes => payload_bytes($args),
    map { $_ => $args->{$_} } qw(filename session_id title note ttl_days));
  my $info = $c->store->public($row, $c->base_url);

  return _data($info,
    { type => 'text',
      text => "Shared. Give this URL to the human, exactly as written:\n\n$info->{url}\n\n"
        . "It stops working in $info->{expires_in}.",
    });
}

sub _tool_list_shared_files ($class, $c, $args) {
  my $rows = $c->store->for_session($args->{session_id});
  my @info = map { $c->store->public($_, $c->base_url) } @$rows;
  return _text('Nothing shared under that session id is still live.') unless @info;
  return _data({count => scalar @info, files => \@info});
}

sub _tool_get_shared_file_metadata ($class, $c, $args) {
  my $row = $c->store->find($args->{id}) or return _tool_failed(_gone($args->{id}));
  return _data($c->store->public($row, $c->base_url));
}

sub _tool_get_shared_file ($class, $c, $args) {
  my $row = $c->store->find($args->{id}) or return _tool_failed(_gone($args->{id}));
  my $info = $c->store->public($row, $c->base_url);

  my $bytes = $c->store->contents($row);
  return _tool_failed("the metadata for $info->{id} is here but its contents are missing")
    unless defined $bytes;

  if ($row->{kind} eq 'markdown') {
    utf8::decode($bytes);
    return _text($bytes);
  }

  if ($row->{kind} eq 'image' && length($bytes) <= MAX_INLINE) {
    my ($mime) = $row->{content_type} =~ /\A([^;]+)/;
    return _result(
      { content => [
          {type => 'image', data => b64_encode($bytes, ''), mimeType => $mime},
          {type => 'text',  text => $JSON->encode($info)},
        ],
      });
  }

  return _data($info,
    { type => 'text',
      text => "$info->{filename} is a $info->{kind} of $info->{size_human}; it is not "
        . "returned inline. Open $info->{url} to see it.",
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
