##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2024 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# Set strict mode to catch errors
Set-StrictMode -Version Latest

function Log {
    param (
        [string]$Message
    )
    Write-Host ("** " + $Message) -ForegroundColor Yellow
}

function Error {
    param (
        [string]$Message
    )
    Write-Host ("** ERROR: " + $Message) -ForegroundColor Red
}

function Fatal {
    param (
        [string]$Message
    )
    Error $Message
    exit 1
}

# Check if SWIFT_VERSION is set
if (-not $env:SWIFT_VERSION) {
    Fatal "SWIFT_VERSION unset"
}

# Check if COMMAND is set
if (-not $env:COMMAND) {
    Fatal "COMMAND unset"
}

$swift_version = $env:SWIFT_VERSION
$command = $env:COMMAND
$command_5_9 = $env:COMMAND_OVERRIDE_5_9
$command_5_10 = $env:COMMAND_OVERRIDE_5_10
$command_6_0 = $env:COMMAND_OVERRIDE_6_0
$command_nightly_6_1 = $env:COMMAND_OVERRIDE_NIGHTLY_6_1
$command_nightly_main = $env:COMMAND_OVERRIDE_NIGHTLY_MAIN

if ($swift_version -eq "5.9" -and $command_5_9) {
    Log "Running 5.9 command override"
    Invoke-Expression $command_5_9
} elseif ($swift_version -eq "5.10" -and $command_5_10) {
    Log "Running 5.10 command override"
    Invoke-Expression $command_5_10
} elseif ($swift_version -eq "6.0" -and $command_6_0) {
    Log "Running 6.0 command override"
    Invoke-Expression $command_6_0
} elseif ($swift_version -eq "nightly-6.1" -and $command_nightly_6_1) {
    Log "Running nightly 6.1 command override"
    Invoke-Expression $command_nightly_6_1
} elseif ($swift_version -eq "nightly-main" -and $command_nightly_main) {
    Log "Running nightly main command override"
    Invoke-Expression $command_nightly_main
} else {
    Log "Running default command"
    Invoke-Expression $command
}

Exit $LASTEXITCODE
