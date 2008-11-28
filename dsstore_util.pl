#!/usr/bin/perl

use Encode;
use IO::File;
use Data::Dumper;

$Data::Dumper::Useqq = 1;

$foo = BuddyAllocator::open(new IO::File $ARGV[0], 'r');
print Dumper([ $foo, unpack('NNN', $foo->{unk2}) ]);
$treeheader = $foo->blockByNumber($foo->{toc}->{DSDB});

#print Dumper([ $treeheader->read(20, 'N5') ]);
#print Dumper([ &readBTreeNode($foo->blockByNumber($treeheader->read(4, 'N'))) ]);

#print Dumper([ &readBTreeNode($foo->blockByNumber( 2 )) ]);

$foo->listblocks();


sub readBTreeNode {
    my($node) = @_;

    my($height) = $node->read(4, 'N');

    my($count) = $node->read(4, 'N');
    if ($height > 0) {
	my(@pointers, @values);
	push(@pointers, $node->read(4, 'N'));
	while($count) {
	    push(@values, &readDesktopDBEntry($node));
	    push(@pointers, $node->read(4, 'N'));
	    $count --;
	}
	return $height, \@values, \@pointers;
    } else {
	my(@values);
	while($count) {
	    push(@values, &readDesktopDBEntry($node));
	    $count --;
	}
	return $height, \@values, undef;
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

sub readDesktopDBEntry {
    my($block) = @_;

    my($filename, $strucID, $strucType, $value);

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
    } else {
	die "Unknown struc type '$strucType', died";
    }

    return [ $filename, $strucId, $strucType, $value ];
}

sub readFilename {
    my($block) = @_;

    my($flen) = $block->read(4, 'N');
    my($utf16be) = $block->read(2 * $flen);
    
    return decode('UTF-16BE', $utf16be, Encode::FB_CROAK);
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
    my($self) = @_;
    my(%byaddr);
    my($addr, $len);

    # We store all blocks (allocated and free) in %byaddr,
    # then go through its keys in order

    # Store the implicit 32-byte block that holds the file header
    push(@{$byaddr{0}}, "5 (file header)");

    # Store all the numbered/allocated blocks from @offsets
    for my $blnum (0 .. $#{$self->{'offsets'}}) {
	$addr_size = $self->{'offsets'}->[$blnum];
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

    # Loop through the blocks in order of address
    my(@addrs) = sort {$a <=> $b} keys %byaddr;
    $addr = 0;
    while(@addrs) {
	my($next) = shift @addrs;
	if ($next > $addr) {
	    print "... ", ($next - $addr), " bytes unaccounted for\n";
	}
	my(@uses) = @{$byaddr{$next}};
	printf "%08x %s\n", $next, join(', ', @uses);

	# strip off the length (log_2(length) really) from the info str
	($len = $uses[0]) =~ s/ .*//;
	$addr = $next + ( 1 << (0 + $len) );
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
