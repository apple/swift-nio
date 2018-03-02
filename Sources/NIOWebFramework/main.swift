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
import Foundation

struct User : Codable {
    let firstName: String
    let lastName: String
    let id: Int
}

let users = [User(firstName: "John", lastName: "Doe", id: 0),
             User(firstName: "Jane", lastName: "Doe", id: 1)]

let router = Router()

router.get("/users") {
    return users
}

router.get("/user/0") {
    return users[0]
}

let server = Server(host: "::1", port: 8888, with: router)

server.run()

print("Server closed")
