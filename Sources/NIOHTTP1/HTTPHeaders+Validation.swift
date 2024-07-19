//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

extension String {
    /// Validates a given header field value against the definition in RFC 9110.
    ///
    /// The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
    /// characters as the following:
    ///
    /// ```
    /// field-value    = *field-content
    /// field-content  = field-vchar
    ///                  [ 1*( SP / HTAB / field-vchar ) field-vchar ]
    /// field-vchar    = VCHAR / obs-text
    /// obs-text       = %x80-FF
    /// ```
    ///
    /// Additionally, it makes the following note:
    ///
    /// "Field values containing CR, LF, or NUL characters are invalid and dangerous, due to the
    /// varying ways that implementations might parse and interpret those characters; a recipient
    /// of CR, LF, or NUL within a field value MUST either reject the message or replace each of
    /// those characters with SP before further processing or forwarding of that message. Field
    /// values containing other CTL characters are also invalid; however, recipients MAY retain
    /// such characters for the sake of robustness when they appear within a safe context (e.g.,
    /// an application-specific quoted string that will not be processed by any downstream HTTP
    /// parser)."
    ///
    /// As we cannot guarantee the context is safe, this code will reject all ASCII control characters
    /// directly _except_ for HTAB, which is explicitly allowed.
    fileprivate var isValidHeaderFieldValue: Bool {
        let fastResult = self.utf8.withContiguousStorageIfAvailable { ptr in
            ptr.allSatisfy { $0.isValidHeaderFieldValueByte }
        }
        if let fastResult = fastResult {
            return fastResult
        } else {
            return self.utf8._isValidHeaderFieldValue_slowPath
        }
    }

    /// Validates a given header field name against the definition in RFC 9110.
    ///
    /// The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
    /// characters as the following:
    ///
    /// ```
    /// field-name     = token
    ///
    /// token          = 1*tchar
    ///
    /// tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
    ///                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
    ///                / DIGIT / ALPHA
    ///                ; any VCHAR, except delimiters
    /// ```
    ///
    /// We implement this check directly.
    fileprivate var isValidHeaderFieldName: Bool {
        let fastResult = self.utf8.withContiguousStorageIfAvailable { ptr in
            ptr.allSatisfy { $0.isValidHeaderFieldNameByte }
        }
        if let fastResult = fastResult {
            return fastResult
        } else {
            return self.utf8._isValidHeaderFieldName_slowPath
        }
    }
}

extension String.UTF8View {
    /// The equivalent of `String.isValidHeaderFieldName`, but a slow-path when a
    /// contiguous UTF8 storage is not available.
    ///
    /// This is deliberately `@inline(never)`, as slow paths should be forcibly outlined
    /// to encourage inlining the fast-path.
    @inline(never)
    fileprivate var _isValidHeaderFieldName_slowPath: Bool {
        self.allSatisfy { $0.isValidHeaderFieldNameByte }
    }

    /// The equivalent of `String.isValidHeaderFieldValue`, but a slow-path when a
    /// contiguous UTF8 storage is not available.
    ///
    /// This is deliberately `@inline(never)`, as slow paths should be forcibly outlined
    /// to encourage inlining the fast-path.
    @inline(never)
    fileprivate var _isValidHeaderFieldValue_slowPath: Bool {
        self.allSatisfy { $0.isValidHeaderFieldValueByte }
    }
}

extension UInt8 {
    /// Validates a byte of a given header field name against the definition in RFC 9110.
    ///
    /// The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
    /// characters as the following:
    ///
    /// ```
    /// field-name     = token
    ///
    /// token          = 1*tchar
    ///
    /// tchar          = "!" / "#" / "$" / "%" / "&" / "'" / "*"
    ///                / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~"
    ///                / DIGIT / ALPHA
    ///                ; any VCHAR, except delimiters
    /// ```
    ///
    /// We implement this check directly.
    ///
    /// We use inline always here to force the check to be inlined, which it isn't always, leading to less optimal code.
    @inline(__always)
    fileprivate var isValidHeaderFieldNameByte: Bool {
        switch self {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),  // DIGIT
            UInt8(ascii: "a")...UInt8(ascii: "z"),
            UInt8(ascii: "A")...UInt8(ascii: "Z"),  // ALPHA
            UInt8(ascii: "!"), UInt8(ascii: "#"),
            UInt8(ascii: "$"), UInt8(ascii: "%"),
            UInt8(ascii: "&"), UInt8(ascii: "'"),
            UInt8(ascii: "*"), UInt8(ascii: "+"),
            UInt8(ascii: "-"), UInt8(ascii: "."),
            UInt8(ascii: "^"), UInt8(ascii: "_"),
            UInt8(ascii: "`"), UInt8(ascii: "|"),
            UInt8(ascii: "~"):

            return true

        default:
            return false
        }
    }

    /// Validates a byte of a given header field value against the definition in RFC 9110.
    ///
    /// The spec in [RFC 9110](https://httpwg.org/specs/rfc9110.html#fields.values) defines the valid
    /// characters as the following:
    ///
    /// ```
    /// field-value    = *field-content
    /// field-content  = field-vchar
    ///                  [ 1*( SP / HTAB / field-vchar ) field-vchar ]
    /// field-vchar    = VCHAR / obs-text
    /// obs-text       = %x80-FF
    /// ```
    ///
    /// Additionally, it makes the following note:
    ///
    /// "Field values containing CR, LF, or NUL characters are invalid and dangerous, due to the
    /// varying ways that implementations might parse and interpret those characters; a recipient
    /// of CR, LF, or NUL within a field value MUST either reject the message or replace each of
    /// those characters with SP before further processing or forwarding of that message. Field
    /// values containing other CTL characters are also invalid; however, recipients MAY retain
    /// such characters for the sake of robustness when they appear within a safe context (e.g.,
    /// an application-specific quoted string that will not be processed by any downstream HTTP
    /// parser)."
    ///
    /// As we cannot guarantee the context is safe, this code will reject all ASCII control characters
    /// directly _except_ for HTAB, which is explicitly allowed.
    ///
    /// We use inline always here to force the check to be inlined, which it isn't always, leading to less optimal code.
    @inline(__always)
    fileprivate var isValidHeaderFieldValueByte: Bool {
        switch self {
        case UInt8(ascii: "\t"):
            // HTAB, explicitly allowed.
            return true
        case 0...0x1f, 0x7F:
            // ASCII control character, forbidden.
            return false
        default:
            // Printable or non-ASCII, allowed.
            return true
        }
    }
}

extension HTTPHeaders {
    /// Whether these HTTPHeaders are valid to send on the wire.
    var areValidToSend: Bool {
        for (name, value) in self.headers {
            if !name.isValidHeaderFieldName {
                return false
            }

            if !value.isValidHeaderFieldValue {
                return false
            }
        }

        return true
    }
}
