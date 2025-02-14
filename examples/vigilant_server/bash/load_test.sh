#!/bin/bash

# Run multiple STATUS requests in parallel and measure response times
for i in {1..100}; do 
  (
    start=$(date +%s.%N)
    response=$(printf "STATUS\n" | nc -w 2 localhost 8080)
    end=$(date +%s.%N)
    duration=$(echo "$end - $start" | bc)
    echo "Request $i: $response (${duration}s)"
  ) &
  # Add small delay between batches of requests
  if (( i % 10 == 0 )); then
    sleep 0.1
  fi
done
wait

# Print summary statistics
echo "Load test complete"