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

public protocol ChannelOption {
    associatedtype AssociatedValueType
    associatedtype OptionType
    
    var value: AssociatedValueType { get }
    var type: OptionType.Type { get }
}

extension ChannelOption {
    public var type: OptionType.Type {
        return OptionType.self
    }
}

extension ChannelOption where AssociatedValueType == () {
    public var value: () {
        return ()
    }
}

public enum SocketOption: ChannelOption {
    public typealias AssociatedValueType = (Int, Int32)

    public typealias OptionType = (Int)
    
    case const(AssociatedValueType)
    
    public init(level: Int, name: Int32) {
        self = .const((level, name))
    }

    public var value: (Int, Int32) {
        switch self {
        case .const(let level, let name):
            return (level, name)
        }
    }
}

public enum AllocatorOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = ByteBufferAllocator
    
    case const(())
}

public enum RecvAllocatorOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = RecvByteBufferAllocator
    
    case const(())
}

public enum AutoReadOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = Bool
    
    case const(())
}

public enum MaxMessagesPerReadOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = UInt
    
    case const(())
}

public enum BacklogOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = Int32
    
    case const(())
}

public struct ChannelOptions {
#if os(Linux)
    public static let Socket = { (level: Int, name: Int32) -> SocketOption in .const((level, name)) }
#else
    public static let Socket = { (level: Int32, name: Int32) -> SocketOption in .const((Int(level), name)) }
#endif
    public static let Allocator = AllocatorOption.const(())
    public static let RecvAllocator = RecvAllocatorOption.const(())
    public static let AutoRead = AutoReadOption.const(())
    public static let MaxMessagesPerRead = MaxMessagesPerReadOption.const(())
    public static let Backlog = BacklogOption.const(())
}
