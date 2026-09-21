#!/usr/bin/env perl
# Regression test for the zombie-child leak in diogenes-server.pl.
#
# The unix "normal" forking server forks one child per accepted
# connection.  If the parent never reaps those children, every served
# request leaves a <defunct> entry in the process table (observed at
# roughly 200 zombies/hour in production, worked around by hourly
# restarts).  This test starts the real server, issues a handful of
# requests, and asserts that the parent has reaped every exited child.

use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec::Functions qw(catdir catfile);
use File::Temp qw(tempdir);
use IO::Socket::INET;
use Test::More;

plan skip_all => 'win32 runs a different, single-child server loop'
    if $^O eq 'MSWin32';
use Config;
plan skip_all => 'fork() is unavailable on this platform'
    if !$Config{d_fork};

my $server_dir = catdir($Bin, '..');
my $server_pl  = catfile($server_dir, 'diogenes-server.pl');
plan skip_all => "cannot find diogenes-server.pl at $server_pl"
    unless -f $server_pl;

# Hermetic config dir: keeps the test from touching the developer's
# own ~/.diogenes, and gives us a private lock file to read the
# server's pid and port from.
my $config_dir = tempdir('diogenes-zombie-t-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$ENV{Diogenes_Config_Dir} = $config_dir;

# Pick a free port for this run.
my $probe = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 0,
    Listen    => 1,
    Proto     => 'tcp',
) or plan skip_all => "cannot probe for a free port: $!";
my $port = $probe->sockport;
$probe->close;

# Start the real server.
my $server_pid = fork;
BAIL_OUT("fork failed: $!") if !defined $server_pid;
if ($server_pid == 0) {
    chdir $server_dir or die "cannot chdir to $server_dir: $!";
    my $log = File::Spec->catfile($config_dir, 'server.log');
    open STDOUT, '>', $log or die "cannot redirect stdout: $!";
    open STDERR, '>&', \*STDOUT or die "cannot redirect stderr: $!";
    exec {$^X} $^X, './diogenes-server.pl', '-p', $port, '-d';
    die "exec failed: $!";
}

sub stop_server {
    return unless $server_pid;
    kill 'TERM', $server_pid;
    my $deadline = time + 10;
    while (time < $deadline && kill(0, $server_pid)) {
        select undef, undef, undef, 0.1;
    }
    kill 'KILL', $server_pid if kill(0, $server_pid);
    waitpid $server_pid, 0;
    # waitpid() leaves $? set to the child's status; do not let that
    # become our own exit status once the END block finishes.
    $? = 0;
    $server_pid = undef;
}
$SIG{INT} = $SIG{TERM} = sub { stop_server(); exit 1 };
END { stop_server() }

# Children of the running server, split into live (S/R/D/...) and
# defunct (Z) processes, via ps(1).
sub server_children {
    my @stat = `ps -o stat= --ppid $_[0] 2>/dev/null`;
    my (@live, @zombies);
    for (@stat) {
        chomp(my $s = $_);
        next unless length $s;
        if ($s =~ /Z/) { push @zombies, $s }
        else           { push @live, $s }
    }
    return (\@live, \@zombies);
}

# Wait for startup: the lock file records the port and parent pid.
my $lock_file = catfile($config_dir, 'diogenes-lock.json');
my $lock = '';
my $startup_deadline = time + 60;
while (time < $startup_deadline) {
    last if !kill(0, $server_pid)
        && do { stop_server(); BAIL_OUT('server died during startup') };
    if (-f $lock_file) {
        open my $fh, '<', $lock_file or BAIL_OUT("cannot read $lock_file: $!");
        local $/;
        $lock = <$fh>;
        close $fh;
        last if $lock =~ /"pid"\s*:\s*(\d+)/;
    }
    select undef, undef, undef, 0.25;
}
BAIL_OUT("server did not write its lock file ($lock_file) within 60s")
    unless $lock =~ /"pid"\s*:\s*(\d+)/;

my ($lock_pid)  = $lock =~ /"pid"\s*:\s*(\d+)/;
my ($lock_port) = $lock =~ /"port"\s*:\s*(\d+)/;
BAIL_OUT('lock file is missing pid/port') unless $lock_pid && $lock_port;
is $lock_pid, $server_pid, 'lock file records the parent server pid';

# Serve a static file a few times; each request costs one fork.
my $requests = 5;
my $served = 0;
for my $i (1 .. $requests) {
    my $client = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1',
        PeerPort => $lock_port,
        Timeout  => 30,
        Proto    => 'tcp',
    ) or diag "connection $i failed: $!";
    next unless $client;
    print $client "GET /diogenes.css HTTP/1.0\r\nHost: localhost\r\n\r\n";
    my $response = '';
    while (<$client>) { $response .= $_ }
    $client->close;
    $served++ if $response =~ /^HTTP\/1\.[01] 200/;
}
cmp_ok $served, '>=', $requests, 'server served every request over a fresh connection';

# Let the final children exit, then require the parent to have reaped
# them: no process may remain in the table.
my ($live, $zombies) = (undef, undef);
my $reap_deadline = time + 30;
do {
    select undef, undef, undef, 0.5;
    ($live, $zombies) = server_children($server_pid);
} while (time < $reap_deadline && @{$live});

is scalar @{$zombies}, 0,
    'parent reaped every forked connection child (no zombies)';
is scalar @{$live}, 0, 'no connection children are left running';

done_testing();
