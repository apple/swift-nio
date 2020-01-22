//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2020 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import NIO

internal class HookedSelector: NIO.Selector<NIORegistration> {
    override init() throws {
    }

    var registration: NIORegistration?

    override func register<S: Selectable>(selectable: S,
                                          interested: SelectorEventSet,
                                          makeRegistration: (SelectorEventSet) -> NIORegistration) throws {
        print("\(#function)")
        self.registration = makeRegistration(interested)
    }

    override func reregister<S: Selectable>(selectable: S, interested: SelectorEventSet) throws {
        print("\(#function) \(selectable) \(interested)")
    }

    override func whenReady(strategy: SelectorStrategy, _ body: (SelectorEvent<NIORegistration>) throws -> Void) throws -> Void {
        print("\(#function)")
        if let registration = self.registration {
            try body(.init(io: .readEOF, registration: registration))
        }
    }
}
