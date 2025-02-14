#!/bin/bash
TEST_STR="TEST_$(date +%s)"
RESPONSE=$(printf "%s\n" "$TEST_STR" | nc -w 2 localhost 8080)
echo "Server response: '$RESPONSE'"

if [ "$RESPONSE" = "$TEST_STR" ]; then
  echo "OK: Echo test passed"
  exit 0
else
  echo "CRITICAL: Echo test failed"
  exit 2
fi