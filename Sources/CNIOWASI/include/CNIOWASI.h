#pragma once

#if __wasi__

#include <time.h>

static inline void CNIOWASI_gettime(struct timespec *tv) {
    // ClangImporter doesn't support `CLOCK_MONOTONIC` declaration in WASILibc, thus we have to define a bridge manually
	clock_gettime(CLOCK_MONOTONIC, tv);
}

#endif