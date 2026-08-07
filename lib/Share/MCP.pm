package Share::MCP;

# The MCP server, built on the CPAN MCP distribution (MCP::Server, by the
# Mojolicious author). It speaks protocol revision 2026-07-28 — stateless, no
# initialize handshake, `server/discover` in its place — and the HTTP transport
# answers the older initialize-based handshake for clients that have not caught
# up. Both eras, one endpoint, none of it our code.
#
# This file used to be 330 lines of hand-rolled JSON-RPC against the 2025-06-18
# revision. Version negotiation, Origin validation, the 405s on GET and DELETE,
# batching, error codes and schema validation of tool arguments all belong to
# the library now. What is left is the four tools and what they say.
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
  $server->tool(
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

  $server->tool(
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

  $server->tool(
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

  $server->tool(
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

1;
