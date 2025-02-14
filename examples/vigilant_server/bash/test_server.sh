#!/bin/bash

# Function to send a request and measure response time in milliseconds
send_request() {
    local start=$(date +%s.%N)
    local response=$(echo "$1" | nc -w 1 127.0.0.1 8080)
    local end=$(date +%s.%N)
    local duration=$(echo "($end - $start) * 1000" | bc)
    # Store response for debugging if needed
    echo "$response" > /dev/null
    printf "%.0f" "$duration"
}

# Arrays to store timing results
declare -A avg_times
declare -A min_times
declare -A max_times
declare -A total_times
declare -A count_times

# Function to update statistics
update_stats() {
    local category=$1
    local duration=$2
    
    # Initialize if first entry
    if [ -z "${count_times[$category]}" ]; then
        min_times[$category]=$duration
        max_times[$category]=$duration
        total_times[$category]=0
        count_times[$category]=0
    fi
    
    # Update stats
    if [ "$duration" -lt "${min_times[$category]}" ]; then
        min_times[$category]=$duration
    fi
    if [ "$duration" -gt "${max_times[$category]}" ]; then
        max_times[$category]=$duration
    fi
    
    total_times[$category]=$((total_times[$category] + duration))
    count_times[$category]=$((count_times[$category] + 1))
}

# Print results for a category
print_stats() {
    local category=$1
    if [ "${count_times[$category]}" -gt 0 ]; then
        local avg=$((total_times[$category] / count_times[$category]))
        echo "Category: $category"
        echo "  Min: ${min_times[$category]}ms"
        echo "  Max: ${max_times[$category]}ms"
        echo "  Avg: ${avg}ms"
        echo "  Count: ${count_times[$category]}"
        echo "-------------------"
    fi
}

echo "Starting benchmarks..."

# Test standard commands
for i in {1..10}; do
    echo -n "Standard commands test $i/10... "
    duration=$(send_request "HEALTHCHECK")
    update_stats "HEALTHCHECK" $duration
    duration=$(send_request "STATUS")
    update_stats "STATUS" $duration
done

# Test various message lengths
for i in {1..10}; do
    echo -n "Variable length test $i/10... "
    duration=$(send_request "$(yes 'x' | head -n $i | tr -d '\n')")
    update_stats "VARIABLE_LENGTH" $duration
    duration=$(send_request "$(openssl rand -base64 $((i*10)))")
    update_stats "RANDOM_DATA" $duration
done

# Test special characters
for i in {1..10}; do
    echo -n "Special chars test $i/10... "
    duration=$(send_request "!@#$%^&*()_+-=[]{}|;:',.<>/?")
    update_stats "SPECIAL_CHARS" $duration
    duration=$(send_request "🚀 💻 🔥 🌟 🎮 📱 🎨 🎭 🎪 🎢")
    update_stats "EMOJI" $duration
done

# Test JSON-like messages
for i in {1..10}; do
    echo -n "JSON test $i/10... "
    duration=$(send_request "{\"id\": $i, \"type\": \"test\", \"value\": \"message\"}")
    update_stats "JSON" $duration
    duration=$(send_request "[{\"array\": $i}, {\"of\": \"json\"}, {\"objects\": true}]")
    update_stats "JSON_ARRAY" $duration
done

# Test with random words
WORDS=("hello" "world" "test" "server" "network" "socket" "protocol" "message" "data" "stream")
for i in {1..10}; do
    echo -n "Random words test $i/10... "
    word1=${WORDS[$((RANDOM % 10))]}
    word2=${WORDS[$((RANDOM % 10))]}
    word3=${WORDS[$((RANDOM % 10))]}
    duration=$(send_request "$word1 $word2 $word3")
    update_stats "WORD_COMBINATIONS" $duration
done

echo -e "\n=== BENCHMARK RESULTS ===\n"

# Print all statistics
print_stats "HEALTHCHECK"
print_stats "STATUS"
print_stats "VARIABLE_LENGTH"
print_stats "RANDOM_DATA"
print_stats "SPECIAL_CHARS"
print_stats "EMOJI"
print_stats "JSON"
print_stats "JSON_ARRAY"
print_stats "WORD_COMBINATIONS"