package Share::Store;

# The whole persistence layer: SQLite for metadata, plain files on disk for the
# bytes, and the classification rules that decide what we are willing to hold.
#
# Two invariants the rest of the app leans on:
#
#   * `secret` is the ONLY identifier. It is what the human's URL contains and
#     what the API and MCP tools take. There is no second, internal handle for
#     an agent to correlate.
#
#   * A stored row always has its blob on disk, and the blob is written before
#     the row and unlinked after it. A crash mid-delete therefore leaves an
#     orphan blob (silent, bounded, reaped) rather than a row that 500s.

use Mojo::Base -base, -signatures;
use utf8;

use Carp         qw(croak);
use Digest::SHA  qw(hmac_sha256_hex);
use Exporter     qw(import);
use Mojo::File   qw(path);
use Mojo::SQLite ();
use Mojo::Util   qw(b64_decode);
use POSIX        qw(strftime);

our @EXPORT_OK = qw(human_duration human_size iso8601 password_hash password_ok payload_bytes token);

has 'key';    # HMAC secret for signed upload URLs; see _load_key

has 'root';                       # Mojo::File — the workspace directory
has 'sql';                        # Mojo::SQLite
has 'log';                        # the app's Mojo::Log, when there is one
has max_bytes        => 32 * 1024 * 1024;
has default_ttl_days => 15;
has max_ttl_days     => 15;

# Ceiling on everything held at once. When an upload pushes the total over it,
# the OLDEST files are evicted until it fits again — a public instance should
# shed history rather than start refusing uploads, because a full disk takes the
# service down and a lost two-week-old demo file does not.
has max_total_bytes => 50 * 1024 * 1024 * 1024;

# Upload attempts allowed per client. 0 disables either limit. The pair matters:
# per-second stops a hammering loop instantly, per-minute stops a patient one.
has rate_per_second => 1;
has rate_per_minute => 10;

# ---------------------------------------------------------------- schema -----

use constant MIGRATIONS => <<'SQL';
-- 1 up
CREATE TABLE files (
  id           INTEGER PRIMARY KEY,
  secret       TEXT    NOT NULL UNIQUE,
  filename     TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  kind         TEXT    NOT NULL,        -- markdown | image | pdf | document | archive
  size         INTEGER NOT NULL,
  sha256       TEXT    NOT NULL,
  session_id   TEXT,
  title        TEXT,
  note         TEXT,
  path         TEXT    NOT NULL,        -- relative to <root>/files
  created_at   INTEGER NOT NULL,
  expires_at   INTEGER NOT NULL,
  downloads    INTEGER NOT NULL DEFAULT 0,
  last_seen_at INTEGER
);
CREATE INDEX files_session_idx ON files (session_id);
CREATE INDEX files_expires_idx ON files (expires_at);

CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL);
INSERT INTO meta (k, v) VALUES ('last_reap', '0');

-- 1 down
DROP TABLE files;
DROP TABLE meta;

-- 2 up
-- Deleting is a separate capability from reading. The share URL grants reading;
-- this grants removal, and it is handed back exactly once, in the response to
-- the upload that created it. Stored as PBKDF2-HMAC-SHA256 over a per-file
-- salt, never in the clear.
ALTER TABLE files ADD COLUMN delete_salt TEXT;
ALTER TABLE files ADD COLUMN delete_hash TEXT;

-- 2 down
-- SQLite before 3.35 cannot DROP COLUMN, and the columns are harmless if this
-- is ever rolled back, so leave them.
SELECT 1;

-- 3 up
-- Upload attempts, for rate limiting. ATTEMPTS, not successes: a limit that
-- only counts what got stored is no limit at all against someone hammering the
-- endpoint with rejects.
CREATE TABLE upload_hits (
  id     INTEGER PRIMARY KEY,
  client TEXT    NOT NULL,
  at     INTEGER NOT NULL
);
CREATE INDEX upload_hits_idx ON upload_hits (client, at);

-- 3 down
DROP TABLE upload_hits;

-- 4 up
-- Attempts are counted per bucket now, because posting to a chat room is
-- limited too and its sensible number is nothing like an upload's: one file a
-- second is generous, one message a second is a conversation stalling.
-- Defaulted rather than backfilled — every row already in here is an upload.
ALTER TABLE upload_hits ADD COLUMN bucket TEXT NOT NULL DEFAULT 'upload';
DROP INDEX upload_hits_idx;
CREATE INDEX upload_hits_idx ON upload_hits (bucket, client, at);

-- 4 down
DROP INDEX upload_hits_idx;
CREATE INDEX upload_hits_idx ON upload_hits (client, at);
SQL

sub init ($self) {
  my $root = path($self->root)->make_path;
  $self->root($root);
  $root->child('files')->make_path;

  # wal_mode is OFF by default in Mojo::SQLite v4 and we want it on: several
  # prefork workers read while one writes. busy_timeout turns the resulting
  # SQLITE_BUSY from an exception into a short wait.
  my $sql = Mojo::SQLite->new->from_filename($root->child('share.db')->to_string,
    {wal_mode => 1, sqlite_busy_timeout => 10_000});
  $sql->migrations->name('share')->from_string(MIGRATIONS)->migrate;
  $self->sql($sql);
  $self->key($self->_load_key);

  return $self;
}

# The HMAC key for signed upload URLs.
#
# Generated once into the workspace rather than demanded as configuration,
# because an operator forgetting to set it must not silently produce
# unverifiable signatures. It sits beside the database it protects, 0600, and
# survives redeploys because the workspace does. SHARE_SECRET_KEY overrides it
# for anyone who would rather manage the key themselves.
sub _load_key ($self) {
  return $ENV{SHARE_SECRET_KEY} if defined $ENV{SHARE_SECRET_KEY} && length $ENV{SHARE_SECRET_KEY};

  my $file = $self->root->child('share.key');
  return $file->slurp =~ s/\s+\z//r if -s $file;

  my $key = token(64);
  $file->spew($key);
  chmod 0600, $file;
  return $key;
}

# --------------------------------------------------- signed upload tickets ---
#
# What the signature is and is not.
#
# It is NOT access control. With no authentication, anything that can reach the
# service can POST to /api/v1/files directly and does not need a ticket at all.
#
# What it buys, today: the parameters an agent was handed — session_id, title,
# note, ttl_days — cannot be edited in transit or after the fact, and a ticket
# stops working after an hour instead of being hoardable forever.
#
# What it buys later: this is the one place a real credential would be minted,
# and the verification below is already sitting in the upload path. Turning
# SHARE_REQUIRE_SIGNED_UPLOADS on makes tickets mandatory in one setting.
#
# NOTE for anyone reading this worried about the shape of the flow: the ticket
# is a POST to a fixed collection endpoint. There is no PUT, no client-chosen
# path, and no route anywhere in this app that modifies an existing file. Every
# accepted upload mints a fresh server-generated secret from /dev/urandom.

use constant TICKET_TTL => 3600;

# ------------------------------------------------------- delete passwords ----

# PBKDF2-HMAC-SHA256, one output block, written out rather than pulled in.
#
# Rolling a primitive by hand deserves an argument. This one: PBKDF2 is six
# lines, the alternative is a new XS dependency for a single call, and the
# implementation is checked against a published RFC 6070-style vector in the
# test suite — so it is verified rather than merely believed. If CryptX ever
# arrives for another reason, swap this for Crypt::KeyDerivation::pbkdf2 and
# keep the vector.
#
# 200k iterations: a caller-chosen password may be weak, and the only attacker
# who can use this hash is one who already has the database — and therefore the
# files. It is worth slowing down, not worth a second of latency.
use constant KDF_ROUNDS => 200_000;

sub _pbkdf2 ($password, $salt, $rounds = KDF_ROUNDS) {
  # A delete password is whatever the caller sent, and it does not arrive the
  # same way twice: JSON and form parameters reach us decoded into characters,
  # an X-Delete-Password header reaches us as raw bytes. Both are reduced to the
  # same UTF-8 bytes here, so a password set through one path still verifies
  # through another — and Digest::SHA is never handed a wide character, which it
  # answers by dying. See _bytes.
  $password = _bytes($password);

  my $block = Digest::SHA::hmac_sha256($salt . pack('N', 1), $password);
  my $out   = $block;
  for (2 .. $rounds) {
    $block = Digest::SHA::hmac_sha256($block, $password);
    $out ^= $block;
  }
  return unpack 'H*', $out;
}

# The two ends of a delete password, exported so the chat side stores one the
# same way. There is one KDF in this codebase with one test vector behind it;
# a second implementation next door would be a second thing to get wrong.
sub password_hash ($password) {
  my $salt = token(16);
  return ($salt, _pbkdf2($password, $salt));
}

# False for a missing password, a missing hash and a wrong password alike — the
# caller is expected to answer all three with the same sentence.
sub password_ok ($password, $salt, $hash) {
  return 0 unless defined $password && length $password;
  return 0 unless defined $salt     && length $salt;
  return 0 unless defined $hash     && length $hash;
  return _constant_eq(_pbkdf2($password, $salt), $hash);
}

sub sign_query ($self, $pairs) {
  my %query = (@$pairs, exp => time + TICKET_TTL);
  $query{sig} = $self->_signature(\%query);
  return \%query;
}

sub check_signature ($self, $query) {
  my %given = %$query;
  my $sig   = delete $given{sig};
  return (0, 'this upload URL is not signed') unless defined $sig && length $sig;

  my $expected = $self->_signature(\%given);
  # Constant-time-ish: compare full strings, never a prefix, and never leak
  # which byte differed.
  return (0, 'this upload URL has been altered since it was issued')
    unless length $sig == length $expected && $sig eq $expected;

  my $exp = $given{exp} // 0;
  return (0, 'this upload URL expired; ask for a new one') if $exp <= time;

  return (1, undef);
}

# Canonical form: every parameter except the signature itself, sorted by name,
# joined as name=value with a separator that cannot appear in a name. Sorting is
# what stops a reordering from producing a different digest for the same URL;
# the length prefix on each part is what stops "a=1&b=2" and "a=1&b=2" built
# from different splits colliding.
#
# Every part is reduced to bytes before it is measured or hashed, and both
# halves of that matter. A title is agent-written prose — em dashes, curly
# quotes, accented names — and Digest::SHA does not hash characters: handed a
# codepoint above 255 it dies with "Wide character in subroutine entry", which
# is exactly how one em dash in a title turned every get_upload_url call into a
# 500. And a length counted in characters cannot frame a value measured in
# bytes, so the prefix only keeps its anti-collision property once both are byte
# counts.
sub _signature ($self, $query) {
  my $canonical = join '', map {
    my $name  = _bytes($_);
    my $value = _bytes($query->{$_});
    sprintf '%d:%s=%d:%s', length $name, $name, length $value, $value;
  } sort keys %$query;

  return hmac_sha256_hex($canonical, _bytes($self->key));
}

# The UTF-8 bytes a string stands for, whatever shape it arrived in.
#
# Perl strings reach this app both ways: Mojo decodes JSON bodies and query
# parameters into characters, while headers and file contents stay as bytes. A
# digest has to see one of those, consistently, on both the signing and the
# checking side — so anything still carrying characters is encoded, and anything
# already made of bytes is left exactly as it is.
sub _bytes ($str) {
  return '' unless defined $str;
  utf8::encode($str) if utf8::is_utf8($str);
  return $str;
}

# ------------------------------------------------------------ classifying ----

# Extension -> (kind, content type). The list is the product: markdown to read,
# images to look at, PDFs to page through — and the formats a colleague actually
# attaches to mail, which arrive here for one reason only, to be handed on. Those
# get no preview, and the viewer says so instead of framing a blank page.
# Anything else is a different service.
my %BY_EXT = (
  md       => ['markdown', 'text/markdown; charset=utf-8'],
  markdown => ['markdown', 'text/markdown; charset=utf-8'],
  mdown    => ['markdown', 'text/markdown; charset=utf-8'],
  mkd      => ['markdown', 'text/markdown; charset=utf-8'],
  txt      => ['markdown', 'text/markdown; charset=utf-8'],
  png      => ['image',    'image/png'],
  jpg      => ['image',    'image/jpeg'],
  jpeg     => ['image',    'image/jpeg'],
  gif      => ['image',    'image/gif'],
  webp     => ['image',    'image/webp'],
  svg      => ['image',    'image/svg+xml'],
  # What a phone produces. Accepted because refusing the format people actually
  # have is a poor answer — but see Share::_preview_note: outside Safari most
  # browsers still cannot DISPLAY one, so the viewer says so and offers the
  # download rather than showing a broken image.
  heic     => ['image',    'image/heic'],
  heif     => ['image',    'image/heif'],
  pdf      => ['pdf',      'application/pdf'],

  # Office, both eras, and OpenDocument. Deliberately NOT the macro-enabled
  # variants (.docm, .xlsm, .pptm): those exist to carry code, and a service
  # that hands files to people who did not choose to receive them has no
  # business being the courier.
  doc  => ['document', 'application/msword'],
  xls  => ['document', 'application/vnd.ms-excel'],
  ppt  => ['document', 'application/vnd.ms-powerpoint'],
  docx => ['document', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
  xlsx => ['document', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
  pptx => ['document', 'application/vnd.openxmlformats-officedocument.presentationml.presentation'],
  odt  => ['document', 'application/vnd.oasis.opendocument.text'],
  ods  => ['document', 'application/vnd.oasis.opendocument.spreadsheet'],
  odp  => ['document', 'application/vnd.oasis.opendocument.presentation'],
  odg  => ['document', 'application/vnd.oasis.opendocument.graphics'],

  zip => ['archive', 'application/zip'],
);

# Which container each of those actually is on disk. Every OOXML and
# OpenDocument file is a zip with a particular layout inside it, everything
# Office wrote before 2007 is an OLE2 compound document, and a .zip is a zip.
#
# The container is where the checking stops. Telling a .docx from a .xlsx means
# unpacking untrusted input in order to decide whether to accept it, which is a
# far larger thing to be doing than a hand-off service needs — and getting it
# wrong costs nothing here, because neither one is ever rendered.
my %DOC_MAGIC = (
  (map { $_ => 'ole2' } qw(doc xls ppt)),
  (map { $_ => 'zip' } qw(docx xlsx pptx odt ods odp odg zip)),
);

# What the magic bytes say, independent of what the name claims.
my %SNIFF_OK = (
  'image/png'     => {png  => 1},
  'image/jpeg'    => {jpeg => 1},
  'image/gif'     => {gif  => 1},
  'image/webp'    => {webp => 1},
  'application/pdf' => {pdf => 1},
  'image/svg+xml' => {svg  => 1},
  'image/heic'    => {heic => 1},
  'image/heif'    => {heic => 1},
  # Markdown is just text; an SVG is also text and would be a confusing but
  # harmless thing to call markdown, so it is allowed through here too.
  'text/markdown; charset=utf-8' => {text => 1, svg => 1},
);

$SNIFF_OK{$BY_EXT{$_}[1]} = {$DOC_MAGIC{$_} => 1} for keys %DOC_MAGIC;

# What _sniff found, in words, for the one message a rejected upload gets back.
# "its contents look like ole2" tells nobody anything.
my %SNIFF_NAME = (
  binary => 'arbitrary binary data',
  text   => 'plain text',
  zip    => 'a zip archive (which is also what a .docx or a .odt is)',
  ole2   => 'an old-style Office document (.doc, .xls or .ppt)',
);

sub _sniff_name ($sniffed) { return $SNIFF_NAME{$sniffed} // $sniffed }

sub _sniff ($bytes) {
  return 'png'  if $bytes =~ /\A\x89PNG\r\n\x1a\n/;
  return 'jpeg' if $bytes =~ /\A\xff\xd8\xff/;
  return 'gif'  if $bytes =~ /\AGIF8[79]a/;
  return 'webp' if $bytes =~ /\ARIFF.{4}WEBP/s;
  return 'pdf'  if $bytes =~ /\A%PDF-/;

  # A zip: the local file header, or the end-of-central-directory record, which
  # is the whole of an empty archive. PK\x07\x08 marks a spanned archive and is
  # not something an office suite or a browser produces.
  return 'zip' if $bytes =~ /\APK(?:\x03\x04|\x05\x06)/;

  # The OLE2 compound document header — .doc, .xls and .ppt all start with it,
  # and it says nothing whatever about which of the three wrote the file.
  return 'ole2' if $bytes =~ /\A\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1/;

  # ISO base media: a 4-byte length, then 'ftyp', then the brand. HEIC and HEIF
  # are the brands below; the same container also carries MP4, which is why the
  # brand is checked rather than just 'ftyp'.
  return 'heic' if $bytes =~ /\A.{4}ftyp(?:heic|heix|heim|heis|hevc|hevx|hevm|hevs|mif1|msf1)/s;

  # utf8::decode mutates in place and returns false on malformed input, so it
  # doubles as the validity check markdown needs. Copy first: the caller still
  # wants the original bytes.
  my $text = $bytes;
  return 'binary' unless utf8::decode($text);
  return 'binary' if $text =~ /\x00/;

  return 'svg' if substr($text, 0, 1024) =~ /<svg[\s>]/i;
  return 'text';
}

# ------------------------------------------------------------------ add ------

sub add ($self, %args) {
  my $bytes = $args{bytes};
  croak 'add() needs bytes' unless defined $bytes;

  _fail('the file is empty') unless length $bytes;
  _fail(sprintf 'the file is %s, the limit is %s',
    human_size(length $bytes), human_size($self->max_bytes))
    if length $bytes > $self->max_bytes;

  my $filename = _clean_filename($args{filename});
  my ($ext) = lc($filename) =~ /\.([a-z0-9]+)\z/i;
  _fail(qq{"$filename" has no file extension; name it .md, .png, .jpg, .gif, .webp, .svg, }
      . q{.pdf, an Office or OpenDocument extension, or .zip})
    unless defined $ext;

  my $spec = $BY_EXT{$ext}
    or _fail(qq{".$ext" is not something this service holds — only markdown (.md), }
      . q{images (.png .jpg .gif .webp .svg), .pdf, documents }
      . q{(.doc .docx .xls .xlsx .ppt .pptx .odt .ods .odp .odg) and .zip});
  my ($kind, $content_type) = @$spec;

  # Declared type and real type must agree. A .png that is really a PDF gets
  # rejected rather than stored and later served with a lying Content-Type.
  my $sniffed = _sniff($bytes);
  _fail(qq{"$filename" claims to be .$ext but its contents look like } . _sniff_name($sniffed))
    unless $SNIFF_OK{$content_type}{$sniffed};

  my $ttl = $self->_ttl_seconds($args{ttl_days});
  my $now = time;

  # One is generated when the caller does not supply one, so that every upload
  # comes back with a way to undo it. It is returned exactly once, on the row
  # this method hands back, and `public` below never carries it.
  my $password = _trim($args{delete_password}) // token(24);
  my ($salt, $hash) = password_hash($password);

  my $secret = token();
  my $rel    = join '/', substr($secret, 0, 2), substr($secret, 2, 2), $secret;
  my $blob   = $self->root->child('files', split m{/}, $rel);
  $blob->dirname->make_path;
  $blob->spew($bytes);

  my $ok = eval {
    $self->sql->db->insert(
      'files',
      { secret       => $secret,
        filename     => $filename,
        content_type => $content_type,
        kind         => $kind,
        size         => length $bytes,
        sha256       => Digest::SHA::sha256_hex($bytes),
        session_id   => _trim($args{session_id}),
        title        => _trim($args{title}),
        note         => _trim($args{note}),
        path         => $rel,
        created_at   => $now,
        expires_at   => $now + $ttl,
        delete_salt  => $salt,
        delete_hash  => $hash,
      }
    );
    1;
  };
  unless ($ok) {
    my $err = $@;
    $blob->remove;    # never leave a blob behind for a row that does not exist
    die $err;         ## no critic (RequireCarping)
  }

  my $row = $self->find($secret);
  # The only moment the plaintext exists outside the caller's hand. Deliberately
  # not a column, not in `public`, and not reachable from any later lookup.
  $row->{delete_password} = $password;
  return $row;
}

sub _ttl_seconds ($self, $days) {
  return $self->default_ttl_days * 86400 unless defined $days && length $days;
  _fail('ttl_days must be a number') unless $days =~ /\A\d+(?:\.\d+)?\z/;
  my $secs = $days * 86400;
  _fail(sprintf 'ttl_days must be at most %d', $self->max_ttl_days)
    if $secs > $self->max_ttl_days * 86400;
  _fail('ttl_days must be at least 1 hour (0.042)') if $secs < 3600;
  return int $secs;
}

# ---------------------------------------------------------------- reading ----

sub find ($self, $secret) {
  return undef unless defined $secret && $secret =~ /\A[A-Za-z0-9]{8,64}\z/;
  my $row = $self->sql->db->query('SELECT * FROM files WHERE secret = ?', $secret)->hash;
  return undef unless $row;

  # Expired but not yet reaped is indistinguishable from gone, as far as anyone
  # asking is concerned.
  return undef if $row->{expires_at} <= time;
  return $row;
}

sub blob ($self, $row) { $self->root->child('files', split m{/}, $row->{path}) }

sub contents ($self, $row) {
  my $blob = $self->blob($row);
  return undef unless -f $blob;
  return $blob->slurp;
}

sub for_session ($self, $session_id, $limit = 200) {
  return [] unless defined $session_id && length $session_id;
  return $self->sql->db->query(
    'SELECT * FROM files WHERE session_id = ? AND expires_at > ? ORDER BY created_at DESC LIMIT ?',
    $session_id, time, $limit)->hashes->to_array;
}

sub stats ($self) {
  my $now = time;
  my $r   = $self->sql->db->query(
    'SELECT COUNT(*) AS files, COALESCE(SUM(size), 0) AS bytes FROM files WHERE expires_at > ?',
    $now)->hash;
  return {files => $r->{files}, bytes => $r->{bytes}};
}

# Bookkeeping, and bookkeeping only: a view counter and a last-seen stamp. It is
# never a reason to fail a delivery. The one time this mattered, the disk under
# SQLite filled up, every write started returning "database or disk is full",
# and /f/<id> answered 500 for a file that was sitting there intact and
# perfectly readable — the bytes were fine, the counter was not. Whoever was
# sent that link had no way to tell the difference.
#
# So the failure is logged and swallowed. Readers keep reading a store that has
# gone read-only for any reason; the log is where you find out it did.
sub touch ($self, $row) {
  eval {
    $self->sql->db->query(
      'UPDATE files SET downloads = downloads + 1, last_seen_at = ? WHERE id = ?',
      time, $row->{id});
    1;
  } or do {
    my $err = $@ || 'unknown error';
    $self->log->warn("touch failed for $row->{id} (serving anyway): $err") if $self->log;
  };
  return;
}

# ---------------------------------------------------- protecting the box -----

# Returns (1, undef) when the attempt may proceed, or (0, seconds-to-wait).
#
# Counted in SQLite rather than in process memory on purpose: the app runs
# prefork, so an in-memory counter would be per-worker and a client would get
# the limit multiplied by the number of workers. The table is tiny and pruned on
# every call.
sub rate_check ($self, $client, %opt) {
  # Uploads unless told otherwise, so every existing caller means what it always
  # did. Chat posts pass their own bucket and their own pair of numbers, and the
  # two never eat into each other: a busy room must not stop anyone uploading a
  # file, which is the whole reason the buckets are separate.
  my $bucket     = $opt{bucket}     // 'upload';
  my $per_second = $opt{per_second} // $self->rate_per_second;
  my $per_minute = $opt{per_minute} // $self->rate_per_minute;
  return (1, undef) unless $per_second || $per_minute;

  $client = 'unknown' unless defined $client && length $client;
  my $now = time;
  my $db  = $self->sql->db;

  # Nothing older than the widest window can matter to anyone, in any bucket.
  $db->query('DELETE FROM upload_hits WHERE at < ?', $now - 60);

  if ($per_second) {
    my $recent
      = $db->query('SELECT COUNT(*) FROM upload_hits WHERE bucket = ? AND client = ? AND at >= ?',
      $bucket, $client, $now)->array->[0];
    return (0, 1) if $recent >= $per_second;
  }

  if ($per_minute) {
    my $recent
      = $db->query('SELECT COUNT(*) FROM upload_hits WHERE bucket = ? AND client = ? AND at > ?',
      $bucket, $client, $now - 60)->array->[0];
    if ($recent >= $per_minute) {
      # Tell them when the window actually frees up rather than guessing a
      # round number: the oldest hit in the window is when a slot returns.
      my $oldest = $db->query(
        'SELECT MIN(at) FROM upload_hits WHERE bucket = ? AND client = ? AND at > ?',
        $bucket, $client, $now - 60)->array->[0] // $now;
      return (0, ($oldest + 60) - $now || 1);
    }
  }

  $db->insert('upload_hits', {bucket => $bucket, client => $client, at => $now});
  return (1, undef);
}

# Shed the oldest files until everything held fits under the ceiling. Called
# after an upload lands, so the limit is enforced by eviction rather than by
# refusal — a public instance filling its disk goes down, and that is a worse
# outcome than losing the oldest thing on it.
#
# Returns the list of evicted rows, so the caller can say what it did.
sub enforce_total_limit ($self) {
  my $limit = $self->max_total_bytes or return [];

  my $total = $self->sql->db->query('SELECT COALESCE(SUM(size), 0) FROM files')->array->[0];
  return [] if $total <= $limit;

  my @evicted;
  # Oldest first, one at a time: each purge changes the total, and stopping the
  # moment it fits means never evicting one file more than necessary.
  my $rows = $self->sql->db->query('SELECT * FROM files ORDER BY created_at ASC')->hashes;
  for my $row (@$rows) {
    last if $total <= $limit;
    $total -= $row->{size};
    $self->_purge($row);
    push @evicted, $row;
  }

  return \@evicted;
}

# --------------------------------------------------------------- removing ----

# Returns (1, undef) on success, or (0, reason) — never a bare boolean, because
# "no such file" and "wrong password" must be told apart by the caller and NOT
# by whoever is trying passwords.
sub remove ($self, $secret, $password = undef) {
  my $row = $self->sql->db->query('SELECT * FROM files WHERE secret = ?', $secret)->hash;

  # Same answer for a file that never existed and a file whose password is
  # wrong, so this cannot be used to enumerate ids.
  my $refuse = "no such file, or the wrong delete password";

  # The same refusal for both cases, and the same cost for both: without the
  # dummy derivation below, a missing file answered in a millisecond and a real
  # one in a quarter of a second.
  unless ($row) {
    my ($salt, $hash) = password_hash(token(24));
    password_ok($password // '', $salt, $hash);
    return (0, $refuse);
  }
  return (0, $refuse) unless password_ok($password, $row->{delete_salt}, $row->{delete_hash});

  $self->_purge($row);
  return (1, undef);
}

# Length-independent, difference-independent comparison. Both operands here are
# hex of a fixed width, so the length check is belt and braces.
sub _constant_eq ($a, $b) {
  return 0 unless length $a == length $b;
  my $diff = 0;
  $diff |= ord(substr $a, $_, 1) ^ ord(substr $b, $_, 1) for 0 .. length($a) - 1;
  return $diff == 0;
}

sub _purge ($self, $row) {
  my $blob = $self->blob($row);
  $blob->remove if -e $blob;

  # Prune the two sharding levels when they empty out, so `find` on the data
  # directory stays useful to a human poking around.
  for my $dir ($blob->dirname, $blob->dirname->dirname) {
    last unless -d $dir;
    rmdir $dir or last;
  }

  $self->sql->db->delete('files', {id => $row->{id}});
  return;
}

# The reaper. Every prefork worker runs this on a timer, so the first thing it
# does is try to claim the round with a conditional UPDATE. Exactly one worker
# wins; the others see zero affected rows and go back to sleep.
sub reap ($self, %opt) {
  my $now = time;

  unless ($opt{force}) {
    my $claimed = $self->sql->db->query(
      q{UPDATE meta SET v = ? WHERE k = 'last_reap' AND CAST(v AS INTEGER) <= ?},
      $now, $now - ($opt{every} // 3600))->rows;
    return {claimed => 0, files => 0, bytes => 0} unless $claimed;
  }

  my $rows = $self->sql->db->query('SELECT * FROM files WHERE expires_at <= ?', $now)->hashes;
  my $bytes = 0;
  for my $row (@$rows) {
    $bytes += $row->{size};
    $self->_purge($row);
  }

  return {claimed => 1, files => scalar(@$rows), bytes => $bytes};
}

# ------------------------------------------------- the public view of a row --

# One representation, used by the REST API, the MCP tools and the viewer
# template alike — so an agent and a human are never told different things
# about the same file.
sub public ($self, $row, $base_url) {
  my $left = $row->{expires_at} - time;
  return {
    id           => $row->{secret},
    # Two URLs, because they are for two different readers. `url` is the page a
    # human opens; `content_url` is the bytes, which is what an agent fetches
    # with curl. Neither is derived from the other by anyone but this line.
    url          => "$base_url/f/$row->{secret}",
    content_url  => "$base_url/api/v1/files/$row->{secret}/content",
    filename     => $row->{filename},
    kind         => $row->{kind},
    content_type => $row->{content_type},
    size         => 0 + $row->{size},
    size_human   => human_size($row->{size}),
    sha256       => $row->{sha256},
    # NOT session_id. It looks like a label and it is a capability: for_session
    # returns every live file a session shared, so printing it in the metadata of
    # one file handed whoever held that link the index to the agent's entire
    # conversation. It is also the same identifier namespace the rooms use, so an
    # id learned from a file was a way into a room.
    #
    # The owner knows its own id and can still list with it. Nobody else learns
    # one from here.
    title        => $row->{title},
    note         => $row->{note},
    created_at   => iso8601($row->{created_at}),
    expires_at   => iso8601($row->{expires_at}),
    expires_in   => human_duration($left),
    views        => 0 + $row->{downloads},
  };
}

# ---------------------------------------------------------------- helpers ----

sub _fail ($msg) { die {share_error => $msg} }    ## no critic (RequireCarping)

# The JSON upload shape, shared by the REST API and the MCP share_file tool so
# that an agent gets the same answer from both. Returns bytes.
sub payload_bytes ($args) {
  if (defined $args->{content_base64} && length $args->{content_base64}) {
    my $b64 = $args->{content_base64};
    $b64 =~ s/\s+//g;
    $b64 =~ tr{-_}{+/};    # base64url is a common enough mistake to just accept
    _fail('content_base64 is not valid base64') unless $b64 =~ m{\A[A-Za-z0-9+/]*={0,2}\z};
    return b64_decode $b64;
  }

  if (defined $args->{content}) {
    my $bytes = $args->{content};
    utf8::encode($bytes);    # JSON hands us characters; everything below wants bytes
    return $bytes;
  }

  _fail('give me either "content" (text) or "content_base64" (binary)');
}

sub _trim ($v) {
  return undef unless defined $v;
  $v =~ s/\A\s+|\s+\z//g;
  return length $v ? $v : undef;
}

# Never used to build a path — that comes from the secret — so this only has to
# be safe to render and pleasant to save as.
sub _clean_filename ($name) {
  $name = '' unless defined $name;
  $name =~ s{\A.*[/\\]}{};          # basename, whatever the client's OS thinks
  $name =~ s/[\x00-\x1f\x7f]//g;
  $name =~ s/\A\.+//;               # no leading dots: no ".", "..", no dotfiles
  $name =~ s/\A\s+|\s+\z//g;
  $name = 'shared' unless length $name;
  $name = substr($name, 0, 120);
  return $name;
}

my $ALPHABET = join '', 'a' .. 'z', 'A' .. 'Z', 0 .. 9;

# 32 chars of base62 is ~190 bits. Rejection sampling (62 * 4 == 248) keeps the
# distribution flat instead of biasing the first six letters of the alphabet.
sub token ($len = 32) {
  open my $fh, '<:raw', '/dev/urandom' or croak "cannot open /dev/urandom: $!";
  my $out = '';
  while (length $out < $len) {
    read($fh, my $buf, 64) or croak 'short read from /dev/urandom';
    for my $byte (unpack 'C*', $buf) {
      next if $byte >= 248;
      $out .= substr $ALPHABET, $byte % 62, 1;
      last if length $out >= $len;
    }
  }
  close $fh;
  return $out;
}

sub iso8601 ($epoch) { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime $epoch) }

sub human_size ($bytes) {
  return "$bytes bytes" if $bytes < 1024;
  my @unit = qw(KB MB GB);
  my $n    = $bytes / 1024;
  while ($n >= 1024 && @unit > 1) { $n /= 1024; shift @unit }
  return sprintf '%.1f %s', $n, $unit[0];
}

sub human_duration ($secs) {
  return 'now' if $secs <= 0;
  for my $step ([86400, 'day'], [3600, 'hour'], [60, 'minute']) {
    my ($div, $name) = @$step;
    next if $secs < $div;
    my $n = int($secs / $div);
    return sprintf '%d %s%s', $n, $name, $n == 1 ? '' : 's';
  }
  return 'less than a minute';
}

1;
