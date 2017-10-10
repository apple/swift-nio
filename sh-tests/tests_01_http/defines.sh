#!/bin/bash

function create_token() {
    mktemp "$tmp/server_token_XXXXXX"
}

function start_server() {
    local token="$1"
    local type="--uds"
    local port="$tmp/port.sock"
    local tmp_server_pid
    local tok_type="--unix-socket"
    local curl_port=80

    if [[ "${2:-uds}" == "tcp" ]]; then
        type=""
        port="0"
        tok_type=""
    fi

    mkdir "$tmp/htdocs"
    "$root/.build/x86_64-apple-macosx10.10/debug/NIOHTTP1Server" "$port" "$tmp/htdocs" &
    for f in $(seq 30); do if [[ -S "$port" ]]; then break; else sleep 0.1; fi; done
    if [[ -z "$type" ]]; then
        port=$(lsof -n -p $! | grep -Eo 'TCP .*:[0-9]+ ' | grep -Eo '[0-9]{4,5} ' | tr -d ' ')
        lsof -n -p $!
        echo "port = '$port'"
        curl_port="$port"
    fi
    echo "port: $port"
    echo "curl port: $curl_port"
    echo "local token_port;   local token_htdocs;         local token_pid;"      >> "$token"
    echo "      token_port='$port'; token_htdocs='$tmp/htdocs'; token_pid='$!';" >> "$token"
    echo "      token_type='$tok_type';" >> "$token"
    do_curl "$token" http://localhost:$curl_port/dynamic/write-delay | grep -q 'Hello World'
    tmp_server_pid=$(get_server_pid "$token")
    echo "local token_open_fds" >> "$token"
    echo "token_open_fds='$(lsof -n -p "$tmp_server_pid" | wc -l)'" >> "$token"
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
    sleep 0.05 # just to make sure all the fds could be closed
    if command -v lsof > /dev/null 2> /dev/null; then
        lsof -n -p "$token_pid"
        local open_fds
        open_fds=$(lsof -n -p "$token_pid" | wc -l)
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

function do_curl() {
    source "$1"
    shift
    if [[ -z "$token_type" ]]; then
        curl -v "$@"
    else
        curl $token_type "$token_port" -v "$@"
    fi
}
