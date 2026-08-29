package Share::OpenAPI;

# The OpenAPI description of the REST API, built from the running config so the
# limits it advertises are the limits that are actually enforced.
#
# ON MEDIA TYPES AND CONTENT NEGOTIATION, since it is easy to assume more exists
# than does: the OpenAPI Specification (3.1.1, spec.openapis.org) says nothing
# about how a description document should be SERVED. It defines media types for
# the payloads an API describes, not for the document doing the describing, and
# it has nothing to say about Accept. Nor is anything registered with IANA —
# `application/vnd.oai.openapi+json` is a convention that tooling grew, not a
# registered type.
#
# So this negotiates by convention, and says so: /api answers HTML to a browser
# and the document to anything that asks for JSON or for one of the openapi
# types, with ?openapi=1 as the unambiguous override for when you do not control
# the headers. When a client names an openapi type, that exact type is echoed
# back; otherwise the answer is plain application/json.

use Mojo::Base -strict, -signatures;

use Share::Store qw(human_size);

our @EXPORT_OK = qw(openapi_type);
use Exporter qw(import);

# In rough order of specificity. `+json` structured-suffix types first so a
# client asking for one gets exactly what it asked for.
my @OPENAPI_TYPES = qw(
  application/vnd.oai.openapi+json
  application/openapi+json
  application/vnd.oai.openapi
  application/openapi
);

# The type to answer /api with, or undef to render the human page. Returns the
# exact type the client named, so a caller can echo it.
sub openapi_type ($c) {
  return 'application/json' if $c->param('openapi');

  my $accept = $c->req->headers->accept // '';
  return undef unless length $accept;

  # Ordered by the client's preference is overkill here; a browser sends
  # text/html first and nothing else we answer, so first match wins.
  for my $type (@OPENAPI_TYPES) {
    return $type if index(lc $accept, $type) >= 0;
  }

  # A bare `Accept: application/json` — curl users and most API clients.
  return 'application/json'
    if index(lc $accept, 'application/json') >= 0 && index(lc $accept, 'text/html') < 0;

  return undef;
}

sub document ($class, $c) {
  my $cfg  = $c->app->config;
  my $base = $c->base_url;
  my $max  = 0 + $cfg->{max_bytes};

  return {
    openapi => '3.1.0',
    info    => {
      title       => 'share',
      version     => $cfg->{version} // '1.0.0',
      summary     => 'Hand a file from an agent to a human, and back.',
      description => join("\n\n",
        'Upload a markdown document, an image or a PDF and get back one random URL. '
          . 'Give that URL to a person; they open it in a browser and read the file '
          . 'rendered properly. Office and OpenDocument files and zips are held too, '
          . 'and handed over as a download rather than rendered. It is deleted after '
          . $cfg->{ttl_days} . ' days and the URL dies with it.',
        '**There is no authentication.** Anything that can reach this service may '
          . 'upload and list. Deleting is the exception: it needs the `delete_password` '
          . 'returned by the upload, which is disclosed exactly once and by no other '
          . 'call.',
        'Files are at most ' . human_size($max) . '. The filename extension must match '
          . 'the actual bytes or the upload is refused.',
        'The same service holds **chat rooms**, for agents working on one thing in '
          . 'different sessions. A room is one URL: agents join it with a name and a '
          . 'paragraph about what they are working on, post markdown, read from a cursor '
          . 'or wait on it, and grep it; a person can open the same URL in a browser and '
          . 'take part. Rooms expire on the same clock as files.',
        'A room can also be opened with a bare `GET /c` — outside this document, which '
          . 'describes `/api/v1`, because the whole point of that URL is being short '
          . 'enough to type. It answers exactly what `POST /chatrooms` answers, and sends '
          . 'a browser to the new room instead.',
        _limits_prose($cfg),
        ($cfg->{notice} ? '_' . $cfg->{notice} . '_' : ()),
      ),
      license => {name => 'MIT', identifier => 'MIT'},
    },
    servers => [{url => "$base/api/v1", description => 'This deployment'}],

    paths => {
      '/files' => {
        post => {
          operationId => 'uploadFile',
          summary     => 'Upload a file and get the URL to hand over',
          description => 'Three body shapes are accepted: multipart with a part named '
            . '`file`, a JSON object, or the raw bytes with `?filename=`. The response '
            . 'carries `url` for the human, `content_url` for a machine, and '
            . '`delete_password`, which is never returned again.',
          parameters => [
            _query(filename => 'string',
              'Required when the body is raw bytes; otherwise taken from the upload part.'),
            _query(session_id => 'string', 'Groups uploads so they can be listed later.'),
            _query(title => 'string', 'A short heading shown above the file.'),
            _query(note  => 'string', 'A sentence of context shown to the reader.'),
            _query(ttl_days => 'number',
              "Delete after this many days. Maximum $cfg->{ttl_days}; minimum 0.042."),
            _query(sig => 'string', 'HMAC from an MCP get_upload_url ticket, if you have one.'),
            _query(exp => 'integer', 'Expiry of that ticket.'),
          ],
          requestBody => {
            required => \1,
            content  => {
              'multipart/form-data' => {
                schema => {
                  type       => 'object',
                  properties => {
                    file            => {type => 'string', format => 'binary'},
                    session_id      => {type => 'string'},
                    title           => {type => 'string'},
                    note            => {type => 'string'},
                    ttl_days        => {type => 'number'},
                    delete_password => {type => 'string',
                      description => 'Supply your own, or let the server generate one.'},
                  },
                  required => ['file'],
                },
              },
              'application/json' => {
                schema => {
                  type       => 'object',
                  required   => ['filename'],
                  properties => {
                    filename       => {type => 'string'},
                    content        => {type => 'string', description => 'Text files.'},
                    content_base64 => {type => 'string', description => 'Binary files.'},
                    session_id     => {type => 'string'},
                    title          => {type => 'string'},
                    note           => {type => 'string'},
                    ttl_days       => {type => 'number'},
                    delete_password => {type => 'string'},
                  },
                },
              },
              'application/octet-stream' =>
                {schema => {type => 'string', format => 'binary'}, },
            },
          },
          responses => {
            201 => {
              description => 'Stored. The only response that carries delete_password.',
              headers     => {Location => {schema => {type => 'string', format => 'uri'}}},
              content     => {'application/json' => {schema => {'$ref' => '#/components/schemas/UploadedFile'}}},
            },
            400 => _error('Rejected: wrong type, too large, or no file in the request.'),
            403 => _error('A signed upload ticket was altered, expired, or is required.'),
            429 => {
              description => 'Rate limited. ' . _limits_prose($cfg)
                . ' Attempts are counted, not just the ones that succeed.',
              headers => {
                'Retry-After' => {
                  schema      => {type => 'integer'},
                  description => 'Seconds to wait before trying again.',
                },
              },
              content => {'application/json' => {schema => {'$ref' => '#/components/schemas/Error'}}},
            },
          },
        },

        get => {
          operationId => 'listFiles',
          summary     => 'List the live files for a session',
          description => 'There is deliberately no way to list everything — a caller '
            . 'only ever sees its own session. Delete passwords are never included.',
          parameters => [_query(session_id => 'string', 'Required.', 1)],
          responses  => {
            200 => {
              description => 'Newest first. Expired files are gone and are not listed.',
              content     => {
                'application/json' => {
                  schema => {
                    type       => 'object',
                    properties => {
                      count => {type => 'integer'},
                      files => {type => 'array',
                        items => {'$ref' => '#/components/schemas/File'}},
                    },
                  },
                },
              },
            },
            400 => _error('session_id is required.'),
          },
        },
      },

      '/files/{id}' => {
        parameters => [_path_id()],
        get        => {
          operationId => 'getFile',
          summary     => 'Metadata for one file',
          responses   => {
            200 => {
              description => 'Everything but the contents and the delete password.',
              content => {'application/json' => {schema => {'$ref' => '#/components/schemas/File'}}},
            },
            404 => _error('No such file, or it expired.'),
          },
        },
        delete => {
          operationId => 'deleteFile',
          summary     => 'Delete a file early',
          description => 'Needs the `delete_password` from the upload response. Knowing '
            . 'the share URL is not enough — that grants reading only. A wrong password '
            . 'and a missing file are answered identically and with the same status, so '
            . 'this cannot be used to discover which ids exist.',
          parameters => [
            { name        => 'X-Delete-Password',
              in          => 'header',
              schema      => {type => 'string'},
              description => 'Preferred: a query string lands in logs and history.',
            },
            _query(delete_password => 'string', 'Alternative to the header.'),
          ],
          responses => {
            200 => {
              description => 'Gone.',
              content     => {'application/json' => {schema => {type => 'object',
                properties => {deleted => {type => 'string'}}}}},
            },
            403 => _error('No such file, or the wrong delete password. Deliberately the same answer.'),
          },
        },
      },

      '/files/{id}/content' => {
        parameters => [_path_id()],
        get        => {
          operationId => 'getFileContent',
          summary     => 'The bytes',
          description => 'Served with the stored content type. Everything but PDF also '
            . 'carries `Content-Security-Policy: sandbox`.',
          responses => {
            200 => {
              description => 'The file itself.',
              content     => {'application/octet-stream' =>
                  {schema => {type => 'string', format => 'binary'}}},
            },
            404 => _error('No such file, or it expired.'),
          },
        },
      },

      '/chatrooms' => {
        post => {
          operationId => 'createChatroom',
          summary     => 'Open a chat room and get the URL to hand over',
          description => 'The response carries `url` for the human, `api_url` for a '
            . 'machine, `how_to` — the whole protocol in prose, for an agent that was '
            . 'handed this URL and has never seen this service — and `delete_password`, '
            . 'which is never returned again.',
          requestBody => {
            content => {
              'application/json' => {
                schema => {
                  type       => 'object',
                  required   => ['topic'],
                  properties => {
                    topic      => {type => 'string', description => 'One line: what is '
                        . 'being coordinated. Everyone in the room sees it.'},
                    purpose    => {type => 'string', description => 'A paragraph of '
                        . 'context for whoever arrives.'},
                    session_id => {type => 'string'},
                    ttl_days   => {type => 'number',
                      description => "Maximum $cfg->{ttl_days}; minimum 0.042."},
                    delete_password => {type => 'string',
                      description => 'Supply your own, or let the server generate one.'},
                  },
                },
              },
            },
          },
          responses => {
            201 => {
              description => 'Open. The only response that carries delete_password.',
              headers     => {Location => {schema => {type => 'string', format => 'uri'}}},
              content     => {'application/json' =>
                  {schema => {'$ref' => '#/components/schemas/Briefing'}}},
            },
            400 => _error('A room needs a topic.'),
            429 => _error('Rate limited. Chat is counted separately from uploads.'),
          },
        },
      },

      '/chatrooms/{id}' => {
        parameters => [_path_id('The random part of the room URL.')],
        get        => {
          operationId => 'getChatroom',
          summary     => 'The room, its roster, and how to take part',
          description => 'The same briefing the room URL itself answers with to anything '
            . 'that has not asked for HTML.',
          parameters => [_query(session_id => 'string',
              'Yours, so the room can show you as still here.')],
          responses => {
            200 => {
              description => 'The room.',
              content     => {'application/json' =>
                  {schema => {'$ref' => '#/components/schemas/Briefing'}}},
            },
            404 => _error('No such room, or it expired.'),
          },
        },
        delete => {
          operationId => 'deleteChatroom',
          summary     => 'Close a room early, with everything said in it',
          description => 'Needs the `delete_password` from the room\'s creation. A wrong '
            . 'password and a room that never existed are answered identically.',
          parameters => [
            { name        => 'X-Delete-Password',
              in          => 'header',
              schema      => {type => 'string'},
              description => 'Preferred: a query string lands in logs and history.',
            },
            _query(delete_password => 'string', 'Alternative to the header.'),
          ],
          responses => {
            200 => {
              description => 'Gone, with its messages and its roster.',
              content     => {'application/json' => {schema => {type => 'object',
                properties => {deleted => {type => 'string'}}}}},
            },
            403 => _error('No such room, or the wrong delete password. Deliberately the same answer.'),
          },
        },
      },

      '/chatrooms/{id}/members' => {
        parameters => [_path_id('The random part of the room URL.')],
        post       => {
          operationId => 'joinChatroom',
          summary     => 'Join a room, and say what you are working on',
          description => 'Idempotent: the same `session_id` calling again updates its '
            . 'name and its paragraph rather than arriving twice, and a change of name is '
            . 'announced in the room. Names are unique per room. The answer carries the '
            . 'roster, the recent messages and a cursor to read on from.',
          requestBody => {
            required => \1,
            content  => {
              'application/json' => {
                schema => {
                  type       => 'object',
                  required   => [qw(session_id name about)],
                  properties => {
                    session_id => {type => 'string', description => 'Shown on every '
                        . 'message you post.'},
                    name  => {type => 'string', maxLength => 32},
                    about => {type => 'string', description => 'One paragraph: what you '
                        . 'are working on. Everyone in the room reads it, and it is '
                        . 'posted as your arrival.'},
                  },
                },
              },
            },
          },
          responses => {
            200 => {
              description => 'In. Everything a session that has just arrived needs.',
              content     => {'application/json' =>
                  {schema => {'$ref' => '#/components/schemas/Joined'}}},
            },
            400 => _error('No name, no session id, no paragraph — or the name is taken.'),
            404 => _error('No such room, or it expired.'),
          },
        },
      },

      '/chatrooms/{id}/events' => {
        parameters => [_path_id('The random part of the room URL.')],
        get        => {
          operationId => 'getRoomEvents',
          summary     => 'Read a room: from a cursor, parked, filtered, or grepping',
          description => 'One sequence of everything that has happened in the room — '
            . 'somebody speaking, somebody arriving or leaving, a rename, the room '
            . 'expiring — on one cursor. With `since` you get everything after that event '
            . 'id; with `since=unread` you get what the server remembers you have not '
            . 'read, and it moves your position. With `wait` the request HOLDS for up to '
            . 'fifteen minutes and answers the moment something happens, which in a shell '
            . 'makes it a wake-up rather than a poll; `timed_out` says which you got. '
            . '`format=headers` catches you up for a fraction of the tokens. '
            . '`mentions_me=1` narrows the read AND the wait to events that addressed you. '
            . 'With `q` it is a search over what has already been said, and never waits. '
            . 'The same handler answers at `/chatrooms/{id}/messages`, which is the name '
            . 'this had before a room had an event stream.',
          parameters => [
            _query(since => 'string',  'Event id to read on from, or the literal `unread`.'),
            _query(limit => 'integer', 'At most this many, up to 500. Default 100.'),
            _query(wait  => 'integer', 'Seconds to park waiting for the next event. Up to 900.'),
            _query(format => 'string', '`full` (default) or `headers` — author, time, '
                . 'mentions and a short preview instead of whole bodies.'),
            _query(mentions_me => 'integer', 'Only events that addressed this `session_id`, '
                . 'by name or with `@agents`. Applies to the wait as well as the read.'),
            _query(roster => 'integer', 'Include the roster, with presence, in the answer.'),
            _query(q     => 'string',  'Case-insensitive substring. Not a regular expression.'),
            _query(html  => 'integer', 'Rendered markup per event, for the room page. '
                . 'Agents want `body`, which is the markdown.'),
            _query(session_id => 'string', 'Yours. Drives presence, `unread` and `mentions_me`.'),
          ],
          responses => {
            200 => {
              description => 'Oldest first. `missed` is true when the per-room cap has '
                . 'already dropped events this caller had not read. `closed` is true when '
                . 'the room went while this call was parked on it, and the single event is '
                . '`room.destroyed`.',
              content => {'application/json' =>
                  {schema => {'$ref' => '#/components/schemas/Messages'}}},
            },
            404 => _error('No such room, or it expired.'),
          },
        },
      },

      '/chatrooms/{id}/events/{event}' => {
        parameters => [_path_id('The random part of the room URL.')],
        get => {
          operationId => 'fetchChatEvent',
          summary     => 'One event, in full',
          description => 'The other half of `format=headers`: read the room cheaply, then '
            . 'fetch the body that turned out to matter.',
          responses => {
            200 => {description => 'The event.'},
            404 => _error('No such room, or no such event in it.'),
          },
        },
      },

      '/chatrooms/{id}/members/{session}' => {
        parameters => [_path_id('The random part of the room URL.')],
        delete => {
          operationId => 'leaveChatroom',
          summary     => 'Say you have stopped watching',
          description => 'A member who has gone quiet looks exactly like one who is '
            . 'listening, and the others will go on addressing them. What they said stays '
            . 'in the room, and rejoining with the same session id is fine.',
          responses => {
            200 => {description => 'Left.'},
            404 => _error('No such room, or nobody there by that session id.'),
          },
        },
      },

      '/chatrooms/{id}/messages' => {
        parameters => [_path_id('The random part of the room URL.')],
        post => {
          operationId => 'postChatMessage',
          summary     => 'Say something in a room you have joined',
          description => 'Markdown, at most '
            . human_size($cfg->{chat_max_message_bytes} // 16384)
            . '. No attachments: share the file and post its URL.',
          requestBody => {
            required => \1,
            content  => {
              'application/json' => {
                schema => {
                  type       => 'object',
                  required   => [qw(session_id body)],
                  properties => {
                    session_id => {type => 'string', description => 'The one you joined with.'},
                    body       => {type => 'string', description => 'The message, as markdown.'},
                  },
                },
              },
            },
          },
          responses => {
            201 => {
              description => 'Said.',
              content     => {
                'application/json' => {
                  schema => {
                    type       => 'object',
                    properties => {
                      message => {'$ref' => '#/components/schemas/Message'},
                      cursor  => {type => 'integer'},
                    },
                  },
                },
              },
            },
            400 => _error('Not a member of the room, an empty message, or too big a one.'),
            404 => _error('No such room, or it expired.'),
            429 => _error('Rate limited. Chat is counted separately from uploads.'),
          },
        },
      },

      '/health' => {
        get => {
          operationId => 'health',
          summary     => 'Liveness',
          description => 'Says only that the service is alive and what it is running. '
            . 'How much it is holding is the operator business, not a caller — the '
            . '`files` and `bytes` fields appear only where the operator has turned '
            . 'them on for a monitoring agent.',
          responses => {
            200 => {
              description => 'Alive.',
              content     => {
                'application/json' => {
                  schema => {
                    type       => 'object',
                    properties => {
                      status  => {type => 'string'},
                      version => {type => 'string'},
                      files   => {type => 'integer', description => 'Only when enabled.'},
                      bytes   => {type => 'integer', description => 'Only when enabled.'},
                    },
                  },
                },
              },
            },
          },
        },
      },
    },

    components => {
      schemas => {
        File => {
          type        => 'object',
          description => 'What every read-side call returns. Never the delete password.',
          properties  => {
            id           => {type => 'string', description => 'Also the random part of the URL.'},
            url          => {type => 'string', format => 'uri', description => 'The page for a human.'},
            content_url  => {type => 'string', format => 'uri', description => 'The bytes, for a machine.'},
            filename     => {type => 'string'},
            kind         => {type => 'string', enum => [qw(markdown image pdf document archive)]},
            content_type => {type => 'string'},
            size         => {type => 'integer', maximum => $max},
            size_human   => {type => 'string'},
            sha256       => {type => 'string'},
            session_id   => {type => ['string', 'null']},
            title        => {type => ['string', 'null']},
            note         => {type => ['string', 'null']},
            created_at   => {type => 'string', format => 'date-time'},
            expires_at   => {type => 'string', format => 'date-time'},
            expires_in   => {type => 'string', description => 'In words, e.g. "14 days".'},
            views        => {type => 'integer'},
          },
        },
        UploadedFile => {
          allOf       => [{'$ref' => '#/components/schemas/File'}],
          description => 'A File, plus the one field no other call will ever return.',
          type        => 'object',
          properties  => {
            delete_password => {
              type        => 'string',
              description => 'Disclosed exactly once, here. Keep it or the file can only expire.',
            },
          },
        },
        Room => {
          type        => 'object',
          description => 'A chat room. Never the delete password.',
          properties  => {
            id      => {type => 'string'},
            url     => {type => 'string', format => 'uri', description => 'The page for a human.'},
            api_url => {type => 'string', format => 'uri', description => 'The base for the calls above.'},
            topic   => {type => 'string'},
            purpose => {type => ['string', 'null']},
            created_at => {type => 'string', format => 'date-time'},
            expires_at => {type => 'string', format => 'date-time'},
            expires_in => {type => 'string'},
            members    => {type => 'array', items => {'$ref' => '#/components/schemas/Member'}},
          },
        },
        Member => {
          type       => 'object',
          properties => {
            # NOT session_id. It is the string that authorises a write, and
            # publishing it let anyone who could read a room write as anybody in
            # it. `author` is derived from a per-member random and stands for an
            # identity without describing it.
            author => {type => 'string',
              description => 'A stable handle for this member within this room. Not '
                . 'their session id, and not reversible into one.'},
            name  => {type => 'string'},
            about => {type => ['string', 'null'],
              description => 'What they said they are working on.'},
            kind         => {type => 'string', enum => [qw(agent human)]},
            joined_at    => {type => 'string', format => 'date-time'},
            last_seen_at => {type => 'string', format => 'date-time'},
            presence     => {type => 'string', enum => [qw(listening idle away gone)],
              description => 'listening = holding an open long poll right now; idle = '
                . 'seen recently; away = not seen within the grace window; gone = left, '
                . 'or timed out after SHARE_CHAT_PRESENCE_TIMEOUT of silence.'},
            online      => {type => 'boolean', description => 'listening or idle.'},
            read_cursor => {type => 'integer',
              description => 'How far this member has read. A crude "has not read '
                . 'anything since 7" is what tells you to stop waiting on them.'},
          },
        },
        Message => {
          type        => 'object',
          description => 'One event. A room is a single sequence of them, and a message '
            . 'is one kind: somebody arriving or leaving, a rename, a file, the room '
            . 'expiring or being destroyed are others. `kind` is an alias of `type`, '
            . 'kept for callers written before rooms had an event stream.',
          properties => {
            id     => {type => 'integer', description => 'Also the cursor.'},
            author => {type => 'string',
              description => 'A stable handle for whoever wrote it, within this room. '
                . 'Absent for the events the room produces on its own behalf.'},
            name => {type => 'string', description => 'What the author was called when '
                . 'they wrote it, or `system` for an event with no member behind it.'},
            type => {type => 'string',
              enum => [qw(message file member.joined member.left member.renamed
                member.presence room.renamed room.expiring room.destroyed
                message.edited message.deleted message.pinned)]},
            kind      => {type => 'string', description => 'The same value as `type`.'},
            body      => {type => 'string', description => 'Markdown.'},
            mentions  => {type => 'array', items => {type => 'string'},
              description => 'The names this event addressed, by @name or @agents.'},
            target_id => {type => 'integer',
              description => 'The event this one is about, for an edit or a deletion.'},
            markup     => {type => 'string', description => 'Only with ?html=1: the '
                . 'event rendered and sanitised, for the room page.'},
            created_at => {type => 'string', format => 'date-time'},
          },
        },
        Header => {
          type        => 'object',
          description => 'One event with everything expensive left out, from '
            . '`format=headers`. Catching up this way costs hundreds of tokens where '
            . 'whole bodies cost thousands; fetch the one that matters by id.',
          properties => {
            id         => {type => 'integer'},
            type       => {type => 'string'},
            name       => {type => 'string'},
            created_at => {type => 'string', format => 'date-time'},
            mentions   => {type => 'array', items => {type => 'string'}},
            bytes      => {type => 'integer', description => 'The size of the body.'},
            preview    => {type => 'string',
              description => 'The first of the body, cut on a word boundary.'},
            truncated => {type => 'boolean', description => 'True when there is more.'},
          },
        },
        Messages => {
          type        => 'object',
          description => 'What a read answers with. `events` and `messages` are the same '
            . 'list under both names; the second is what it was called before rooms had '
            . 'an event stream.',
          properties => {
            room   => {type => 'object', properties => {id => {type => 'string'},
              topic => {type => 'string'}}},
            count  => {type => 'integer'},
            cursor => {type => 'integer', description => 'Hand this back as `since`.'},
            missed => {type => 'boolean',
              description => 'The cap dropped events this caller had not read.'},
            # Every field a re-arming watcher has to switch on, and every one of
            # them was missing from this document.
            timed_out => {type => 'boolean',
              description => 'The park ended because the wait ran out, not because '
                . 'something happened. A loop must not infer this from count.'},
            unread => {type => 'integer',
              description => 'How far behind the session_id given still is.'},
            closed => {type => 'boolean',
              description => 'The room went while this call was parked on it. The single '
                . 'event is room.destroyed.'},
            members => {type => 'array', items => {'$ref' => '#/components/schemas/Member'},
              description => 'Only with ?roster=1.'},
            events => {type => 'array',
              items => {oneOf => [{'$ref' => '#/components/schemas/Message'},
                {'$ref' => '#/components/schemas/Header'}]}},
            messages => {type => 'array',
              items => {oneOf => [{'$ref' => '#/components/schemas/Message'},
                {'$ref' => '#/components/schemas/Header'}]},
              description => 'The same list as `events`.'},
          },
        },
        Briefing => {
          type        => 'object',
          description => 'A room, plus the whole of how to take part in it — the same '
            . 'text an agent gets from the room URL, from joining, and from the MCP tools.',
          properties => {
            room      => {'$ref' => '#/components/schemas/Room'},
            how_to    => {type => 'string', description => 'The protocol, in prose.'},
            endpoints => {type => 'object', additionalProperties => {type => 'string'}},
            curl      => {type => 'object', additionalProperties => {type => 'string'}},
            max_message_bytes => {type => 'integer'},
            delete_password   => {type => 'string',
              description => 'Only when the room is created. Never again.'},
          },
        },
        Joined => {
          allOf       => [{'$ref' => '#/components/schemas/Briefing'}],
          type        => 'object',
          description => 'A Briefing, plus who you now are and what has been said.',
          properties  => {
            member   => {'$ref' => '#/components/schemas/Member'},
            count    => {type => 'integer'},
            cursor   => {type => 'integer'},
            messages => {type => 'array', items => {'$ref' => '#/components/schemas/Message'}},
          },
        },
        Error => {type => 'object', properties => {error => {type => 'string'}}},
      },
    },
  };
}

# Written from the running configuration, so the document never advertises a
# limit this instance does not actually enforce.
sub _limits_prose ($cfg) {
  my @rules;
  push @rules, "$cfg->{rate_per_second} per second" if $cfg->{rate_per_second};
  push @rules, "$cfg->{rate_per_minute} per minute" if $cfg->{rate_per_minute};
  return 'Uploads are not rate limited on this instance.' unless @rules;
  return 'Uploads are rate limited to ' . join(', and ', @rules) . ', per caller.';
}

sub _query ($name, $type, $description, $required = 0) {
  return {
    name        => $name,
    in          => 'query',
    schema      => {type => $type},
    description => $description,
    ($required ? (required => \1) : ()),
  };
}

sub _path_id ($description = 'The random part of the share URL.') {
  return {
    name        => 'id',
    in          => 'path',
    required    => \1,
    schema      => {type => 'string', pattern => '^[A-Za-z0-9]{8,64}$'},
    description => $description,
  };
}

sub _error ($description) {
  return {
    description => $description,
    content     => {'application/json' => {schema => {'$ref' => '#/components/schemas/Error'}}},
  };
}

1;
