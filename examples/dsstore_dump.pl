#
#  "Symbolic" dump of records to stdout
#
#  This does not precisely reproduce its input, but should be
#  equivalent (some probably-meaningless fields are not preserved)
#

use Mac::Finder::DSStore::BuddyAllocator;
use Mac::Finder::DSStore;
use IO::File;
use Data::Dumper;
use Config;
use Mac::Files;
use Mac::Memory;

die "Usage: $0 /path/to/.DS_Store > result.pl\n"
    unless @ARGV == 1;

%byFilename = ( );
$want_alias = 0;

$filename = $ARGV[0];
die "$0: $filename: not a file?\n" unless -f $filename;
$store = Mac::Finder::DSStore::BuddyAllocator->open(new IO::File $filename, '<');
foreach my $rec (&Mac::Finder::DSStore::getDSDBEntries($store)) {
    push(@{$byFilename{$rec->filename}}, $rec);
    $want_alias = 1 if $rec->strucId eq 'pict';
}
undef $store;

print "#!" . $Config{perlpath} . " -w\n\n";

print "use Mac::Finder::DSStore qw( writeDSDBEntries makeEntries );\n";

# Older MacPerls have some sort of problem autoloading Handle if you
# don't explicitly import Mac::Memory
print "use Mac::Memory qw( );\n"
    if $want_alias;

print "use Mac::Files qw( NewAliasMinimal );\n"
    if $want_alias;

print "\n";

print '&writeDSDBEntries(', &repr($filename);

foreach $fn (sort keys %byFilename) {
    my(%recs) = map { $_->strucId, $_->value } @{$byFilename{$fn}};
    my(@lines);

    if (!exists($recs{'BKGD'})) {
        # pass
    } elsif ($recs{'BKGD'} =~ /^DefB/ ) {
        push(@lines, 'BKGD_default');
        delete $recs{'BKGD'};
    } elsif ($recs{'BKGD'} =~ /^ClrB/ ) {
        my(@rgb) = unpack('x4 nnn', $recs{'BKGD'});
        push(@lines, sprintf("BKGD_color => '#%02X%02X%02X'", @rgb));
        delete $recs{'BKGD'};
    } elsif ($recs{'BKGD'} =~ /^PctB/ && exists($recs{'pict'})) {
        my($l, $a, $b) = unpack('x4 N nn', $recs{'BKGD'});
        if($l == length($recs{'pict'})) {
            my($user, $alias_len) = unpack('Nn', $recs{'pict'});
            warn "Possible extra data in BKGD alias entry: udata=$user, ".($l - $alias_len)." bytes trailing data\n"
                if ($user != 0 or $alias_len != $l);
            my($hdl) = new Handle( $recs{'pict'} );
            my($unalias) = Mac::Files::ResolveAliasRelative($filename, $hdl);
            if ($unalias) {
                push(@lines, 'BKGD_alias => NewAliasMinimal('.&repr($unalias).')');
                delete $recs{'BKGD'};
                delete $recs{'pict'};
            }
        }
    }

    if(exists($recs{'Iloc'})) {
        my(@xyn) = unpack('NNnnnn', $recs{'Iloc'});
        &pop_matching(\@xyn, 65535, 65535, 65535, 0);
        push(@lines, 'Iloc_xy => '.&repr(\@xyn, 1));
        delete $recs{'Iloc'};
    }

    if(exists($recs{'icvo'}) && $recs{'icvo'} =~ /^icv4/) {
        push(@lines, "icvo => ".&as_unpacked('A4 n A4 A4 n*', $recs{'icvo'}));
        delete $recs{'icvo'};
    }

    if(exists($recs{'fwi0'}) && length($recs{'fwi0'}) == 16) {
        my(@flds) = unpack('n4 A4 n*', $recs{'fwi0'});
        push(@lines, 'fwi0_flds => '.&repr(\@flds, 1));
        delete $recs{'fwi0'};
    }

    foreach my $k (keys %recs) {
        my($qqv) = &repr($recs{$k});
        my($hexv) = "'" . unpack('H*', $recs{$k}) . "'";

        push(@lines,
             ((length($qqv) > length($hexv)) ? "${k}_hex => $hexv" : "$k => $qqv"));
    }

    print ",\n    &makeEntries(", &repr($fn);
    if (1 == @lines and length($lines[0]) < 50) {
        print ", ", $lines[0], ")";
    } else {
        print ",\n        $_" foreach sort @lines;
        print "\n    )";
    }
}
print "\n);\n\n";

sub pop_matching {
    my($from, @what) = @_;

    while(@$from && @what && ($from->[$#$from] == $what[$#what])) {
        pop(@$from);
        pop(@what);
    }
}

sub repr {
    my($v, $pack) = @_;
    my($dumper) = Data::Dumper->new([ $v ]);
    $dumper->Useqq(1);
    $dumper->Terse(1);
    my($repr) = $dumper->Dump;
    chomp $repr;
    $repr =~ s/\s*\n\s+/ /g if $pack;
    $repr;
}

sub as_unpacked {
    my($fmt, $buf) = @_;

    my(@flds) = unpack($fmt, $buf);
    return "pack('$fmt', ".join(', ', map { &repr($_, 1) } @flds).')';
}
