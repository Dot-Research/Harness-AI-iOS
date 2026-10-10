#!/usr/bin/env bash
# Usage: annotate-failure.sh <log file> <title>
# Turns the error lines of a failed step's log into one GitHub annotation, so failures are readable
# from the PR's Checks tab and the API without opening the full log.
log="$1"; title="$2"
[ -f "$log" ] || exit 0
lines="$(grep -E '(^|[^a-z])(error|fatal error|FAIL|FAILED|Traceback|AssertionError)\b|: error:|^Error:' "$log" \
  | grep -vE 'warning: |^\s*$' | awk '!seen[$0]++' | head -150)"
[ -n "$lines" ] || lines="$(tail -40 "$log")"
# Workflow commands need %, CR and LF escaped.
body="$(printf '%s' "$lines" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}')"
echo "::error title=${title}::${body}"
