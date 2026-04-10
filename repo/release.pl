#!/usr/bin/perl

use strict;
use warnings;

use XML::Simple qw(XMLin XMLout);
use Digest::SHA qw(sha1_hex);

if (@ARGV != 4) {
    die "Usage: $0 <repo.xml> <version> <zipfile> <url>\n";
}

my ($repofile, $version, $zipfile, $url) = @ARGV;

if (!-f $repofile) {
    die "Repo file not found: $repofile\n";
}

if (!-f $zipfile) {
    die "ZIP file not found: $zipfile\n";
}

my $repo = eval {
    XMLin(
        $repofile,
        ForceArray => 1,
        KeepRoot   => 0,
        KeyAttr    => q{},
        NoAttr     => 0,
    );
};

if ($@) {
    die "Failed to parse XML: $@\n";
}

if (
    !exists $repo->{plugins}
    || !exists $repo->{plugins}[0]->{plugin}
    || !exists $repo->{plugins}[0]->{plugin}[0]
) {
    die "Invalid XML structure: plugins/plugin missing\n";
}

my $plugin = $repo->{plugins}[0]->{plugin}[0];

$plugin->{version} = $version;

open my $fh, '<', $zipfile
    or die "Cannot open $zipfile: $!\n";

binmode $fh;

my $sha1 = sha1_hex(do { local $/; <$fh> });

close $fh;

$plugin->{sha}[0] = $sha1;

$url =~ s{/\z}{};
my $full_url = $url . q{/} . $zipfile;

$plugin->{url}[0] = $full_url;

printf "version=%s sha1=%s url=%s\n", $version, $sha1, $full_url;

eval {
    XMLout(
        $repo,
        RootName   => 'extensions',
        NoSort     => 1,
        XMLDecl    => 1,
        KeyAttr    => q{},
        OutputFile => $repofile,
        NoAttr     => 0,
    );
};

if ($@) {
    die "Failed to write XML: $@\n";
}

exit 0;