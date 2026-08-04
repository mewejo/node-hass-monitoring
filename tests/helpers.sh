#!/usr/bin/env bash
# Assertion helpers for the test suite.
#
# Plain bash rather than bats: the project's whole point is running without
# installed dependencies, and the test suite holding to the same bar means
# `tests/run.sh` works on a bare box or a CI container with no setup step.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT

_fail() {
    printf '    FAIL: %s\n' "$1" >&2
    return 1
}

assert_eq() {
    local expected=$1 actual=$2 msg=${3:-values differ}
    if [[ $expected != "$actual" ]]; then
        _fail "$msg
      expected: [$expected]
      actual:   [$actual]"
        return 1
    fi
}

assert_contains() {
    local haystack=$1 needle=$2 msg=${3:-substring not found}
    if [[ $haystack != *"$needle"* ]]; then
        _fail "$msg
      looking for: [$needle]
      in:          [$haystack]"
        return 1
    fi
}

assert_not_contains() {
    local haystack=$1 needle=$2 msg=${3:-unexpected substring present}
    if [[ $haystack == *"$needle"* ]]; then
        _fail "$msg
      should not contain: [$needle]
      in:                 [$haystack]"
        return 1
    fi
}

# Renders an escape string (\xNN...) as spaced hex, so failures show the actual
# bytes on the wire rather than an opaque blob.
hex_of() {
    printf '%b' "$1" | od -An -tx1 | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'
}

# Asserts a built MQTT frame matches an expected byte sequence exactly.
assert_bytes() {
    local expected=$1 escape_string=$2 msg=${3:-frame bytes differ}
    assert_eq "$expected" "$(hex_of "$escape_string")" "$msg"
}

skip() {
    printf '    SKIP: %s\n' "$1"
    return 0
}
