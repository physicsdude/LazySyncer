#!/usr/bin/perl -w
use warnings;
use strict;
use Getopt::Long;
use FindBin qw($Bin);
use File::Path qw(make_path);

# script that acts like a daemon to constantly push local to remote but only if a local file has changed - remote is not queried until then
$|++;

my $sync         = "$Bin/sync.pl";
my $verbose      = 0;
my $quiet        = 0;
my $reload       = 0;
my $restart      = 0;
my $push_count   = 0;

# Do a full rsync approx every two minutes
my $full_push_interval = 120;
my $push_options       = '';
my ($local, $remote, $user_local, $user_remote, $remote_host,$excludes);

my $result = GetOptions(
	"remote=s"             => \$remote,             # remote dir
	"local=s"              => \$local,              # local dir
	"user_local=s"         => \$user_local,         # string
	"user_remote=s"        => \$user_remote,        # string
	"remote_host=s"        => \$remote_host,        # string
	"full_push_interval=i" => \$full_push_interval, # string
	"excludes=s"           => \$excludes, # string
	"reload"               => \$reload,
	"restart"              => \$restart,
	"verbose"              => \$verbose,
);
exit "Incorrect options: $!" if not $result;
die 'need local'             if not $local;
die 'need remote'            if not $remote;
my $push_cmd = "$sync --push";
my $control_file_dir = "$local/../.constant_push";
$control_file_dir .= "/$remote_host" if $remote_host;
my $push_out = $control_file_dir."/.push_stdout";
my $push_err = $control_file_dir."/.push_stderr";
if ( not -d $control_file_dir ) {
	make_path($control_file_dir) or die "Couldn't make control file dir $control_file_dir";
	print "Made control file directory $control_file_dir";
}
`touch $push_out; touch $push_err;`;

$push_options .= " --local $local"               if $local;
$push_options .= " --remote $remote"             if $remote;
$push_options .= " --user_local $user_local"     if $user_local;
$push_options .= " --user_remote $user_remote"   if $user_remote;
$push_options .= " --remote_host $remote_host"   if $remote_host;
$push_options .= " --restart $restart"           if $restart;
$push_options .= " --reload $reload"             if $reload;
$push_options .= " --excludes '$excludes'"       if $excludes;
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
