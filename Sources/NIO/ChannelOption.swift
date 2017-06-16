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

public typealias SocketOptionName = Int32
#if os(Linux)
    public typealias SocketOptionLevel = Int
    public typealias SocketOptionValue = Int
#else
    public typealias SocketOptionLevel = Int32
    public typealias SocketOptionValue = Int32
#endif

public enum SocketOption: ChannelOption {
    public typealias AssociatedValueType = (SocketOptionLevel, SocketOptionName)

    public typealias OptionType = (SocketOptionValue)
    
    case const(AssociatedValueType)
    
    public init(level: SocketOptionLevel, name: SocketOptionName) {
        self = .const((level, name))
    }

    public var value: (SocketOptionLevel, SocketOptionName) {
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

public enum WriteSpinOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = UInt
    
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

public typealias WriteBufferWaterMark = Range<UInt32>

public enum WriteBufferWaterMarkOption: ChannelOption {
    public typealias AssociatedValueType = ()
    public typealias OptionType = WriteBufferWaterMark
    
    case const(())
}

public struct ChannelOptions {
    public static let Socket = { (level: SocketOptionLevel, name: SocketOptionName) -> SocketOption in .const((level, name)) }
    public static let Allocator = AllocatorOption.const(())
    public static let RecvAllocator = RecvAllocatorOption.const(())
    public static let AutoRead = AutoReadOption.const(())
    public static let MaxMessagesPerRead = MaxMessagesPerReadOption.const(())
    public static let Backlog = BacklogOption.const(())
    public static let WriteSpin = WriteSpinOption.const(())
    public static let WriteBufferWaterMark = WriteBufferWaterMarkOption.const(())
}
