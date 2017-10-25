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

import NIO
import CNIOOpenSSL

private let SSL_MAX_RECORD_SIZE = 16 * 1024;

enum AsyncOperationResult<T> {
    case incomplete
    case complete(T)
    case failed(OpenSSLError)
}

// TODO(cory): This should definitely be a struct, but if it is we cannot use a deinitializer to clean up
// resources. What's the Swift idiom for managing lifetimes?
internal final class SSLConnection {
    private let ssl: UnsafeMutablePointer<SSL>
    private let parentContext: SSLContext
    private let fromNetwork: UnsafeMutablePointer<BIO>
    private let toNetwork: UnsafeMutablePointer<BIO>
    
    init? (_ ssl: UnsafeMutablePointer<SSL>, parentContext: SSLContext) {
        self.ssl = ssl
        self.parentContext = parentContext
        
        let fromNetwork = BIO_new(BIO_s_mem())
        let toNetwork = BIO_new(BIO_s_mem())
        
        guard (fromNetwork != nil) && (toNetwork != nil) else {
            // TODO(cory): I don't love having this cleanup here, it means I have to remember it.
            SSL_free(ssl)
            return nil
        }
        
        self.fromNetwork = fromNetwork!
        self.toNetwork = toNetwork!
        SSL_set_bio(self.ssl, self.fromNetwork, self.toNetwork)
    }
    
    deinit {
        SSL_free(ssl)
    }
    
    func setAcceptState() {
        SSL_set_accept_state(ssl)
    }
    
    func setConnectState() {
        SSL_set_connect_state(ssl)
    }

    func setSNIServerName(name: String) throws {
        ERR_clear_error()
        let rc = name.withCString {
            return CNIOOpenSSL_SSL_set_tlsext_host_name(ssl, $0)
        }
        guard rc == 1 else {
            throw OpenSSLError.invalidSNIName(OpenSSLError.buildErrorStack())
        }
    }
    
    func doHandshake() -> AsyncOperationResult<Int32> {
        ERR_clear_error()
        let rc = SSL_do_handshake(ssl)
        
        if (rc == 1) { return .complete(rc) }
            
        guard (rc != 1) else { return .complete(rc) }
        
        let result = SSL_get_error(ssl, rc)
        let error = OpenSSLError.fromSSLGetErrorResult(result)!
        
        switch error {
        case .wantRead,
             .wantWrite:
            return .incomplete
        default:
            return .failed(error)
        }
    }
    
    func doShutdown() -> AsyncOperationResult<Int32> {
        ERR_clear_error()
        let rc = SSL_shutdown(ssl)
        
        switch rc {
        case 1:
            return .complete(rc)
        case 0:
            return .incomplete
        default:
            let result = SSL_get_error(ssl, rc)
            let error = OpenSSLError.fromSSLGetErrorResult(result)!
            
            switch error {
            case .wantRead,
                 .wantWrite:
                return .incomplete
            default:
                return .failed(error)
            }
        }
    }
    
    // Note that this function has no return value. This is because there is as-yet no notion of
    // a BIO with bounded buffer size, so this will always succeed.
    func consumeDataFromNetwork(_ data: inout ByteBuffer) {
        let consumedBytes = data.withUnsafeReadableBytes { (pointer) -> Int32 in
            let bytesWritten = BIO_write(self.fromNetwork, pointer.baseAddress, Int32(pointer.count))
            assert(bytesWritten == pointer.count)
            return bytesWritten
        }
        
        data.moveReaderIndex(forwardBy: Int(consumedBytes))
    }
    
    func getDataForNetwork(allocator: ByteBufferAllocator) -> ByteBuffer? {
        let bufferedBytes = BIO_ctrl_pending(toNetwork)
        if bufferedBytes == 0 {
            return nil
        }
        
        var outputBuffer = allocator.buffer(capacity: bufferedBytes)
        let writtenBytes = outputBuffer.writeWithUnsafeMutableBytes { (pointer) -> Int in
            let rc = BIO_read(toNetwork, pointer.baseAddress, Int32(pointer.count))
            assert(rc > 0)
            return Int(rc)
        }
        assert(writtenBytes == bufferedBytes) // I can't see how this would fail, but...it might!
        return outputBuffer
    }
    
    func readDataFromNetwork(allocator: ByteBufferAllocator, size: Int) -> AsyncOperationResult<ByteBuffer> {
        var outputBuffer = allocator.buffer(capacity: size)
        
        // TODO(cory): It would be nice to have an withUnsafeMutableWriteableBytes here, but we don't, so we
        // need to make do with writeWithUnsafeMutableBytes instead. The core issue is that we can't
        // safely return any of the error values that SSL_read might provide here because writeWithUnsafeMutableBytes
        // will try to use that as the number of bytes written and blow up. If we could prevent it doing that (which
        // we can with reading) that would be grand, but we can't, so instead we need to use a temp variable. Not ideal.
        var bytesRead: Int32 = 0
        let _ = outputBuffer.writeWithUnsafeMutableBytes { (pointer) -> Int in
            bytesRead = SSL_read(self.ssl, pointer.baseAddress, Int32(pointer.count))
            return bytesRead >= 0 ? Int(bytesRead) : 0
        }
        
        if bytesRead > 0 {
            return .complete(outputBuffer)
        } else {
            let result = SSL_get_error(ssl, Int32(bytesRead))
            let error = OpenSSLError.fromSSLGetErrorResult(result)!
            
            switch error {
            case .wantRead,
                 .wantWrite:
                return .incomplete
            default:
                return .failed(error)
            }
        }
    }
    
    func readDataFromNetwork(allocator: ByteBufferAllocator) -> AsyncOperationResult<ByteBuffer> {
        return readDataFromNetwork(allocator: allocator, size: SSL_MAX_RECORD_SIZE)
    }
    
    func writeDataToNetwork(_ data: inout ByteBuffer) -> AsyncOperationResult<Int32> {
        let writtenBytes = data.withUnsafeReadableBytes { (pointer) -> Int32 in
            return SSL_write(ssl, pointer.baseAddress, Int32(pointer.count))
        }
        
        if writtenBytes > 0 {
            // The default behaviour of SSL_write is to only return once *all* of the data has been written,
            // unless the underlying BIO cannot satisfy the need (in which case WANT_WRITE will be returned).
            // We're using memory BIOs, which are always writable, so WANT_WRITE cannot fire so we'd always
            // expect this to write the complete quantity of readable bytes in our buffer.
            precondition(writtenBytes == data.readableBytes)
            data.moveReaderIndex(forwardBy: Int(writtenBytes))
            return .complete(writtenBytes)
        } else {
            let result = SSL_get_error(ssl, writtenBytes)
            let error = OpenSSLError.fromSSLGetErrorResult(result)!
            
            switch error {
            case .wantRead, .wantWrite:
                return .incomplete
            default:
                return .failed(error)
            }
        }
    }
}
