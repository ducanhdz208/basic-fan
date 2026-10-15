#!/bin/zsh
set -eu
cd "$(dirname "$0")"
TEST_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/basicfan-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD"' EXIT
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/cache" Source/SMC.swift Source/Control.swift Source/Tests.swift -framework IOKit -o "$TEST_BUILD/policy-tests"
"$TEST_BUILD/policy-tests"
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/cache" Source/SMC.swift Source/Control.swift Source/FanEngine.swift Source/EngineTests.swift -framework IOKit -o "$TEST_BUILD/engine-tests"
"$TEST_BUILD/engine-tests"
swiftc -swift-version 5 -module-cache-path "$TEST_BUILD/cache" Source/UpdatePolicy.swift Source/UpdateTests.swift -o "$TEST_BUILD/update-tests"
"$TEST_BUILD/update-tests"
