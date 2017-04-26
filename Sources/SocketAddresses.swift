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

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    import Darwin
#elseif os(Linux)
    import Glibc
#endif

public class SocketAddresses {
    public class func newAddress(for host: String, on port: Int32) -> SocketAddress? {
        var info: UnsafeMutablePointer<addrinfo>?
        
        if getaddrinfo(host, String(port), nil, &info) != 0 {
            return nil
        }
        
        defer {
            if info != nil {
                freeaddrinfo(info)
            }
        }
        
        if info!.pointee.ai_family == Int32(AF_INET) {
            var addr = sockaddr_in()
            memcpy(&addr, info!.pointee.ai_addr, Int(MemoryLayout<sockaddr_in>.size))
            return .v4(address: addr)
            
        }
        
        if info!.pointee.ai_family == Int32(AF_INET6) {
            var addr = sockaddr_in6()
            memcpy(&addr, info!.pointee.ai_addr, Int(MemoryLayout<sockaddr_in6>.size))
            return .v6(address: addr)
        }
        return nil
    }
    
}


public enum SocketAddress {
    case v4(address: sockaddr_in)
    case v6(address: sockaddr_in6)
    
    
    /// Size of address. (Readonly)
    ///
    public var size: Int {
        
        switch self {
            
        case .v4( _):
            return MemoryLayout<(sockaddr_in)>.size
        case .v6( _):
            return MemoryLayout<(sockaddr_in6)>.size
        }
    }
    
    ///
    /// Cast as sockaddr. (Readonly)
    ///
    public var addr: sockaddr {
        switch self {
        case .v4(let addr):
            return addr.asAddr()
            
        case .v6(let addr):
            return addr.asAddr()
        }
    }
    
    public var host: String {
        return self.host
    }
    
    public var port: Int32 {
        return self.port
    }
}


// MARK: sockaddr_in Extension
public extension sockaddr_in {
    
    ///
    /// Cast to sockaddr
    ///
    /// - Returns: sockaddr
    ///
    public func asAddr() -> sockaddr {
        
        var temp = self
        let addr = withUnsafePointer(to: &temp) {
            return UnsafeRawPointer($0)
        }
        return addr.assumingMemoryBound(to: sockaddr.self).pointee
    }
}

// MARK: sockaddr_in6 Extension
public extension sockaddr_in6 {
    
    ///
    /// Cast to sockaddr
    ///
    /// - Returns: sockaddr
    ///
    public func asAddr() -> sockaddr {
        
        var temp = self
        let addr = withUnsafePointer(to: &temp) {
            return UnsafeRawPointer($0)
        }
        return addr.assumingMemoryBound(to: sockaddr.self).pointee
    }
}

