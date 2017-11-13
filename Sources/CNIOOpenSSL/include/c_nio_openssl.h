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

// MARK: OpenSSL version shims
// These are functions that shim over differences in different OpenSSL versions,
// which are best handled by using the C preprocessor.
static inline void CNIOOpenSSL_SSL_CTX_setAutoECDH(SSL_CTX *ctx) {

	#if (OPENSSL_VERSION_NUMBER >= 0x1000200fL && OPENSSL_VERSION_NUMBER < 0x10100000L) || defined(LIBRESSL_VERSION_NUMBER)
		SSL_CTX_ctrl(ctx, SSL_CTRL_SET_ECDH_AUTO, 1, NULL);
	#endif
}

static inline int CNIOOpenSSL_SSL_set_tlsext_host_name(SSL *ssl, const char *name) {
    return SSL_set_tlsext_host_name(ssl, name);
}

static inline const unsigned char *CNIOOpenSSL_ASN1_STRING_get0_data(ASN1_STRING *x) {
#if (OPENSSL_VERSION_NUMBER < 0x10100000L) || defined(LIBRESSL_VERSION_NUMBER)
    return ASN1_STRING_data(x);
#else
    return ASN1_STRING_get0_data(x);
#endif
}

// MARK: Macro wrappers
// These are functions that rely on things declared in macros in OpenSSL, at least in
// some versions. The Swift compiler cannot expand C macros, so we need a file that
// can.
static inline int CNIOOpenSSL_sk_GENERAL_NAME_num(STACK_OF(GENERAL_NAME) *x) {
    return sk_GENERAL_NAME_num(x);
}

static inline const GENERAL_NAME *CNIOOpenSSL_sk_GENERAL_NAME_value(STACK_OF(GENERAL_NAME) *x, int idx) {
    return sk_GENERAL_NAME_value(x, idx);
}

static inline int CNIOOpenSSL_SSL_CTX_set_app_data(SSL_CTX *ctx, void *arg) {
    return SSL_CTX_set_app_data(ctx, arg);
}

static inline void *CNIOOpenSSL_SSL_CTX_get_app_data(SSL_CTX *ctx) {
    return SSL_CTX_get_app_data(ctx);
}

// We bring this typedef forward in case it's not present in the version of OpenSSL
// we have.
typedef int (*CNIOOpenSSL_SSL_CTX_alpn_select_cb_func)(SSL *ssl,
                                                          const unsigned char **out,
                                                          unsigned char *outlen,
                                                          const unsigned char *in,
                                                          unsigned int inlen,
                                                          void *arg);

static inline int CNIOOpenSSL_SSL_CTX_set_alpn_protos(SSL_CTX *ctx,
                                                         const unsigned char *protos,
                                                         unsigned int protos_len) {
    #if OPENSSL_VERSION_NUMBER >= 0x10002000L
        return SSL_CTX_set_alpn_protos(ctx, protos, protos_len);
    #else
        return 1;
    #endif
}

static inline void CNIOOpenSSL_SSL_CTX_set_alpn_select_cb(SSL_CTX *ctx,
                                                             CNIOOpenSSL_SSL_CTX_alpn_select_cb_func cb,
                                                             void *arg) {
    #if OPENSSL_VERSION_NUMBER >= 0x10002000L
        SSL_CTX_set_alpn_select_cb(ctx, cb, arg);
    #endif
}

static inline void CNIOOpenSSL_SSL_get0_alpn_selected(const SSL *ssl,
                                                         const unsigned char **data,
                                                         unsigned int *len) {
    #if OPENSSL_VERSION_NUMBER >= 0x10002000L
        SSL_get0_alpn_selected(ssl, data, len);
    #endif
}
#endif
