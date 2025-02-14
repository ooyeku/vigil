#!/bin/bash

# Send status request and capture response
response=$(printf "STATUS\n" | nc -w 2 localhost 8080)
echo "Server response: '$response'"

if [ -n "$response" ] && echo "$response" | grep -q "OK"; then
    echo "OK: Server reports $(echo "$response" | cut -d' ' -f2) active connections"
    exit 0
else
    echo "CRITICAL: Server not responding correctly"
    exit 2
fi