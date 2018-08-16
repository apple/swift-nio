#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

function server_lsof() {
    lsof -a -d 0-1024 -p "$1"
}

function do_netstat() {
    pf="$1"
    netstat_options=()
    case "$(uname -s)" in
        Linux)
            netstat_options+=( "-A" "$pf" -p )
            ;;
        Darwin)
            netstat_options+=( "-f" "$pf" -v )
            ;;
        *)
            fail "Unknown OS $(uname -s)"
            ;;
    esac
    netstat -an "${netstat_options[@]}"
}

function create_token() {
    mktemp "$tmp/server_token_XXXXXX"
}

function start_server() {
    local extra_args=''
    if [[ "$1" == "--disable-half-closure" ]]; then
        extra_args="$1"
        shift
    fi
    local token="$1"
    local type="unix"
    local port="$tmp/port.sock"
    local tmp_server_pid
    local curl_port=80

    maybe_host=""
    maybe_nio_host=""
    if [[ "${2:-uds}" == "tcp" ]]; then
        type="inet"
        port="0"
        maybe_host="localhost"
        maybe_nio_host="127.0.0.1"
    fi

    mkdir "$tmp/htdocs"
    swift build
    "$(swift build --show-bin-path)/NIOHTTP1Server" $extra_args $maybe_nio_host "$port" "$tmp/htdocs" &
    tmp_server_pid=$!
    case "$type" in
    inet)
        # TCP mode, need to wait until we found a port that we can curl
        worked=false
        for f in $(seq 20); do
            server_lsof "$tmp_server_pid"
            port=$(server_lsof "$tmp_server_pid" | grep -Eo 'TCP .*:[0-9]+ ' | grep -Eo '[0-9]{4,5} ' | tr -d ' ' || true)
            curl_port="$port"
            if [[ -n "$port" ]] && curl --ipv4 "http://$maybe_host:$curl_port/dynamic/pid"; then
                worked=true
                break
            else
                server_lsof "$tmp_server_pid"
                sleep 0.1 # wait for the socket to be bound
            fi
        done
        "$worked" || fail "Could not reach server 2s after lauching..."
        ;;
    unix)
        # Unix Domain Socket, wait for the file to appear
        for f in $(seq 30); do if [[ -S "$port" ]]; then break; else sleep 0.1; fi; done
        ;;
    *)
        fail "Unknown server type '$type'"
        ;;
    esac
    echo "port: $port"
    echo "curl port: $curl_port"
    echo "local token_port;   local token_htdocs;         local token_pid;"      >> "$token"
    echo "      token_port='$port'; token_htdocs='$tmp/htdocs'; token_pid='$!';" >> "$token"
    echo "      token_type='$type'; token_server_ip='$maybe_nio_host'" >> "$token"
    tmp_server_pid=$(get_server_pid "$token")
    echo "local token_open_fds" >> "$token"
    echo "token_open_fds='$(server_lsof "$tmp_server_pid" | wc -l)'" >> "$token"
    server_lsof "$tmp_server_pid"
    do_curl "$token" "http://$maybe_host:$curl_port/dynamic/pid"
}

function get_htdocs() {
    source "$1"
    echo "$token_htdocs"
}

function get_socket() {
    source "$1"
    echo "$token_port"
}

function stop_server() {
    source "$1"
    sleep 0.5 # just to make sure all the fds could be closed
    if command -v lsof > /dev/null 2> /dev/null; then
        server_lsof "$token_pid"
        do_netstat "$token_type"
        local open_fds
        open_fds=$(server_lsof "$token_pid" | wc -l)
        assert_equal "$token_open_fds" "$open_fds" \
            "expected $token_open_fds open fds, found $open_fds"
    fi
    kill -0 "$token_pid" # assert server is still running
    ###kill -INT "$token_pid" # tell server to shut down gracefully
    kill "$token_pid" # tell server to shut down gracefully
    for f in $(seq 20); do
        if ! kill -0 "$token_pid" 2> /dev/null; then
            break # good, dead
        fi
        ps auxw | grep "$token_pid" || true
        sleep 0.1
    done
    if kill -0 "$token_pid" 2> /dev/null; then
        fail "server $token_pid still running"
    fi
}

function get_server_pid() {
    source "$1"
    echo "$token_pid"
}

function get_server_port() {
    source "$1"
    echo "$token_port"
}

function get_server_ip() {
    source "$1"
    echo "$token_server_ip"
}

function do_curl() {
    source "$1"
    shift
    case "$token_type" in
        inet)
            curl -v --ipv4 "$@"
            ;;
        unix)
            curl --unix-socket "$token_port" -v "$@"
            ;;
        *)
            fail "Unknown type '$token_type'"
            ;;
    esac
}
