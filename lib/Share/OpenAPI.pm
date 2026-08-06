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
          . 'rendered properly. It is deleted after '
          . $cfg->{ttl_days} . ' days and the URL dies with it.',
        '**There is no authentication.** Anything that can reach this service may '
          . 'upload and list. Deleting is the exception: it needs the `delete_password` '
          . 'returned by the upload, which is disclosed exactly once and by no other '
          . 'call.',
        'Files are at most ' . human_size($max) . '. The filename extension must match '
          . 'the actual bytes or the upload is refused.',
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
            kind         => {type => 'string', enum => [qw(markdown image pdf)]},
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
        Error => {type => 'object', properties => {error => {type => 'string'}}},
      },
    },
  };
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

sub _path_id {
  return {
    name        => 'id',
    in          => 'path',
    required    => \1,
    schema      => {type => 'string', pattern => '^[A-Za-z0-9]{8,64}$'},
    description => 'The random part of the share URL.',
  };
}

sub _error ($description) {
  return {
    description => $description,
    content     => {'application/json' => {schema => {'$ref' => '#/components/schemas/Error'}}},
  };
}

1;
