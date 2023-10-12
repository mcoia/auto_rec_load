#!/usr/bin/perl

package seleniumOverdrive;

use pQuery;
use Try::Tiny;
use Data::Dumper;
use Text::CSV;
use Digest::SHA2;
use JSON;

use parent selenium;

sub scrape
{
    my $self = shift;

    # our hashed key for the TitleIDs
    $self->{titleIDKey} = '';
    $self->{idtracker}; # idtracker is the first 30 chars of titleIDKey
    $self->{titleIDs};
    $self->{completedIDs} = $self->getCompletedTitleIDs();
    $self->{continue};
    print "jobID: [$self->{jobID}]\n";

    # Login Overdrive
    $self->loginOverdrive();

    # Download our list of ID's via CSV file. This actually returns a filepath.
    $self->{continue} = $self->downloadTitleIdCSVFile($self->{titleIDs}, $self->{completedIDs}) if $self->{continue};

    # we failed to obtain titleIDs from CSV file
    $self->finalizeScrape() if !$self->{continue};

    # Download Express Marc page. url => Admin/CreateCustomFile
    my $seleniumMarcZipFile = $self->downloadExpressMarc() if $self->{continue};

    $self->{log}->addLine("downloadExpressMarc filename: $seleniumMarcZipFile");

    # Extract our zip file and grab the filenames with the complete absolute path  
    my $marcExtractedFiles = $self->extractMARCRecordsFromZipFile($seleniumMarcZipFile) if $seleniumMarcZipFile;

    # get our deletes for this run 
    my $marcDeleteFiles = $self->getMarcFileDeletes() if $marcExtractedFiles;

    # This is our final set of marc records. 
    my $marcFiles = $self->combineMarcFiles($marcExtractedFiles, $marcDeleteFiles);

    # extract the files from our $continue filename 
    $self->createJobsFromMARCRecords($self->{idtracker}, $marcFiles);

    # record the pending id's
    $self->savePendingOverdriveIDs($self->{titleIDs});

    $self->finalizeScrape();

}

sub finalizeScrape
{
    my $self = shift;
    my $fileCount = shift | 0;

    # We've made it to the end of execution
    # whether there were files or not, we need to mark this source as having had a successful scrape
    $self->updateSourceScrapeDate();
    $self->finishThisJob("Downloaded $fileCount file(s)");

}

sub loginOverdrive
{
    my $self = shift;

    $self->startThisJob();
    $self->{log}->addLine("Getting " . $self->{URL});
    $self->{driver}->get($self->{URL});
    $self->cleanScreenShotFolder();
    $self->updateThisJobStatus("Cleaned Screen Shot Folder");
    $self->takeScreenShot('pageload');
    $self->addTrace("scrape", "login");
    $self->updateThisJobStatus("Login Page");
    print "Logging in\n" if ($self->{debug});
    $self->{continue} = $self->handleLoginPage("id", "UserName", "Password", "The information entered is incorrect");
    print "Continue: $self->{continue}\n" if ($self->{debug});

}

sub combineMarcFiles
{
    my $self = shift;

    my $extractedMARCFiles = shift;
    my $deleteMARCFiles = shift;

    my @MARCFiles = ();
    push(@MARCFiles, @{$deleteMARCFiles}) if ($self->{completedIDs} != undef);
    push(@MARCFiles, @{$extractedMARCFiles});

    return \@MARCFiles;

}

sub downloadTitleIdCSVFile
{

    my $self = shift;
    my $continue = 0;

    $self->updateThisJobStatus("Login Page Worked");
    print "Login Page Worked\n" if ($self->{debug});
    $self->addTrace("scrape", "getting title ID's");

    $self->{titleIDs} = $self->getTitleIDs();

    # Doh! Something went wrong! 
    if ($self->{titleIDs} == 0)
    {return 0;}

    # todo: DEBUG ONLY !!! REMOVE FOR PRODUCTION !!! 
    # todo: DEBUG ONLY !!! REMOVE FOR PRODUCTION !!! 

    # cut the ids down to a manageable size for development 
    $self->{titleIDs} = $self->cutTitleIDs($self->{titleIDs}, 20);

    # not only will this trigger deletes but should trigger adds because the 1st run also have 5 records removed.
    $self->{titleIDs} = $self->simulateDeletes($self->{titleIDs}, 5);

    # todo: DEBUG ONLY !!! REMOVE FOR PRODUCTION !!! 
    # todo: DEBUG ONLY !!! REMOVE FOR PRODUCTION !!! 

    if (ref $self->{titleIDs} eq 'ARRAY')
    {
        $self->{continue} = 1;

        my $titleIDTotal = @{$self->{titleIDs}};
        $self->addTrace("scrape", "Got:" . $titleIDTotal . " Title IDs");

        # remove completed id's 
        $self->{titleIDs} = $self->{utils}->diffArray($self->{titleIDs}, $self->{completedIDs}) if ($self->{completedIDs} != undef); # couldn't this just be --> if $self->{completedIDs}

        # sort our array for hash comparison 
        my @titleIDs = @{$self->{titleIDs}};
        @titleIDs = sort @titleIDs;
        $self->{titleIDs} = \@titleIDs;

        $self->{titleIDKey} = $self->createKeyString($self->{titleIDs});
        $continue = $self->decideDownload($self->{titleIDKey}); # continue is now a filepath 

    }
    else
    {
        $continue = 0;
        $self->setError("Didn't get CSV of Title IDs");
        print "Didn't get CSV of Title IDs";
    }

    return $continue;

}

sub downloadExpressMarc
{

    my $self = shift;

    # The ultimate anchor tag that we want to click is setup to create a new tab.
    # So I am skipping the page scrape click through, and hard-coding the relative URL
    my $js = "window.location.href = '/Admin/CreateCustomFile';";
    $self->updateThisJobStatus("Navigating to /Admin/CreateCustomFile");
    $self->{driver}->execute_script($js);
    $self->waitForPageLoad();
    $self->takeScreenShot($self, "CreateCustomFile");
    $self->updateThisJobStatus("On Custom MARC Express file Page");
    print "On Search Grid Page\n" if ($self->{debug});

    $self->{idtracker} = substr($self->{titleIDKey}, 0, 32); # The website doesn't allow more than 50 characters

    $self->{idValues} = $self->{utils}->arrayToCSVString($self->{titleIDs});

    # # Cut this sucka! # todo: Debug only!!! Remove for production  
    # I'm cutting the titleIDs earlier in the process so this shouldn't be needed anymore.
    # $self->{idValues} = substr($self->{idValues}, 0, 100);

    $self->{log}->addLine($self->{idValues});
    $self->{log}->addLine("Setting Description: '$self->{idtracker}'");

    $self->handleDOMTriggerOrSetValue('action', 'CreateFileBtn', 'click()');
    $self->handleDOMTriggerOrSetValue('action', 'btnTitleIds', 'click()');
    $self->handleDOMTriggerOrSetValue('setval', 'CrossRefIds', $self->{idValues});
    $self->handleDOMTriggerOrSetValue('action', 'CrossRefIds', 'dispatchEvent(new Event("keyup"))');
    $self->handleDOMTriggerOrSetValue('setval', 'Description', $self->{idtracker});
    $self->handleDOMTriggerOrSetValue('action', 'submitCreateFile', 'click()');
    # the UI has a load time here, 2 seconds is plenty
    sleep 2;
    $self->handleDOMTriggerOrSetValue('action', 'submitConfirmCreation', 'click()');
    sleep 3;

    return $self->waitAndDownloadExpressMARC();

}

sub getMarcFileDeletes
{
    my $self = shift;

    # get our deletes 
    my @empty = ();
    my $deletesTitleIDs = ($self->{completedIDs} == undef) ? \@empty : $self->{utils}->diffArray($self->{completedIDs}, $self->{titleIDs});

    # print out our total deletes to generate  
    my @deleteTitleIDsArray = @{$deletesTitleIDs};
    my $deleteTotals = $#deleteTitleIDsArray + 1;
    print "deleteTotals: [$deleteTotals]\n";

    return $self->createMARCDeleteFiles($deletesTitleIDs);

}

# pass in an array of Overdrive TitleIDs
# returns an array or marc files with absolute file paths 
sub createMARCDeleteFiles
{
    my $self = shift;
    my $deletesTitleIDs = shift;

    my @marcRecords = ();
    push(@marcRecords, $self->_generateLimitedMARCRecord($_)) for (@{$deletesTitleIDs});

    # save marc Record 
    $self->_saveMARCRecord(\@marcRecords);

    return \@marcRecords;
}

sub _build001FromID
{
=pod
    # 001 and overdrive records 
    So overdrive is recording the id in the 001. It looks like.
    I want a handful of these to show.

        Example:
    id:[484911]  =001  ODN0000484911
    id:[1186235] =001  ODN0001186235

The 001 looks to be 13 chars long

=cut

    my $self = shift;
    my $field_001 = shift;

    # we should use the padLeft method in the mobiusutils 
    # $field_001 = padLeft($field_001, '0', 10);

    $field_001 = '0' . $field_001 while (length($field_001) < 10);

    $field_001 = "ODN$field_001";

    return $field_001;
}

sub _generateLimitedMARCRecord
{

=pod 

We generate a basic marc record consisting of only the 001. this is to baby sit Sierra which only needs 
the 001 to qualify it as a 'MARC' record. 

The 001 contains the overdrive id number. 

=cut

    my $self = shift;
    my $id = shift;

    print "building marc record id:[$id]\n" if ($self->{debug});

    my $marc = MARC::Record->new();
    my $field_001 = MARC::Field->new('001', $self->_build001FromID($id));
    $marc->append_fields($field_001);

    return MARC::File::USMARC->encode($marc);

}

sub _generateMARCFilename
{
    my $self = shift;

    # I need to grab the delete name from the json config object
    # the word delete must exist in the filename for sierra marc records to trigger sierra to delete   

    # from the json config object 
    # "deletes": [
    # "delete"
    # ],

    my $deleteNames = "";
    for (@{$self->{deletes}})
    {$deleteNames .= $_;}

    # clean our files names. 
    # We may get commas and or spaces so we change them to underscores instead. 
    $deleteNames =~ s/,/_/g;
    $deleteNames =~ s/\s/_/g;

    my $time = time();
    my $filename = $deleteNames . "_" . $time . ".mrc";
    return $filename;

}

sub _saveMARCRecord
{
    my $self = shift;
    my $encodedMarcRecords = shift;

    # we need a filename for our marc record
    my $marcFilename = $self->_generateMARCFilename();

    # this needs to have the epoch time prefixed  
    my $filePathFull = $self->{downloadDIR} . "/" . $marcFilename;

    # // save to file
    open(my $fh, '>', $filePathFull) or die "Could not open file '$filePathFull' $!";
    print $fh $_ for (@{$encodedMarcRecords});
    close $fh;

    return $filePathFull;

}

sub waitAndDownloadExpressMARC
{

    my $self = shift;

    my $searchCount = 0;
    my $maxSearchCount = 100;
    my $maxSleepCount = 300;
    my $secondsUntilNextCheckCycle = 15; # set to 15 seconds 

    $self->takeScreenShot('waitAndDownloadExpressMARC');
    $self->updateThisJobStatus("waitAndDownloadExpressMARC");
    $self->waitForPageLoad();
    my $tableRows = $self->{driver}->execute_script("return document.getElementsByTagName('tr').length - 1;");
    $self->{log}->addLine("tableRows: $tableRows");

    while ($searchCount < $maxSearchCount)
    {

        $self->{log}->addLine("Checking for hash: [$self->{idtracker}]");
        my $status = $self->_waitAndDownloadExpressMARC_getRowCurrentStatus($self->{idtracker});

        # We didn't find the hash anywhere on the page. 
        # Which means Overdrive had an error on the worksheet page. 
        if (!$status->{containsHash})
        {return 0;}

        if (!$status->{ready})
        {
            $self->{log}->addLine("Reloading Page! HashID:[$self->{idtracker}] is pending. Check count[$searchCount]");

            $self->{driver}->refresh();
            print "Still waiting... HashID:[$self->{idtracker}] is pending. Check count[$searchCount]\n";
            $self->waitForPageLoad($searchCount);
            $self->takeScreenShot('waitAndDownloadExpressMARC_pageRefresh');
        }

        if ($status->{ready})
        {

            $self->{log}->addLine("Clicking checkbox");
            $self->addTrace("scrape", "clicking file checkbox");
            $self->updateThisJobStatus("executing javascript checkbox code");

            my $js = $self->hammerTime($self->{idtracker});

            $self->{log}->addLine($js);
            $self->{log}->addLine("executing javascript event trigger code.");
            $self->{driver}->execute_script($js);
            $self->addTrace("scrape", "checkbox javascript has been executed");

            $self->{log}->addLine("waiting for page to load...");
            $self->waitForPageLoad();

            $self->{log}->addLine("done waiting...");
            $self->takeScreenShot("click_checkbox");
            $self->{log}->addLine("screenshot taken");

            # click 'CREATE FILE'
            $self->{log}->addLine("Downloading File");
            $self->addTrace("scrape", "Downloading File");
            $self->updateThisJobStatus("Downloading File");
            $self->readSaveFolder(1); # read the contents of the download folder to get a baseline
            $self->{driver}->execute_script("document.getElementsByClassName('downloadfilesbutton')[0].click();");
            $self->takeScreenShot("file_download");

            # wait for file to download 
            my $newFile = 0;
            my $sleepCount = 0;
            while (!$newFile && $sleepCount < $maxSleepCount)
            {
                $newFile = $self->seeIfNewFile();
                print "Waiting for Express MARC File to download\n";
                sleep 1;
                $sleepCount++;
            }

            return $newFile;
        }

        $searchCount++;
        sleep $secondsUntilNextCheckCycle;

    }

    return 0;

}

sub _waitAndDownloadExpressMARC_getRowCurrentStatus
{
    my $self = shift;
    my $status->{ready} = 0;
    $status->{containsHash} = 0;
    my $tableRows = $self->{driver}->execute_script("return document.getElementsByTagName('tr').length - 1;");
    foreach my $row (reverse 0 .. $tableRows)
    {

        my $rowText = $self->{driver}->execute_script("return document.getElementsByTagName('tr')[$row].textContent;");

        # check the hash and make sure we're on the right row
        if ($rowText =~ $self->{idtracker})
        {
            $self->{log}->addLine("row:[$row] Checking HashID:[$self->{idtracker}] rowText:[$rowText]");
            $status->{containsHash} = 'true';
            $status->{ready} = "true" if ($rowText =~ 'Ready');
        }
        undef $rowText;
    }
    return $status;
}

sub getTitleIDs
{
    my $self = shift;
    ##############
    #
    # Click "Insights"
    #
    ##############
    my $continue = $self->doWebActionAfewTimes('handleAnchorClick($self, "/Insights", "Title status", 1)', 4);

    # we had an error 

    print "Clicked on Insights\n" if ($self->{debug});
    print "Continue: $continue\n";


    ##############
    #
    # Click "Reports/TitleStatusAndUsage"
    #
    ##############
    if ($continue)
    {
        $continue = $self->doWebActionAfewTimes('handleAnchorClick($self, "Reports/TitleStatusAndUsage", "Title status and usage", 1)', 4);
        print "Clicked on Title status and usage\n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # Click Run new report
    #
    ##############
    # todo: This section here may not be needed??? When you load this page the "Run New Report" window is already opened. Commenting out for now. If we don't need it, I'll remove it. 

    # if ($continue)
    # {
    #     $continue = $self->doWebActionAfewTimes('handleParentAnchorClick($self, "span", "Run new report", "innerHTML", "Title status and usage report options", "a")', 4);
    #     print "Clicked on Title status and usage report options\n" if ($self->{debug});
    # }
    # print "Continue: $continue\n";


    ##############
    #
    # Clear out Search Title Field 
    #
    ##############
    # <input id="Title-inputEl" data-ref="inputEl" type="text" size="1" name="Title" value="stamped" aria-hidden="false" aria-disabled="false" role="textbox" aria-invalid="false" aria-readonly="false" aria-describedby="Title-ariaStatusEl" aria-required="false" class="x-form-field x-form-text x-form-text-default   " autocomplete="off" data-componentid="Title">
    if ($continue)
    {
        $continue = $self->handleDOMTriggerOrSetValue('setval', 'Title-inputEl', '', 'input');
        print "Cleared out Search Title Field \n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # Click Date Dropdown, and Choose "Specific"
    #
    ##############
    if ($continue)
    {
        my %attribs =
            (
                "data-ref" => 'inputEl',
                "role"     => "combobox",
                "type"     => "text",
                "name"     => "DateRangePeriodType"
            );
        my $dropdownID = $self->findElementByAttributes("input", "id", \%attribs);
        print "Clicking on $dropdownID\n";
        $continue = $self->handleDOMTriggerOrSetValue('action', $dropdownID, "click()");
        sleep 1;
        if ($continue)
        {
            # Get the associated number value for the dropdown element, so we can find the associated combo element
            $dropdownID =~ s/[^\d]//g;
            %attribs =
                (
                    "data-boundview" => 'combobox-' . $dropdownID . '-picker',
                    "role"           => "option"
                );
            $continue = $self->handleDOMTriggerOrSetValue('action', undef, "click()", "li", \%attribs, "Specific");
        }
        print "Filled 'Specific' into DateRangePeriodType\n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # Start Date empty
    #
    ##############
    if ($continue) # Start date
    {
        my %attribs =
            (
                "data-ref" => 'inputEl',
                "role"     => "combobox",
                "type"     => "text",
                "name"     => "StartDateInputValue"
            );
        $continue = $self->handleDOMTriggerOrSetValue('setval', undef, "", "input", \%attribs);
        print "Filled 'Specific' into DateRangePeriodType\n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # End Date 01/01/4000
    #
    ##############
    if ($continue) # End date
    {
        my %attribs =
            (
                "data-ref" => 'inputEl',
                "role"     => "combobox",
                "type"     => "text",
                "name"     => "EndDateInputValue"
            );
        $continue = $self->handleDOMTriggerOrSetValue('setval', undef, "01/01/4000", "input", \%attribs);
        print "Filled 'Specific' into DateRangePeriodType\n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # Formats: Ebook, Audiobook
    #
    ##############
    if ($continue)
    {
        my %attribs =
            (
                "data-ref" => 'inputEl',
                "role"     => "combobox",
                "type"     => "text",
                "name"     => "Format"
            );
        $continue = $self->handleDOMTriggerOrSetValue('setval', undef, "Ebook, Audiobook", "input", \%attribs);
        print "Filled 'Specific' into DateRangePeriodType\n" if ($self->{debug});
    }
    print "Continue: $continue\n";


    ##############
    #
    # Click "Update"
    #
    ##############

    if ($continue)
    {
        $continue = $self->handleParentAnchorClick("span", "Update", "innerHTML", "Displaying 1", 'a');
        print "Clicked 'Update' \n";
        $self->waitForPageLoad();
    }


    # I got this error message when trying to manually run a report.
    # Error Message ==> Marketplace has encountered an error. Our team is actively monitoring error logs and will address the issue as soon as possible.
    # <div class="x-toolbar-text x-box-item x-toolbar-item x-toolbar-text-default" id="tbtext-1051" style="left: 405px; top: 4px; margin: 0px;">
    #   <span class="text--red--dark">
    #       <span class="bold">Marketplace has encountered an error. Our team is actively monitoring error logs and will address the issue as soon as possible.</span>
    #   </span>
    # </div>
    my $newFile = 0;
    if ($continue)
    {
        $self->handleParentAnchorClick("span", "Create worksheet", "innerHTML", "Displaying 1", 'a');
        print "Clicked 'Create Worksheet'\n";

        $self->waitForPageLoad();
        $self->waitForLoadingSpinner();

        # we should also check for failed page loads and errors. look at ==> resources/error-screenshots/overdrive-getTitleIDs-site-error.png 
        # also look at the error mentioned above. 


        # We have an issue with the next portion of code. 
        # We're calling my @files = @{readSaveFolder($self)}; after the file has already been downloaded. 

        my $tries = 0;
        while (!$newFile && $tries < 120) # sometimes Overdrive can take a whole minute to generate the file
        {
            $tries++;
            $newFile = $self->seeIfNewFile();
            print "Waiting for file to download: $tries\n";
            sleep 1;
        }
        if ($newFile)
        {
            print "Got this: $newFile\n";
            if (lc $self->getFileExt($newFile) eq 'csv')
            {
                $continue = 1;
            }
            else
            {
                $continue = 0;
            }
        }
        else
        {
            $continue = 0;
            print "Something went wrong! We did not get a CSV file!\n";
        }
    }

    if ($continue)
    {
        my @titleIDs = @{$self->getColumnFromCSV($newFile, 'TitleID')};
        $self->{log}->addLine(Dumper(\@titleIDs)) if $self->{debug};

        # check titleIDs for non numeric characters 
        @titleIDs = @{$self->removeNonNumericChars(\@titleIDs)};

        # Any other modifications to the original titleIDs should probably go here.
        # We set $self->{titleIDs} = thisMethod

        sort @titleIDs;
        return \@titleIDs;
    }

    return 0;
}

sub waitForLoadingSpinner
{
    my $self = shift;
    my $timeout = 0;
    my $timeoutMax = 120;

    my $display = $self->{driver}->execute_script("return document.querySelector('[id^=\"loadmask-\"]').style.display");

=pod 

What if...
We are actually on the error page? will it even have this? ==> document.querySelector('[id^="loadmask-"]').style.display
If it doesn't than it's possible display eq '' yea? 
It's basically saying we're empty. 
The timeout saves us from this but still suspect.

=cut

    # display should == 'none', if it's '' then it's visible! 
    while ($display eq '' && $timeout < $timeoutMax)
    {
        $display = $self->{driver}->execute_script("return document.querySelector('[id^=\"loadmask-\"]').style.display");
        sleep 1;
        $timeout++;
    }

}

sub removeNonNumericChars
{
    my $self = shift;
    my $titleIDs = shift;

    my @titleIDs = @{$titleIDs};
    my @nonNumericChars = ();

    @nonNumericChars = grep(!/\d/, @titleIDs);
    @titleIDs = grep(/\d/, @titleIDs);

    # print out results 
    if ($#nonNumericChars > 0)
    {
        print "Removed these entries from TitleIDs\n";
        for (@nonNumericChars)
        {
            print "$_\n";
        }
        print "Total Removed Entries = [$#nonNumericChars]\n";
    }
    else
    {
        print "TitleIDs all good! \n";
    }

    print "Total IDs [$#titleIDs]\n";
    return \@titleIDs;

}

sub getCurrentIDListFromDB
{
    my $self = shift;
    my @dbList = ();
    my $load_key = $self->{'name'};
    my $query = "select * from auto_load_misc where load_key='" . $load_key . "' order by id desc limit 1";

    @dbList = @{$self->{dbHandler}->query($query)};
    # @dbList = @{$self->getDataFromDB($query)};

    return \@dbList;
}

sub removeCompletedIDs
{
    my $self = shift;
    my $titleIDs = shift;
    my $currentIDs = shift;

    return $self->{utils}->diffArray($titleIDs, $currentIDs);

}

sub getCompletedTitleIDs
{
    my $self = shift;
    my $load_key = $self->{'name'};
    my $query = "select * from auto_load_misc alm where alm.load_key='$load_key' order by id desc limit 1;";
    my @results = @{$self->{dbHandler}->query($query)};
    my @idArray = ();
    for (@results)
    {
        my @jsonRow = @{$_};
        my $ids = decode_json($jsonRow[2]);
        @idArray = @{$ids->{ids}};
    }
    return \@idArray;
}

sub savePendingOverdriveIDs
{
    my $self = shift;
    my $titleIDs = shift;

    my $load_key = $self->{name};
    my $jobID = $self->{jobID};

    # Convert our array into a csv string 
    my $idString = $self->{utils}->arrayToCSVString($titleIDs);

    my $insertStatement =
        "insert into auto_load_misc (load_key,value) values('$load_key.pending.$jobID', '{ \"ids\": [$idString] }')";

    $self->{dbHandler}->update($insertStatement);

}

sub createKeyString
{
    my $self = shift;
    my $sortedTitleIDs = shift;
    my @ids = @{$sortedTitleIDs};
    my $digest = new Digest::SHA2;
    $digest->add($_) foreach (@ids);
    $digest = $digest->hexdigest();
    $self->{log}->addLine("Final KeyString: " . $digest) if $self->{debug};
    return $digest;
}

sub decideDownload
{
    my $self = shift;
    my $keyString = shift;
    print "Deciding\n";
    return !$self->getFileID($keyString);
}

# Extract Zip file and return an array of file paths 
sub extractMARCRecordsFromZipFile
{
    my $self = shift;
    my $file = shift;

    my @fileTypes = ("mrc");
    $self->addTrace("processDownloadedFile", "$self->{titleIDKey} -> $file");

    return $self->extractCompressedFile($file, \@fileTypes);

}

sub createJobsFromMARCRecords
{
    my $self = shift;
    my $file = shift;
    my @files = @{$file};

    if ($#files > -1)
    {
        my $job = $self->createJob();
        $self->{job} = $job;

        foreach (@files)
        {
            my $thisFile = $_;
            my $bareFileName = $self->getFileNameWithoutPath($thisFile);
            my $fileID = $self->createFileEntry($bareFileName, $self->{titleIDKey});

            if ($fileID)
            {
                my @records = @{$self->readMARCFile($thisFile)};
                $self->{log}->addLine("Read: " . $#records . " MARC records");
                $self->createImportStatusFromRecordArray($fileID, $job, \@records);
            }
            else
            {
                $self->setError("Couldn't create a DB entry for $file");
            }
        }
        $self->readyJob($job);
    }

}

sub cutTitleIDs
{
    my $self = shift;
    my $titleIDs = shift;
    my $cutLength = shift;

    my @titleIDs = @{$titleIDs};

    @titleIDs = splice(@titleIDs, 0, $cutLength);

    return \@titleIDs;
}

sub simulateDeletes
{
    my $self = shift;
    my $titleIDs = shift;
    my $numberOfDeletes = shift;

    # convert to array
    my @titleIDs = @{$titleIDs};

    # get array length
    my $titleIDLength = @titleIDs;

    for (0 .. $numberOfDeletes)
    {
        splice(@titleIDs, int(rand($titleIDLength)), 1);
    }

    return \@titleIDs;

}

1;