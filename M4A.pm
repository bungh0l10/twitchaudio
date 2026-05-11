package Plugins::Twitch::M4a;

# (c) 2018, philippe_44@outlook.com
# enhanced fragmented MP4 AAC parser

use strict;
use Config;
use bytes;

use base qw(Slim::Utils::Accessor);

use Slim::Utils::Log;
use Slim::Utils::Cache;

my $cache = Slim::Utils::Cache->new;
my $log   = logger('plugin.twitch');

use Data::Dumper;

use constant MAX_INBUF  => 128*1024;
use constant MAX_OUTBUF => 4096;
use constant MAX_READ   => 32768;

use constant ATOM_NEED	=> 8;

# streaming states
use constant ATOM     => 1;
use constant PARSING  => 2;
use constant DATA	  => 3;

{
	__PACKAGE__->mk_accessor('rw', qw(bitrate samplerate channels format url));
	__PACKAGE__->mk_accessor('rw', qw(_mp4a _context));
}

sub new {
	my ($class, $url) = @_;
	my $self = $class->SUPER::new;

	$self->init_accessor(
		format => 'aac',
		url => $url,
		_context => {},
		_mp4a => {},
	);

	return bless $self, $class;
}

sub flush {
	$_[0]->_context( { } );
}

sub addBytes {
	my ($self, $data) = @_;
	$self->_context->{'inBuf'} .= ref $data ? $$data : $data;
}

sub bufferLength {
	return length($_[0]->_context->{'inBuf'} || '');
}

sub initialize {
	my ($self, $cb, $ecb, $url) = @_;

	my $http = Slim::Networking::Async::HTTP->new;
	my $args = {};

	$url ||= $self->url;

	$http->send_request( {
		request => HTTP::Request->new( GET => $url ),

		onStream => sub {
			my ($http, $dataref) = @_;

			if (my $atom = parseAtoms('moov', $dataref, $args)) {

				my $trak = get_first($atom->{'trak'});
				my $mdia = get_first($trak->{'mdia'});
				my $minf = get_first($mdia->{'minf'});
				my $stbl = get_first($minf->{'stbl'});
				my $stsd = get_first($stbl->{'stsd'});

				$self->_mp4a(
					$stsd->{'entries'}->{'mp4a'}
				);

				$self->bitrate($self->_mp4a->{'esds'}->{'avgbitrate'});
				$self->samplerate($self->_mp4a->{'samplerate'});
				$self->channels($self->_mp4a->{'channelcount'});

				$cb->();
				return 0;
			}

			return 1 if ($args->{offset} < 128*1024);

			$ecb->();
			return 0;
		},

		onError => sub {
			$ecb->();
		},
	} );
}

sub parseAtoms {
	my ( $wanted_atom, $dataref, $context ) = @_;

	if (!defined $context->{offset}) {
		$context->{offset} = 0;
		$context->{_parser} = {
			'inBuf' => '',
			'state' => ATOM,
			'need'  => ATOM_NEED,
			'offset'=> 0,
		};
	}

	my $v = $context->{_parser};
	$v->{'inBuf'} .= $$dataref;

	while ($v->{need} <= length $v->{inBuf}) {

		if ($v->{state} == ATOM) {

			my ($atom, $size, $header) = get_next_atom($v->{inBuf});

			last unless $atom;

			$v->{need}  = $size - $header;
			$v->{atom}  = $atom;
			$v->{header}= $header;
			$v->{state} = PARSING;

			substr($v->{inBuf}, 0, $header, '');

			$context->{offset} += $size;
		}

		return undef if $v->{need} > length $v->{inBuf};

		my $payload = substr($v->{inBuf}, 0, $v->{need});

		$v->{$v->{atom}} = process_atom(
			$v->{atom},
			$v->{need},
			$payload
		);

		substr($v->{inBuf}, 0, $v->{need}, '');

		$v->{state} = ATOM;
		$v->{need}  = ATOM_NEED;

		return $v->{$wanted_atom} if $v->{$wanted_atom};
	}

	return undef;
}

sub getAudio {
	my ($self, $outBuf) = @_;

	my $v = $self->_context;

	$v->{state} //= ATOM;
	$v->{need}  //= ATOM_NEED;

	while ($v->{need} <= length($v->{'inBuf'} || '')) {

		if ($v->{state} == ATOM) {

			my ($atom, $size, $header) = get_next_atom($v->{'inBuf'});

			last unless $atom;

			$v->{need}  = $size - $header;
			$v->{atom}  = $atom;
			$v->{header}= $header;
			$v->{state} = PARSING;

			substr($v->{'inBuf'}, 0, $header, '');
		}

		return 1 if $v->{need} > length $v->{'inBuf'};

		my $payload = substr($v->{'inBuf'}, 0, $v->{need});

		$v->{$v->{atom}} = process_atom(
			$v->{atom},
			$v->{need},
			$payload
		);

		substr($v->{'inBuf'}, 0, $v->{need}, '');

		$v->{state} = ATOM;
		$v->{need}  = ATOM_NEED;

		if ($v->{mdat}) {

			my $moov = get_first($v->{'moov'});
			my $trak = get_first($moov->{'trak'});
			my $mdia = get_first($trak->{'mdia'});
			my $minf = get_first($mdia->{'minf'});
			my $stbl = get_first($minf->{'stbl'});
			my $stsd = get_first($stbl->{'stsd'});

			my $mp4a =
				$stsd->{'entries'}->{'mp4a'}
				|| $self->_mp4a;

			my $moof = get_first($v->{'moof'});
			my $traf = get_first($moof->{'traf'});

			$$outBuf .= convertDashSegtoADTS(
				$mp4a->{'esds'},
				$v->{mdat}->{data},
				$traf
			);

			$v->{mdat} = undef;
		}
	}

	return 1;
}

my %atom_handler = (
	'moov' => sub { process_container('moov', @_) },
	'trak' => sub { process_container('trak', @_) },
	'edts' => sub { process_container('edts', @_) },
	'mdia' => sub { process_container('mdia', @_) },
	'minf' => sub { process_container('minf', @_) },
	'stbl' => sub { process_container('stbl', @_) },
	'mvex' => sub { process_container('mvex', @_) },
	'moof' => sub { process_container('moof', @_) },
	'traf' => sub { process_container('traf', @_) },
	'mfra' => sub { process_container('mfra', @_) },
	'skip' => sub { process_container('skip', @_) },

	'stsd' => \&process_stsd_atom,
	'sidx' => \&process_sidx_atom,
	'mp4a' => \&process_mp4a_atom,
	'esds' => \&process_esds_atom,
	'tfhd' => \&process_tfhd_atom,
	'trun' => \&process_trun_atom,
	'tfdt' => \&process_tfdt_atom,
	'mdat' => \&process_mdat_atom,
);

sub process_atom {
	my ($type, $size, $data) = @_;

	return undef unless $atom_handler{$type};

	return $atom_handler{$type}->($size, $data);
}

sub get_next_atom {
	my $data = shift;

	return unless defined $data;
	return unless length($data) >= 8;

	my $size = decode_u32(substr($data, 0, 4));
	my $type = substr($data, 4, 4);

	return unless $size;

	my $header = 8;

	if ($size == 1) {

		return unless length($data) >= 16;

		$size = decode_u64(substr($data, 8, 8));
		$header = 16;
	}

	return unless $size >= $header;

	return ($type, $size, $header);
}

sub process_container {
	my ($type, $size, $data) = @_;

	my %result;

	while ($size > 0) {

		last if length($data) < 8;

		my ($sub_type, $sub_size, $header) =
			get_next_atom($data);

		last unless $sub_type;
		last if $sub_size < $header;
		last if $sub_size > length($data);

		my $parsed = process_atom(
			$sub_type,
			$sub_size - $header,
			substr($data, $header, $sub_size - $header)
		);

		if (exists $result{$sub_type}) {

			if (ref($result{$sub_type}) eq 'ARRAY') {
				push @{$result{$sub_type}}, $parsed;
			}
			else {
				$result{$sub_type} = [
					$result{$sub_type},
					$parsed
				];
			}
		}
		else {
			$result{$sub_type} = $parsed;
		}

		substr($data, 0, $sub_size, '');

		$size -= $sub_size;
	}

	return \%result;
}

sub process_tfdt_atom {
	my ($size, $data) = @_;

	my %result;

	$result{'version'} = decode_u8($data);
	$result{'flags'}   = decode_u24(substr($data,1,3));

	if ($result{'version'}) {
		$result{'base_media_decode_time'} =
			decode_u64(substr($data,4,8));
	}
	else {
		$result{'base_media_decode_time'} =
			decode_u32(substr($data,4,4));
	}

	return \%result;
}

sub process_tfhd_atom {
	my ($size, $data) = @_;

	my %result;

	$result{'version'}  = decode_u8($data);
	$result{'tf_flags'} = decode_u24(substr($data,1,3));
	$result{'track_ID'} = decode_u32(substr($data,4,4));

	my $base = 8;

	if ($result{'tf_flags'} & 0x1) {
		$base += 8;
	}

	if ($result{'tf_flags'} & 0x2) {
		$result{'sample_description_index'} =
			decode_u32(substr($data,$base,4));
		$base += 4;
	}

	if ($result{'tf_flags'} & 0x8) {
		$result{'default_sample_duration'} =
			decode_u32(substr($data,$base,4));
		$base += 4;
	}

	if ($result{'tf_flags'} & 0x10) {
		$result{'default_sample_size'} =
			decode_u32(substr($data,$base,4));
		$base += 4;
	}

	if ($result{'tf_flags'} & 0x20) {
		$result{'default_sample_flags'} =
			decode_u32(substr($data,$base,4));
		$base += 4;
	}

	return \%result;
}

sub process_trun_atom {
	my ($size, $data) = @_;

	my %result;

	my $base = 0;

	$result{'version'}      = decode_u8($data);
	$result{'tr_flags'}     = decode_u24(substr($data,1,3));
	$result{'sample_count'} = decode_u32(substr($data,4,4));

	if ($result{'tr_flags'} & 0x1) {
		$result{'data_offset'} =
			decode_u32(substr($data,8,4));
		$base += 4;
	}

	if ($result{'tr_flags'} & 0x4) {
		$result{'first_sample_flags'} =
			decode_u32(substr($data,8+$base,4));
		$base += 4;
	}

	my @samples;

	for (my $i = 0; $i < $result{'sample_count'}; $i++) {

		my %sample;

		if ($result{'tr_flags'} & 0x100) {
			$sample{'sample_duration'} =
				decode_u32(substr($data,8+$base,4));
			$base += 4;
		}

		if ($result{'tr_flags'} & 0x200) {
			$sample{'sample_size'} =
				decode_u32(substr($data,8+$base,4));
			$base += 4;
		}

		if ($result{'tr_flags'} & 0x400) {
			$sample{'sample_flags'} =
				decode_u32(substr($data,8+$base,4));
			$base += 4;
		}

		if ($result{'tr_flags'} & 0x800) {
			$sample{'sample_composition_time_offset'} =
				decode_u32(substr($data,8+$base,4));
			$base += 4;
		}

		push @samples, \%sample;
	}

	$result{'samples'} = \@samples;

	return \%result;
}

sub process_stsd_atom {
	my ($size, $data) = @_;

	my %result;

	$result{'version'}     = decode_u8($data);
	$result{'flags'}       = decode_u24(substr($data,1,3));
	$result{'entry_count'} = decode_u32(substr($data,4,4));

	$result{'entries'} = {};

	my $offset = 8;

	for (my $i = 0; $i < $result{'entry_count'}; $i++) {

		last if $offset + 8 > length($data);

		my ($sub_type, $sub_size, $header) =
			get_next_atom(substr($data, $offset));

		last unless $sub_type;

		$result{'entries'}->{$sub_type} =
			process_atom(
				$sub_type,
				$sub_size - $header,
				substr(
					$data,
					$offset + $header,
					$sub_size - $header
				)
			);

		$offset += $sub_size;
	}

	return \%result;
}

sub process_sidx_atom {
	my ($size, $data) = @_;

	my %result;

	my $offset = 24;

	$result{'version'}      = decode_u32(substr($data,0,4));
	$result{'reference_id'} = decode_u32(substr($data,4,4));
	$result{'timescale'}    = decode_u32(substr($data,8,4));

	if ($result{'version'}) {
		$result{'time'}   = decode_u64(substr($data,12,8));
		$result{'offset'} = decode_u64(substr($data,20,8));
		$offset += 8;
	}
	else {
		$result{'time'}   = decode_u32(substr($data,12,4));
		$result{'offset'} = decode_u32(substr($data,16,4));
	}

	$result{'reference_count'} =
		decode_u16(substr($data,22,2));

	$result{'indexes'} = [];

	for (my $i = 0; $i < $result{'reference_count'}; $i++) {

		last if $offset + 12 > length($data);

		my $size =
			decode_u32(substr($data,$offset,4))
			& 0x7fffffff;

		my $duration =
			decode_u32(substr($data,$offset+4,4));

		push @{$result{'indexes'}}, {
			size     => $size,
			duration => $duration,
		};

		$offset += 12;
	}

	return \%result;
}

sub process_mp4a_atom {
	my ($size, $data) = @_;

	my %result;

	$result{'channelcount'} =
		decode_u16(substr($data,16,2));

	$result{'samplesize'} =
		decode_u16(substr($data,18,2));

	$result{'samplerate'} =
		decode_u32(substr($data,24,4)) >> 16;

	if ($size > 28) {

		my ($sub_type, $sub_size, $header) =
			get_next_atom(substr($data,28));

		if ($sub_type) {
			$result{$sub_type} = process_atom(
				$sub_type,
				$sub_size - $header,
				substr(
					$data,
					28 + $header,
					$sub_size - $header
				)
			);
		}
	}

	return \%result;
}

sub read_descriptor_length {
	my ($data, $offset_ref) = @_;

	my $length = 0;

	for (1..4) {

		my $b = decode_u8(substr($data, $$offset_ref, 1));

		$$offset_ref++;

		$length = ($length << 7) | ($b & 0x7f);

		last unless ($b & 0x80);
	}

	return $length;
}

sub process_esds_atom {
	my ($size, $data) = @_;

	my %result;

	$result{'version'} = decode_u8($data);
	$result{'flags'}   = decode_u24(substr($data,1,3));

	my $offset = 4;

	my $tag = decode_u8(substr($data,$offset,1));
	return undef unless $tag == 0x03;

	$offset++;

	my $tag_size = read_descriptor_length($data, \$offset);

	$offset += 3;

	$tag = decode_u8(substr($data,$offset,1));
	return undef unless $tag == 0x04;

	$offset++;

	$tag_size = read_descriptor_length($data, \$offset);

	$result{'objectTypeId'} =
		decode_u8(substr($data,$offset,1));

	$offset += 1;

	$offset += 3;

	$result{'maxbitrate'} =
		decode_u32(substr($data,$offset,4));

	$offset += 4;

	$result{'avgbitrate'} =
		decode_u32(substr($data,$offset,4));

	$offset += 4;

	$tag = decode_u8(substr($data,$offset,1));
	return undef unless $tag == 0x05;

	$offset++;

	$tag_size = read_descriptor_length($data, \$offset);

	my $asc =
		substr($data,$offset,$tag_size);

	return undef unless length($asc) >= 2;

	my $b0 = decode_u8(substr($asc,0,1));
	my $b1 = decode_u8(substr($asc,1,1));

	$result{'AudioObjectType'} =
		($b0 >> 3);

	$result{'FreqIndex'} =
		(($b0 & 0x07) << 1)
		| ($b1 >> 7);

	$result{'channelConfig'} =
		(($b1 >> 3) & 0x0f);

	return \%result;
}

sub process_mdat_atom {
	my ($size, $data) = @_;

	return {
		data => $data
	};
}

sub mp4esdsToADTSHeader {

	my ($mp4esds, $framelength) = @_;

	my $profile =
		$mp4esds->{'AudioObjectType'};

	$profile = 2 if ($profile == 5);

	my $frequency_index =
		$mp4esds->{'FreqIndex'};

	my $channel_config =
		$mp4esds->{'channelConfig'};

	my $finallength =
		$framelength + 7;

	my @ADTSHeader =
		(0xFF,0xF1,0,0,0,0,0xFC);

	$ADTSHeader[2] =
		(((($profile & 0x3) - 1) << 6)
		+ ($frequency_index << 2)
		+ ($channel_config >> 2));

	$ADTSHeader[3] =
		((($channel_config & 0x3) << 6)
		+ ($finallength >> 11));

	$ADTSHeader[4] =
		(($finallength & 0x7ff) >> 3);

	$ADTSHeader[5] =
		((($finallength & 7) << 5)
		+ 0x1f);

	return pack("CCCCCCC", @ADTSHeader);
}

sub convertDashSegtoADTS {

	my ($mp4esds, $dashsegment, $traf) = @_;

	my $segpos = 0;

	my $adtssegment = '';

	my @truns =
		ref($traf->{'trun'}) eq 'ARRAY'
		? @{$traf->{'trun'}}
		: ($traf->{'trun'});

	foreach my $trun (@truns) {

		foreach my $sample (@{$trun->{'samples'}}) {

			my $sample_size =
				$sample->{'sample_size'}
				|| $traf->{'tfhd'}->{'default_sample_size'};

			last unless $sample_size;

			last if (
				$segpos + $sample_size >
				length($dashsegment)
			);

			$adtssegment .=
				mp4esdsToADTSHeader(
					$mp4esds,
					$sample_size
				);

			$adtssegment .= substr(
				$dashsegment,
				$segpos,
				$sample_size
			);

			$segpos += $sample_size;
		}
	}

	return $adtssegment;
}

sub get_first {
	my $x = shift;

	return undef unless defined $x;

	return ref($x) eq 'ARRAY'
		? $x->[0]
		: $x;
}

sub decode_u8  { unpack('C', $_[0]) }
sub decode_u16 { unpack('n', $_[0]) }
sub decode_u24 { unpack('N', ("\0" . $_[0])) }
sub decode_u32 { unpack('N', $_[0]) }

sub decode_u64 {
	return unpack('Q>', substr($_[0], 0, 8))
		if $Config{ivsize} == 8;

	return unpack('N', substr($_[0], 4, 4));
}

1;