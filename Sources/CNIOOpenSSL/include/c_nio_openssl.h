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
#ifndef C_NIO_OPENSSL_H
#define C_NIO_OPENSSL_H

#include <openssl/conf.h>
#include <openssl/evp.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <openssl/ssl.h>
#include <openssl/sha.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <openssl/pkcs12.h>
#include <openssl/x509v3.h>

// This is a wrapper function that allows the setting of AUTO ECDH mode when running
// on OpenSSL v1.0.2/LibreSSL.
static inline void CNIOOpenSSL_SSL_CTX_setAutoECDH(SSL_CTX *ctx) {

	#if (OPENSSL_VERSION_NUMBER >= 0x1000200fL && OPENSSL_VERSION_NUMBER < 0x10100000L) || defined(LIBRESSL_VERSION_NUMBER)
		SSL_CTX_ctrl(ctx, SSL_CTRL_SET_ECDH_AUTO, 1, NULL);
	#endif
}

static inline int CNIOOpenSSL_sk_GENERAL_NAME_num(STACK_OF(GENERAL_NAME) *x) {
    return sk_GENERAL_NAME_num(x);
}

static inline const GENERAL_NAME *CNIOOpenSSL_sk_GENERAL_NAME_value(STACK_OF(GENERAL_NAME) *x, int idx) {
    return sk_GENERAL_NAME_value(x, idx);
}

static inline const unsigned char *CNIOOpenSSL_ASN1_STRING_get0_data(ASN1_STRING *x) {
    #if (OPENSSL_VERSION_NUMBER < 0x10100000L) || defined(LIBRESSL_VERSION_NUMBER)
        return ASN1_STRING_data(x);
    #else
        return ASN1_STRING_get0_data(x);
    #endif
}

#endif
