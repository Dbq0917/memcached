#!/usr/bin/env perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/lib";
use MemcachedTest;

# Verifies the safe-counter facility exposed through "stats counters":
#   * declared widths match the real traffic magnitude (uint64 storage);
#   * values agree with the classic "stats" fields (semantics unchanged);
#   * time-window deltas/rates and saturation metadata are reported;
#   * "stats reset" keeps its existing behaviour and clears the view.

my $server = new_memcached();
my $sock = $server->sock;

my @counter_fields = qw(cmd_get cmd_set get_hits get_misses
                        bytes_read bytes_written);

# First call establishes the sampling baseline.
my $baseline = mem_stats($sock, "counters");
isa_ok($baseline, 'HASH', "stats counters returns a stat map");

# Width + initial overflow state for every registered counter.
for my $field (@counter_fields) {
    is($baseline->{"$field:width"}, "u64", "$field declared as u64");
    is($baseline->{"$field:overflow_events"}, 0,
       "$field starts without overflow");
}

# Let the sampling window span at least one second.
sleep 1;

# Regular read/write workload: 50 stores, 50 hits, 20 misses.
for my $i (1 .. 50) {
    print $sock "set key$i 0 0 5\r\nvalue\r\n";
    is(scalar <$sock>, "STORED\r\n", "stored key$i");
    mem_get_is($sock, "key$i", "value");
}
for my $i (1 .. 20) {
    print $sock "get missing$i\r\n";
    is(scalar <$sock>, "END\r\n", "missing$i is a miss");
}

# Snapshot counters before the classic stats query so command counters are
# directly comparable; the stats query itself only moves byte counters.
my $counters = mem_stats($sock, "counters");
my $stats = mem_stats($sock);

# Classic stats fields keep their exact name and value.
for my $field (qw(cmd_get cmd_set get_hits get_misses)) {
    is($counters->{"$field:value"}, $stats->{$field},
       "$field value matches classic stats field");
}
is($stats->{cmd_get}, 70, "classic cmd_get counts 70 lookups");
is($stats->{cmd_set}, 50, "classic cmd_set counts 50 stores");
is($stats->{get_hits}, 50, "classic get_hits counts 50 hits");
is($stats->{get_misses}, 20, "classic get_misses counts 20 misses");

# Byte counters must be monotonic and only differ by the follow-up query.
ok($counters->{"bytes_read:value"} <= $stats->{bytes_read},
   "bytes_read counters view is not ahead of classic stats");
ok($counters->{"bytes_written:value"} <= $stats->{bytes_written},
   "bytes_written counters view is not ahead of classic stats");
ok($counters->{"bytes_read:value"} > 0, "bytes_read grew during workload");
ok($counters->{"bytes_written:value"} > 0,
   "bytes_written grew during workload");

# No saturation under normal traffic.
for my $field (@counter_fields) {
    is($counters->{"$field:overflow_events"}, 0,
       "$field records no overflow event");
}

# Time-windowed growth.
is($counters->{"cmd_get:window_delta"}, 70, "cmd_get window delta is 70");
is($counters->{"cmd_set:window_delta"}, 50, "cmd_set window delta is 50");
is($counters->{"get_misses:window_delta"}, 20,
   "get_misses window delta is 20");
cmp_ok($counters->{"cmd_get:window_seconds"}, '>=', 1,
       "cmd_get window spans at least one second");
is($counters->{"cmd_get:rate_per_sec"}, 70, "cmd_get rate is 70 per second");
for my $field (@counter_fields) {
    unlike($counters->{"$field:eta_seconds"}, qr/^unknown$/,
           "$field ETA is numeric while growing");
}

# Existing reset behaviour must be preserved.
print $sock "stats reset\r\n";
is(scalar <$sock>, "RESET\r\n", "stats reset still returns RESET");
my $reset_stats = mem_stats($sock);
is($reset_stats->{cmd_get}, 0, "classic cmd_get reset to zero");
my $reset_counters = mem_stats($sock, "counters");
is($reset_counters->{"cmd_get:value"}, 0,
   "counters view reset alongside classic stats");
is($reset_counters->{"cmd_get:overflow_events"}, 0,
   "overflow bookkeeping cleared on reset");

done_testing();
