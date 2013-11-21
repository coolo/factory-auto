#! /usr/bin/perl

use File::Basename;
use File::Temp qw/ tempdir  /;
use XML::Simple;
use Data::Dumper;
use Cwd;
BEGIN {
  unshift @INC, ($::ENV{'BUILD_DIR'} || '/usr/lib/build');
}
use Build;

my $old = $ARGV[0];
my $dir = $ARGV[1];
my $bname = basename($dir);

if (-f "$dir/_service") {
    my $service = XMLin("$dir/_service", ForceArray => [ 'service' ]);
    while( my ($name, $s) = each %{$service->{service}} ) {
        my $mode = $s->{mode} || '';
        next if ($mode eq "localonly" || $mode eq "disabled");
        print "Services are only allowed if they are mode='localonly'. Please change the mode of $name and use osc service localrun\n";
        exit(1);
    }
    # now remove it to have full service from source validator
    unlink("$dir/_service");
}

if (-f "$dir/_constraints") {
  unlink("$dir/_constraints");
}

if (! -f "$dir/$bname.changes") {
    print "A $bname.changes is missing. Packages submitted as FooBar, need to have a FooBar.changes file with a format created by osc vc\n";
    exit(1);
}

if (! -f "$dir/$bname.spec") {
    print "A $bname.spec is missing. Packages submitted as FooBar, need to have a FooBar.spec file\n";
    exit(1);
}

open(SPEC, "$dir/$bname.spec");
my $spec = join("", <SPEC>);
close(SPEC);

if ($spec !~ m/#\s+Copyright\s/) {
    print "$bname.spec does not appear to contain a Copyright comment. Please stick to the format\n\n";
    print "# Copyright (c) 2011 Stephan Kulow\n\n";
    print "or use osc service localrun format_spec_file\n";
    exit(1);
}

if ($spec =~ m/\nVendor:/) {
    print "$bname.spec contains a Vendor line, this is forbidden.\n";
    exit(1);
}

foreach my $file (glob("$dir/_service:*")) {
   $file=basename($file);
   print "Found _service generate file $file in checkout. Please clean this up first.";
   exit(1);
}

# Check that we have for each spec file a changes file - and that at least one
# contains changes
my $changes_updated = 0;
for my $spec (glob ("$dir/*.spec")) {
    $changes = basename ($spec);
    $changes =~ s/\.spec$/.changes/;
    if (! -f "$dir/$changes") {
	print "A $changes is missing. Packages submitted as FooBar, need to have a FooBar.changes file with a format created by osc vc\n";
	exit(1);
    }
    if (-f "$old/$changes") {
	if (system("cmp -s $old/$changes $dir/$changes")) {
	    $changes_updated = 1;
	}
    } else { # a new file is an update too
	$changes_updated = 1;
    }
}
if (!$changes_updated) {
    print "No changelog. Please use 'osc vc' to update the changes file(s).\n";
    exit(1); 
}

my @bugs;
my @failing_bugs;
for my $spec (glob ("$dir/*.spec")) {
    $changes = basename ($spec);
    $changes =~ s/\.spec$/.changes/;
    # read the changelog as whole in the new
    # we can't rely on diff as they might remove bnc to fix it
    # and to implement diff logic is overkill so just always verify all bugs
    my $content;
    open(my $fh, '<', "$dir/$changes") or die "cannot open file $changes";
    {
        local $/;
        $content = <$fh>;
    }
    close($fh);
    my @matches = ($content =~ m/bnc#(\d+)/g);
    push(@bugs, @matches);
}

my $result;
foreach (@bugs) {
    # curl the state
    $result = `curl --silent --head "https://bugzilla.novell.com/show_bug.cgi?id=$_" 2>&1`;
    # only if curl succeeded do the check, bugzie down too much to be reliable
    if ($? == 0) {
        #if we have the ichain location then we actually need to login
        if ($result =~ m/Location: ichainlogin.cgi/) {
            push(@failing_bugs, $_);
            next;
        }
        #if we get anything not like 200 on result we fail the pkg
        my $check = ($result =~ m/HTTP\/1.1 200 OK/);
        if (!$check) {
            push(@failing_bugs, $_);
        }
    }
}

if (scalar(@failing_bugs) > 0) {
    print "Package contains following bnc# entries which are not visible for community: ".join( ', ', @failing_bugs);
    print "For explanation please visit http://lists.opensuse.org/opensuse-packaging/2013-11/msg00042.html";
    exit(1);
}

if ($spec !~ m/\n%changelog\s/ && $spec != m/\n%changelog$/) {
    print "$bname.spec does not contain a %changelog line. We don't want a changelog in the spec file, but the %changelog section needs to be present\n";
    exit(1);
}

if ($spec !~ m/(#[^\n]*license)/i) {
    print "$bname.spec does not appear to have a license, the file needs to contain a free software license\n";
    print "Suggestion: use \"osc service localrun format_spec_file\" to get our default license or\n";
    print "the minimal license:\n\n";
    print "# This file is under MIT license\n";
    exit(1);
}

foreach my $test (glob("/usr/lib/obs/service/source_validators/*")) {
    next if (!-f "$test");
    my $checkivsd = `/bin/bash $test --batchmode --verbose $dir $old < /dev/null 2>&1`;
    if ($?) {
	print "Source validator failed. Try \"osc service localrun source_validator\"\n";
	print $checkivsd;
	print "\n";
	exit(1);
    }
}

if (-d "$old") {
    my $odir = getcwd();
    chdir($old) || die "chdir $old failed";
    my $cf = Build::read_config("x86_64", "/usr/lib/build/configs/default.conf");

    my %thash = ();
    my %rhash = ();
    for my $spec (glob("*.spec")) {
	my $ps = Build::Rpm::parse($cf, $spec);

	while (my ($k, $v) = each %$ps) {
	    if ($k =~ m/^source/) {
		$thash{$v} = 1;
	    }
	}
    }
    chdir($odir) || die "chdir $odir failed";
    chdir($dir) || die "chdir $dir failed";
    for my $spec (glob("*.spec")) {
	my $ps = Build::Rpm::parse($cf, $spec);
	open(OSPEC, "$spec");
	open(NSPEC, ">$spec.new");
	while (<OSPEC>) {
	    chomp;
	    if (m/^Source/) {
		my $line = $_;
		$line =~ s/^(Source[0-9]*)\s*:\s*//;
		my $prefix = $1;
		my $parsedline = $ps->{lc $prefix};
		if (defined $thash{$parsedline}) {
		    my $file = $line;
		    my $bname = basename($file);
		    print NSPEC "$prefix: $bname\n";
		} else {
		    print NSPEC "$_\n";
		}
	    } else {
		print NSPEC "$_\n";
	    }
	}
	close(OSPEC);
	close(NSPEC);
	#system("diff -u $spec $spec.new");
	#exit(0);
	rename("$spec.new", "$spec") || die "rename failed";
    }
    chdir($odir);
}

my $odir = getcwd;
my $tmpdir = tempdir ( "obs-XXXXXXX", TMPDIR => 1 );
chdir($dir) || die 'tempdir failed';
if (system("/usr/lib/obs/service/download_files","--enforceupstream", "yes", "--enforcelocal", "yes", "--outdir", $tmpdir)) {
    print "Source URLs are not valid. Try \"osc service localrun download_files\"\n";
    exit(1);
}
chdir($odir);

foreach my $rpmlint (glob("$dir/*rpmlintrc")) {
    open(RPMLINTRC, $rpmlint);
    while ( <RPMLINTRC> ) {
	if ( m/^\s*setBadness/ ) {
	    print "For Factory submissions, you can not use setBadness. Use filters in $rpmlint\n";
	    exit(1);
	}
    }
}
