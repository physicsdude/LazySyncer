#!/usr/bin/perl -w
use warnings;
use strict;
use Getopt::Long;
use FindBin qw($Bin);

# script that acts like a daemon to constantly push local to remote but only if a local file has changed - remote is not queried until then
$|++;

my $sync         = "$Bin/sync.pl";
my $verbose      = 0;
my $quiet        = 0;
my $reload       = 0;
my $restart      = 0;
my $push_count   = 0;

# Do a full rsync approx every hour
my $full_push_interval = 3000;
my $push_options       = '';
my ($local, $remote, $user_local, $user_remote, $remote_host);

my $result = GetOptions(
	"remote=s"             => \$remote,             # remote dir
	"local=s"              => \$local,              # local dir
	"user_local=s"         => \$user_local,         # string
	"user_remote=s"        => \$user_remote,        # string
	"remote_host=s"        => \$remote_host,        # string
	"full_push_interval=i" => \$full_push_interval, # string
	"reload"               => \$reload,
	"restart"              => \$restart,
	"verbose"              => \$verbose,
);
exit "Incorrect options: $!" if not $result;
die 'need local'             if not $local;
die 'need remote'            if not $remote;
my $push_out = "$local/../.push_stdout";
my $push_err = "$local/../.push_stderr";
my $push_cmd = "$sync --push";
$push_out = $push_out . '.' . $remote_host if $remote_host;
$push_err = $push_err . '.' . $remote_host if $remote_host;

$push_options .= " --local $local"               if $local;
$push_options .= " --remote $remote"             if $remote;
$push_options .= " --user_local $user_local"     if $user_local;
$push_options .= " --user_remote $user_remote"   if $user_remote;
$push_options .= " --remote_host $remote_host"   if $remote_host;
$push_options .= " --restart $restart"           if $restart;
$push_options .= " --reload $reload"             if $reload;
$push_options .= " --verbose"                    if $verbose;
$push_options .= " --quiet"                      if not $verbose;

my $error = 0;
while (not $error) {
	$push_count++;
	my $pushed = 0;
	if ($verbose) {
		print "pushing\n";
	}
	my $new = ' --new ';
	if ($push_count % $full_push_interval == 0) {
		if (not $quiet) {
			print "**** Performing full rsync push, please wait. ****\n";
		}
		$new = '';
	}
	else {
		if (not $quiet) {
			print ".\n";
		}
	}
	my $result = `$push_cmd $new $push_options 1>$push_out 2>$push_err`;
	if (-s $push_err) {
		$error = 1;
	}
	if (-s $push_out) {
		if (not $quiet) {
			print "Pushed data (output in $push_out):\n";
			print `cat $push_out`;
		}
		$pushed = 1;
	}
	if ($verbose or $error) {
		print "result of push command was:\n" . $result;
		if (-s $push_err) {
			print "ERROR:";
			print `cat $push_err`;
		}
		if (-s $push_out) {
			print "STDOUT: ";
			print `cat $push_out`;
		}
	}

	sleep 1;
}
