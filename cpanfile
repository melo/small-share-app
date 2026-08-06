# share — Perl dependencies. Installed into /deps by pdi-build-deps at image
# build time; see Dockerfile.

# The web framework, the templates, the DOM sanitiser and the JSON codec all
# come from here. 9.41 is what MCP 0.15 requires.
requires 'Mojolicious', '9.41';

# The MCP server, by the Mojolicious author. 0.15 is the first release speaking
# protocol revision 2026-07-28 — stateless, no initialize handshake — and it
# ships MCP::Server::Legacy so clients still on the older handshake keep
# working. At least 0.15; earlier releases speak a protocol we do not.
requires 'MCP', '0.15';

# v4 is the line where WAL stopped being the default and became the `wal_mode`
# connect option that Share::Store passes. Pulls in DBD::SQLite itself.
requires 'Mojo::SQLite', 'v4.0.0';

# Pure-Perl CommonMark with a GitHub mode: tables, strikethrough, fenced code
# blocks tagged with their language (which is how mermaid blocks are spotted).
# Pure Perl matters — no libcmark to keep in step with the base image.
requires 'Markdown::Perl', '1.13';

# Core, but named so a slim base image cannot surprise us. Digest::SHA does the
# HMAC on upload tickets and the PBKDF2 on delete passwords.
requires 'Digest::SHA';

# --- optional, but recommended by Mojolicious for performance ----------------
#
# From the Mojolicious FAQ: "we do in fact already use several optional CPAN
# modules such as Cpanel::JSON::XS, CryptX, EV, IO::Socket::Socks,
# IO::Socket::SSL, Net::DNS::Native, Plack and Role::Tiny to provide advanced
# functionality if possible."
#
# Listed as `recommends` rather than `requires`: every one of them is picked up
# automatically when present and silently skipped when not, so the app must
# still build if one fails to compile on some platform. pdi-build-deps installs
# recommendations.
recommends 'Cpanel::JSON::XS', '4.09';    # Mojo::JSON uses it when available
recommends 'EV', '4.32';                  # a faster event loop for Mojo::IOLoop
recommends 'CryptX', '0.087';             # constant-time and faster crypto; MCP wants it too
recommends 'Net::DNS::Native', '0.15';    # non-blocking DNS resolution
recommends 'IO::Socket::SSL', '2.009';    # TLS, and certificate verification
recommends 'Role::Tiny', '2.000001';      # roles, used by with_roles

# Deliberately NOT taken from that list: Plack (we are not a PSGI app — the
# container runs Mojo's own prefork server) and IO::Socket::Socks (nothing here
# makes outbound connections through a SOCKS proxy).
