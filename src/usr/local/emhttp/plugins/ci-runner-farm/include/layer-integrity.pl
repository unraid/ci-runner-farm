#!/usr/bin/perl
# Read-only layer integrity check for one persistent DinD overlay2 store.
#
# `docker push` and `docker save` rebuild each layer tar from the layer's diff
# directory and its tar-split metadata. tar-split records a CRC64 (ISO) for
# every regular file at registration time. If the bytes in the diff directory
# no longer match, the export fails with "file integrity checksum failed", and
# every later build that reuses the layer from cache fails in the same way.
#
# Files written through shared memory maps (for example SQLite -shm/-wal
# indexes and Berkeley DB __db.* regions) can reach this state when a
# filesystem's read path briefly returns older bytes than the dirty mapped
# pages. Those are the only entries checked, so a scan reads a few KB per
# affected layer instead of whole layers.
#
# Usage: layer-integrity.pl <docker-root> <verified-cache> <budget-seconds>
#                           <min-age-seconds> <max-file-bytes>
#
# Output (one record per line):
#   BAD <chain-id> <reason> <path>      the layer cannot be exported
#   SUMMARY checked=N cached=N young=N skipped=N bytes=N [partial]
# The verified cache holds "<chain-id> <cache-id>" for layers already checked
# and found consistent. It is rewritten atomically, keeping only layers that
# still exist. Layers younger than min-age are not checked yet, so a check
# never races the filesystem writeback it is trying to detect.
#
# Only builtins are used (no modules beyond strict/warnings), so the script
# runs on a minimal perl-base installation.
use strict;
use warnings;

my ($root, $cache_path, $budget, $min_age, $max_bytes) = @ARGV;
usage() unless defined $max_bytes;
for ($budget, $min_age, $max_bytes) { usage() unless /^[0-9]+$/; }

my $layerdb = "$root/image/overlay2/layerdb/sha256";
my $overlay = "$root/overlay2";
# No overlay2 image store yet: nothing to check.
exit 0 unless real_dir($root) && real_dir("$root/image")
  && real_dir("$root/image/overlay2") && real_dir($layerdb);

my $started = time;
my $byte_budget = 256 * 1024 * 1024;
my $wanted = qr{(?:-shm|-wal|(?:^|/)__db\.[0-9]+)$};

my %verified;
if (open my $fh, '<', $cache_path) {
  while (<$fh>) {
    $verified{"$1 $2"} = 1 if /^([0-9a-f]{64}) ([A-Za-z0-9]{1,128})$/;
  }
  close $fh;
}

opendir my $dh, $layerdb or exit 0;
my @layers;
for my $chain (readdir $dh) {
  next unless $chain =~ /^[0-9a-f]{64}$/;
  my $dir = "$layerdb/$chain";
  next unless real_dir($dir);
  my $cid = read_line("$dir/cache-id");
  next unless defined $cid && $cid =~ /^[A-Za-z0-9]{1,128}$/;
  my @st = lstat "$dir/tar-split.json.gz";
  next unless @st && -f _;
  push @layers, [$chain, $cid, $st[9]];
}
closedir $dh;
# Newest first: a fresh bad layer is the one the next build will reuse.
@layers = sort { $b->[2] <=> $a->[2] } @layers;

my %keep;
my ($checked, $cached, $young, $skipped, $bytes, $partial) = (0, 0, 0, 0, 0, 0);
my @crc_table = crc64_table();

LAYER: for my $layer (@layers) {
  my ($chain, $cid, $mtime) = @$layer;
  my $key = "$chain $cid";
  if ($verified{$key}) { $keep{$key} = 1; $cached++; next; }
  if (time - $mtime < $min_age) { $young++; next; }
  if (time - $started >= $budget || $bytes >= $byte_budget) { $partial = 1; last; }

  my $diff = "$overlay/$cid/diff";
  unless (real_dir("$overlay/$cid") && real_dir($diff)) {
    # A layer without its diff directory is not this failure; leave it.
    next;
  }
  my $ts;
  unless (open $ts, '-|', 'gzip', '-dc', '--', "$layerdb/$chain/tar-split.json.gz") {
    next;
  }
  my $bad = 0;
  while (my $line = <$ts>) {
    next unless index($line, '"type":1') >= 0;
    my $name = json_field_string($line, 'name');
    next unless defined $name && $name =~ $wanted;
    my ($size) = $line =~ /"size":([0-9]+)/;
    next unless $size;    # empty files have no checksum
    my ($payload) = $line =~ /"payload":"([A-Za-z0-9+\/=]+)"/;
    next unless defined $payload;
    my $raw = b64decode($payload);
    next unless length($raw) == 8;
    my $want = unpack 'Q>', $raw;

    my $path = safe_path($diff, $name);
    unless (defined $path) {
      print_bad($chain, 'missing', $name); $bad = 1; next;
    }
    my @st = lstat $path;
    if ($st[7] != $size) {
      print_bad($chain, 'size', $name); $bad = 1; next;
    }
    if ($size > $max_bytes) { $skipped++; next; }
    my $got = crc64_file($path);
    unless (defined $got) { $skipped++; next; }
    $bytes += $size;
    if ($got != $want) { print_bad($chain, 'checksum', $name); $bad = 1; }
  }
  close $ts;
  $checked++;
  $keep{$key} = 1 unless $bad;
}

# Keep verified entries for layers that were not reached this run.
for my $layer (@layers) {
  my $key = "$layer->[0] $layer->[1]";
  $keep{$key} = 1 if $verified{$key};
}
write_cache($cache_path, \%keep);
printf "SUMMARY checked=%d cached=%d young=%d skipped=%d bytes=%d%s\n",
  $checked, $cached, $young, $skipped, $bytes, $partial ? ' partial' : '';
exit 0;

sub usage {
  print STDERR "usage: layer-integrity.pl <docker-root> <verified-cache> <budget-seconds> <min-age-seconds> <max-file-bytes>\n";
  exit 2;
}

# A directory that is not a symlink. Job code controls the store's contents,
# so the host-side reader never follows links out of it.
sub real_dir { my @st = lstat $_[0]; return @st && -d _; }

sub read_line {
  open my $fh, '<', $_[0] or return;
  my $line = <$fh>;
  close $fh;
  return unless defined $line;
  chomp $line;
  return $line;
}

# Resolve a tar member under the diff directory without following any symlink:
# every parent must be a real directory and the file itself a regular file.
# Some image builders store members as "./usr/...". Like tar extraction, "."
# and empty components (including a leading "/") are dropped; ".." is refused.
sub safe_path {
  my ($base, $name) = @_;
  return if $name =~ /\0/;
  my @parts = grep { $_ ne '' && $_ ne '.' } split m{/}, $name;
  return if !@parts || grep { $_ eq '..' } @parts;
  my $path = $base;
  for my $i (0 .. $#parts) {
    $path .= "/$parts[$i]";
    my @st = lstat $path;
    return unless @st;
    if ($i < $#parts) { return unless -d _; }
    else { return unless -f _; }
  }
  return $path;
}

# Extract one string field from a single-line JSON object written by Go's
# encoder. Go escapes ", \, control characters, <, >, & and U+2028/U+2029.
sub json_field_string {
  my ($line, $field) = @_;
  return unless $line =~ /"\Q$field\E":"((?:[^"\\]|\\.)*)"/;
  my $s = $1;
  $s =~ s{\\(u([0-9a-fA-F]{4})|.)}{
    defined $2 ? chr(hex $2)
    : $1 eq 'n' ? "\n" : $1 eq 't' ? "\t" : $1 eq 'r' ? "\r"
    : $1 eq 'b' ? "\b" : $1 eq 'f' ? "\f" : $1
  }ge;
  utf8::encode($s) if utf8::is_utf8($s);
  return $s;
}

# Base64 without MIME::Base64 (not in perl-base): map to uuencode's alphabet and
# let unpack 'u' decode. Payloads here are 8-byte checksums, well under one line.
sub b64decode {
  my ($s) = @_;
  $s =~ tr{A-Za-z0-9+/}{}cd;
  return '' if length($s) > 60;
  $s =~ tr{A-Za-z0-9+/}{ -_};
  return unpack 'u', chr(32 + int(length($s) * 3 / 4)) . $s;
}

sub crc64_table {
  no warnings 'portable';
  my $poly = 0xD800000000000000;    # ISO 3309, reflected (Go hash/crc64 ISO)
  my @t;
  for my $i (0 .. 255) {
    my $c = $i;
    for (1 .. 8) { $c = ($c & 1) ? (($c >> 1) ^ $poly) : ($c >> 1); }
    $t[$i] = $c;
  }
  return @t;
}

sub crc64_file {
  my ($path) = @_;
  open my $fh, '<:raw', $path or return;
  my $crc = ~0;
  my $buf;
  while (1) {
    my $n = read $fh, $buf, 1 << 16;
    return unless defined $n;
    last if $n == 0;
    for my $byte (unpack 'C*', $buf) {
      $crc = $crc_table[($crc ^ $byte) & 0xFF] ^ ($crc >> 8);
    }
  }
  close $fh;
  return ~$crc;
}

sub print_bad {
  my ($chain, $reason, $name) = @_;
  (my $shown = $name) =~ s/[^\x21-\x7e]/?/g;
  print "BAD $chain $reason $shown\n";
}

sub write_cache {
  my ($path, $keep) = @_;
  my $tmp = "$path.tmp.$$";
  open my $fh, '>', $tmp or return;
  print {$fh} "$_\n" for sort keys %$keep;
  close $fh or do { unlink $tmp; return; };
  rename $tmp, $path or unlink $tmp;
}
