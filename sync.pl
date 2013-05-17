#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;
use Getopt::Long;
use Cwd qw/abs_path/;

# Sync remote dev area with local and vice versa
#
# For quick push:
#   find files newer than last sync file time stamp
#   if there are any new ones
#     touch last sync file
#     add new file paths/names to a file
#     sync them to remote using rsync --files-from option
#   otherwise do nothing
#
# This way the script does not need to run a full rsync.

# need to undo lock if die
local $SIG{__DIE__} = sub { undo_lock(); print "DYING!"; die @_; };
$|++; # autmatically flush output

my $local;
my $remote;
my $user_local;
my $user_remote;
my $remote_host;
my $last_push_file;
my $files_from_file;
my $lock_file;
my $bandwidth_throttle;
my $no_throttle;
my $excludes = '.*.swp,.*.swo,.git,.~.*,.*.komodoproject';
my $rsync    = 'rsync --rsync-path="nice -n 19 rsync" -ave ssh ';
my $lock_wait        = 1;
my $lock_tries       = 10;
my $default_throttle = 2000;
my $pull             = 0;
my $push             = 0;
my $sync             = 0;  # a pull followed by a push
my $test             = 0;
my $show             = 0;
my $new              = 0;  # for push, find files new compared to last sync to sync
my $quiet            = 1;  # don't say anything - unless you synced something
my $stfu             = 0;  # never say nothin
my $verbose          = 0;
my $delete           = 0;
my $break            = 0;
my $komodo_friendly  = 1;
my $excludes_in;
my $result           = GetOptions(
	"push"               => \$push,
	"pull"               => \$pull,
	"sync"               => \$sync,
	"delete"             => \$delete,
	"new"                => \$new,
	"quiet"              => \$quiet,
	"test"               => \$test,
	"show"               => \$show,
	"break"              => \$break,
	"local=s"            => \$local,             # string
	"excludes=s"         => \$excludes_in,          # string
	"remote=s"           => \$remote,            # string
	"user_local=s"       => \$user_local,        # string
	"user_remote=s"      => \$user_remote,       # string
	"rsync=s"            => \$rsync,             # string
	"remote_host=s"      => \$remote_host,       # string
	"verbose"            => \$verbose,
	"bandwidth_throttle" => \$bandwidth_throttle,
	"no_throttle"        => \$no_throttle,
);
die 'incorrect options' unless $result;
die 'need local'  if not $local;
die 'need remote' if not $remote;
$excludes .= ",$excludes_in" if $excludes_in;
if (not $push and not $pull) {

	# default to pull
	$pull = 1;
}
if ($rsync !~ /rsync/) {
	die 'only rsync is supported';
}
if ($test) {
	$rsync .= ' --dry-run ';
}
if ($delete) {
	$rsync .= ' --delete ';
}
if (not defined $bandwidth_throttle) {
	$bandwidth_throttle = $default_throttle; # default 2 mbps
}
$last_push_file  = abs_path("$local/../.last_push.$remote_host")  if not $last_push_file;
$files_from_file = abs_path("$local/../.files_from.$remote_host") if not $files_from_file;
$lock_file       = abs_path("$local/../.sync_lock.$remote_host")  if not $lock_file;

if ($sync) {
	$push = 1;
	$pull = 1;
}

my @excludes = split(',', $excludes);
my $excludes_opt;
foreach my $x (@excludes) {
	$excludes_opt .= " --exclude '" . $x . "' ";
}

# Wait for the lock to be unset or die
my $tries = 0;
while (is_locked()) {
	$tries++;
	if ($verbose) {
		print "Lock is set.";
	}
	if ($tries == $lock_tries) {
		print "Tried lock ($lock_file) $lock_tries times.\n";
		if ($break) {
			print "Breaking lock.\n";
			undo_lock();
		}
		else {
			print "Giving up.\n";
			exit 2;
		}
	}
	sleep $lock_wait;
}

create_lock();

# Find files that have changed locally since last sync
if ($push and $new) {

	my $find_new = "/usr/bin/find $local -newer $last_push_file";

	verbose("Checking if last push file ($last_push_file) exists");
	if (-e $last_push_file) {

		# Clean up last files from file
		verbose("Checking if files from file ($files_from_file) exists");
		if (-e $files_from_file) {
			verbose("Cleaning up files from file ($files_from_file)");
			unlink $files_from_file or die "Couldn't clean up $last_push_file";
		}

		# Dump the new files into a file to be read by rsync
		#  with the --files-from directive
		run_cmd("touch \"$last_push_file.tmp\"", 'quietly'); #account for fractions of sec/secs when dir/files change for komodo
		my @files_found = split(/\n/, `$find_new 2>/dev/null`);

		#print Dumper(@files_found);

		my $found = '';

		my $fnum = 0;
	FILE:
		foreach my $f (@files_found) {

			# Get rid of local directory, this messes up rsync command
			#  This way the files names are relative
			my $fo = $f;
			$f =~ s/^\Q$local\E/.\//;

			# ignore some stuff
			foreach my $x (@excludes) {
				next FILE if $f =~ /$x/;
			}
			if ($komodo_friendly) {

				# hack to ignore when komodo only changes the timestamp on the local dir
				$fnum++;
				next FILE if (-d $fo) and $fnum == 1;
			}
			$found .= $f . "\n";
		}

		if ($found) {
			shout("Changed files:");
			shout($found);
			open my $OUT, '>', $files_from_file or die
				"Error opening $files_from_file: $!";
			print $OUT $found;
			close $OUT;
		}
		else {
			mysay("No files changed, exiting.\n");
			finish(0);
		}

		# Add --files-from option to rsync command
		$rsync .= " --files-from \"$files_from_file\" ";

		# cannot seem to have excludes with files from
		$excludes_opt = '';
	}
	else {
		mysay("No last push file found at ($last_push_file).");
	}
}

my $throttle = '';
if (not $no_throttle) {
	$throttle = "--bwlimit=$bandwidth_throttle";
}

my $pull_cmd = "$rsync $throttle $excludes_opt $user_remote\@$remote_host:$remote $local";
my $push_cmd = "$rsync $throttle $excludes_opt $local $user_remote\@$remote_host:$remote";

my $out;
if ($pull) {
	verbose("Executing pull command ($pull_cmd)\n");
	if ($show) {
		print "\n\n=========================================\n";
		print "Showing command only! Not really syncing!\n";
		print "=========================================\n\n";
	}
	else {
		$out .= `$pull_cmd 2>&1`;
	}
}
if ($push) {
	if ($show) {
		print "\n\n=========================================\n";
		print "Showing command only! Not really syncing!\n";
		print "=========================================\n\n";
	}
	else {
		run_cmd("$push_cmd 2>&1");
		if (not $test) {
			if ( -e "$last_push_file.tmp" ) {
				run_cmd("mv \"$last_push_file.tmp\" \"$last_push_file\"");
			}
			else {
				# Create the last push file for next time
				run_cmd("touch \"$last_push_file.tmp\"", 'quietly'); 
			}

		}
	}
}

if ($verbose) {
	print "Output of command was:\n";
	print $out if defined $out;
	print "\n";
}

if ($test) {
	print "Test output was:\n$out\n";
}

finish(0);

sub create_lock {
	if ($verbose) {
		print "\ncreating lock file ($lock_file)\n";
	}
	open my $LF, '>', $lock_file or warn "Couldn't open lock file ($lock_file): $!";
	print $LF '1';
	close $LF;
	return 1;
}

sub undo_lock {
	if ($verbose) {
		print "\nbreaking lock file ($lock_file)\n";
	}
	if ($lock_file and -e $lock_file) {
		unlink $lock_file or warn "Couldn't delete lock file: $!";
	}
	return 1;
}

sub is_locked {
	if (-e $lock_file) {
		return 1;
	}
	else {
		return 0;
	}
}

sub finish {
	my $exit_code = shift;
	undo_lock();
	exit $exit_code;
}

sub verbose {
	my $thing = shift;
	if ($verbose) {
		print "$thing\n";
	}
	return 1;
}

sub mysay {
	my $thing = shift;
	if (not $quiet) {
		print "$thing\n";
	}
	return 1;
}

sub shout {
	my $thing = shift;
	if (not $stfu) {
		print "$thing\n";
	}
	return 1;
}

sub run_cmd {
	my $cmd     = shift;
	my $stfu_in = shift;
	$stfu++ if $stfu_in;

	shout("Running command ($cmd)");
	my $out = `$cmd 2>&1`;
	if ($? != 0) {
		die "There was an error ($?) running ($cmd):\n $!";
	}
	shout($out);

	$stfu-- if $stfu;
	return $out;
}

sub run_cmd_nocatcherror {
	my $cmd = shift;
	open my $CMD, "$cmd|";
	while (<$CMD>) {
		chomp;
		mysay($_) if $verbose;
	}
	close($CMD);
	return;
}
