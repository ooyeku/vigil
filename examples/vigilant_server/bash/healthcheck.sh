#!/usr/bin/env bash

# Send healthcheck and capture response
# -w 2: wait 2 seconds for connection/response
response=$(printf "HEALTHCHECK\n" | nc -w 2 localhost 8080)
echo "Server response: '$response'"

if [ -n "$response" ] && echo "$response" | grep -q "OK"; then
    echo "OK: Server is responsive"
    exit 0
else
    echo "CRITICAL: Server not responding"
    exit 2
fi