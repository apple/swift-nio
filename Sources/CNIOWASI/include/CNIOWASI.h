//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) YEARS Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#pragma once

#if __wasi__

#include <fcntl.h>
#include <time.h>

static inline void CNIOWASI_gettime(struct timespec *tv) {
    // ClangImporter doesn't support `CLOCK_MONOTONIC` declaration in WASILibc, thus we have to define a bridge manually
    clock_gettime(CLOCK_MONOTONIC, tv);
}

static inline int CNIOWASI_O_CREAT() {
    // ClangImporter doesn't support `O_CREATE` declaration in WASILibc, thus we have to define a bridge manually
    return O_CREAT;
}

#endif
