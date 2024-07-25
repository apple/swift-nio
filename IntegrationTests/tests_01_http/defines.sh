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

function get_number_of_open_fds_for_pid() {
    server_lsof "$1" >&2
    server_lsof "$1" | wc -l
}

# pid, expected_number_of_fds
function assert_number_of_open_fds_for_pid_equals() {
    local pid expected actual
    pid="$1"
    expected="$2"

    for f in $(seq 50); do
        sleep 0.2
        actual=$(get_number_of_open_fds_for_pid "$pid")
        echo "try $f, actually having $actual open fds, expecting $expected"
        if [[ "$expected" == "$actual" ]]; then
            break
        fi
    done
    server_lsof "$pid"
    assert_equal "$expected" "$actual" "wrong number of open fds"
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
    mktemp "${tmp:?}/server_token_XXXXXX"
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
    # shellcheck disable=SC2086 # Disabled to properly pass the args
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
    {
        echo "local token_port;   local token_htdocs;         local token_pid;"
        echo "      token_port='$port'; token_htdocs='$tmp/htdocs'; token_pid='$!';"
        echo "      token_type='$type'; token_server_ip='$maybe_nio_host'"
    } >> "$token"
    tmp_server_pid=$(get_server_pid "$token")
    echo "local token_open_fds" >> "$token"
    echo "token_open_fds='$(get_number_of_open_fds_for_pid "$tmp_server_pid")'" >> "$token"
    local curl_host=${maybe_host:-localhost}
    do_curl "$token" "http://$curl_host:$curl_port/dynamic/pid"
}

function get_htdocs() {
    # shellcheck source=/dev/null
    source "$1"
    # shellcheck disable=SC2154
    echo "${token_htdocs:?}"
}

function get_socket() {
    # shellcheck source=/dev/null
    source "$1"
    echo "${token_port:?}"
}

function stop_server() {
    # shellcheck source=/dev/null
    source "$1"
    sleep 0.5 # just to make sure all the fds could be closed
    if command -v lsof > /dev/null 2> /dev/null; then
        do_netstat "${token_type:?}"
        assert_number_of_open_fds_for_pid_equals "${token_pid:?}" "${token_open_fds:?}"
    fi
    # assert server is still running
    kill -0 "$token_pid" # ignore-unacceptable-language
    # tell server to shut down gracefully
    kill "$token_pid" # ignore-unacceptable-language
    for f in $(seq 20); do
        if ! kill -0 "$token_pid" 2> /dev/null; then # ignore-unacceptable-language
            break # good, dead
        fi
        # shellcheck disable=SC2009
        ps auxw | grep "$token_pid" || true
        sleep 0.1
    done
    if kill -0 "$token_pid" 2> /dev/null; then # ignore-unacceptable-language
        fail "server $token_pid still running"
    fi
}

function get_server_pid() {
    # shellcheck source=/dev/null
    source "$1"
    echo "$token_pid"
}

function get_server_port() {
    # shellcheck source=/dev/null
    source "$1"
    echo "$token_port"
}

function get_server_ip() {
    # shellcheck source=/dev/null
    source "$1"
    # shellcheck disable=SC2154
    echo "$token_server_ip"
}

function do_curl() {
    # shellcheck source=/dev/null
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

_new_nc=false
if nc -h 2>&1 | grep -- -N | grep -q EOF; then
    # this is a new kind of 'nc' that doesn't automatically shut down
    # the input socket after EOF. But we rely on that behaviour.
    _new_nc=true
fi

function do_nc() {
    if "$_new_nc"; then
        nc -N "$@"
    else
        nc "$@"
    fi
}
