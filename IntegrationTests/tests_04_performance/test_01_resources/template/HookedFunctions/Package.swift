// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "HookedFunctions",
    products: [
        .library(name: "HookedFunctions", type: .dynamic, targets: ["HookedFunctions"]),
    ],
    dependencies: [
        .package(url: "../AtomicCounter/", .branch("master")),
    ],
    targets: [
        .target(name: "HookedFunctions", dependencies: ["AtomicCounter"]),
    ]
)
