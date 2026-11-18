#include "counter.h"

#include <pthread.h>
#include <string.h>

struct mc_registry_slot {
    bool          used;
    mc_counter_t  counter;
};

static struct mc_registry_slot registry[MC_COUNTER_REGISTRY_MAX];
static pthread_mutex_t registry_lock = PTHREAD_MUTEX_INITIALIZER;

uint64_t mc_width_limit(mc_width_t width) {
    switch (width) {
    case MC_WIDTH_U8:
        return UINT8_MAX;
    case MC_WIDTH_U16:
        return UINT16_MAX;
    case MC_WIDTH_U32:
        return UINT32_MAX;
    case MC_WIDTH_U64:
        return UINT64_MAX;
    }
    return 0;
}

const char *mc_width_name(mc_width_t width) {
    switch (width) {
    case MC_WIDTH_U8:
        return "u8";
    case MC_WIDTH_U16:
        return "u16";
    case MC_WIDTH_U32:
        return "u32";
    case MC_WIDTH_U64:
        return "u64";
    }
    return "unknown";
}

void mc_counter_init(mc_counter_t *counter, const char *name, mc_width_t width) {
    memset(counter, 0, sizeof(*counter));
    pthread_mutex_init(&counter->lock, NULL);
    counter->width = width;
    counter->limit = mc_width_limit(width);
    if (name != NULL) {
        strncpy(counter->name, name, sizeof(counter->name) - 1);
        counter->name[sizeof(counter->name) - 1] = '\0';
    }
}

bool mc_counter_add(mc_counter_t *counter, uint64_t amount) {
    bool overflowed = false;

    if (counter == NULL) {
        return false;
    }

    pthread_mutex_lock(&counter->lock);
    if (amount > counter->limit - counter->value) {
        /* Saturate instead of wrapping and latch the event. */
        counter->value = counter->limit;
        counter->overflow_events++;
        overflowed = true;
    } else {
        counter->value += amount;
    }
    pthread_mutex_unlock(&counter->lock);

    return overflowed;
}

bool mc_counter_observe(mc_counter_t *counter, uint64_t absolute) {
    bool overflowed = false;

    if (counter == NULL) {
        return false;
    }

    pthread_mutex_lock(&counter->lock);
    if (absolute < counter->value) {
        /* The externally owned value moved backwards: its narrow storage
         * wrapped. Latch it and keep our own value monotonic. */
        counter->overflow_events++;
        overflowed = true;
    } else if (absolute > counter->limit) {
        counter->value = counter->limit;
        counter->overflow_events++;
        overflowed = true;
    } else {
        counter->value = absolute;
    }
    pthread_mutex_unlock(&counter->lock);

    return overflowed;
}

void mc_counter_sample(mc_counter_t *counter, time_t now,
                       struct mc_counter_sample *out) {
    if (counter == NULL || out == NULL) {
        return;
    }

    pthread_mutex_lock(&counter->lock);

    strncpy(out->name, counter->name, sizeof(out->name) - 1);
    out->name[sizeof(out->name) - 1] = '\0';
    out->width = counter->width;
    out->limit = counter->limit;
    out->overflow_events = counter->overflow_events;
    out->value = counter->value;
    out->headroom = counter->limit - counter->value;

    if (!counter->has_baseline) {
        counter->has_baseline = true;
        counter->last_sample_time = now;
        counter->last_sample_value = counter->value;
        out->window_delta = 0;
        out->window_seconds = 0;
        out->rate_per_sec = 0;
        out->eta_seconds = UINT64_MAX;
        pthread_mutex_unlock(&counter->lock);
        return;
    }

    time_t elapsed = now - counter->last_sample_time;
    if (elapsed < 0) {
        elapsed = 0;
    }
    out->window_seconds = (uint64_t)elapsed;
    /* Stored values are monotonic, so this difference can never go negative. */
    out->window_delta = counter->value - counter->last_sample_value;
    out->rate_per_sec = elapsed > 0 ? out->window_delta / (uint64_t)elapsed : 0;

    if (out->headroom == 0 || out->rate_per_sec == 0) {
        out->eta_seconds = UINT64_MAX;
    } else {
        /* Ceiling division: round the predicted fill time up. */
        out->eta_seconds = (out->headroom + out->rate_per_sec - 1)
                         / out->rate_per_sec;
    }

    counter->last_sample_time = now;
    counter->last_sample_value = counter->value;

    pthread_mutex_unlock(&counter->lock);
}

const char *mc_counter_name(const mc_counter_t *counter) {
    return counter != NULL ? counter->name : "";
}

mc_width_t mc_counter_width(const mc_counter_t *counter) {
    return counter != NULL ? counter->width : 0;
}

uint64_t mc_counter_value(const mc_counter_t *counter) {
    return counter != NULL ? counter->value : 0;
}

uint64_t mc_counter_limit(const mc_counter_t *counter) {
    return counter != NULL ? counter->limit : 0;
}

uint64_t mc_counter_overflow_events(const mc_counter_t *counter) {
    return counter != NULL ? counter->overflow_events : 0;
}

bool mc_counter_overflowed(const mc_counter_t *counter) {
    return counter != NULL && counter->overflow_events > 0;
}

uint64_t mc_counter_delta(uint64_t older, uint64_t newer) {
    return newer >= older ? newer - older : 0;
}

void mc_registry_init(void) {
    pthread_mutex_lock(&registry_lock);
    memset(registry, 0, sizeof(registry));
    pthread_mutex_unlock(&registry_lock);
}

mc_counter_t *mc_registry_register(const char *name, mc_width_t width) {
    mc_counter_t *result = NULL;

    if (name == NULL || name[0] == '\0' || mc_width_limit(width) == 0) {
        return NULL;
    }

    pthread_mutex_lock(&registry_lock);
    for (size_t i = 0; i < MC_COUNTER_REGISTRY_MAX; i++) {
        if (registry[i].used
            && strncmp(registry[i].counter.name, name,
                       MC_COUNTER_NAME_MAX) == 0) {
            pthread_mutex_unlock(&registry_lock);
            return NULL;
        }
    }
    for (size_t i = 0; i < MC_COUNTER_REGISTRY_MAX; i++) {
        if (!registry[i].used) {
            registry[i].used = true;
            mc_counter_init(&registry[i].counter, name, width);
            result = &registry[i].counter;
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);

    return result;
}

mc_counter_t *mc_registry_find(const char *name) {
    mc_counter_t *result = NULL;

    if (name == NULL) {
        return NULL;
    }

    pthread_mutex_lock(&registry_lock);
    for (size_t i = 0; i < MC_COUNTER_REGISTRY_MAX; i++) {
        if (registry[i].used
            && strncmp(registry[i].counter.name, name,
                       MC_COUNTER_NAME_MAX) == 0) {
            result = &registry[i].counter;
            break;
        }
    }
    pthread_mutex_unlock(&registry_lock);

    return result;
}

size_t mc_registry_count(void) {
    size_t count = 0;

    pthread_mutex_lock(&registry_lock);
    for (size_t i = 0; i < MC_COUNTER_REGISTRY_MAX; i++) {
        if (registry[i].used) {
            count++;
        }
    }
    pthread_mutex_unlock(&registry_lock);

    return count;
}

size_t mc_registry_snapshot(struct mc_counter_sample *out, size_t max, time_t now) {
    size_t written = 0;

    pthread_mutex_lock(&registry_lock);
    for (size_t i = 0; i < MC_COUNTER_REGISTRY_MAX && written < max; i++) {
        if (!registry[i].used) {
            continue;
        }
        mc_counter_sample(&registry[i].counter, now, &out[written]);
        written++;
    }
    pthread_mutex_unlock(&registry_lock);

    return written;
}
