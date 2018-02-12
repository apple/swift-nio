#!/bin/bash

function server_lsof() {
    lsof -a -d 0-1024 -p "$1"
}

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

    maybe_host=""
    maybe_nio_host=""
    if [[ "${2:-uds}" == "tcp" ]]; then
        type=""
        port="0"
        tok_type=""
        maybe_host="localhost"
        maybe_nio_host="$(host -4 -t a "$maybe_host" | tr ' ' '\n' | tail -1)"
    fi

    mkdir "$tmp/htdocs"
    swift build
    "$(swift build --show-bin-path)/NIOHTTP1Server" $maybe_nio_host "$port" "$tmp/htdocs" &
    tmp_server_pid=$!
    if [[ -z "$type" ]]; then
        # TCP mode, need to wait until we found a port that we can curl
        worked=false
        for f in $(seq 20); do
            server_lsof "$tmp_server_pid"
            port=$(server_lsof "$tmp_server_pid" | grep -Eo 'TCP .*:[0-9]+ ' | grep -Eo '[0-9]{4,5} ' | tr -d ' ' || true)
            echo "port = '$port'"
            curl_port="$port"
            if curl --ipv4 "http://$maybe_host:$curl_port/dynamic/pid"; then
                worked=true
                break
            else
                server_lsof "$tmp_server_pid"
                sleep 0.1 # wait for the socket to be bound
            fi
        done
        "$worked" || fail "Could not reach server 2s after lauching..."
    else
        # Unix Domain Socket, wait for the file to appear
        for f in $(seq 30); do if [[ -S "$port" ]]; then break; else sleep 0.1; fi; done
    fi
    echo "port: $port"
    echo "curl port: $curl_port"
    echo "local token_port;   local token_htdocs;         local token_pid;"      >> "$token"
    echo "      token_port='$port'; token_htdocs='$tmp/htdocs'; token_pid='$!';" >> "$token"
    echo "      token_type='$tok_type';" >> "$token"
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

function do_curl() {
    source "$1"
    shift
    if [[ -z "$token_type" ]]; then
        curl -v --ipv4 "$@"
    else
        curl $token_type "$token_port" -v "$@"
    fi
}
