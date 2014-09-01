#! /usr/bin/perl -w

require LWP::UserAgent;
use strict;
#use warnings FATAL => 'all';
use JSON;
use POSIX;
use Encode;
use Carp::Always;
use Data::Dumper;
use URI::Escape;
use Net::Netrc;
require Date::Format;

my $user = $ARGV[0];
my $tproject = "openSUSE:Factory";
my $baseurl = "https://build.opensuse.org";

sub fetch_user_infos($)
{
    my ($user) = @_;

    if (-f "reports/$user") {
	open( my $fh, '<', "reports/$user" );
	my $json_text   = <$fh>;
	my $st = decode_json( $json_text );
	close($fh);
	return ($st->{'mywork'}, $st->{projstat});
    }

    my $ua = LWP::UserAgent->new;
    $ua->agent("generate-reminder.pl");
    my $mach = Net::Netrc->lookup('api.opensuse.org');
    $ua->credentials("api.opensuse.org:443", "Use your novell account", $mach->login(), $mach->password());
    $ua->timeout(180);
    $ua->max_size(100000000);
    $ua->default_header("Accept" => "application/json");
    my $mywork = $ua->get("$baseurl/home/requests.json?user=$user");
    unless ($mywork->is_success) { die $mywork->status_line; }

    $mywork = from_json( $mywork->decoded_content, { utf8 => 1 });

    my $url = "$baseurl/project/status/$tproject?ignore_pending=0";
    $url .= "&limit_to_fails=false&limit_to_old=false&include_versions=true&filter_for_user=$user";
    my $projstat = $ua->get($url);
    die $projstat->status_line unless ($projstat->is_success);
    $projstat = from_json( $projstat->decoded_content, { utf8 => 1 });

    my %st = ();
    $st{'mywork'} = $mywork;
    $st{'projstat'} = $projstat;
   # open(my $fh, '>', "reports/$user");
   # print STDOUT to_json(\%st);
   # close $fh;
    return ($mywork, $projstat);
}

my $shortener = LWP::UserAgent->new;

sub shorten_url($$)
{
    my ($url, $slug) = @_;

#    return $url;
    $url = uri_escape($url);
    my $ret = $shortener->get("http://s.kulow.org/-/?url=$url&api=6cf62823d52e6d95582c07f55acdecc7&custom_url=$slug&overwrite=1");
    die $ret->status_line unless ($ret->is_success);
    return $ret->decoded_content;
}

sub time_distance($)
{
    my ($past) = @_;
    my $minutes = (time() - $past) / 60;

    if ($minutes < 1440) {
	return "less than 1 day";
    }
    if ($minutes < 2520) {
	return "1 day";
    }
    if ($minutes < 43200) {
	my $days = floor($minutes / 1440. + 0.5);
	return "$days days";
    }

    my $months = floor($minutes / 43200. + 0.5);
    if ($months == 1) {
	return "1 month";
    } else {
	return "$months months";
    }
}

my %requests_to_ignore;

sub explain_request($$)
{
    my ($request, $list) = @_;
    return if (defined($requests_to_ignore{$request->{id}}));
    #print Dumper($request);
    my $actions = $request->{action};
    $actions = [$actions] if (ref($actions) eq "HASH");
    my $line = '';
    for my $action (@{$actions || []}) {
	my $source = $action->{source};
	my $target = $action->{target};

        if ($target->{project} eq $tproject) {
                #print "ignore $request->{id}\n";
                next;
       }

        my $atype = $action->{type} || '';
	if ($atype eq "submit") {
	    $line .= "  Submit request from $source->{project}/$source->{package} to $target->{project}\n";
	} elsif ($atype eq "delete") {
	    $line .= "  Delete request for $target->{project}/$target->{package}\n";
	} elsif ($atype eq "maintenance_release") {
	    $line .= "  Maintenance release request from $source->{project}/$source->{package} to $target->{project}\n";
	} elsif ($atype eq "maintenance_incident") {
	    $line .= "  Maintenance incident request from $source->{project} to $target->{project}\n";
	} elsif ($atype eq "add_role") {
            my %person = %{$action->{person}};
	    $line .= "  User $person{name} wants to be $person{role} in $target->{project}\n";
	} elsif ($atype eq "change_devel") {
            $line .= "  Package $target->{project}/$target->{package} should be developed in $source->{project}\n";
	} else {
	    print STDERR "HUH" . Dumper($action);
	}
    }
    $list->{int($request->{id})} = $line if ($line);
}

sub generate_report($)
{
    my ($user) = @_;

    my ($mywork, $projstat) = fetch_user_infos($user);

    #print to_json($mywork, {pretty => 1 });
    #print to_json($projstat, {pretty => 1});

    my %projects;
    for my $package (@$projstat) {
        my $develproject = $package->{develproject} || next;
        next if ($develproject eq $tproject); 
	$projects{$develproject} ||= [];
	push(@{$projects{$develproject}}, $package);
    }

    my %reviews_by;

    my $report = '';

    for my $request (@{$mywork->{review}}) {
      # as we query the build service as anonymous, we always get the reviews for "the others"
	my $reviews = $request->{other_open_reviews};
	$reviews = [$reviews] if (ref($reviews) eq "HASH");
	for my $review (@{$reviews}) {
	    next if ($review->{state} ne 'new');
	    if (($review->{by_user} || '') eq $user) {
		$report .= "Request $request->{id} is waiting for your review!\n";
		$report .= "  https://build.opensuse.org/request/show/$request->{id}\n\n";
		$requests_to_ignore{$request->{id}} = 1;
		next;
	    }
	    # we ignore by_group for now
	    if ($review->{by_group} ) {
		$requests_to_ignore{$request->{id}} = 1;
		next;
	    }
	    if ($review->{by_project}) {
		my $bproj = $review->{by_project};
		my $bpack = $review->{by_package};
		$reviews_by{"$bproj/$bpack"} = $request;
		next;
	    }
	}
    }

    for my $project (sort(keys %projects)) {
	my $lines = {};

	for my $package (@{$projects{$project}}) {
	    next if @{$package->{requests_from}};

	    # do not show version information if there is more important stuff
	    my $showversion = 1;
	    my $ignorechanges = 0;

	    my $key = "$project/$package->{name}";
	    if ($reviews_by{$key}) {
		my $r = $reviews_by{$key};
		push(@{$lines->{reviews}}, "  $package->{name} has request $r->{id} waiting for review!");
		delete $reviews_by{$key};
	    }

	    if ($package->{firstfail}) {
		my $fail = time_distance($package->{firstfail});
		my $comment = $package->{failedcomment} || 'unknown failure';
		$comment =~ s,^\s+,,;
		$comment =~ s,\s+$,,;
		my $url = "$baseurl/package/live_build_log/";
		$url   .= uri_escape($tproject) . "/";
		$url   .= uri_escape($package->{name}) . "/";
		$url   .= uri_escape($package->{failedrepo}) . "/";
		$url   .= uri_escape($package->{failedarch});
		$url = shorten_url($url, "bf-$package->{name}");
		push(@{$lines->{fails}}, "  $package->{name} fails for $fail ($comment):");
		push(@{$lines->{fails}}, "    $url\n");
		$ignorechanges = 1;
	    }

	    for my $problem (sort @{$package->{problems}}) {
		if ($problem eq 'different_changes') {
                    my $url = "$baseurl/package/rdiff/";
                    $url .= uri_escape($package->{develproject});
		    $url .= "/" . uri_escape($package->{develpackage});
		    $url .= "?opackage=" .  uri_escape($package->{name});
                    $url .= "&oproject=" . uri_escape($tproject);
		    if ($ignorechanges == 0) {
			$url = shorten_url($url, "rd-$package->{name}");
			push(@{$lines->{unsubmit}}, "    $package->{name} - $url");
			$showversion = 0;
		    }
		} elsif ($problem eq 'currently_declined') {
		    my $url = "https://build.opensuse.org/request/show/$package->{currently_declined}";
		    push(@{$lines->{declined}}, "    $package->{name} - $url");
		    $showversion = 0;
		}
	    }

	    for my $request (@{$package->{requests_to}}) {
		push(@{$lines->{requests}}, "    $package->{name} - https://build.opensuse.org/request/show/$request");
		$requests_to_ignore{$request} = 1;
		$showversion = 0;
	    }

	    if ($showversion && $package->{upstream_version}) {
		push(@{$lines->{upstream}}, "    $package->{name} - packaged: $package->{version}, upstream: $package->{upstream_version}");
	    }
	}
	$report .= "Project $project\n" if %$lines;
	for my $reason (qw(reviews fails declined unsubmit requests upstream)) {
	    next unless $lines->{$reason};
	    if ($reason eq "fails") {
		$report .= "\n";
	    } elsif ($reason eq "upstream") {
		$report .= "\n  Packages with new upstream versions:\n";
	    } elsif ($reason eq "unsubmit") {
		$report .= "\n  Packages with unsubmitted changes:\n";
	    } elsif ($reason eq "requests") {
		$report .= "\n  Packages with pending requests:\n";
	    } elsif ($reason eq "declined") {
		$report .= "\n  Declined submit requests - please check the reason:\n";
	    }

	    $report .= join("\n",@{$lines->{$reason}}); 
	    $report .= "\n" if ($reason ne "fails");
	}
	$report .= "\n" if %$lines;
    }

    my %list;

    %list = ();

    for my $request (@{$mywork->{declined}}) {
	explain_request($request, \%list);
    }

    if (%list && $report) {
	$report .= "Your declined requests (not related to your factory packages, please revoke or reopen):\n";
	my @lkeys = keys %list;
	foreach my $request (sort { $a <=> $b } @lkeys) {
	    $report .= $list{$request};
	    $report .= "    https://build.opensuse.org/request/show/$request\n\n";
	}
    }

    %list = ();

    for my $request (@{$mywork->{new}}) {
	explain_request($request, \%list);
    }

    if (%list && $report) {
	$report .= "Other new requests (not related to your factory packages):\n";
	my @lkeys = keys %list;
	foreach my $request (sort { $a <=> $b } @lkeys) {
	    $report .= $list{$request};
	    $report .= "    https://build.opensuse.org/request/show/$request\n\n";
	}
    }

    return $report;
}

my $report = generate_report($user);

if ($report) {
    my $url = "$baseurl/project/status?project=" . uri_escape($tproject);
    $url .= "&limit_to_fails=false&include_versions=true";
    $url .= "&filter_for_user=" . uri_escape($user);
    $url = shorten_url($url, "fs-$user");

    my $prefix = <<END;
Dear openSUSE contributor,

The following status report is a reminder I send to you in the hope that it
proves useful to you. I do not intend to spam you - if you don't want these
reports, please tell me why and I'll either fix the issue or disable the
mail to you.

But please note that I filtered the information as good as I could and that
if you find a package that you have no connection to and wonder why I send
this information to you, then you are most likely "maintainer" in a project
for some reason. The best option IMO then is to remove yourself from that
role - or if you know the real package maintainer, set it in the package.

I intent to send these reminders on a weekly basis, you can find more details
in this thread: http://lists.opensuse.org/opensuse-packaging/2012-02/msg00011.html

The following packages are sorted by devel project of openSUSE:Factory
END

    $prefix .= "( you can find an uptodate version under $url )\n\n";
    $report = $prefix . $report;
    my $fortune = '';
    open(FORTUNE, "fortune -s|");
    while ( <FORTUNE> ) { $fortune .= "  " . $_; }
    close(FORTUNE);
    $report .= "\n\n-- \nYour fortune cookie:\n" . $fortune;

    use MIME::Lite;
    use XML::Simple;

    my $xml = '';
    open(USER, "osc meta user -- '$user'|") || die "osc meta user $user failed";
    while ( <USER> ) { $xml .= $_; }
    close(USER);

    my $info = XMLin($xml);
    my $to = $info->{email};
    if (ref($info->{realname}) ne "HASH") {
      my $name = $info->{realname};
      $to = encode('MIME-Header', "$name <$to>");
    }
    my $email = 
	MIME::Lite->new(
   	   From    => 'Stephan Kulow <coolo@suse.de>',
	   To      => $to,
	   Subject => 'Reminder for openSUSE:Factory work',
	   Data => $report,
	   Encoding => '7bit',
	);

    # update from time to time :)
    $email->add( 'User-Agent' => 'Mozilla/5.0 (X11; Linux x86_64; rv:9.0) Gecko/20111220 Thunderbird/9.0');
    $email->add( 'X-Mailer' => 'https://github.com/coolo/factory-auto/blob/master/generate-reminder.pl');

    print "From - " . Date::Format::time2str("%a %b %d %T %Y\n", time);
    $email->print(\*STDOUT);
}
