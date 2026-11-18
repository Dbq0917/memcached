#!/usr/bin/env perl
# Tests for delayed flush_all semantics with and without -o flush_from_now.
#
# Legacy mode (default): a delayed flush invalidates everything up to the
# moment the delay elapses, including items written during the delay.
#
# flush_from_now mode: a delayed flush only invalidates items that existed
# when the command was issued; items written during the delay are kept.

use strict;
use Test::More tests => 46;
use FindBin qw($Bin);
use lib "$Bin/lib";
use MemcachedTest;

sub write_batch {
    my ($sock, $prefix) = @_;
    for my $n (1 .. 3) {
        my $val = "$prefix$n";
        print $sock "set $prefix$n 0 0 " . length($val) . "\r\n$val\r\n";
        is(scalar <$sock>, "STORED\r\n", "stored $prefix$n");
    }
}

sub check_batch {
    my ($sock, $prefix, $expect) = @_;
    for my $n (1 .. 3) {
        mem_get_is($sock, "$prefix$n", $expect ? "$prefix$n" : undef);
    }
}

# Legacy mode: default server, delayed flush wipes data written during
# the delay window as well.
{
    my $server = new_memcached();
    my $sock = $server->sock;

    write_batch($sock, "before");
    print $sock "flush_all 3\r\n";
    is(scalar <$sock>, "OK\r\n", "did delayed flush_all (legacy)");
    write_batch($sock, "during");
    # Nothing is flushed until the delay elapses.
    check_batch($sock, "before", 1);
    check_batch($sock, "during", 1);
    sleep 5;
    # Legacy semantics: both batches are gone.
    check_batch($sock, "before", 0);
    check_batch($sock, "during", 0);
}

# from_now mode: delayed flush keeps data written during the delay window.
{
    my $server = new_memcached('-o flush_from_now');
    my $sock = $server->sock;

    my $settings = mem_stats($sock, "settings");
    is($settings->{flush_from_now}, "yes", "flush_from_now enabled in settings");

    write_batch($sock, "before");
    print $sock "flush_all 3\r\n";
    is(scalar <$sock>, "OK\r\n", "did delayed flush_all (from_now)");
    # Ensure the next batch lands in a later second than the flush command:
    # timestamps have one second granularity.
    sleep 1;
    write_batch($sock, "during");
    # Nothing is flushed until the delay elapses.
    check_batch($sock, "before", 1);
    check_batch($sock, "during", 1);
    sleep 5;
    # Data written before the command is flushed, data written during
    # the delay window survives.
    check_batch($sock, "before", 0);
    check_batch($sock, "during", 1);

    # Immediate flush still wipes everything, regardless of mode.
    print $sock "flush_all\r\n";
    is(scalar <$sock>, "OK\r\n", "did immediate flush_all (from_now)");
    check_batch($sock, "during", 0);
}

# from_now mode: flush is recorded in the sysevents log stream.
{
    my $server = new_memcached('-o flush_from_now');
    my $sock = $server->sock;
    my $watcher = $server->new_sock;

    print $watcher "watch sysevents\r\n";
    is(scalar <$watcher>, "OK\r\n", "watcher enabled");

    print $sock "flush_all 5\r\n";
    is(scalar <$sock>, "OK\r\n", "did delayed flush_all for log check");

    # Give the logger thread a moment, then nudge it with another command.
    sleep 1;
    print $sock "version\r\n";
    scalar <$sock>;

    my $log = <$watcher>;
    like($log, qr/type=flush_all delay=5 mode=from_now/,
        "flush_all recorded in sysevents log");
}
