# share — Perl dependencies. Installed into /deps by pdi-build-deps at image
# build time; see Dockerfile.

# The web framework, the templates, the DOM sanitiser and the JSON codec all
# come from here. 9.36 for Mojolicious::Routes::add_type and max_request_size.
requires 'Mojolicious', '9.36';

# v4 is the line where WAL stopped being the default and became the `wal_mode`
# connect option that Share::Store passes. Pulls in DBD::SQLite itself.
requires 'Mojo::SQLite', 'v4.0.0';

# Pure-Perl CommonMark with a GitHub mode: tables, strikethrough, fenced code
# blocks tagged with their language (which is how mermaid blocks are spotted).
# Pure Perl matters — no libcmark to keep in step with the base image.
requires 'Markdown::Perl', '1.13';

# Core, but named so a slim base image cannot surprise us. Used for the pretty,
# key-ordered JSON that MCP tools return, which a model has to read.
requires 'JSON::PP';
requires 'Digest::SHA';

# Devel::Cover is deliberately NOT here. It is installed only inside the
# coverage build step (see Dockerfile), so it never reaches the runtime image
# and never costs anything on an ordinary build.
