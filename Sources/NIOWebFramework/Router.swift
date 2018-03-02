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

public protocol Responder {
    func respond() -> String
}

public struct RouteResponder<T>: Responder where T: Encodable
{
    public typealias Handler = () -> T
    
    public let handler: Handler
    
    public init(handler: @escaping Handler) {
        self.handler = handler
    }
    
    public func respond() -> String {
        let encodable = handler()
        let data = try! JSONEncoder().encode(encodable)
        return String(data: data, encoding: .utf8)!
    }
}

class Router {
    var routingTable = [String : Responder]()
    
    func get<T: Encodable>(_ route: String, handler: @escaping () -> T) {
        let rr = RouteResponder<T>(handler: handler)
        routingTable[route] = rr
    }
}