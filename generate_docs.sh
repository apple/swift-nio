#!/bin/bash

set -eu

here="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [[ "$(uname -s)" != Darwin ]]; then
    echo >&2 "Sorry, at this point in time documentation can only be generated on macOS."
    exit 1
fi

if ! command -v jazzy > /dev/null; then
    echo >&2 "ERROR: jazzy not installed, install with"
    echo >&2
    echo >&2 "  gem install jazzy"
fi

[[ -d swift-nio.xcodeproj ]] || swift package generate-xcodeproj

cd "$here"

tmp="$(mktemp /tmp/.swift-nio-jazzy_XXXXXX)"
cat >> "$tmp" <<EOF
# SwiftNIO Docs

SwiftNIO contains multiple modules:

EOF
modules=(SwiftNIO NIOHTTP1 NIOTLS NIOOpenSSL)
for module in "${modules[@]}"; do
    echo " - [$module](../$module/index.html)" >> "$tmp"
done
mv "$tmp" docs/README.md
for module in "${modules[@]}"; do
    jazzy \
        --clean \
        --readme docs/README.md \
        --author 'SwiftNIO Team' \
        --author_url https://github.com/apple/nio \
        --github_url https://github.com/apple/nio \
        --xcodebuild-arguments -scheme,swift-nio-Package \
        --output "docs/$module" \
        --module "$module"
done
