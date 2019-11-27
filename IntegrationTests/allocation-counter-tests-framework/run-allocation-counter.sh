#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2019 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

set -eu
here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
build_opts=( -c release )

function die() {
    echo >&2 "ERROR: $*"
    exit 1
}

function make_git_commit_all() {
    git init > /dev/null
    if [[ "$(git config user.email)" == "" ]]; then
        git config --local user.email does@really-not.matter
        git config --local user.name 'Does Not Matter'
    fi
    git add . > /dev/null
    git commit -m 'everything' > /dev/null
}

# <extra_dependencies_file> <swiftpm_pkg_name> <targets...>
function hooked_package_swift_start() {
    local extra_dependencies_file=$1
    local swiftpm_pkg_name=$2
    shift 2

    cat <<"EOF"
// swift-tools-version:5.0
import PackageDescription

let package = Package(
    name: "allocation-counter-tests",
    products: [
EOF
    for f in "$@"; do
        local module
        module=$(module_name_from_path "$f")
        echo ".executable(name: \"$module\", targets: [\"bootstrap_$module\"]),"
    done
    cat <<EOF
    ],
    dependencies: [
        .package(url: "HookedFunctions/", .branch("master")),
        .package(url: "$swiftpm_pkg_name/", .branch("master")),
EOF
    if [[ -n "$extra_dependencies_file" ]]; then
        cat "$extra_dependencies_file"
    fi
    cat <<EOF
    ],
    targets: [
EOF
}

# <target_name> <deps...>
function hooked_package_swift_target() {
    local target_name="$1"
    shift
    local deps=""
    for dep in "$@"; do
        deps="$deps \"$dep\","
    done
    cat <<EOF
            .target(name: "Test_$target_name", dependencies: [$deps]),
            .target(name: "bootstrap_$target_name",
                    dependencies: ["Test_$target_name", "HookedFunctions"]),
EOF
}

function hooked_package_swift_end() {
    cat <<"EOF"
    ]
)
EOF
}

function abs_path() {
    if [[ "${1:0:1}" == "/" ]]; then
        echo "$1"
    else
        echo "$PWD/$1"
    fi
}

function dir_basename() {
    test -d "$1"
    basename "$(cd "$1" && pwd)"
}

function fake_package_swift() {
    cat > Package.swift <<EOF
// swift-tools-version:4.0
import PackageDescription

let package = Package(name: "$1")
EOF
}

# <target> <template> <swiftpm_pkg_root> <swiftpm_pkg_name> <hooked_function_module> <bootstrap_module>
# <shared file> <extra_dependencies_file> <modules...> -- <test_files...>
function build_package() {
    local target=$1
    local template=$2
    local swiftpm_pkg_root=$3
    local swiftpm_pkg_name=$4
    local hooked_function_module=$5
    local bootstrap_module=$6
    local shared_file=$7
    local extra_dependencies_file=$8
    shift 8

    local modules=()
    while [[ "$1" != "--" ]]; do
        modules+=( "$1" )
        shift
    done
    shift

    test -d "$target" || die "target dir '$target' not a directory"
    test -d "$template" || die "template dir '$template' not a directory"
    test -d "$swiftpm_pkg_root" || die "root dir '$swiftpm_pkg_root' not a directory"
    test -n "$hooked_function_module" || die "hooked function module empty"
    test -n "$bootstrap_module" || die "bootstrap module empty"

    cp -R "$template"/* "$target/"
    mv "$target/$hooked_function_module" "$target/HookedFunctions"
    mv "$target/Sources/$bootstrap_module" "$target/Sources/bootstrap"

    (
    set -eu

    cd "$target"

    cd HookedFunctions
    make_git_commit_all
    cd ..

    cd AtomicCounter
    make_git_commit_all
    cd ..

    mkdir "$swiftpm_pkg_name"
    cd "$swiftpm_pkg_name"
    fake_package_swift "$swiftpm_pkg_name"
    make_git_commit_all
    cd ..

    hooked_package_swift_start "$extra_dependencies_file" "$swiftpm_pkg_name" "$@" > Package.swift
    for f in "$@"; do
        local module
        module=$(module_name_from_path "$f")
        hooked_package_swift_target "$module" "${modules[@]}" >> Package.swift
        mkdir "Sources/bootstrap_$module"
        ln -s "../bootstrap/main.c" "Sources/bootstrap_$module"
        mkdir "Sources/Test_$module"
        cat > "Sources/Test_$module/trampoline.swift" <<EOF
        @_cdecl("swift_main")
        func swift_main() {
            run(identifier: "$module")
        }
EOF
        ln -s "$f" "Sources/Test_$module/file.swift"
        ln -s "../../scaffolding.swift" "Sources/Test_$module/"
        if [[ -n "$shared_file" ]]; then
            ln -s "$shared_file" "Sources/Test_$module/shared.swift"
        fi
    done
    hooked_package_swift_end >> Package.swift

    swift package edit --path "$swiftpm_pkg_root" "$swiftpm_pkg_name"
    )
}

function module_name_from_path() {
    basename "${1%.*}" | tr ". " "__"
}

# <pkg_root>
function find_swiftpm_package_name() {
    (
    set -eu
    cd "$1"
    swift package dump-package | grep '^  "name"' | cut -d'"' -f4
    )
}

do_hooking=true
pkg_root="$here/.."
shared_file=""
modules=()
extra_dependencies_file=""
tmp_dir="/tmp"

while getopts "ns:p:m:d:t:" opt; do
    case "$opt" in
        n)
            do_hooking=false
            ;;
        s)
            shared_file="$OPTARG"
            ;;
        p)
            pkg_root=$(abs_path "$OPTARG")
            ;;
        m)
            modules+=( "$OPTARG" )
            ;;
        d)
            extra_dependencies_file="$OPTARG"
            ;;
        t)
            tmp_dir="$OPTARG"
            ;;
        \?)
            die "unknown option $opt"
            ;;
    esac
done

shift $(( OPTIND - 1 ))
if [[ $# -lt 1 ]]; then
    die "not enough files provided"
fi

if [[ "${#modules}" == 0 ]]; then
    die "no modules specified, use '-m <MODULE>' for every module you plan to use"
fi

if [[ ! -f "$pkg_root/Package.swift" ]]; then
    die "package root '$pkg_root' doesn't contain a Package.swift file, use -p"
fi

files=()
for f in "$@"; do
    files+=( "$(abs_path "$f")" )
done

if [[ -n "$shared_file" ]]; then
    shared_file=$(abs_path "$shared_file")
fi

test -d "$pkg_root" || die "package root '$pkg_root' not a directory"
for f in "${files[@]}"; do
    test -f "$f" || die "file '$f' not a file"
done

working_dir=$(mktemp -d "$tmp_dir/.nio_alloc_counter_tests_XXXXXX")

selected_hooked_functions="HookedFunctionsDoHook"
selected_bootstrap="bootstrapDoHook"

if ! $do_hooking; then
    selected_hooked_functions=HookedFunctionsDoNotHook
    selected_bootstrap=bootstrapDoNotHook
fi

build_package \
    "$working_dir" \
    "$here/template" \
    "$pkg_root" \
    "$(find_swiftpm_package_name "$pkg_root")" \
    "$selected_hooked_functions" \
    "$selected_bootstrap" \
    "$shared_file" \
    "$extra_dependencies_file" \
    "${modules[@]}" \
    -- \
    "${files[@]}"
(
set -eu
cd "$working_dir"
swift build "${build_opts[@]}"
for f in "${files[@]}"; do
    echo "- $f"
    swift run "${build_opts[@]}" "$(module_name_from_path "$f")"
done
)
