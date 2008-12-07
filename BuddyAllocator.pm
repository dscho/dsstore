package Mac::Finder::DSStore::BuddyAllocator;

=head1 NAME

Mac::Finder::DSStore::BuddyAllocator - Allocate space within a file

=head1 DESCRIPTION

C<Mac::Finder::DSStore::BuddyAllocator>
implements a buddy-allocation scheme within a file. It's used by
C<Mac::Finder::DSStore> to read certain files created by the Macintosh
Finder.

Only the C<open> and C<writeMetaData> methods actually perform any
file I/O. The contents of allocated blocks are read and written with
methods on C<BuddyAllocator::Block>. If the C<allocate> and C<free>
methods are used, C<writeMetaData> must be called for the changes to
be reflected in the file.

=head1 METHODS

=cut

use strict;

our($VERSION) = '0.9';

# Debug logging. Uncomment these and all uses of them to activate.
# It might be nice to make this more easily switchable.
#our($loglevel) = 0;
#sub logf {
#    print STDERR ( ' ' x $loglevel ) . sprintf($_[0], @_[1 .. $#_ ]) . "\n";
#}

=head2 $allocator = Mac::Finder::DSStore::BuddyAllocator->open($fh)

C<open($fh)> constructs a new buddy allocator 
and initializes its state from the information in the file.
The file handle is retained by the allocator for future
operations.

=cut

sub open {
    my($class, $fh) = @_;

    # read the file header: 32 bytes, plus a mysterious extra
    # four bytes at the front
    my($fheader);
    $fh->read($fheader, 4 + 0x20) == 0x24
	or die "Can't read file header: $!";
    my($magic1, $magic, $offset, $size, $offset2, $unk2) = unpack('N a4 NNN a16', $fheader);
    die 'bad magic' unless $magic eq 'Bud1' and $magic1 == 1;
    die 'inconsistency: two root addresses are different'
	unless $offset == $offset2;

    my($self) = {
	fh => $fh,
	unk2 => $unk2,
	fudge => 4,  # add this to offsets for some unknown reason
    };
    bless($self, ref($class) || $class);
    
    # retrieve the root/index block which contains the allocator's
    # book-keeping data
    my ($rootblock) = $self->getBlock($offset, $size);

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

=head2 $allocator->listBlocks($verbose)

List all the blocks in order and see if there are any gaps or overlaps.
If C<$verbose> is true, then the blocks are listed to the current
output filehandle. Returns true if the allocated and free blocks
have no gaps or overlaps.

=cut

sub listBlocks {
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

=head2 $allocator->writeMetaData( )

Writes the allocator's metadata (header block and root block)
back to the file.

=cut

sub writeMetaData {
    my($self) = @_;

    my($rbs) = $self->rootBlockSize();
    $self->allocate($rbs, 0);
}

sub rootBlockSize {
    my($self) = @_;
    my($size);

    $size = 8;  # The offset count and the unknown field that follows it
    
    # The offset blocks, rounded up to a multiple of 256 entries
    my($offsetcount) = scalar( @{$self->{'offsets'}} );
    my($tail) = $offsetcount % 256;
    $offsetcount += 256 - $tail if ($tail);
    $size += 4 * $offsetcount;

    # The table of contents
    $size += 4; # count
    $size += (5 + length($_)) foreach keys %{$self->{'toc'}};

    # The freelists
    foreach my $width (0 .. 31) {
	$size += 4 + 4 * scalar( @{$self->{'freelist'}->{$width}} );
    }

    $size;
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

=head2 $block = $allocator->blockByNumber(blocknumber)

Retrieves a block by its block number or block ID.

=head2 $block = $allocator->getBlock(offset, size)

Retrieves a block (a BuddyAllocator::Block instance) by offset & length.
Normally you should use C<blockByNumber> instead of this method.

=cut

sub getBlock {
    my($self, $offset, $size) = @_;
    $self->{fh}->seek($offset + $self->{fudge}, 0);
    
    my($value);
    $self->{fh}->read($value, $size) == $size
	or die;
    my($block) = [ $self, $value, 0 ];
    bless($block, 'Mac::Finder::DSStore::BuddyAllocator::Block');
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
    return $self->getBlock($offset, $len);
}

# Return freelist + index of a block's buddy in its freelist (or empty list)
sub _buddy {
    my($self, $offset, $width) = @_;
    my($freelist, $buddyaddr);

    $freelist = $self->{'freelist'}->{$width};
    $buddyaddr = $offset ^ ( 1 << $width );

    return ($freelist,
	    grep { $freelist->[$_] == $buddyaddr } 0 .. $#$freelist );
}

# Free a block, coalescing ith buddies as needed.
sub _free {
    my($self, $offset, $width) = @_;

    my($freelist, $buddyindex) = $self->_buddy($offset, $width);

    if(defined($buddyindex)) {
	# our buddy is free. Coalesce, and add the coalesced block to flist.
	my($buddyoffset) = splice(@$freelist, $buddyindex, 1);
	#&logf("Combining %x with buddy %x", $offset, $buddyoffset);
	$self->_free($offset & $buddyoffset, $width+1);
    } else {
	#&logf("Adding block %x to freelist %d", $offset, $width);
	@$freelist = sort( @$freelist, $offset );
    }
}

# Allocate a block of a specified width, splitting as needed.
sub _alloc {
    my($self, $width) = @_;
    
    #&logf("Allocating a block of width %d", $width);
    #$loglevel ++;

    my($flist) = $self->{'freelist'}->{$width};
    if (@$flist) {
	# There is a block of the desired size; return it.
	#&logf("Pulling %x from freelist", $flist->[0]); $loglevel --;
	return shift @$flist;
    } else {
	# Allocate a block of the next larger size; split it.
	my($offset) = $self->_alloc($width + 1);
	# and put the other half on the free list.
	my($buddy) = $offset ^ ( 1 << $width );
	#&logf("Splitting %x into %x and %x", $offset, $offset, $buddy);
	#$loglevel ++;
	$self->_free($buddy, $width);
	#$loglevel -= 2;
	return $offset;
    }
}

=head2 $blocknumber = $allocator->allocate($size, [$blocknumber])

Allocates or re-allocates a block to be at least C<$size> bytes long.
If C<$blocknumber> is given, the specified block will be grown or
shrunk if needed, otherwise a new block number will be chosen and
given to the allocated block.

Unlike the libc C<realloc> function, this may move a block even if the
block is not grown.

=head2 $allocator->free($blocknumer)

Releases the block number and the block associated with it back to the
block pool.

=cut

sub allocate {
    my($self, $bytes, $blocknum) = @_;
    my($offsets) = $self->{'offsets'};

    #if(defined($blocknum)) {
    #    &logf("(Re)allocating %d bytes for blkid %d", $bytes, $blocknum);
    #}

    if(!defined($blocknum)) {
	$blocknum = 1;
	# search for an empty slot, or extend the array
	$blocknum++ while defined($offsets->[$blocknum]);
	#&logf("Allocating %d bytes, assigning blkid %d", $bytes, $blocknum);
    }

    #$loglevel ++;

    my($wantwidth) = 5;
    # Minimum width, since that's how many low-order bits we steal for the tag
    $wantwidth ++ while $bytes > 1 << $wantwidth;

    my($blkaddr, $blkwidth, $blkoffset);

    if(exists($offsets->[$blocknum]) && $offsets->[$blocknum]) {
	$blkaddr = $offsets->[$blocknum];
	$blkwidth = $blkaddr & 0x1F;
	$blkoffset = $blkaddr & ~0x1F;
	if ($blkwidth == $wantwidth) {
	    #&logf("Block is already width %d, no change", $wantwidth);
	    #$loglevel --;
	    # The block is currently of the desired size. Leave it alone.
	    return $blkoffset;
	} else {
	    #&logf("Freeing wrong-sized block");
	    #$loglevel ++;
	    # Free the current block, allocate a new one.
	    $self->_free($blkoffset, $blkwidth);
	    delete $offsets->[$blocknum];
	    #$loglevel --;
	}
    }

    # Allocate a block, update the offsets table, and return the new offset
    $blkoffset = $self->_alloc($wantwidth);
    $blkaddr = $blkoffset | $wantwidth;
    $offsets->[$blocknum] = $blkaddr;
    #$loglevel --;
    $blocknum;
}

sub free {
    my($self, $blknum) = @_;
    my($blkaddr) = $self->{'offsets'}->[$blknum];

    #&logf("Freeing block index %d", $blknum);
    #$loglevel ++;

    if($blkaddr) {
	my($blkoffset, $blkwidth);
	$blkwidth = $blkaddr & 0x1F;
	$blkoffset = $blkaddr & ~0x1F;
	$self->_free($blkoffset, $blkwidth);
    }

    delete $self->{'offsets'}->[$blknum];
    #$loglevel --;
    undef;
}

=head1 ATTRIBUTES

=head2 $allocator->{toc}

C<toc> holds a hashref whose keys are short strings and whose values
are integers. This table of contents is read and written as part of the
allocator's metadata but is not otherwise used by the allocator;
users of the allocator use it to find their data within the file.

=cut

package Mac::Finder::DSStore::BuddyAllocator::Block;

=head1 BuddyAllocator::Block

C<BuddyAllocator::Block> instances are returned by the
C<blockByNumber> and C<getBlock> methods. They hold a pointer into
the file and provide a handful of useful methods.

=head2 $block->read(length, [format])

Reads C<length> bytes from the block (advancing the read pointer
correspondingly). If C<format> is specified, the bytes read are
unpacked using the format; otherwise a byte string is returned. 

=head2 $block->length( )

Returns the length (or size) of this block.

=head2 $block->seek(position[, whence])

Adjusts the read/write pointer within the block.

=cut

use Carp;
use strict;

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

=head1 AUTHOR

Written by Wim Lewis as part of the Mac::Finder::DSStore package.

This file is copyright 2008 by Wim Lewis.
All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.




