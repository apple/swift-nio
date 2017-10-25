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

public struct NIOAny {
    private let storage: _NIOAny
    public init<T>(_ value: T) {
        self.storage = _NIOAny(value)
    }
    
    enum _NIOAny {
        case ioData(IOData)
        case other(Any)
        
        init<T>(_ value: T) {
            switch value {
            case is ByteBuffer:
                self = .ioData(.byteBuffer(value as! ByteBuffer))
            case is FileRegion:
                self = .ioData(.fileRegion(value as! FileRegion))
            case is IOData:
                self = .ioData(value as! IOData)
            default:
                self = .other(value)
            }
        }
        
    }
    
    func tryAsByteBuffer() -> ByteBuffer? {
        if case .ioData(.byteBuffer(let bb)) = self.storage {
            return bb
        } else {
            return nil
        }
    }
    
    func forceAsByteBuffer() -> ByteBuffer {
        if let v = tryAsByteBuffer() {
            return v
        } else {
            fatalError("tried to decode as type \(ByteBuffer.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsIOData() -> IOData? {
        if case .ioData(let data) = self.storage {
            return data
        } else {
            return nil
        }
    }
    
    func forceAsIOData() -> IOData {
        if let v = tryAsIOData() {
            return v
        } else {
            fatalError("tried to decode as type \(IOData.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsFileRegion() -> FileRegion? {
        if case .ioData(.fileRegion(let f)) = self.storage {
            return f
        } else {
            return nil
        }
    }
    
    func forceAsFileRegion() -> FileRegion {
        if let v = tryAsFileRegion() {
            return v
        } else {
            fatalError("tried to decode as type \(FileRegion.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func tryAsOther<T>(type: T.Type = T.self) -> T? {
        if case .other(let any) = self.storage {
            return any as? T
        } else {
            return nil
        }
    }
    
    func forceAsOther<T>(type: T.Type = T.self) -> T {
        if let v = tryAsOther(type: type) {
            return v
        } else {
            fatalError("tried to decode as type \(T.self) but found \(Mirror(reflecting: Mirror(reflecting: self.storage).children.first!.value).subjectType)")
        }
    }
    
    func forceAs<T>(type: T.Type = T.self) -> T {
        if T.self == ByteBuffer.self {
            return self.forceAsByteBuffer() as! T
        } else if T.self == FileRegion.self {
            return self.forceAsFileRegion() as! T
        } else if T.self == IOData.self {
            return self.forceAsIOData() as! T
        } else {
            return self.forceAsOther(type: type)
        }
    }
    
    func tryAs<T>(type: T.Type = T.self) -> T? {
        if T.self == ByteBuffer.self {
            return self.tryAsByteBuffer() as! T?
        } else if T.self == FileRegion.self {
            return self.tryAsFileRegion() as! T?
        } else if T.self == IOData.self {
            return self.tryAsIOData() as! T?
        } else {
            return self.tryAsOther(type: type)
        }
    }
    
    func asAny() -> Any {
        switch self.storage {
        case .ioData(.byteBuffer(let bb)):
            return bb
        case .ioData(.fileRegion(let f)):
            return f
        case .other(let o):
            return o
        }
    }
}
