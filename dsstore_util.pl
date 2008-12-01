#!/usr/bin/perl

use Encode;
use IO::File;
use Data::Dumper;

$Data::Dumper::Useqq = 1;

$foo = BuddyAllocator::open(new IO::File $ARGV[0], 'r');
print Dumper([ $foo, unpack('NNN', $foo->{unk2}) ]);
$treeheader = $foo->blockByNumber($foo->{toc}->{DSDB});

{
    my(@treeheader) = $treeheader->read(20, 'N5');
    print Dumper(\@treeheader);
#    print Dumper([ &readBTreeNode($foo->blockByNumber($treeheader[0])) ]);
    &traverse_btree($foo, $treeheader[0], sub { print $_[0]->[1], ' ', $_[0]->[0], "\n"; } );
}


sub traverse_btree {
    my($store, $nodenr, $callback) = @_;

    my($values, $pointers) = &readBTreeNode( $store->blockByNumber( $nodenr ) );
    if (defined $pointers) {
	die "Value count should be one less than pointer count" 
	    unless ( @$values + 1 ) == ( @$pointers ) ;
	&traverse_btree($store, shift(@$pointers), $callback);
	while(@$values) {
	    &{$callback}(shift @$values);
	    &traverse_btree($store, shift(@$pointers), $callback);
	}
    } else {
	&{$callback}($_) foreach @$values;
    }
}


sub readBTreeNode {
    my($node) = @_;

    my($pointer) = $node->read(4, 'N');

    my($count) = $node->read(4, 'N');
    if ($pointer > 0) {
	my(@pointers, @values);
	while($count) {
	    push(@pointers, $node->read(4, 'N'));
	    push(@values, &DesktopDB::readEntry($node));
	    $count --;
	}
	push(@pointers, $pointer);
	return \@values, \@pointers;
    } else {
	my(@values);
	while($count) {
	    push(@values, &DesktopDB::readEntry($node));
	    $count --;
	}
	return \@values, undef;
    }
}

sub writeBTreeNode {
    my($into, $values, $pointers) = @_;

    if (!$pointers) {
	# A leaf node: no pointers, just database entries.
	$into->write('NN', 0, scalar(@$values));
	$_->write($into) foreach @$values;
    } else {
	# An internal node: interleaved pointers and values,
	# with the final pointer moved to the front.
	my(@vals) = @$values;
	my(@ps) = @$pointers;
	die "number of pointers must be one more than number of entries"
	    unless 1+@vals == @ps;
	$into->write('NN', pop(@ps), scalar(@vals));
	while(@vals) {
	    $into->write('N', shift(@ps));
	    ( shift(@vals) )->write($into);
	}
    }
}

sub readBytes {
    my($fh, $len, $unpack) = @_;

    my($rv, $value);

    $rv = $fh->read($value, $len);
    die "read($len)=$rv: $!, died" if $rv < 0;
    die "read($len)=$rv: short read?, died" if $rv != $len;

    return $unpack? unpack($unpack, $value) : $value;
}

package DesktopDB;

sub readEntry {
    my($block) = @_;

    my($filename, $strucId, $strucType, $value);

    $filename = &readFilename($block);
    $strucId = $block->read(4);
    $strucType = $block->read(4);
    
    if ($strucType eq 'bool') {
	$value = $block->read(1, 'C');
    } elsif ($strucType eq 'long' or $strucType eq 'shor') {
	$value = $block->read(4, 'N');
    } elsif ($strucType eq 'blob') {
	my($bloblen) = $block->read(4, 'N');
	$value = $block->read($bloblen);
    } elsif ($strucType eq 'ustr') {
	my($strlen) = $block->read(4, 'N');
	$value = Encode::decode('UTF-16BE', $block->read(2 * $strlen));
    } else {
	die "Unknown struc type '$strucType', died";
    }

    return bless([ $filename, $strucId, $strucType, $value ],
		 'DesktopDB::Entry');
}

sub readFilename {
    my($block) = @_;

    my($flen) = $block->read(4, 'N');
    my($utf16be) = $block->read(2 * $flen);
    
    return Encode::decode('UTF-16BE', $utf16be, Encode::FB_CROAK);
}

package DesktopDB::Entry;

sub byteSize {
    my($filename, $strucId, $strucType, $value) = @{$_[0]};
    my($size);

    # TODO: We're assuming that the filename is completely normal
    # basic-multilingual-plane characters, and doesn't need to be de/re-
    # composed or anything.
    $size = length($filename) * 2 + 12;
    # 12 bytes: 4 each for filename length, struct id, and struct type

    if ($strucType eq 'long' or $strucType eq 'shor') {
	$size += 4;
    } elsif ($strucType eq 'bool') {
	$size += 1;
    } elsif ($strucType eq 'blob') {
	$size += length($value);
    } elsif ($strucType eq 'ustr') {
	$size += 4 + 2 * length($value);
    } else {
	die "Unknown struc type '$strucType', died";
    }

    $size;
}

sub write {
    my($self, $into) = @_;
    
    my($fname) = Encode::encode('UTF-16BE', $self->[0]);

    my($strucType) = $self->[2];

    $into->write('N a* a4 a4', length($fname)/2, $fname,
		 $self->[1], $strucType);

    if ($strucType eq 'long' or $strucType eq 'shor') {
	$into->write('N', $self->[3]);
    } elsif ($strucType eq 'bool') {
	$into->write('C', $self->[3]);
    } elsif ($strucType eq 'blob') {
	$into->write('N', length($self->[3]));
	$into->write($self->[3]);
    } elsif ($strucType eq 'ustr') {
	$into->write('N', length($self->[3]));
	$into->write(Encode::encode('UTF-16BE', $self->[3]));
    } else {
	die "Unknown struc type '$strucType', died";
    }
}

package BuddyAllocator;

sub open {
    my($fh) = @_;

    # read the file header: 32 bytes, plus a mysterious extra
    # four bytes at the front
    my($magic1, $magic, $offset, $size, $offset2, $unk2) = &main::readBytes($fh, 0x24, 'N a4 NNN a16');
    die 'bad magic' unless $magic eq 'Bud1' and $magic1 == 1;
    die 'inconsistency: two root addresses are different'
	unless $offset == $offset2;

    my($self) = {
	fh => $fh,
	unk2 => $unk2,
	fudge => 4,  # add this to offsets for some unknown reason
    };
    bless($self, 'BuddyAllocator');
    
    # retrieve the root/index block which contains the allocator's
    # book-keeping data
    my ($rootblock) = $self->getblock($offset, $size);

    # parse out the offsets of all the allocated blocks
    # these are in tagged offset format (27 bits offset, 5 bits size)
    my($offsetcount, $unk3) = $rootblock->read(8, 'NN');
    # not sure what the word following the offset count is
    $self->{'unk3'} = $unk3;
    # For some reason, offsets are always stored in blocks of 256.
    my(@offsets);
    while($offsetcount > 0) {
	push(@offsets, $rootblock->read(1024, 'N256'));
	$offsetcount -= 256;
    }
    # 0 indicates an empty slot; don't need to keep those around
    while($offsets[$#offsets] == 0) { pop(@offsets); }

    # Next, read N key/value pairs
    my($toccount) = $rootblock->read(4, 'N');
    my($toc) = {
    };
    while($toccount--) {
	my($len) = $rootblock->read(1, 'C');
	my($name) = $rootblock->read($len);
	my($value) = $rootblock->read(4, 'N');
	$toc->{$name} = $value;
    }

    $self->{'offsets'} = \@offsets;
    $self->{'toc'} = $toc;

    # Finally, read the free lists.
    my($freelists) = { };
    for(my $width = 0; $width < 32; $width ++) {
	my($blkcount) = $rootblock->read(4, 'N');
	$freelists->{$width} = [ $rootblock->read(4 * $blkcount, 'N*') ];
    }
    $self->{'freelist'} = $freelists;

    return $self;
}

# List all the blocks in order and see if there are any gaps or overlaps.
sub listblocks {
    my($self, $verbose) = @_;
    my(%byaddr);
    my($addr, $len);

    # We store all blocks (allocated and free) in %byaddr,
    # then go through its keys in order

    # Store the implicit 32-byte block that holds the file header
    push(@{$byaddr{0}}, "5 (file header)");

    # Store all the numbered/allocated blocks from @offsets
    for my $blnum (0 .. $#{$self->{'offsets'}}) {
	my($addr_size) = $self->{'offsets'}->[$blnum];
	$addr = $addr_size & ~0x1F;
	$len = $addr_size & 0x1F;
	push(@{$byaddr{$addr}}, "$len (blkid $blnum)");
    }

    # Store all the blocks in the freelist(s)
    for $len (keys %{$self->{'freelist'}}) {
	for $addr (@{$self->{'freelist'}->{$len}}) {
	    push(@{$byaddr{$addr}}, "$len (free)");
	}
    }

    my($gaps, $overlaps) = (0, 0);

    # Loop through the blocks in order of address
    my(@addrs) = sort {$a <=> $b} keys %byaddr;
    $addr = 0;
    while(@addrs) {
	my($next) = shift @addrs;
	if ($next > $addr) {
	    print "... ", ($next - $addr), " bytes unaccounted for\n"
		if $verbose;
	    $gaps ++;
	}
	my(@uses) = @{$byaddr{$next}};
	printf "%08x %s\n", $next, join(', ', @uses)
	    if $verbose;
	$overlaps ++ if @uses > 1;

	# strip off the length (log_2(length) really) from the info str
	($len = $uses[0]) =~ s/ .*//;
	$addr = $next + ( 1 << (0 + $len) );
    }

    ( $gaps == 0 && $overlaps == 0 );
}

sub writeRootblock {
    my($self, $into) = @_;

    my(@offsets) = @{$self->{'offsets'}};
    
    # Write the offset count & the unknown field that follows it
    $into->write('NN', scalar(@offsets), $self->{'unk3'});
    
    # Write the offsets (using 0 to indicate an unused slot)
    $into->write('N*', map { (defined($_) && $_ > 0)? $_ : 0 } @offsets);
    
    # The offsets are always written in blocks of 256.
    my($offsetcount) = scalar(@offsets) % 256;
    if ($offsetcount > 0) {
	# Fill out the last block
	$into->write('N*', (0) x (256-$offsetcount));
    }

    # The DS_Store files only ever have one item in their
    # table of contents, so I'm not sure if it needs to be sorted or what
    my(@tockeys) = sort keys %{$self->{'toc'}};
    $into->write('N', scalar(@tockeys));
    foreach my $entry (@tockeys) {
	$into->write('C a* N', length($entry), $entry, $self->{'toc'}->{$entry});
    }
    
    # And finally the freelists
    for my $width ( 0 .. 31 ) {
	my($blks) = $self->{'freelist'}->{$width};
	$into->write('N N*', scalar(@$blks), @$blks);
    }
}
    

# Retrieve a block (a BuddyAllocator::Block instance) by offset & length
sub getblock {
    my($self, $offset, $size) = @_;
    $self->{fh}->seek($offset + $self->{fudge}, 0);
    
    my($value);
    $self->{fh}->read($value, $size) == $size
	or die;
    my($block) = [ $self, $value, 0 ];
    bless($block, 'BuddyAllocator::Block');
}

# Retrieve a block by its block number (small integer)
sub blockByNumber {
    my($self, $id) = @_;
    my($addr) = $self->{offsets}->[$id];
    return undef unless $addr;
    my($offset, $len);
    $offset = $addr & ~0x1F;
    $len = 1 << ( $addr & 0x1F );
#    print "  node id $id is $len bytes at 0x".sprintf('%x', $offset)."\n";
    return $self->getblock($offset, $len);
}

package BuddyAllocator::Block;

use Carp;

sub read {
    my($self, $len, $unpack) = @_;
    my($pos) = $self->[2];
    die "out of range: pos=$pos len=$len max=".(length($self->[1])) if $pos + $len > length($self->[1]);
    my($bytes) = substr($self->[1], $pos, $len);
    $self->[2] = $pos + $len;
    
    $unpack? unpack($unpack, $bytes) : $bytes;
}

sub length {
    return length($_[0]->[1]);
}

sub seek {
    my($self, $pos, $whence) = @_;
    $whence = 0 unless defined $whence;
    if ($whence == 0) {
	# pos = pos
    } elsif ($whence == 1) {
	$pos += $self->[2];
    } elsif ($whence == 2) {
	$pos += $self->length();
    } else {
	croak "seek: whence=$whence";
    }
    $self->[2] = $pos;
}
