#!/usr/bin/perl
package OverdriveCleanup;

use MARC::Record;
use MARC::File::USMARC;
use MARC::File::XML (BinaryEncoding => 'utf8', RecordFormat => 'UNIMARC');

use lib qw(./ ./cleanup);
use ARLUtils;

=pod 

### In this class titleIDs are referred to as just IDs

This is where we insert pending titleIDs 
seleniumOverdrive
    sub savePendingOverdriveIDs
    
we insert those titleIDs into this table ==> auto_load_misc 


Where does this class actually get called? 
job.pm -> runCheckILSLoaded at the end of this method 


=cut

use Loghandler;
use JSON;
use Data::Dumper;

sub new
{
    my $class = shift;
    my $self = {
        'dbHandler'       => shift,
        'log'             => shift,
        'load_key'        => shift,
        'jobID'           => shift,
        'filePathAdds'    => shift,
        'filePathDeletes' => shift,
        'utils'           => ARLUtils->new(),
    };
    bless $self, $class;
    return $self;
}

################################################################################
################################################################################
# This is a BIG TODO: Write out logging & trace entries!
################################################################################
################################################################################

=head1 clean()

Merge pending id's into the completed id list.

Example: 
overdrive_archway_overdrive.pending.13
get appended to
overdrive_archway_overdrive

Steps:
grab our pending ids
merge them into completed ids

I think we should add to the json object at this point. 
{ "ids": [2354,2354...] , "completed": true }


=cut
sub clean
{

    my $self = shift;

    my $pendingIDs = $self->_getPendingIDs();
    my $completedIDs = $self->_getCompletedIDs();

    # opps! something went wrong! 
    return 0 if ($pendingIDs == undef && $completedIDs == undef);

    my @mergedTitleIDs = ();
    push(@mergedTitleIDs, @{$completedIDs});
    push(@mergedTitleIDs, @{$pendingIDs});

    $self->_updateCompletedIDs(\@mergedTitleIDs) if ($completedIDs != undef);
    $self->_insertCompletedIDs(\@mergedTitleIDs) if ($completedIDs == undef);


    # should we return something ? 
    return 1;

}

# sub clean_old
# {
# 
# =pod 
# 
# What are the steps here? 
# 
# Retrieve our list of current ID's for this job run.
# 
# Compare this list of current ID to what's been completed in the database. 
# 
# ########## Thoughts:
# Any pending ID's for this job should be the stashed id's from this run. It's tied by the job #
# 
# What if we have multiple pending ID's that haven't been crossed off yet? DELETE them! 
# At what point should we 'cleanup' potential previous failed marc runProcessMarcJobs that didn't take the pending ids and complete them. 
# 
# Maybe we should remove all .pending at the end of cleanup?
# Yes! At the end of cleanup all the pending ids become completed ids. 
# at some point we'll call appendCompletedIds() 
# 
# =cut
# 
#     my $self = shift;
# 
#     # Retrieve our list of current ID's for this job run.
#     my $pendingIDs = $self->_getPendingIDs();
# 
#     # Compare this list of current ID to what's been completed in the database.
#     my $completedIDs = $self->_getCompletedIDs();
# 
#     # process our adds 
#     my $adds = ($completedIDs == undef) ? $pendingIDs : $self->{utils}->diffArray($pendingIDs, $completedIDs);
#     my $MARCAdds = $self->_generateFullMARCRecord($adds);
#     $self->_saveMARCRecord($MARCAdds, $self->{filePathAdds});
# 
#     # process our deletes 
#     if ($completedIDs != undef)
#     {
# 
#         # our cleaned Title IDs
#         my $deletes = $self->{utils}->diffArray($completedIDs, $pendingIDs);
# 
#         # Generate marc records. We'll get back an array of hashes 
#         my $MARCDeletes = $self->_generateLimitedMARCRecord($deletes);
# 
#         # save our deletes 
#         $self->_saveMARCRecord($MARCDeletes, $self->{filePathDeletes});
# 
#     }
# 
#     # save completed  
#     $self->_insertCompletedIDs($adds) if ($completedIDs == undef); # $adds & $pendingIDs should be the same at this point. 
#     $self->_updateCompletedIDs($self->_mergeIDs($adds, $completedIDs)) if ($completedIDs != undef);
# 
#     # remove pending ID's for this run
# 
# 
#     my $debug = 1; # a place to breakpoint before we exit clean()
# }

# returns an array
sub _getPendingIDs
{
    my $self = shift;
    my $query = "select alm.value from auto_load_misc alm where load_key='$self->{load_key}.pending.$self->{jobID}' order by alm.id desc limit 1";
    return $self->_getTitleIDs($query);
}

# returns an array
sub _getCompletedIDs
{
    my $self = shift;
    my $query = "select alm.value from auto_load_misc alm where load_key='$self->{load_key}' order by alm.id desc limit 1";
    return $self->_getTitleIDs($query);
}

sub _getTitleIDs
{
    my $self = shift;
    my $query = shift;
    my %json;

    for (@{$self->{dbHandler}->query($query)})
    {%json = %{decode_json($_->[0])};}

    my @json = (values %json)[0];

    return (values %json)[0];

}

sub _updateCompletedIDs
{
    my $self = shift;
    my $completedIDs = shift;

    my $idString = $self->{utils}->arrayToCSVString($completedIDs);

    my $json = "{ \"ids\": [$idString] }";

    my $query = "update auto_load.auto_load_misc set value = '$json' where load_key='$self->{load_key}'";

    $self->{dbHandler}->update($query);

}

sub _insertCompletedIDs
{
    my $self = shift;
    my $completedIDs = shift;

    my $idString = $self->{utils}->arrayToCSVString($completedIDs);
    my $json = "{ \"ids\": [$idString] }";

    my $query = "insert into auto_load_misc (load_key, value) values('$self->{load_key}', '$json')";

    $self->{dbHandler}->update($query);

}

sub _generateMARCFilename
{
    my $self = shift;
    my $id = shift;

    my $time = time();
    my $filename = "marc_T" . $time . "_" . $id . ".mrc";
    return $filename;
}

=head1 _generateLimitedMARCRecord()

We generate a basic marc record consisting of only the 001. this is to baby sit Sierra which only needs 
the 001 to qualify it as a 'MARC' record. 

The 001 contains the overdrive id number. 

=cut
sub _generateLimitedMARCRecord
{

    my $self = shift;
    my $IDs = shift;
    my @ids = @{$IDs};

    my @records = ();

    for my $id (@ids)
    {

        print "building marc record id:[$id]\n";

        my $marc = MARC::Record->new();
        my $field_001 = MARC::Field->new('001', $self->_build001FromID($id));
        $marc->append_fields($field_001);

        my $encodedMARC = MARC::File::USMARC->encode($marc);

        # our return dataset 
        my %marcRecord = (
            id       => $id,   # <== not being used 
            marc     => $marc, # <== not being used 
            encoded  => $encodedMARC,
            filename => $self->_generateMARCFilename($id)
        );

        push(@records, \%marcRecord);

    }

    return \@records;

}

sub _generateFullMARCRecord
{
    my $self = shift;
    my $IDs = shift;

    my @records = ();

    for my $id (@{$IDs})
    {
        my $marcXML = $self->_getXMLFromID($id);
        my $marc = MARC::Record->new_from_xml($marcXML, "UTF-8", "USMARC");
        push(@records, $marc);
    }

    return \@records;

}

sub _saveMARCRecord
{
    my $self = shift;
    my $marcRecords = shift;
    my $filepath = shift;

    my $utils = ARLUtils->new();
    $filepath = $utils->sanitizeFilePath($filepath);

    my @marcRecords = @{$marcRecords};

    for my $marc (@marcRecords)
    {

        # $marc is a hash! 
        # my %marcRecord = (
        #     id       => $id,
        #     marc     => $marc,
        #     encoded  => $encodedMARC,
        #     filename => $filename
        # );

        # this needs to have the epoch time prefixed  
        my $filePathFull = $filepath . "/" . $marc->{filename};

        # // save to file
        open(my $fh, '>', $filePathFull) or die "Could not open file 'marc.mrc' $!";
        print $fh $marc->{encoded};
        close $fh;
    }

}

=head1 _build001FromID()

001 and overdrive records.

So overdrive is recording the id in the 001 it looks like.
I want a handful of these to show.

        Example:
    id:[484911]  =001  ODN0000484911
    id:[1186235] =001  ODN0001186235

The 001 looks to be 13 chars long

=cut
sub _build001FromID
{

    my $self = shift;
    my $field_001 = shift;
    my $charLength001 = 10;

    # convert 001 string into an array 
    my @field_001 = split //, $field_001;
    my $length001 = @field_001;

    # get the length of our id to figure out how many 0's we need to add 
    my $NumberOfZerosToAdd = $charLength001 - $length001;

    my $NEW_001 = "ODN";

    # concat our zeros 
    for (1 .. $NumberOfZerosToAdd)
    {$NEW_001 .= "0";}

    # now add the original id and return 
    $NEW_001 .= $field_001;

    return $NEW_001;

}

sub _getXMLFromID
{
    my $self = shift;
    my $id = shift;

    # we'll key off this 001 to query the database. 
    my $z001 = $self->_build001FromID($id);

    my $query = "select ais.record_tweaked from auto_import_status ais where 
                    ais.z001='$z001' and
                    ais.job=$self->{jobID};";

    my $xml;
    for (@{$self->{dbHandler}->query($query)})
    {
        $xml = @{$_}[0];
    }

    return $xml;

}

1;