package Mac::Finder::DSStore;

=head1 NAME

Mac::Finder::DSStore - Read and write Macintosh Finder DS_Store files

=head1 DESCRIPTION

C<Mac::Finder::DSStore> provides a handful of functions for reading and
writing the desktop database files created by the Macintosh Finder.

=head1 FUNCTIONS

Many functions take a C<$store> argument which is the opened file as
an instance of L<Mac::Finder::DSStore::BuddyAllocator>, or a C<$block>
argument which is a specific block of the file as an instance of
L<Mac::Finder::DSStore::BuddyAllocator::Block>.

=cut

use strict;
use POSIX qw(ceil);
use Exporter qw(import);

our($VERSION) = '0.90';
our($testpoint);
our(@EXPORT_OK) = qw( getDSDBEntries putDSDBEntries );

=head2 @records = &Mac::Finder::DSStore::getDSDBEntries($store[, $callback])

Retrieves the "superblock" pointed to by the C<DSDB> entry in the store's table
of contents, and traverses the B-tree it points to, returning a list of
the records in the tree. Alternately, you can supply a callback which will
be invoked for each record, and C<getDSDBEntries> will return an empty list.

=cut

sub getDSDBEntries {
    my($file, $callback) = @_;

    my(@retval);

    $callback = sub { push(@retval, $_[0]); } unless defined $callback;

    my($rootnode, $height, $nrec, $nnodes, $blksize) = $file->blockByNumber($file->{toc}->{DSDB})->read(20, 'N5');
    
    my($n) = &traverse_btree($file, $rootnode, $callback);

    warn "Header node count ($nrec) not equal to actual node count ($n)"
	if $n != $nrec;

    @retval;
}

=head2 &Mac::Finder::DSStore::putDSDBEntries($store, $arrayref)

C<$arrayref> must contain a correctly ordered list of
C<Mac::Finder::DSStore::Entry> objects. They will be evenly
organized into a B-tree structure and written to the C<$store>. If there is
an existing tree of records in the file already, it will be deallocated.

This function does not flush the allocator's information back to the file.

=cut


sub putDSDBEntries {
    my($file, $recs) = @_;
    
    my($tocblock, $pagesize);
    my($pagecount, $reccount, $height);

    # Delete the old btree (but keep its superblock), or allocate a superblock.
    if(defined($file->{toc}->{DSDB})) {
	$tocblock = $file->{toc}->{DSDB};
	my($old_rootblock);
	($old_rootblock, $pagesize) = $file->blockByNumber($tocblock)->read(20, 'N x15 N');
	&freeBTreeNode($file, $old_rootblock);
    } else {
	$tocblock = $file->allocate( 20 );
	$file->{toc}->{DSDB} = $tocblock;
	$pagesize = 0x1000;
    }

    $reccount = @$recs;
    $pagecount = 0;
    $height = 0;

    my(@children);

    do {
	my(@sizes);

	if (@children) {
	    @sizes = map { 4 + $_->byteSize } @$recs;
	} else {
	    @sizes = map { $_->byteSize } @$recs;
	}

	my(@interleaf) = &partition_sizes($pagesize - 4, @sizes);
	my(@nchildren);

	my($next) = 0;
	foreach my $non (@interleaf, 1+$#$recs) {
	    my($blknr) = $file->allocate($pagesize);
	    push(@nchildren, $blknr);
	    my($blk) = $file->blockByNumber($blknr, 1);
	    if (@children) {
		&writeBTreeNode($blk,
				[ @$recs[ $next .. $non-1 ] ],
				[ @children[ $next .. $non ] ] );
	    } else {
		&writeBTreeNode($blk,
				[ @$recs[ $next .. $non-1 ] ]);
	    }
            $blk->close(1);
	    $next = $non + 1;
	    $pagecount ++;
	}
	
	$height ++;
	$recs = [ map { $recs->[$_] } @interleaf ];
	@children = @nchildren;
	die unless @children == 1+@$recs;
    } while(@children > 1);
    die unless 0 == @$recs;

    my($masterblock) = $file->blockByNumber($tocblock, 1);
    $masterblock->write('NNNNN',
			$children[0],
			$height - 1,
			$reccount,
			$pagecount,
			$pagesize);
    $masterblock->close;

    1;
}

sub partition_sizes {
    my($max, @sizes) = @_;
    my($sum) = 0;
    $sum += $_ foreach @sizes;

    return () if $sum <= $max;

    my(@ejecta);
    my($bcount) = ceil($sum / $max);
    my($target) = $sum / $bcount;

    my($n) = 0;
    for(;;) {
	my($bsum) = 0;
	while( $n < @sizes && $bsum < $target && ($bsum + $sizes[$n]) < $max ) {
	    $bsum += $sizes[$n];
	    $n ++;
	}

	last if $n >= @sizes;

	push(@ejecta, $n);
	$n++;
    }

    @ejecta;
}

sub traverse_btree {
    my($store, $nodenr, $callback) = @_;
    my($count);
    my($values, $pointers) = &readBTreeNode( $store->blockByNumber( $nodenr ) );

    if ($testpoint) {
        my($o) = Mac::Finder::DSStore::BuddyAllocator::StringBlock->new();
        {
            # Temporarily disable the test point so writeBTreeNode doesn't
            # recursively invoke it
            local($testpoint) = undef;
            &writeBTreeNode($o, $values, $pointers);
        }
        my($actual) = $store->blockByNumber( $nodenr )->copyback;
        my($roundtrip) = $o->copyback;
        $actual = substr($actual, 0, length($roundtrip));
        $testpoint->( $actual, $roundtrip );
    }

    $count = @$values;
    
    if (defined $pointers) {
	die "Value count should be one less than pointer count" 
	    unless ( @$values + 1 ) == ( @$pointers ) ;
	$count += &traverse_btree($store, shift(@$pointers), $callback);
	while(@$values) {
	    &{$callback}(shift @$values);
	    $count += &traverse_btree($store, shift(@$pointers), $callback);
	}
    } else {
	&{$callback}($_) foreach @$values;
    }

    $count;
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
	    push(@values, Mac::Finder::DSStore::Entry->readEntry($node));
	    $count --;
	}
	push(@pointers, $pointer);
	return \@values, \@pointers;
    } else {
	my(@values);
	while($count) {
	    push(@values, Mac::Finder::DSStore::Entry->readEntry($node));
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

    if($testpoint) {
        my($x) = [ &readBTreeNode($into->copyback) ];
        $testpoint->( [ $values, $pointers], $x );
    }
}

package Mac::Finder::DSStore::Entry;

=head1 Mac::Finder::DSStore::Entry

This class holds the individual records from the database. Each record
contains a filename (in some cases, "." to refer to the containing
directory), a 4-character record type, and a value. The value is
one of a few concrete types, according to the record type.

=cut

use Encode ();
use Carp qw(croak);

#
# Concrete types of known ids
#
our(%types) = (
               'BKGD' => 'blob',
               'cmmt' => 'ustr',
               'dilc' => 'blob',
               'dscl' => 'bool',
               'fwi0' => 'blob',
               'fwsw' => 'long',
               'fwvh' => 'shor',
               'icgo' => 'blob',
               'icsp' => 'blob',
               'icvo' => 'blob',
               'ICVO' => 'bool',
               'icvt' => 'shor',
               'Iloc' => 'blob',
               'info' => 'blob',
               'lssp' => 'blob',
               'lsvo' => 'blob',
               'LSVO' => 'bool',
               'lsvt' => 'shor',
               'pict' => 'blob',
               );

=head2 $entry = ...::Entry->new($filename, $typecode)

Creates a new entry with no value. The concrete type is inferred from the
record type code.

=head2 $entry->filename

Gets the filename of an entry.

=head2 $entry->strucId

Gets the record type of this entry, as a four-character string, indicating
what aspect of the file the entry describes.

=head2 $entry->value([$value])

Gets or sets the value of an entry.

If the concrete type is C<blob>, the value is interpreted as a byte string; 
if it is C<ustr>, as a character string.
If the concrete type is C<long>, C<shor>, or C<bool>, then the value should
be an integer.

=cut

sub new {
    my($class, $filename, $strucId, @opts) = @_;
    
    croak "no opts supported yet, died" if @opts;

    bless([ $filename, $strucId, $types{$strucId}, undef ],
          ref $class || $class);
}

sub filename {
    $_[0]->[0];
}

sub strucId {
    $_[0]->[1];
}

sub value {
    my($self, $value) = @_;
 
    return $self->[3] unless defined $value;
   
    croak "Can't set a value on an entry with no concrete type"
        unless defined($self->[2]);
    
    my($t) = $self->[2];
    if($t eq 'blob' or $t eq 'ustr') {
        $self->[3] = '' . $value;
    } elsif ($t eq 'bool' or $t eq 'shor' or $t eq 'long') {
        $self->[3] = 0 + $value;
    } else {
        die "Unknown concrete type $t, died";
    }

    $self->[3];
}

sub readEntry {
    my($class, $block) = @_;

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
		 ref($class) || $class);
}

sub readFilename {
    my($block) = @_;

    my($flen) = $block->read(4, 'N');
    my($utf16be) = $block->read(2 * $flen);
    
    return Encode::decode('UTF-16BE', $utf16be, Encode::FB_CROAK);
}

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
	$size += 4 + length($value);
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

=head2 $entry->cmp($other)

Returns -1, 0, or 1 depending on the relative ordering of the two entries,
according to (a guess at) the record ordering used by the store's B-tree.

=cut

sub cmp {
    my($self, $other) = @_;

    #
    # There's probably some wacky Mac-specific Unicode collation
    # rule for these, but case-insensitive comparison is a good
    # approximation
    #

    # Ordering in the btree is Finder-filename-ordering on the files,
    # and simple bytewise ordering on the structure IDs.

    ( lc($self->[0]) cmp lc($other->[0]) ) 
        ||
    ( $self->[1] cmp $other->[1] );
}

=head1 SEE ALSO

See L<Mac::Finder::DSStore::Format> for more detailed information on
the record types found in a DS_Store file.

See L<Mac::Finder::DSStore::BuddyAllocator> for the low-level organization
of the DS_Store file.

=cut

1;
