//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#include <atomic-counter.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define MAKE_COUNTER(name) /*
*/ _Atomic long g_ ## name ## _counter = ATOMIC_VAR_INIT(0); /*
*/ void inc_ ## name ## _counter(void) { /*
*/    atomic_fetch_add_explicit(&g_ ## name ## _counter, 1, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ void add_ ## name ## _counter(intptr_t v) { /*
*/    atomic_fetch_add_explicit(&g_ ## name ## _counter, v, memory_order_relaxed); /*
*/ } /*
*/ void reset_ ## name ## _counter(void) { /*
*/     atomic_store_explicit(&g_ ## name ## _counter, 0, memory_order_relaxed); /*
*/ } /*
*/ /*
*/ intptr_t read_ ## name ## _counter(void) { /*
*/     return atomic_load_explicit(&g_ ## name ## _counter, memory_order_relaxed); /*
*/ }

MAKE_COUNTER(free)
MAKE_COUNTER(malloc)
MAKE_COUNTER(malloc_bytes)

// This section covers tracking leaked FDs.
//
// We do this by recording which FD has been set in a queue. A queue is a bad data structure here,
// but using a better one requires writing too much code, and the performance impact here is not
// going to be too bad.
typedef struct {
    size_t capacity;
    size_t count;
    int *allocatedFDs;
} FDTracker;

static _Bool FDTracker_search_fd(const FDTracker *tracker, int fd, size_t *foundIndex) {
    if (tracker == NULL) { return false; }

    for (size_t i = 0; i < tracker->count; i++) {
        if (tracker->allocatedFDs[i] == fd) {
            if (foundIndex != NULL) { 
                *foundIndex = i;
            }
            return true;
        }
    }

    return false;
}

static void FDTracker_remove_at_index(FDTracker *tracker, size_t index) {
    assert(tracker != NULL);
    assert(index < tracker->count);

    // Shuffle everything down by 1 from index onwards.
    const size_t lastValidTargetIndex = tracker->count - 1;
    for (size_t i = index; i < lastValidTargetIndex; i++) {
        tracker->allocatedFDs[i] = tracker->allocatedFDs[i + 1];
    }
    tracker->count--;
}

_Atomic _Bool is_tracking = ATOMIC_VAR_INIT(false);
pthread_mutex_t tracker_lock = PTHREAD_MUTEX_INITIALIZER;
FDTracker tracker = { 0 };

void begin_tracking_fds(void) {
    int rc = pthread_mutex_lock(&tracker_lock);
    assert(rc == 0);

    assert(tracker.capacity == 0);
    assert(tracker.count == 0);
    assert(tracker.allocatedFDs == NULL);

    tracker.allocatedFDs = calloc(1024, sizeof(int));
    tracker.capacity = 1024;

    atomic_store_explicit(&is_tracking, true, memory_order_release);
    rc = pthread_mutex_unlock(&tracker_lock);
    assert(rc == 0);
}

void track_open_fd(int fd) {
    bool should_track = atomic_load_explicit(&is_tracking, memory_order_acquire);
    if (!should_track) { return; }

    int rc = pthread_mutex_lock(&tracker_lock);
    assert(rc == 0);

    // We need to not be tracking this FD already, or there's a correctness error.
    assert(!FDTracker_search_fd(&tracker, fd, NULL));

    // We want to append to the queue.
    if (tracker.capacity == tracker.count) {
        // Wuh-oh, resize. We do this by doubling.
        assert((tracker.capacity * sizeof(int)) < (SIZE_MAX / 2));
        size_t newCapacity = tracker.capacity * 2;
        int *new = realloc(tracker.allocatedFDs, newCapacity * sizeof(int));
        assert(new != NULL);
        tracker.allocatedFDs = new;
        tracker.capacity = newCapacity;
    }

    tracker.allocatedFDs[tracker.count] = fd;
    tracker.count++;

    rc = pthread_mutex_unlock(&tracker_lock);
    assert(rc == 0);
}

void track_closed_fd(int fd) {
    bool should_track = atomic_load_explicit(&is_tracking, memory_order_acquire);
    if (!should_track) { return; }

    int rc = pthread_mutex_lock(&tracker_lock);
    assert(rc == 0);

    size_t index;
    if (FDTracker_search_fd(&tracker, fd, &index)) {
        // We're tracking this FD, let's remove it.
        FDTracker_remove_at_index(&tracker, index);
    }

    rc = pthread_mutex_unlock(&tracker_lock);
    assert(rc == 0);
}

LeakedFDs stop_tracking_fds(void) {
    int rc = pthread_mutex_lock(&tracker_lock);
    assert(rc == 0);

    LeakedFDs result = {
        .count = tracker.count,
        .leaked = tracker.allocatedFDs
    };

    // Clear the tracker.
    tracker.allocatedFDs = NULL;
    tracker.capacity = 0;
    tracker.count = 0;

    atomic_store_explicit(&is_tracking, false, memory_order_release);
    rc = pthread_mutex_unlock(&tracker_lock);
    assert(rc == 0);

    return result;
}
