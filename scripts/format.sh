#!/bin/bash

export SF_VERSION="0.48.9"

rm swiftformat*
wget "https://github.com/nicklockwood/SwiftFormat/releases/download/$SF_VERSION/swiftformat.zip" -O "/tmp/swiftformat-$SF_VERSION.zip"
unzip -o "/tmp/swiftformat-$SF_VERSION.zip" -d "/tmp/swiftformat"
rm "/tmp/swiftformat-$SF_VERSION.zip"
mv /tmp/swiftformat/swiftformat "/tmp/swiftformat-$SF_VERSION"

"/tmp/swiftformat-$SF_VERSION" "$PWD"
