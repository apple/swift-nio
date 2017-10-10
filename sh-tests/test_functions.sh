function fail() {
    echo >&2 "FAILURE: $*"
    false
}

function assert_equal() {
    if [[ "$1" != "$2" ]]; then
        fail "expected '$1', got '$2' ${3-}"
    fi
}

function assert_equal_files() {
    if ! cmp -s "$1" "$2"; then
        diff -u "$1" "$2" || true
        echo
        echo "--- SNIP ($1, size=$(wc "$1"), SHA=$(shasum "$1")) ---"
        cat "$1"
        echo "--- SNAP ($1)---"
        echo "--- SNIP ($2, size=$(wc "$2"), SHA=$(shasum "$2")) ---"
        cat "$2"
        echo "--- SNAP ($2) ---"
        fail "file '$1' not equal to '$2'"
    fi
}
