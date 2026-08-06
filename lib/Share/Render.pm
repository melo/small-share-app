package Share::Render;

# Markdown -> HTML that is safe to put in front of a human.
#
# The markdown arriving here was written by an agent, and an agent can be talked
# into writing anything. This module assumes the input is hostile. It is the
# first of the three layers described in the spec; the other two (a sandboxed
# iframe and a CSP) live in share.pl, and none of them is trusted alone.

use Mojo::Base -strict, -signatures;

use Exporter       qw(import);
use Markdown::Perl ();
use Mojo::DOM      ();

our @EXPORT_OK = qw(render_markdown);

# GitHub mode gets tables, strikethrough and the fenced-code behaviour people
# expect. code_blocks_info => 'language' is what puts `language-mermaid` on the
# <code>, which is how the mermaid pass below finds its blocks.
my $MD = Markdown::Perl->new(mode => 'github', code_blocks_info => 'language');

# Removed outright, contents and all: there is no version of these we want.
my %KILL = map { $_ => 1 } qw(
  script style iframe frame frameset object embed applet form input button
  select option textarea label link meta base template noscript svg math
  audio video source track canvas map area portal dialog
);

# Everything else is unwrapped rather than removed, so unknown-but-harmless
# markup loses its tag and keeps its text.
my %ALLOW = map { $_ => 1 } qw(
  p br hr h1 h2 h3 h4 h5 h6 em strong b i u s del ins mark small sub sup
  code pre blockquote q cite ul ol li dl dt dd table thead tbody tfoot caption
  tr th td a img span div section article details summary figure figcaption
  kbd samp var abbr address time hgroup
);

# Attributes worth keeping, per tag. Anything not listed — every on* handler
# included — is dropped.
my %ATTR = (
  '*'        => [qw(id class title lang dir)],
  a          => [qw(href)],
  img        => [qw(src alt width height loading)],
  ol         => [qw(start reversed type)],
  td         => [qw(align colspan rowspan)],
  th         => [qw(align colspan rowspan scope)],
  time       => [qw(datetime)],
  q          => [qw(cite)],
  blockquote => [qw(cite)],
);

sub render_markdown ($text) {
  # Markdown::Perl works in characters and returns characters.
  my $dom = Mojo::DOM->new($MD->convert($text));
  _clean($dom);

  # Do this after cleaning so the promoted <pre class="mermaid"> — whose text is
  # deliberately not HTML — is never walked as markup.
  my $mermaid = _promote_mermaid($dom);

  return {html => "$dom", mermaid => $mermaid};
}

# Depth-first, one level at a time, taking a fresh snapshot of each node's
# children before touching them.
#
# The tempting one-liner ($dom->find('*')->each, strip as you go) is a trap:
# find() snapshots the whole tree up front, and Mojo::DOM's internal _offset
# spins forever looking for a node its parent no longer holds. Removing a node
# would then hang the worker on the next already-detached descendant.
sub _clean ($node) {
  for my $child ($node->child_nodes->each) {
    my $type = $child->type;

    if ($type ne 'tag') {
      $child->remove if $type eq 'comment' || $type eq 'pi' || $type eq 'cdata' || $type eq 'doctype';
      next;
    }

    my $tag = $child->tag;
    if   ($KILL{$tag}) { $child->remove; next }
    else               { _clean($child) }

    # Unknown tag: keep the words, drop the element.
    unless ($ALLOW{$tag}) { $child->strip; next }

    my %keep = map { $_ => 1 } @{$ATTR{'*'}}, @{$ATTR{$tag} // []};
    my $attr = $child->attr;
    delete @{$attr}{grep { !$keep{$_} } keys %$attr};

    delete $attr->{href} if $tag eq 'a'   && !_safe_url($attr->{href}, 0);
    delete $attr->{src}  if $tag eq 'img' && !_safe_url($attr->{src},  1);
  }
  return;
}

# ```mermaid fences arrive as <pre><code class="language-mermaid">. mermaid.js
# looks for <pre class="mermaid">, so hand it that, with the diagram source as
# literal text (new_tag escapes it) rather than re-parsed HTML.
sub _promote_mermaid ($dom) {
  my $found = 0;
  for my $code ($dom->find('pre > code.language-mermaid')->each) {
    $code->parent->replace(Mojo::DOM->new_tag('pre', class => 'mermaid', $code->text));
    $found++;
  }
  return $found;
}

# Relative URLs are fine — they resolve inside the sandboxed preview and reach
# nothing interesting. Absolute ones must use a scheme we are happy to hand a
# reader: notably not javascript:, and not data: except for images.
sub _safe_url ($url, $allow_data_image) {
  return 0 unless defined $url;
  $url =~ s/\A\s+//;
  return 1 unless $url =~ m{\A([a-zA-Z][a-zA-Z0-9+.\-]*):}s;

  my $scheme = lc $1;
  return 1 if $scheme eq 'http' || $scheme eq 'https' || $scheme eq 'mailto';
  return 1 if $allow_data_image && $url =~ m{\Adata:image/(?:png|jpeg|gif|webp);base64,}i;
  return 0;
}

1;
