#ifndef COUNTER_H
#define COUNTER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <time.h>
#include <pthread.h>

/*
 * Safe monotonic counters.
 *
 * A narrow (for example uint8_t) counter silently wraps back to zero once it
 * passes its natural limit. Any ratio derived from two such counters (hit
 * rate = hits / lookups, ...) can then go negative, because the numerator may
 * have wrapped while the denominator has not. This module stores every value
 * in uint64_t but keeps the *declared* width of the counter so that:
 *
 *   - the type is chosen for the real traffic magnitude (see mc_width_t);
 *   - reaching the declared limit saturates instead of wrapping, and the
 *     overflow is latched and counted so it can be discovered;
 *   - periodic samples provide a time-windowed growth rate and an estimate of
 *     when the counter would hit its limit.
 *
 * The counter value itself is always monotonic: it never decreases and never
 * wraps. Existing statistics fields keep their exact name and semantics; this
 * module only adds observability around them.
 */

#define MC_COUNTER_NAME_MAX 64

/* Declared magnitude of a counter. The storage is always uint64_t; the width
 * only defines the saturation limit and the overflow bookkeeping. */
typedef enum {
    MC_WIDTH_U8  = 1,  /* up to 2^8  - 1   (255)                 */
    MC_WIDTH_U16 = 2,  /* up to 2^16 - 1   (65 535)              */
    MC_WIDTH_U32 = 4,  /* up to 2^32 - 1   (4 294 967 295)       */
    MC_WIDTH_U64 = 8   /* up to 2^64 - 1   (18 446 744 073 709 551 615) */
} mc_width_t;

typedef struct mc_counter {
    char            name[MC_COUNTER_NAME_MAX];
    mc_width_t      width;
    uint64_t        limit;
    uint64_t        value;
    uint64_t        overflow_events;
    time_t          last_sample_time;
    uint64_t        last_sample_value;
    bool            has_baseline;
    pthread_mutex_t lock;
} mc_counter_t;

struct mc_counter_sample {
    char           name[MC_COUNTER_NAME_MAX];
    mc_width_t     width;
    uint64_t value;              /* value at sample time                       */
    uint64_t limit;              /* declared width maximum                     */
    uint64_t overflow_events;    /* number of saturating / wrapping events     */
    uint64_t window_delta;       /* value growth since the previous sample     */
    time_t   window_seconds;     /* elapsed time since the previous sample     */
    uint64_t rate_per_sec;       /* window_delta / window_seconds (rounded)    */
    uint64_t headroom;           /* limit - value                              */
    /* Seconds until the limit at the current window rate. UINT64_MAX means
     * "never" (rate is zero) or "already saturated" (headroom is zero). */
    uint64_t eta_seconds;
};

/* Returns the natural maximum for a declared width, 0 for an unknown width. */
uint64_t mc_width_limit(mc_width_t width);

/* Human readable width name ("u8", "u16", ...), "unknown" on bad input. */
const char *mc_width_name(mc_width_t width);

/* Initialise a counter. name is copied; limit is derived from width. */
void mc_counter_init(mc_counter_t *counter, const char *name, mc_width_t width);

/* Saturating add. The internal uint64_t never wraps; increments that would
 * cross the declared width limit are clamped to the limit and each clamped
 * increment is recorded as an overflow event. Returns true on overflow. */
bool mc_counter_add(mc_counter_t *counter, uint64_t amount);

/* Observation variant: set the counter to an externally maintained absolute
 * value (for counters owned by another subsystem). The stored value only
 * moves forward, and a source value that is smaller than the stored value is
 * treated as evidence that the source wrapped, which is latched as an
 * overflow. Returns true when overflow/wrap was detected. */
bool mc_counter_observe(mc_counter_t *counter, uint64_t absolute);

/* Take a time-windowed sample. now is usually time(NULL), but takes an
 * explicit clock so tests are deterministic. The first sample establishes the
 * baseline and reports a zero rate. */
void mc_counter_sample(mc_counter_t *counter, time_t now,
                       struct mc_counter_sample *out);

/* Accessors (values are plain reads; the counters are monotonic). */
const char *mc_counter_name(const mc_counter_t *counter);
mc_width_t mc_counter_width(const mc_counter_t *counter);
uint64_t mc_counter_value(const mc_counter_t *counter);
uint64_t mc_counter_limit(const mc_counter_t *counter);
uint64_t mc_counter_overflow_events(const mc_counter_t *counter);
bool mc_counter_overflowed(const mc_counter_t *counter);

/* Wrap-safe difference between two monotonic samples. Returns 0 when the
 * newer value is not greater than the older one, so derived ratios can never
 * go negative even if an underlying narrow counter wrapped. */
uint64_t mc_counter_delta(uint64_t older, uint64_t newer);

/*
 * Global registry, exposed through the "stats counters" text subcommand.
 * The registry owns the mc_counter_t storage (a fixed-size table); names must
 * be unique. All functions are thread safe.
 */
#define MC_COUNTER_REGISTRY_MAX 64

void mc_registry_init(void);

/* Registers a counter under name; returns the registered counter or NULL when
 * the table is full or the name is duplicated/empty. */
mc_counter_t *mc_registry_register(const char *name, mc_width_t width);
mc_counter_t *mc_registry_find(const char *name);
size_t mc_registry_count(void);

/* Snapshot the registry into out (up to max entries) and return the number
 * written. Samples are taken inside the same critical section so the reported
 * rates are mutually consistent. */
size_t mc_registry_snapshot(struct mc_counter_sample *out, size_t max, time_t now);

#endif
