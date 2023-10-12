package ARLUtils;

sub new
{
    my $class = shift;
    my $self = {};
    bless $self, $class;
    return $self;
}

# take Array B, compare it to Array A for differences. 
# What's in A that's not in B
sub diffArray
{
    my $self = shift;
    my $A = shift;
    my $B = shift;

    my @A = @{$A};
    my @B = @{$B};

    my %diff;
    @diff{ @B } = ();
    my @diffArray = grep !exists $diff{$_}, @A;

    return \@diffArray;

}

sub sanitizeFilePath
{
    my $self = shift;
    my $filepath = shift;

    # remove / at the end of line 
    $filepath =~ s/\/$//g;

    return $filepath;
}

sub arrayToCSVString
{
    my $self = shift;
    my $someArray = shift;
    my @someArray = @{$someArray};

    my $idString = "@someArray";
    $idString =~ s/\s/,/g; # replace spaces with , commas 

    return $idString;

}



1;