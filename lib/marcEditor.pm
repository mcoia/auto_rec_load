#!/usr/bin/perl

package marcEditor;

use lib qw(./);

use MARC::Record;
use MARC::Field;
use Data::Dumper;
use Cwd;

sub new
{
    my ($class, @args) = @_;
    my $self = _init($class, @args);
    bless $self, $class;
    return $self;
}

sub _init
{
    my $self = shift;
    $self =
        {
            log   => shift,
            debug => shift,
            type  => shift || 'adds'
        };
    return $self;
}

sub manipulateMARC
{
    my $self = shift;
    my $key = shift;
    my $marc = shift;
    my $tag = shift;
    my $ret = $marc;

    my $ev = '$ret = ' . $key . '($self, $marc);';
    $self->{log}->addLine("Running " . $ev) if ($self->{debug});
    # print $ev . "\n";
    # eval $ev;
    local $@;
    eval
    {
        eval $ev;
        1; # ok
    } or do
    {
        print "Failed to manipulate\n";
        print $@;
        die;
    };
    $ret = tagAddsMARC($self, $ret, $tag);
    $ret = tagDeletesMARC($self, $ret, $key) if ($self->{type} eq 'deletes');
    $ret = removeField($self, $ret, '856') if ($self->{type} eq 'deletes');

    return $ret;
}

sub createSubfieldBetween
{
    my $self = shift;
    my $marc = shift;
    my $field = shift;
    my $subfield = shift;
    my $subfieldValue = shift;
    my $presubfieldsRef = shift;
    my $aftersubfieldsRef = shift;
    my $optionalAppend = shift;
    my @preSubfieldCodes;
    my @afterSubfieldCodes;

    if ($presubfieldsRef)
    {
        @preSubfieldCodes = @{$presubfieldsRef};
    }
    if ($aftersubfieldsRef)
    {
        @afterSubfieldCodes = @{aftersubfieldsRef};
    }

    my @fields = $marc->field($field);
    foreach (@fields)
    {
        my $thisfield = $_;
        # print Dumper($thisfield);
        $thisfield->delete_subfield(code => $subfield); # remove any pre-existing destination subfield
        my @all = $thisfield->subfields();
        # print Dumper(\@all);
        $thisfield->delete_subfield(match => qr/./); #wipe everything out
        my $didntPrepend = 0;
        for my $i (0 .. $#all) #find all of the subfields that we should start with
        {
            if (@all[$i])
            {
                my @combo = @{@all[$i]};
                my $found = 0;
                foreach (@preSubfieldCodes)
                {
                    if (($_ eq @combo[0]) && !$found)
                    {
                        $thisfield->add_subfields(@combo[0] => @combo[1]);
                        @all[$i] = undef;
                        $found = 1;
                    }
                }
                $didntPrepend = 1 if (!$found);
            }
        }

        $subfieldValue .= $optionalAppend if ($optionalAppend && $didntPrepend);

        $thisfield->add_subfields($subfield => $subfieldValue);
        for my $i (0 .. $#all) #Append the rest of the old subfields back onto th end
        {
            if (@all[$i])
            {
                my @combo = @{@all[$i]};
                $thisfield->add_subfields(@combo[0] => @combo[1]);
            }
        }
    }
    return $marc;
}

sub tagAddsMARC
{
    my $self = shift;
    my $marc = shift;
    my $tag = shift;
    if ($tag)
    {
        my $field890 = MARC::Field->new('890', ' ', ' ', 'a' => $tag);
        $marc->insert_grouped_field($field890);
    }
    return $marc;
}

sub tagDeletesMARC
{
    my $self = shift;
    my $marc = shift;
    my $tag = shift;
    if ($tag)
    {
        my $field890 = MARC::Field->new('891', ' ', ' ', 'a' => $tag);
        $marc->insert_grouped_field($field890);
    }
    return $marc;
}

sub replaceStringFoundInTag
{
    my $self = shift;
    my $marc = shift;
    my $field = shift;
    my $original = shift;
    my $replace = shift || '';
    my $isRegEx = shift || 0;
    my @fields = $marc->field($field);
    $original = escapeRegexChars($self, $original) if !$isRegEx;
    foreach (@fields)
    {
        my $thisfield = $_;
        my @allsubs = $thisfield->subfields();
        my @all = ();
        foreach (@allsubs)
        {
            my @pair = @{$_};
            my $value = @pair[1];
            if ($value =~ /$original/)
            {
                $value =~ s/$original/$replace/g;
                @pair[1] = $value;
            }
            push(@all, [ @pair ]);
        }
        $thisfield->delete_subfield(code => qr/[^.]/); # delete all subfields
        foreach (@all)
        {
            my @pair = @{$_};
            $thisfield->add_subfields(@pair[0] => @pair[1]);
        }
    }
    return $marc;
}

sub getSubField
{
    my $self = shift;
    my $marc = shift;
    my $tag = shift;
    my $subtag = shift;
    my $ret;
    #print "Extracting $tag $subtag\n";
    if ($marc->field($tag))
    {
        if ($tag < 10)
        {
            #print "It was less than 10 so getting data\n";
            $ret = $marc->field($tag)->data();
        }
        elsif ($marc->field($tag)->subfield($subtag))
        {
            $ret = $marc->field($tag)->subfield($subtag);
        }
    }
    #print "got $ret\n";
    $ret = utf8::is_utf8($ret) ? Encode::encode_utf8($ret) : $ret;
    return $ret;
}

sub updateSubfields
{
    my $self = shift;
    my $marc = shift;
    my $field = shift;
    my $subfield = shift;
    my $value = shift;
    my $prepend = shift || 0;
    my $append = shift || 0;
    my @fields = $marc->field($field);
    foreach (@fields)
    {
        my $thisfield = $_;
        my @all = $thisfield->subfield($subfield);
        for my $i (0 .. $#all)
        {
            @all[$i] = appendPrepend($self, @all[$i], $value, $prepend, $append);
        }
        if ($#all > -1) # wipe em and make new ones
        {
            $thisfield->delete_subfield(code => $subfield);
            foreach (@all)
            {
                $thisfield->add_subfields($subfield => $_);
            }
        }
        else
        {
            $thisfield->update($subfield => $value);
        }
    }
    return $marc;
}

sub appendPrepend
{
    my $self = shift;
    my $og = shift;
    my $add = shift;
    my $prepend = shift || 0;
    my $append = shift || 0;
    $og = $add . $og if $prepend;
    $og .= $add if $append;
    return $add if (!$append && !$prepend); # if neither, then it's a replace
    return $og;
}

sub removeSubfield
{
    my $self = shift;
    my $marc = shift;
    my $field = shift;
    my $subfield = shift;
    my @fields = $marc->field($field);
    foreach (@fields)
    {
        $_->delete_subfield(code => $subfield);
    }
    return $marc;
}

sub deleteFieldIfSubfieldExists
{
    my $self = shift;
    my $marc = shift;
    my $tag = shift;
    my $subfield = shift;

    # Delete ALL subfields
    my @field = $marc->field($tag);
    foreach my $field (@field)
    {
        $marc->delete_field($field) if ($field->subfield($subfield));
    }

    return $marc;

}

sub removeField
{
    my $self = shift;
    my $marc = shift;
    my $field = shift;
    my @fields = $marc->field($field);
    $marc->delete_fields(@fields);
    return $marc;
}

sub escapeRegexChars
{
    my $self = shift;
    my $txt = shift;
    $txt =~ s/\\/\\\\/g;
    $txt =~ s/\//\\\//g;
    $txt =~ s/\(/\\(/g;
    $txt =~ s/\)/\\)/g;
    $txt =~ s/\?/\\?/g;
    $txt =~ s/\+/\\+/g;
    $txt =~ s/\[/\\[/g;
    $txt =~ s/\]/\\]/g;
    $txt =~ s/\-/\\-/g;
    return $txt;
}

sub writeMarcFile
{

    my $self = shift;
    my $marc = shift;
    my $filename = shift;

    my $marcOutput = MARC::File::USMARC->encode($marc);

    my $logMessage = "saving marc => [$filename]";
    print $logMessage . "\n" if ($self->{debug});
    $self->{log}->addLine($logMessage) if ($self->{debug});

    open(FH, '>', $filename) or die $!;
    print FH $marcOutput;
    close(FH);

}

sub parseSubfieldString
{
    my $self = shift;
    my $subfield = shift;
    my %subfieldHash = $subfield =~ /\$(.{1})([^\$]*)/gm;
    my @sortOrder = $subfield =~ /\$(.{1})/gm;
    my %hash = (
        'subfields' => \%subfieldHash,
        'sortOrder' => \@sortOrder
    );
    return \%hash;
}

# ($marc, $byte, $position)
sub updateLeaderByte
{
    my $self = shift;
    my $marc = shift;

    # The replacement character  
    my $byte = shift;

    # This is the byte position from the left
    my $position = shift;

    # error checking 
    return $marc unless $byte =~ /^.$/;
    return $marc unless $position =~ /^\d*$/;

    # grab out leader 
    my $leader = $marc->leader();

    # update the leader 
    my @leaderToArray = split(//, $leader);
    $leaderToArray[$position] = $byte;
    my $newLeader = join('', @leaderToArray);

    # update the marc 
    $marc->leader($newLeader);

    return $marc;

}

sub DESTROY
{
    my ($self) = @_[0];
    ## call destructor
}

################################################################################
#                                                                              #  
#                All marc manipulation API Above                               # 
#                                                                              #  
################################################################################

sub ebook_central_MWSU
{
    my $self = shift;
    my $marc = shift;

    # Add 506
    my $field506 = MARC::Field->new('506', ' ', ' ', 'c' => 'Access restricted to subscribers');
    $marc->insert_grouped_field($field506);
    if ($self->{type} eq 'adds')
    {
        # Add 949
        # \1$aMW E-Book$g1$h020$i0$lm2wii$o-$r-$s-$t014$u-$z099$xProQuest Reference E-Book
        my $field949 = MARC::Field->new('949', ' ', 1,
            'a' => 'MW E-Book',
            'h' => '020',
            'o' => '-',
            'r' => '-',
            's' => '-',
            't' => '014',
            'u' => '-',
            'z' => '099',
            'x' => 'ProQuest Reference E-Book',
        );
        $marc->insert_grouped_field($field949);
    }
    $marc = updateSubfields($self, $marc, '856', 'u', 'https://login.ezproxy.missouriwestern.edu/login?url=', 1); # prepend
    $marc = updateSubfields($self, $marc, '856', 'z', 'MWSU E Book');
    $marc = updateSubfields($self, $marc, '856', '5', '6mwsu');

    # Inject a 245$h after all a and p subfields
    my @prefields = ('a', 'p', 'n');
    $marc = createSubfieldBetween($self, $marc, '245', 'h', '[electronic resource (video)]', \@prefields, undef, undef);
    return $marc;
}

sub ebook_central_SPST
{
    my $self = shift;
    my $marc = shift;

    if ($self->{type} eq 'adds')
    {
        # Add 949
        # \1$aEbook Central Electronic Book; click SPST link above to access$h060$i0$lsdebi$o-$rs$s-$t014$u-$z099
        my $field949 = MARC::Field->new('949', ' ', 1,
            'a' => 'Ebook Central Electronic Book; click SPST link above to access',
            'h' => '060',
            'i' => '0',
            'l' => 'sdebi',
            'o' => '-',
            'r' => 's',
            's' => '-',
            't' => '014',
            'u' => '-',
            'z' => '099'
        );
        $marc->insert_grouped_field($field949);
    }
    $marc = replaceStringFoundInTag($self, $marc, '856', 'ebookcentral.proquest.com', '0-ebookcentral.proquest.com.kc-towers.searchmobius.org');
    # make it non-ssl
    $marc = replaceStringFoundInTg($self, $marc, '856', 'https://', 'http://');
    $marc = updateSubfields($self, $marc, '856', 'z', 'SPST electronic book; click here to access');
    $marc = updateSubfields($self, $marc, '856', '5', '6spst');

    return $marc;
}

sub getMarcSubfieldOrder
{
    # takes something like => \1$g1$h060$i0$lmorre$o-$r-$sj$t015$u- 
    # spits out something like ==> g h i l o r s t u
    my @subFields = shift =~ /\$(.{1})/gm;
    return \@subFields;
}

################################################################################
#                       Overdrive                                              #
################################################################################
# Archway
# Arthur
# Avalon
# Bridges
# Explore
# KC-Towers
# SWAN


# returns eBook || Audio Book 
sub getOverdriveRecordType
{
    my $self = shift;
    my $marc = shift;

=pod

Info on the 007
I should build a method that returns the code types below that this method calls.

007 codes     

https://www.loc.gov/marc/bibliographic/bd007.html

007/00	Category of material
a	Map
c	Electronic resource
d	Globe
f	Tactile material
g	Projected graphic
h	Microform
k	Nonprojected graphic
m	Motion picture
o	Kit
q	Notated music
r	Remote-sensing image
s	Sound recording
t	Text
v	Videorecording
z	Unspecified

=cut

    # we default to eBook as this is what most of the records are 
    my $recordType = 'Overdrive eBook';

    # Grab our record type from the 007.
    foreach ($marc->field('007'))
    {
        $recordType = 'Overdrive Audio Book' if ($_->data() =~ m/^s/); # starts with 's'
        $recordType = 'Overdrive Video' if ($_->data() =~ m/^v/);      # starts with 'v'
    }
    $self->{log}->addLine("overdrive record type: $recordType") if ($self->{debug});
    return $recordType;
}

sub getRecordType
{
    my $self = shift;
    my $recordType = shift;

    # I hate this function with all my soul. Just lazy... lol  

    return 'ebook' if ($recordType eq 'Overdrive eBook');
    return 'audio' if ($recordType eq 'Overdrive Audio Book');
    return 'video' if ($recordType eq 'Overdrive Video');

}

# ($mark)
# returns int 
sub getOverdriveURLTitleID
{

=pod 
 This may get abstracted a little more.
 Make this a method that deletes a subfield based on some regex pattern . 
 pass in the regex, tag & the field. 
 
=cut

    my $self = shift;
    my $marc = shift;
    my @overdriveURLID = ();
    my @fields = $marc->field('856');

    foreach my $field (@fields)
    {
        # We modify the subfield $u and replace the original url with a mobius url
        if ($field->subfield('u'))
        {
            # we have to grab the titleID from the original url to append on the mobius url 
            # example: $uhttp://link.overdrive.com/?websiteID=202758&titleID=9054312
            my $overdriveURL = $field->subfield('u');
            if ($overdriveURL =~ /titleID/)
            {
                print "overdriveURL: [$overdriveURL]\n";
                @overdriveURLID = $overdriveURL =~ /.*?titleID=(\d*).*$/gm;
                $marc->delete_field($field);
            }
            else
            {
                print "invalid url. Can't parse titleID\n" if ($self->{debug});
            }

        }
    }

    print "overdrive URL id: $overdriveURLID[0]\n" if ($self->{debug});

    return $overdriveURLID[0];
}

# ($marc, $libraries, $clusterName)
# returns $marc
sub overdriveGeneric
{

    my $self = shift;
    my $marc = shift;
    my $config = shift;

    $self->{log}->addLine("################################################################################") if ($self->{debug});
    $self->{log}->addLine("Overdrive $config->{'clusterName'}") if ($self->{debug});
    $self->{log}->addLine("################################################################################") if ($self->{debug});
    $self->{log}->addLine("Library HASH: " . Dumper(\%libraries)) if ($self->{debug});

    # determine record type. Is it audio or video 
    my $recordType = $self->getRecordType($self->getOverdriveRecordType($marc));
    print "recordType: [$recordType]\n" if ($self->{debug});

    # Get the Overdrive URL id
    my $mobiusURL = "https://mobius.overdrive.com/media/" . $self->getOverdriveURLTitleID($marc);
    $self->{log}->addLine("mobiusURL => [$mobiusURL]") if ($self->{debug});

    # update the leader 
    $marc = $self->updateLeaderByte($marc, $config->{leader}{$recordType}, 6);

    # Delete ALL 856 records with a subfield $3
    $marc = $self->deleteFieldIfSubfieldExists($marc, '856', '3');

    print "checking libraries...\n";

    foreach my $library (keys %{$config->{'libraries'}})
    {
        print "\n\nlibrary: $library\n" if ($self->{debug});
        $self->{log}->addLine("----------------------------------------") if ($self->{debug});
        $self->{log}->addLine("Library: $library") if ($self->{debug});
        $self->{log}->addLine("----------------------------------------") if ($self->{debug});


        # Some libraries don't have audio or ebook definitions 
        next if ($config->{'libraries'}{$library}{$recordType} eq ''); ### todo: DEBUG THIS!!! I don't know if it works.

        # Some libraries are not processing the marc correctly. bridges, avalon. 


        # loop thru our libraries 
        foreach my $tag (keys %{$config->{'libraries'}{$library}{$recordType}})
        {

            # next if (%{$config->{'libraries'}{$library}{$recordType}{tag}} eq '');
            
            print "tag: $tag\n" if ($self->{debug});
            $self->{log}->addLine("Current Tag: $tag") if ($self->{debug});

            print "creating new field\n" if ($self->{debug});

            # Create a new field for the marc record 
            my $field = MARC::Field->new(
                $tag, $config->{'staticTags'}{$tag}{'ind1'}, $config->{'staticTags'}{$tag}{'ind2'},
                # Do NOT delete this 'u' tag as we have to have at least 1 tag for this to work.
                # I believe it's a bug with the MARC::Field object 
                'u' => $mobiusURL,
            );

            print "deleting subfield u\n" if ($tag ne '856' && $self->{debug});
            # Only the 856 gets the the mobius url added. This is to babysit the bug above.   
            $field->delete_subfield(code => 'u') if ($tag ne '856');

            my %parsedFields = %{$self->parseSubfieldString($config->{libraries}{$library}{$recordType}{$tag})};

            print "adding subfield data...\n" if ($self->{debug});
            foreach my $subfield (@{%parsedFields{sortOrder}})
            {
                print "adding... [$library] ==> [$tag]:[$subfield][$parsedFields{subfields}{$subfield}]\n" if ($self->{debug});
                $self->{log}->addLine("Adding... [$library][$recordType] ==> [$tag]:[$subfield]=[$parsedFields{subfields}{$subfield}]") if ($self->{debug});
                # $field->add_subfields($subfield => $config->{libraries}{$library}{$recordType}{$tag}{$subfield});
                $field->add_subfields($subfield => $parsedFields{subfields}{$subfield});
            }

            print "DONE adding subfield data\n" if ($self->{debug});
            $marc->insert_grouped_field($field) ;
            undef $field;
        }

    }

    print "delete stray 856\n";
    # $marc = $self->deleteStray856($marc); # delete stray function and consolidate? yea? 

    $self->{ log }->addLine("Overdrive marc edit... DONE") if ($self->{debug});
    return $marc;

}

### Leader info 
# From Overdrive
#Audiobook = i
#eBook = a
# 
#Archway
#Audiobook = 4
# eBook = 2
# 
# Arthur
#Audiobook = 5
# eBook = 2
# 
# Avalon
#Audiobook = i
#eBook = 2
# 
# Bridges
#Audiobook = i
#eBook = 2
# 
# Explore
#Audiobook = @
#eBook = @
# 
#KC-Towers
#Audiobook = 3
# eBook = 2
# 
# SWAN
#Audiobook = 2
# eBook = 2
### Leader info 

# ($marc)
# returns $marc 
sub overdrive_archway
{

    my $self = shift;
    my $marc = shift;

    my %config = (
        'clusterName' => 'Archway',
        'leader'      => {
            'audio' => '4',
            'ebook' => '2',
        },
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '\\',
                'ind2' => '1',
                'v'    => $self->getOverdriveRecordType($marc),
            },
        },
        'libraries'   => {
            'East Central'                  => {
                'audio' => {
                    '856' => '$56eacc$zEast Central: Click to access',
                    '949' => '\1$vOverdrive Audio Book$g1$h001$i0$leceii$o-$r-$si$t058$u',
                },
                'ebook' => {
                    '856' => '$56eacc$zEast Central: Click to access',
                    '949' => '\1$vOverdrive eBook$g1$h001$i0$leceii$o-$r-$si$t058$u'
                },
            },
            'Jefferson College'             => {
                'audio' => {
                    '856' => '$56jeff$zJefferson College click to access',
                    '949' => '\1$vOverdrive Audio Book$g1$h002$i0$ljheri$o-$r-$si$t058$u',
                },
                'ebook' => {
                    '856' => '$56jeff$zJefferson College click to access',
                    '949' => '\1$vOverdrive eBook$g1$h002$i0$ljheri$o-$r-$si$t058$u'
                },
            },
            'St. Charles Community College' => {
                'audio' => {
                    '856' => '$56sccc$zSt. Charles click to access',
                    '949' => '\1$vOverdrive Audio Book$g1$h003$i0$lcleii$o-$r-$si$t058$u',
                },
                'ebook' => {
                    '856' => '$56sccc$zSt. Charles click to access',
                    '949' => '\1$vOverdrive eBook$g1$h003$i0$lcleii$o-$r-$si$t058$u'
                },
            },
            'St. Louis Community College'   => {
                'audio' => {
                    '856' => '$56slcc$zSTLCC click to access',
                    '949' => '\1$vOverdrive Audio Book$g1$h004$i0$llaele$o-$r-$si$t058$u',
                },
                'ebook' => {
                    '856' => '$56sccc$zSt. Charles click to access',
                    '949' => '\1$vOverdrive eBook$g1$h004$i0$llaele$o-$r-$si$t058$u'
                },
            },
            'Three Rivers'                  => {
                'audio' => {
                    '856' => '$56thrc$zThree Rivers click to access',
                    '949' => '\1$vOverdrive Audio Book$g1$h007$i0$ltrers$o-$r-$si$t058$u',
                },
                'ebook' => {
                    '856' => '$56thrc$zThree Rivers click to access',
                    '949' => '\1$vOverdrive eBook$g1$h007$i0$ltrers$o-$r-$si$t058$u'
                },
            }
        }

    );

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_arthur
{

    my $self = shift;
    my $marc = shift;

    my %config = (
        'clusterName' => 'Arthur',
        'leader'      => {
            'audio' => '5',
            'ebook' => '2',
        },
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'libraries'   => {
            'Stephens College'       => {
                'audio' => {
                    '856' => '$56step$zOverdrive Audio Books (Stephens login required)',
                    '949' => '\1$g1$h030$i0$lsheii$o-$r-$sc$t015$u-'
                },
                'ebook' => {
                    '856' => '$56step$zOverdrive eBook (Stephens login required)',
                    '949' => '\1$g1$h030$i0$lsheii$o-$r-$sc$t015$u-'
                },
            },
            'Missouri State Library' => {
                'audio' => {
                    '856' => '$56mosl$zOverDrive Audiobook (Missouri State Government Employee Access)',
                    '949' => '\1$g1$h060$i0$lmorre$o-$r-$sj$t015$u-'
                },
                'ebook' => {
                    '856' => '$56mosl$zOverDrive eBook (Missouri State Government Employee Access)',
                    '949' => '\1$g1$h060$i0$lmorre$o-$r-$sj$t015$u-'
                },
            },

            'Westminster College'    => {
                'audio' => {
                    '856' => '$56wmst$zOverDrive Audiobook (Westminster login required)',
                    '949' => '\1$g1$h040$i0$l2reii$o-$r-$s2$t015$u-' },
                'ebook' => {
                    '856' => '$56wmst$zOverDrive eBook (Westminster login required)',
                    '949' => '\1$g1$h040$i0$l2reii$o-$r-$s2$t015$u-'
                },

            },

            'William Woods'          => {
                'audio' => {
                    '856' => '$56wmwu$zOverDrive Audiobook (William Woods login required)',
                    '949' => '\1$g1$h050$i0$lwddii$o-$r-$s2$t015$u-'
                },
                'ebook' => {
                    '856' => '$56wmwu$zOverDrive eBook (William Woods login required)',
                    '949' => '\1$g1$h050$i0$lwddii$o-$r-$s2$t015$u-'
                },

            },

        },
    );

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_avalon
{

    my $self = shift;
    my $marc = shift;

    my %config = (
        'clusterName' => 'Avalon',
        'leader'      => {
            'audio' => 'i',
            'ebook' => '2',
        },
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'libraries'   => {
            'A. T. Still'                   => {
                'audio' => {
                    '856' => '$56atsu$zOverdrive eBooks and Audio Books (ATSU login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h070$i0$lkleov$o-$r-$s-$t015$u'
                },
                'ebook' => {
                    '856' => '$56atsu$zOverdrive eBooks and Audio Books (ATSU login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h070$i0$lkleov$o-$r-$s-$t015$u'
                },
            },
            'Missouri Valley College'       => {
                'audio' => {
                    '856' => '$56atsu$zOverdrive eBooks and Audio Books (ATSU login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h070$i0$lkleov$o-$r-$s-$t015$u'
                },
                'ebook' => {
                    '856' => '$56atsu$zOverdrive eBooks and Audio Books (ATSU login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h070$i0$lkleov$o-$r-$s-$t015$u'
                },
            },
            'Moberly Area Commnity College' => {
                'audio' => {
                    '856' => '$56macc$zOverdrive eBooks and Audio Books (MACC login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h090$i0$lmbgiii$o-$rn$s-$t015$u'
                },
                'ebook' => {
                    '856' => '$56macc$zOverdrive eBooks and Audio Books (MACC login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h090$i0$lmbgiii$o-$rn$s-$t015$u'
                },
            },
            'State Technical College'       => {
                'audio' => {
                    '856' => '$56stcm$zOverdrive eBooks and Audio Books (State Tech login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h080$i0$llsnsi$o-$rz$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56stcm$zOverdrive eBooks and Audio Books (State Tech login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$h080$i0$llsnsi$o-$rz$s-$t015$u-'
                },
            },
            'Truman State University'       => {
                'audio' => {
                    '949' => '\1$g1$h100$i0$ltpeni$o-$rz$sn$t015$u-',
                },
                'ebook' => {
                    '949' => '\1$g1$h100$i0$ltpeni$o-$rz$sn$t015$u-'
                },
            }
        }
    );

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_bridges
{

    my $self = shift;
    my $marc = shift;

    my %config = (
        'clusterName' => 'Bridges',
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'leader'      => {
            'audio' => 'i',
            'ebook' => '2',
        },
        'libraries'   => {
            'Fontbonne University'          => {
                'audio' => {
                    '949' => '\1$g1$h020$i0$lfcint$o-$r-$se$t089$u-$vOverdrive Audio eBook: click on above link$dOverdrive audio eBook'
                },
                'ebook' => {
                    '949' => '\1$g1$h020$i0$lfcint$o-$r-$se$t068$u-$vOverdrive eBook: click on above link$dOverdrive eBook'
                },
            },
            'Harris Stowe State University' => {
                'audio' => {
                    '949' => '\1$aHSSU Audio eBook$h050$lhsoiit$t019$z050$vHSSU Audio eBook'
                },
                # 'ebook' => {
                    # '949' => '',
                # }
            },
            'Lindenwood University'         => {
                'audio' => {
                    '949' => '\1$aLindenwood eBook$h050$llbint$t019$z050$vLindenwood Audio eBook',
                },
                'ebook' => {
                    '949' => '\1$aLindenwood eBook$h050$llbint$t019$z050$vLindenwood eBook'
                }
            },
            'Logan University'              => {
                'audio' => {
                    '949' => '\1$vOnline resource: Click on above link$g1$h060$i0$lojebi$o-$r-$se$t019$u-',
                },
                'ebook' => {
                    '949' => '\1$vOnline resource: Click on above link$g1$h060$i0$lojebi$o-$r-$se$t068$u-'
                }
            },
            'Maryville University'          => {
                'audio' => {
                    '949' => '\1$g1$h070$i0$lmuint$o-$r-$se$t068$u-$vOnline resource: Click on above link',
                },
                'ebook' => {
                    '949' => '\1$g1$h070$i0$lmuint$o-$r-$se$t068$u-$vOnline resource: Click on above link'
                }
            },
        },
    );

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_explore
{

    my $self = shift;
    my $marc = shift;
    my %config = (
        'clusterName' => 'Explore',
        'leader'      => {
            'audio' => '@',
            'ebook' => '@',
        },
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'libraries'   => {
            'Goldfarb' => {
                'audio' => {
                    '856' => '$56gfrb$zOverdrive Audio Book (Goldfarb login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$i0$lgelec$o-$rn$s-$t007$u-'
                },
                'ebook' => {
                    '856' => '$56gfrb$zOverdrive eBook (Goldfarb login required)',
                    '949' => '\1$vOnline resource: click on above link$g1$i0$lgelec$o-$rn$s-$t007$u-'
                },
            },
        });

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_kctowers
{

    my $self = shift;
    my $marc = shift;
    my %config = (
        'clusterName' => 'KC-Towers',
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'leader'      => {
            'audio' => '3',
            'ebook' => '2'
        },
        'libraries'   => {
            'Conception Abbey'               => {
                'audio' => {
                    '856' => '$56cabb$zOverdrive Audio Book (CA login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h010$i0$lc1eii$o-$r-$si$t014$u-$z099'
                },
                'ebook' => {
                    '856' => '$56cabb$zOverdrive eBook (CA login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h010$i0$lc1eii$o-$r-$si$t014$u-$z099'
                },
            },
            'Metropolitan Comunity College'  => {
                'audio' => {
                    '856' => '$56mcmc$zOverdrive Audio Book (MCC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h200$i0$lmebks$o-$r-$si$t014$u-$z099'
                },
                'ebook' => {
                    '856' => '$56mcmc$zOverdrive eBook (MCC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h200$i0$lmebks$o-$r-$si$t014$u-$z099'
                },
            },
            'North Central Missouri College' => {
                'audio' => {
                    '856' => '$56ncmc$zOverdrive Audio Book (NCMC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h030$i0$ln3int$o-$r-$si$t014$u-$z099'
                },
                'ebook' => {
                    '856' => '$56ncmc$zOverdrive eBook (NCMC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h030$i0$ln3int$o-$r-$si$t014$u-$z099'
                },
            },
            'William Jewell College '        => {
                'audio' => {
                    '856' => '$56wjmc$zOverdrive Audio Book (WJC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h250$i0$lwjeeb$o-$r-$si$t014$u-$z099'
                },
                'ebook' => {
                    '856' => '$56wjmc$zOverdrive eBook (WJC login required)',
                    '949' => '\1$aOverdrive eBooks$g1$h250$i0$lwjeeb$o-$r-$si$t014$u-$z099'
                },
            },
        }
    );

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

# ($marc)
# returns $marc 
sub overdrive_swan
{

    my $self = shift;
    my $marc = shift;

    my %config = (
        'clusterName' => 'Swan',
        'staticTags'  => {
            '856' => { 'ind1' => '4', 'ind2' => '0' },
            '949' => {
                'ind1' => '',
                'ind2' => '1',
            },
        },
        'leader'      => {
            'audio' => '2',
            'ebook' => '2'
        },
        'libraries'   => {
            'Cottey College'                     => {
                'audio' => {
                    '856' => '$56cott$zOverdrive eBooks and Audio Books (Cottey login required)',
                    '949' => '\1$g1$h070$i0$ltreki$o-$rz$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56cott$zOverdrive eBooks and Audio Books (Cottey login required)',
                    '949' => '\1$g1$h070$i0$ltreki$o-$rz$s-$t015$u-'
                },
            },
            'Crowder College'                    => {
                'audio' => {
                    '856' => '$56crow$zOverdrive eBooks and Audio Books (Crowder login required)',
                    '949' => '\1$g1$h010$i0$lcne2i$o-$rz$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56crow$zOverdrive eBooks and Audio Books (Crowder login required)',
                    '949' => '\1$g1$h010$i0$lcne2i$o-$rz$s-$t015$u-'
                },
            },
            'Missouri Southern State University' => {
                'audio' => {
                    '856' => '$56mssu$zMSSU OverDrive Audio Book',
                    '949' => '\1$g1$h030$i0$lmsebk$o-$rn$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56mssu$zMSSU OverDrive Audio Book',
                    '949' => '\1$g1$h030$i0$lmsebk$o-$rn$s-$t015$u-'
                },
            },
            'Ozark Christian College'            => {
                'audio' => {
                    '856' => '$56ozcc$zOverdrive eBooks and Audio Books (OCC login required)',
                    '949' => '\1$g1$h110$i0$l77er0$o-$rz$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56ozcc$zOverdrive eBooks and Audio Books (OCC login required)',
                    '949' => '\1$g1$h110$i0$l77er0$o-$rz$s-$t015$u-'
                },
            },
            'Ozarks Technical College'           => {
                'audio' => {
                    '856' => '$56otcc$zOverdrive eBooks and Audio Books (OTC login required)',
                    '949' => '\1$g1$h40$i0$loseei$o-$rz$se$t015$u-'
                },
                'ebook' => {
                    '856' => '$56otcc$zOverdrive eBooks and Audio Books (OTC login required)',
                    '949' => '\1$g1$h40$i0$loseei0$o-$rz$se$t015$u-'
                },
            },
            'Southwest Baptist University'       => {
                'audio' => {
                    '856' => '$56swbu$zOverdrive eBooks and Audio Books (SBU login required)',
                    '949' => '\1$g1$h050$i0$lbbeei$o-$rz$s-$t015$u-'
                },
                'ebook' => {
                    '856' => '$56swbu$zOverdrive eBooks and Audio Books (SBU login required)',
                    '949' => '\1$g1$h050$i0$lbbeei$o-$rz$s-$t015$u'
                },
            }
        });

    $marc = $self->overdriveGeneric($marc, \%config);

    return $marc;

}

1;