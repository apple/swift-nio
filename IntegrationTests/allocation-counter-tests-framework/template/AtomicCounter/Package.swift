// swift-tools-version:5.0
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
    name: "AtomicCounter",
    products: [
        .library(name: "AtomicCounter", targets: ["AtomicCounter"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "AtomicCounter",
            dependencies: []
        ),
    ]
)
