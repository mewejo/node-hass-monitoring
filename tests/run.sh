#!/usr/bin/env bash
# Test runner.
#
# Usage: tests/run.sh [unit|integration|all]   (default: unit)
#
# Each file in tests/unit or tests/integration defines functions named test_*.
# Every test runs in its own subshell so a crash or a stray `exit` in one test
# cannot take down the run or leak state into the next test.
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

SUITE=${1:-unit}
PASS=0
FAIL=0
FAILED_TESTS=()

run_file() {
    local file=$1
    printf '\n\033[1m%s\033[0m\n' "${file#"$REPO_ROOT"/}"

    # Discover test functions by sourcing in a throwaway shell, so the runner's
    # own state is never polluted by a test file.
    local fns
    fns=$(bash -c "
        source '${REPO_ROOT}/tests/helpers.sh'
        source '$file'
        declare -F | awk '{print \$3}' | grep '^test_' | sort
    " 2>/dev/null)

    if [[ -z $fns ]]; then
        printf '  (no tests found)\n'
        return
    fi

    local fn output status
    while IFS= read -r fn; do
        output=$(
            bash -c "
                set -uo pipefail
                source '${REPO_ROOT}/tests/helpers.sh'
                source '$file'
                $fn
            " 2>&1
        )
        status=$?

        if ((status == 0)); then
            printf '  \033[32m✓\033[0m %s\n' "${fn#test_}"
            ((PASS++))
        else
            printf '  \033[31m✗\033[0m %s\n' "${fn#test_}"
            [[ -n $output ]] && printf '%s\n' "$output"
            ((FAIL++))
            FAILED_TESTS+=("${file#"$REPO_ROOT"/}::${fn}")
        fi
    done <<<"$fns"
}

run_suite() {
    local dir="${REPO_ROOT}/tests/$1"
    [[ -d $dir ]] || return 0
    local file
    for file in "$dir"/*.sh; do
        [[ -e $file ]] || continue
        run_file "$file"
    done
}

case "$SUITE" in
unit) run_suite unit ;;
integration) run_suite integration ;;
all)
    run_suite unit
    run_suite integration
    ;;
*)
    echo "usage: $0 [unit|integration|all]" >&2
    exit 2
    ;;
esac

printf '\n────────────────────────────\n'
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"

if ((FAIL > 0)); then
    printf '\nfailed tests:\n'
    printf '  %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi

# An empty run must not look like success — a broken discovery glob would
# otherwise report a green build having executed nothing.
if ((PASS == 0)); then
    printf '\nno tests ran\n' >&2
    exit 1
fi

exit 0
