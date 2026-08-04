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

# Reads a value out of a JSON document by dotted path, e.g. 'device.name' or
# 'device.identifiers.0'.
#
# Python is used only here, in the test suite. It is deliberately NOT used by
# anything that runs on a monitored node -- the whole point of the agent is
# installing with no dependencies. Parsing JSON with a real parser rather than
# grep means these tests check the actual structure, so a payload that merely
# happens to contain the right substring cannot pass.
json_get() {
    local document=$1 path=$2
    printf '%s' "$document" | python3 -c '
import json, sys

path = sys.argv[1]
value = json.load(sys.stdin)

for part in path.split("."):
    if isinstance(value, list):
        value = value[int(part)]
    else:
        value = value[part]

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("null")
else:
    print(value)
' "$path" 2>/dev/null
}
