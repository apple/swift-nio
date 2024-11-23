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

function setup_swiftpm_package() {
    destination="$1"
    main_module_name="$2"
    shift; shift

    modules=()
    dependencies=()
    dep_mods=()

    for module in "$@"; do
        shift
        if [[ "$module" == "--" ]]; then
            break
        fi
        modules+=( "$module" )
    done

    for dependency in "$@"; do
        shift
        if [[ "$dependency" == "--" ]]; then
            break
        fi
        dependencies+=( "$dependency" )
    done

    for dep_mod in "$@"; do
        shift
        if [[ "$dep_mod" == "--" ]]; then
            break
        fi
        dep_mods+=( "$dep_mod" )
    done

    cd "$destination"
    cat > Package.swift <<"EOF"
// swift-tools-version:5.7
import PackageDescription

var targets: [PackageDescription.Target] = [
EOF

    mods_before=()
    if [[ ${#modules} -gt 0 ]]; then
        for module in "${modules[@]}"; do
            echo "    .target(name: \"$module\", dependencies: [" >> Package.swift
            if [[ ${#mods_before} -gt 0 ]]; then
                for inner_module in "${mods_before[@]}"; do
                    echo "\"$inner_module\", " >> Package.swift
                done
            fi
            echo "])," >> Package.swift
            mods_before+=( "$module" )
        done
    fi

    echo "    .target(name: \"$main_module_name\", dependencies: [" >> Package.swift
    if [[ ${#modules} -gt 0 ]]; then
        for module in "${modules[@]}"; do
            echo "\"$module\", " >> Package.swift
        done
    fi
    if [[ ${#dep_mods} -gt 0 ]]; then
        for module in "${dep_mods[@]}"; do
            echo "\"$module\", " >> Package.swift
        done
    fi
    echo "])]" >> Package.swift
    cat >> Package.swift <<EOF
let package = Package(
    name: "$main_module_name",
    products: [
        .executable(name: "$main_module_name", targets: ["$main_module_name"])
    ],
    dependencies: [
EOF

    if [[ "${#dependencies}" -gt 0 ]]; then
        for dependency in "${dependencies[@]}"; do
            echo "$dependency" >> Package.swift
        done
    fi

    cat >> Package.swift <<EOF
    ],
    targets: targets
)
EOF
}

function usage() {
    echo >&2 "Usage: $0 FILE COMMAND"
    echo >&2
    echo >&2 "COMMANDs:"
    echo >&2 "  xcode # Open this project in Xcode"
    echo >&2 "  mallocs # Show the malloc aggregation for running this project"
    echo >&2 "  build # Build this project"
    echo >&2 "  lldb # Compile and open project in lldb"
    echo >&2 "  run # Run this project"
    echo >&2
    echo >&2 "FILE format example:"
    echo >&2
    echo >&2 "// DEPENDENCY: https://github.com/apple/swift-nio.git 1.0.0 NIO NIOHTTP1"
    echo >&2 "// ^^^ this indicates a dependency"
    echo >&2 "// this is code in the main module"
    echo >&2
    echo >&2 "import NIO"
    echo >&2 "import Foo"
    echo >&2
    echo >&2 "print(Foo.hello)"
    echo >&2
    echo >&2 "// MODULE: Foo"
    echo >&2 "// everything here is now in module Foo"
    echo >&2
    echo >&2 "public let hello = \"Hello World\""
}

if [[ $# -lt 2 ]]; then
    usage
    exit 1
fi

destination=$(mktemp -d /tmp/test_package_XXXXXX)
file="$1"
command="$2"
shift; shift

main_module_name="TestApp"
mkdir -p "$destination/Sources/$main_module_name"
current_module_file="$destination/Sources/$main_module_name/main.swift"
current_module_name="$main_module_name"
all_modules=()
all_dependencies=()
all_dependency_modules=()
number_of_lines=0

while IFS="" read -r line; do
    if [[ "$line" =~ ^//\ MODULE:\ (.*)$ ]]; then
        module=${BASH_REMATCH[1]}

        all_modules+=( "$module" )
        mkdir -p "$destination/Sources/$module"
        current_module_file="$destination/Sources/$module/module.swift"
        for (( i=0; i <= number_of_lines; i++ )); do
            echo >> "$current_module_file"
        done
    elif [[ "$line" =~ ^//\ DEPENDENCY:\ ([^ ]+)\ ([^ ]+)\ (.*)$ ]]; then
        url=${BASH_REMATCH[1]}
        version=${BASH_REMATCH[2]}
        dep_mods=( ${BASH_REMATCH[3]} )
        echo "dependency $url $version, modules: ${dep_mods[*]}"
        all_dependencies+=( ".package(url: \"$url\", from: \"$version\"), " )
        all_dependency_modules+=( ${dep_mods[@]} )
    else
        echo "$line" >> "$current_module_file"
    fi
    number_of_lines=$(( number_of_lines + 1 ))
done < "$file"

echo "all extra modules: ${all_modules[@]+"${all_modules[@]}"}"
setup_swiftpm_package "$destination" \
    "$main_module_name" \
    "${all_modules[@]+"${all_modules[@]}"}" \
    -- \
    "${all_dependencies[@]+"${all_dependencies[@]}"}" \
    -- \
    "${all_dependency_modules[@]+"${all_dependency_modules[@]}"}"

cd "$destination"
swift package dump-package > /dev/null
echo "SwiftPM package in:"
echo "  $destination"
build_mode=release
binary="$destination/.build/$build_mode/$main_module_name"
echo "  $binary"

function compile() {
    swift build -c "$build_mode" "$@"
}

case "$command" in
    xcode)
        xed .
        ;;
    xcodeproj)
        swift package generate-xcodeproj
        xed "$main_module_name.xcodeproj"
        ;;
    run)
        compile "$@"
        swift run -c "$build_mode" "$main_module_name" "$@"
        ;;
    build)
        compile "$@"
        ;;
    hopper)
        compile "$@"
        hopperv4 -l Mach-O -e "$binary"
        ;;
    lldb)
        compile "$@"
        lldb "$binary"
        ;;
    mallocs)
        compile "$@"
        sudo  "$here/malloc-aggregation.d" -c "$binary"
        ;;
    *)
        echo "ERROR: unknown command $command"
        ;;
esac
