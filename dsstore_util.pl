#!/usr/bin/perl

use IO::File;
use Data::Dumper;
use DSStore;
use BuddyAllocator;

$Data::Dumper::Useqq = 1;

$foo = Mac::Finder::DSStore::BuddyAllocator->open(new IO::File $ARGV[0], 'r');
$dsdb = $foo->{toc}->{DSDB};

print Dumper($foo);
print Dumper(Mac::Finder::DSStore::BuddyAllocator->new(-1));

$otros = Mac::Finder::DSStore::BuddyAllocator->new(new IO::File '/tmp/foo', 'w');
@ents = &Mac::Finder::DSStore::getDSDBEntries($foo);
&Mac::Finder::DSStore::putDSDBEntries($otros, \@ents);
$otros->writeMetaData;
$otros->listBlocks() or die;
$otros->close;

$otros = Mac::Finder::DSStore::BuddyAllocator->open(new IO::File '/tmp/foo', 'r');
$otros->listBlocks() or die;

@rents = &Mac::Finder::DSStore::getDSDBEntries($otros);
print Dumper([ \@ents, \@rents ]);
exit(0);

#{
#    my(@treeheader) = $treeheader->read(20, 'N5');
#    print Dumper(\@treeheader);
#    print Dumper([ &readBTreeNode($foo->blockByNumber($treeheader[0])) ]);
#    &traverse_btree($foo, $treeheader[0], sub { print $_[0]->[1], ' ', $_[0]->[0], "\n"; } );
#}

$treeroot = $foo->blockByNumber($dsdb)->read(4, 'N');

$foo->listBlocks(1);
&Mac::Finder::DSStore::freeBTreeNode($treeroot, $foo);
$foo->listBlocks(1);

$foo->free($dsdb);
$foo->writeMetaData();

$foo->listBlocks(1);

$foo->allocate(1024) foreach (1 .. 6);
$foo->free($_) foreach(6,1,3,2,4,5);

$foo->listBlocks(1);

