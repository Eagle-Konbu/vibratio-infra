#!/usr/bin/env bash
# Runs the AppSync resolver tests on the APPSYNC_JS runtime with `aws appsync evaluate-code`.
#
# Each resolver graphql/resolvers/<Type>.<field>.js needs a test file graphql/tests/<Type>.<field>.json
# containing an array of cases:
#   name          - description of the case
#   function      - "request" or "response"
#   context       - AppSync context passed to the function (arguments, result, error, ...)
#   expected      - expected return value, compared after removing the `ignore` paths
#   ignore        - optional jq paths of non-deterministic values, e.g. [["key", "sk", "S"]]
#   expectedError - expected error message, instead of `expected`
set -uo pipefail

GRAPHQL_DIR="$(cd "$(dirname "$0")/../terraform/graphql" && pwd)"
failures=0

fail() {
  echo "FAIL $1"
  failures=$((failures + 1))
}

for resolver in "$GRAPHQL_DIR"/resolvers/*.js; do
  name="$(basename "$resolver" .js)"
  tests="$GRAPHQL_DIR/tests/$name.json"
  if [[ ! -f "$tests" ]]; then
    fail "$name: missing tests/$name.json"
    continue
  fi

  case_count="$(jq length "$tests")"
  for ((i = 0; i < case_count; i++)); do
    test_case="$(jq -c ".[$i]" "$tests")"
    label="$name.$(jq -r .function <<<"$test_case"): $(jq -r .name <<<"$test_case")"

    if ! evaluation="$(aws appsync evaluate-code \
      --runtime name=APPSYNC_JS,runtimeVersion=1.0.0 \
      --code "file://$resolver" \
      --function "$(jq -r .function <<<"$test_case")" \
      --context "$(jq -c '.context // {}' <<<"$test_case")" \
      --output json)"; then
      fail "$label: evaluate-code failed"
      continue
    fi

    error="$(jq -r '.error.message // empty' <<<"$evaluation")"
    if jq -e 'has("expectedError")' <<<"$test_case" >/dev/null; then
      expected_error="$(jq -r .expectedError <<<"$test_case")"
      if [[ "$error" == "$expected_error" ]]; then
        echo "PASS $label"
      else
        fail "$label: expected error \"$expected_error\", got \"${error:-no error}\""
      fi
      continue
    fi

    if [[ -n "$error" ]]; then
      fail "$label: unexpected error \"$error\""
      continue
    fi

    actual="$(jq -c --argjson ignore "$(jq -c '.ignore // []' <<<"$test_case")" \
      '.evaluationResult | fromjson | delpaths($ignore)' <<<"$evaluation")"
    expected="$(jq -c .expected <<<"$test_case")"
    if jq -e --argjson a "$actual" --argjson b "$expected" -n '$a == $b' >/dev/null; then
      echo "PASS $label"
    else
      fail "$label"
      echo "  expected: $expected"
      echo "  actual:   $actual"
    fi
  done
done

if ((failures > 0)); then
  echo "$failures failure(s)"
  exit 1
fi
