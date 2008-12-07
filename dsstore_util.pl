#!/usr/bin/perl

use Encode;
use IO::File;
use Data::Dumper;
use BuddyAllocator;

$Data::Dumper::Useqq = 1;

$foo = Mac::Finder::DSStore::BuddyAllocator->open(new IO::File $ARGV[0], 'r');
$dsdb = $foo->{toc}->{DSDB};

#{
#    my(@treeheader) = $treeheader->read(20, 'N5');
#    print Dumper(\@treeheader);
#    print Dumper([ &readBTreeNode($foo->blockByNumber($treeheader[0])) ]);
#    &traverse_btree($foo, $treeheader[0], sub { print $_[0]->[1], ' ', $_[0]->[0], "\n"; } );
#}

$treeroot = $foo->blockByNumber($dsdb)->read(4, 'N');

$foo->listBlocks(1);
&freeBTreeNode($treeroot, $foo);
$foo->listBlocks(1);

$foo->free($dsdb);
$foo->writeMetaData();

$foo->listBlocks(1);

$foo->allocate(1024) foreach (1 .. 6);
$foo->free($_) foreach(6,1,3,2,4,5);

$foo->listBlocks(1);

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

sub freeBTreeNode {
    my($nodeid, $allocator) = @_;
    my($block) = $allocator->blockByNumber( $nodeid );
    
    if($block->read(4, 'N') != 0) {
	$block->seek(0);
	my($values, $pointers) = &readBTreeNode($block);
	&freeBTreeNode($_, $allocator) foreach @$pointers;
    }

    $allocator->free($nodeid);
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

