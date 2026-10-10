#!/usr/bin/env bash
# Usage: annotate-failure.sh <log file> <title>
# Turns the important lines of a failed step's log into one GitHub annotation, so failures are
# readable from the PR's Checks tab and the API without opening the full log.
log="$1"; title="$2"
[ -f "$log" ] || exit 0
if grep -q '^======' "$log"; then
  # unittest: the failure details start at the first ==== separator.
  lines="$(sed -n '/^======/,$p' "$log" | head -150)"
elif grep -q 'Undefined symbols' "$log"; then
  # Linker: the whole undefined-symbols block, and whether -lsqlite3 reached each link command.
  lines="$(sed -n '/Undefined symbols/,/symbol(s) not found/p' "$log" | awk '!seen[$0]++' | head -120)
link commands mentioning -lsqlite3: $(grep -E '^\s*(Ld |cd .*clang|.*/clang .*-Xlinker)' "$log" | grep -c -- '-lsqlite3') of $(grep -cE '^\s*Ld ' "$log") Ld steps
$(grep -E 'BUILD FAILED|^\s+Ld .*\(in target' "$log" | head -10)"
else
  lines="$(grep -E -A4 ': error:|error: |Undefined symbols|duplicate symbol|ld: |ld\[|fatal error|FAIL|Traceback|Error:|BUILD FAILED' "$log" \
    | grep -vE ': warning: |^\s*$' | awk '!seen[$0]++' | head -150)"
fi
[ -n "$lines" ] || lines="$(tail -40 "$log")"
# Workflow commands need %, CR and LF escaped.
body="$(printf '%s' "$lines" | sed -e 's/%/%25/g' -e 's/\r/%0D/g' | awk 'BEGIN{ORS="%0A"} {print}')"
echo "::error title=${title}::${body}"
