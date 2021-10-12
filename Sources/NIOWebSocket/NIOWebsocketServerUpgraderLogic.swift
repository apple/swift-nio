//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import CNIOSHA1
import NIOHTTP1

struct NIOWebsocketServerUpgraderLogic {
    static func generateUpgradeHeaders(key: String, headers: inout HTTPHeaders) {
        // Cool, we're good to go! Let's do our upgrade. We do this by concatenating the magic
        // GUID to the base64-encoded key and taking a SHA1 hash of the result.
        let acceptValue: String
        do {
            var hasher = SHA1()
            hasher.update(string: key)
            hasher.update(string: magicWebSocketGUID)
            acceptValue = String(base64Encoding: hasher.finish())
        }

        headers.replaceOrAdd(name: "Upgrade", value: "websocket")
        headers.add(name: "Sec-WebSocket-Accept", value: acceptValue)
        headers.replaceOrAdd(name: "Connection", value: "upgrade")
    }
    
    static func getWebsocketKeyVersion(from upgradeRequest: HTTPRequestHead) throws -> (String, String) {
        let key = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Key")
        let version = try upgradeRequest.headers.nonListHeader("Sec-WebSocket-Version")
        return (key, version)
    }
}
