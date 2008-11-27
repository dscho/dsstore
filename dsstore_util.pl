#!/usr/bin/perl

use Encode;
use IO::File;
use Data::Dumper;

$Data::Dumper::Useqq = 1;

$foo = BuddyAllocator::open(new IO::File $ARGV[0], 'r');
print Dumper([ $foo, unpack('NNN', $foo->{unk2}) ]);
$treeheader = $foo->blockByNumber($foo->{toc}->{DSDB});

#print Dumper([ $treeheader->read(20, 'N5') ]);
print Dumper([ &readBTreeNode($foo->blockByNumber($treeheader->read(4, 'N'))) ]);

#print Dumper([ &readBTreeNode($foo->blockByNumber( 2 )) ]);



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
    print "flen=$flen\n";
    my($utf16be) = $block->read(2 * $flen);
    
    return decode('UTF-16BE', $utf16be, Encode::FB_CROAK);
}

package BuddyAllocator;

sub open {
    my($fh) = @_;

    my($unk1, $magic, $offset, $size, $offset2, $unk2) = &main::readBytes($fh, 0x20, 'N a4 NNN a12');
    die 'bad magic' unless $magic eq 'Bud1';
    die 'inconsistency: two root addresses are different'
	unless $offset == $offset2;

    my($self) = {
	fh => $fh,
	unk1 => $unk1,
	unk2 => $unk2,
	fudge => 4,  # add this to offsets for some unknown reason
    };
    bless($self, 'BuddyAllocator');
    
    my ($rootblock) = $self->getblock($offset, $size);

    my($offsetcount, $unk3) = $rootblock->read(8, 'NN');
    print "c0 $offsetcount c1 $unk3\n";
    # For some reason, offsets are always stored in blocks of 256.
    my(@offsets);
    while($offsetcount > 0) {
	push(@offsets, $rootblock->read(1024, 'N256'));
	$offsetcount -= 256;
    }
    # 0 indicates an empty slot; don't need to keep those around
    while($offsets[$#offsets] == 0) { pop(@offsets); }

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

    return $self;
}

sub getblock {
    my($self, $offset, $size) = @_;
    $self->{fh}->seek($offset + $self->{fudge}, 0);
    
    my($value);
    $self->{fh}->read($value, $size) == $size
	or die;
    my($block) = [ $self, $value, 0 ];
    bless($block, 'BuddyAllocator::Block');
}

sub blockByNumber {
    my($self, $id) = @_;
    my($addr) = $self->{offsets}->[$id];
    return undef unless $addr;
    my($offset, $len);
    $offset = $addr & ~0x1F;
    $len = 1 << ( $addr & 0x1F );
    print "  node id $id is $len bytes at 0x".sprintf('%x', $offset)."\n";
    return $self->getblock($offset, $len);
}

package BuddyAllocator::Block;

sub read {
    my($self, $len, $unpack) = @_;
    my($pos) = $self->[2];
    print "reading $len at $pos\n";
    die "out of range: pos=$pos len=$len max=".(length($self->[1])) if $pos + $len > length($self->[1]);
    my($bytes) = substr($self->[1], $pos, $len);
    $self->[2] = $pos + $len;
    
    $unpack? unpack($unpack, $bytes) : $bytes;
}

=cut

sub readStore {
    my($fh) = @_;


    die "bad magic" unless $magic eq 'Bud1';
    $fh->seek($itemStart, 0);
    for(my $itemNumber = 0; $itemNumber < $itemCount; $itemNumber ++) {
	print "item $itemNumber of $itemCount, at ".(sprintf '%08x', $fh->tell())."\n";
	print Dumper(&readItem($fh));
    }
}

&readStore(new IO::File '/Users/ximl/Desktop/.DS_Store', 'r');

sub read4CC {
    &readBytes($_[0], 4);
}

