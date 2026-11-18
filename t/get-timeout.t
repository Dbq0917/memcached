#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use MemcachedTest;
use Time::HiRes qw(time);
use IO::Select;

if (!supports_extstore()) {
    plan skip_all => 'extstore not enabled';
    exit 0;
}

my $fast_count = 80;
my $deadline_ms = 200;
my $slow_ms = 800;
my $value = "V" x 20000;
my @fast_keys = map { sprintf("fast%02d", $_) } (0 .. $fast_count - 1);
my @keys = (@fast_keys, "slow");

sub server_args {
    my ($ext_path, $timeout) = @_;
    my $args = "-m 4 -U 0 -t 1 "
        . "-o ext_page_size=8,ext_wbuf_size=2,ext_threads=4,ext_io_depth=2,"
        . "ext_item_size=512,ext_item_age=0,ext_recache_rate=10000,"
        . "ext_max_frag=0.9,ext_path=$ext_path:64m,slab_automove=0,"
        . "no_lru_crawler,ext_test_slow_key=slow,ext_test_slow_ms=$slow_ms";
    if (defined $timeout) {
        $args .= ",get_timeout_ms=$timeout";
    }
    return $args;
}

sub seed_keys {
    my ($sock) = @_;
    for my $key (@keys) {
        print $sock "set $key 0 0 " . length($value) . " noreply\r\n$value\r\n";
    }
}

sub wait_for_ext {
    my ($sock) = @_;
    for (1 .. 100) {
        my $items = mem_stats($sock, "items");
        my $in_memory = 0;
        for my $key (keys %$items) {
            next unless $key =~ m/^items:(\d+):number$/ && $1 >= 3;
            $in_memory += $items->{$key};
        }
        return if $in_memory == 0;
        sleep 0.1;
    }
    fail("items did not flush to extstore");
}

sub read_get {
    my ($sock, @get_keys) = @_;
    my %got;
    my $start = time();
    print $sock "get @get_keys\r\n";
    while (my $line = <$sock>) {
        if ($line =~ m/^VALUE (\S+) \d+ (\d+)\r\n$/) {
            my ($key, $len) = ($1, $2);
            my $val = "";
            my $left = $len;
            while ($left > 0) {
                my $n = read($sock, $val, $left, length($val));
                last unless $n;
                $left -= $n;
            }
            my $crlf = <$sock>;
            $got{$key} = $val;
        } elsif ($line eq "END\r\n") {
            return (\%got, time() - $start);
        }
    }
    return (\%got, time() - $start);
}

sub read_timeout_log {
    my ($watch) = @_;
    my $sel = IO::Select->new($watch);
    my $until = time() + 1;
    while (time() < $until) {
        last unless $sel->can_read(0.1);
        my $line = <$watch>;
        next unless defined $line;
        return $line if $line =~ m/type=item_get key=slow status=timeout/;
    }
    return undef;
}

my $timeout_ext = "/tmp/get-timeout-timed.$$";
my $baseline_ext = "/tmp/get-timeout-baseline.$$";

my $server = new_memcached(server_args($timeout_ext, $deadline_ms));
my $sock = $server->sock;
$sock->timeout(3);
is(mem_stats($sock, "settings")->{get_timeout_ms}, $deadline_ms,
    "deadline setting is visible in stats settings");
seed_keys($sock);
wait_for_ext($sock);

my $watch = $server->new_sock;
$watch->timeout(2);
print $watch "watch fetchers\r\n";
is(scalar <$watch>, "OK\r\n", "fetcher watcher enabled");

my ($got, $elapsed) = read_get($sock, @keys);
my $after = mem_stats($sock);

is(scalar keys %$got, $fast_count, "all fast keys returned");
ok(!exists $got->{slow}, "slow key was omitted from the partial result");
cmp_ok($elapsed, "<", $slow_ms / 1000, "partial result arrived before the slow key");
cmp_ok($after->{get_timeout}, ">=", 1, "deadline was recorded in stats");
cmp_ok($after->{get_timeout_keys}, ">=", 1, "timed out keys were counted");

like(read_timeout_log($watch), qr/type=item_get key=slow status=timeout/,
    "timed out key was written to the fetcher log");

my $misses = [grep { !exists $got->{$_} } @keys];
is_deeply($misses, ["slow"], "partial result identifies the missing key");

# Let the timed out IO drain before the retry. This keeps the assertion about
# duplicate fetches independent from test-hook queue ordering.
sleep($slow_ms / 1000 + 0.2);
my $reads_before = mem_stats($sock)->{extstore_objects_read};
my ($retry, $retry_elapsed) = read_get($sock, @$misses);
my $retry_stats = mem_stats($sock);
ok(exists $retry->{slow}, "retry of the missing key succeeded");
cmp_ok($retry_elapsed, "<", $slow_ms / 1000, "retry did not wait on the slow path again");
is($retry_stats->{extstore_objects_read} - $reads_before, 1,
    "retry fetched only the key that was missing");

$server->stop();

my $baseline = new_memcached(server_args($baseline_ext, undef));
my $bsock = $baseline->sock;
$bsock->timeout(3);
seed_keys($bsock);
wait_for_ext($bsock);
my ($base_got, $base_elapsed) = read_get($bsock, @keys);
is(scalar keys %$base_got, scalar @keys, "baseline batch returned every key");
cmp_ok($base_elapsed, ">", $slow_ms / 1000, "baseline batch waited for the slow key");
$baseline->stop();

diag sprintf("multiget latency: deadline=%dms partial=%.1fms; no deadline=%.1fms full",
    $deadline_ms, $elapsed * 1000, $base_elapsed * 1000);

done_testing();
