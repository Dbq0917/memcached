Multiget deadlines
==================

Background
----------

An ASCII multiget (`get k1 k2 ...`) can contain keys backed by asynchronous
storage. A single slow object used to hold the entire connection's response
open, so a client timeout forced a retry of every key in the batch. The keys
that had already been returned were fetched again.

Configuration
-------------

Batch deadlines are disabled by default:

    memcached -o get_timeout_ms=200

`get_timeout_ms` is the maximum time in milliseconds to wait for asynchronous
key fetches in one retrieval command. A value of `0` keeps the historical
behavior. Local (non-asynchronous) keys are not affected.

Response semantics
------------------

The wire format is unchanged. A timed out batch is still a normal response:

    VALUE <key> <flags> <bytes>\r\n
    <data>\r\n
    ...
    END\r\n

Keys whose fetches were still outstanding at the deadline are omitted, exactly
like cache misses. The server sends the remaining completed items and `END`
without waiting for the slow key. The set of keys that were not returned is the
retry set; clients should retry only those keys, not the original batch.

The deadline is opt-in, so existing clients and the default configuration keep
the previous command semantics and response format.

Audit records
-------------

Timed out keys are written to the standard fetcher log:

    $ memcached -o get_timeout_ms=200 -vv
    $ telnet ...
    watch fetchers
    OK
    ts=... gid=... type=item_get key=slow status=timeout clsid=0 cfd=... size=0

The following `stats` counters are also updated:

- `get_timeout`: retrieval commands that hit the deadline.
- `get_timeout_keys`: keys omitted across those commands.

Implementation notes
--------------------

- `get`, `gets`, `gat`, and `gats` share the batch path.
- Each asynchronous key already has its own response object. At the deadline,
  responses still waiting on extstore are detached from the client-facing chain
  and marked as timed out. Their IO is allowed to finish in the background and
  the response object is released when the IO returns.
- A separate `END` response object is created when deadlines are enabled, so a
  timeout on the final key cannot also remove the batch terminator.
- Extstore reads are submitted per key. This lets the extstore IO thread picker
  spread independent keys across IO threads; one slow read no longer parks the
  rest of a multiget in a single queue.

Reproducible test and latency
-----------------------------

The regression test injects a deterministic slow extstore read (debug builds
only) and runs the same batch twice:

    perl t/get-timeout.t

It asserts that:

- all fast keys are returned while the slow key is omitted;
- the slow key appears as `status=timeout` in the fetcher log;
- a retry of only the missing key succeeds;
- the retry performs one extstore read, not one per key in the original batch.

Example run from this workspace (81-key batch, one 800ms slow key):

| mode | keys returned | elapsed |
| --- | ---: | ---: |
| `get_timeout_ms=200` | 80/81, slow key omitted | 202.2 ms |
| deadlines disabled | 81/81, waits for slow key | 801.8 ms |

The test also prints these values on every run:

    multiget latency: deadline=200ms partial=202.2ms; no deadline=801.8ms full

Absolute timings vary with hardware and storage.
