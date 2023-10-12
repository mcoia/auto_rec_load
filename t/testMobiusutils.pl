#!/usr/bin/perl
# use strict;
# use warnings FATAL => 'all';
use Data::Dumper;

use lib qw(../lib);

use Mobiusutil;

my $mobiusUtil = Mobiusutil->new();

sub TEST_readConf
{

    # my $conf = $mobiusUtil->readConfFile('../arl.conf');
    my $conf = $mobiusUtil->readConfFile('arl.conf');
    my %conf = %{$conf};
    # print Dumper(%conf);
    while ((my $key, my $value) = each(%conf))
    {
        print "$key => $value\n";
    }

}
