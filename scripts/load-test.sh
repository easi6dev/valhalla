#!/bin/bash

################################################################################
# Valhalla JNI Load Testing Script
################################################################################
# Phase 5: Testing & Monitoring
#
# This script runs various load tests on Valhalla JNI bindings
#
# Usage:
#   ./scripts/load-test.sh [test-type] [duration]
#
# Test types:
#   quick      - Quick test (100 requests)
#   standard   - Standard test (1000 requests)
#   sustained  - Sustained load (5 minutes)
#   stress     - Stress test (high concurrency)
#   all        - Run all tests
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_CLASS="global.tada.valhalla.LoadTest"
RESULTS_DIR="${PROJECT_ROOT}/build/reports/load-tests"

# Parse arguments
TEST_TYPE="${1:-standard}"
DURATION="${2:-}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Valhalla JNI Load Testing${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

# Function to run a specific test
run_test() {
    local test_name=$1
    local test_method=$2
    local description=$3

    echo -e "${GREEN}Running: $test_name${NC}"
    echo -e "${YELLOW}Description: $description${NC}"
    echo ""

    cd "${PROJECT_ROOT}/src/bindings/java"

    # Run test
    ./gradlew test --tests "${TEST_CLASS}.${test_method}" 2>&1 | tee "${RESULTS_DIR}/${test_name}.log"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ $test_name completed successfully${NC}"
    else
        echo -e "${RED}✗ $test_name failed${NC}"
        return 1
    fi

    echo ""
}

# Quick test
if [ "$TEST_TYPE" = "quick" ] || [ "$TEST_TYPE" = "all" ]; then
    echo -e "${BLUE}=== Quick Load Test ===${NC}"
    echo "This test runs 1000 sequential route calculations"
    echo ""
    run_test "quick-load" "testHighThroughput" "1000 sequential routes"
fi

# Concurrent load test
if [ "$TEST_TYPE" = "concurrent" ] || [ "$TEST_TYPE" = "all" ]; then
    echo -e "${BLUE}=== Concurrent Load Test ===${NC}"
    echo "This test runs 100 threads × 10 routes (1000 total)"
    echo ""
    run_test "concurrent-load" "testConcurrentLoad" "100 concurrent threads"
fi

# Sustained load test
if [ "$TEST_TYPE" = "sustained" ] || [ "$TEST_TYPE" = "all" ]; then
    echo -e "${BLUE}=== Sustained Load Test ===${NC}"
    echo "This test runs continuous routing for 1 minute"
    echo ""
    run_test "sustained-load" "testSustainedLoad" "1 minute continuous load"
fi

# Memory stability test
if [ "$TEST_TYPE" = "memory" ] || [ "$TEST_TYPE" = "all" ]; then
    echo -e "${BLUE}=== Memory Stability Test ===${NC}"
    echo "This test monitors memory usage under load"
    echo ""
    run_test "memory-stability" "testMemoryStability" "Memory leak detection"
fi

# Error handling test
if [ "$TEST_TYPE" = "error" ] || [ "$TEST_TYPE" = "all" ]; then
    echo -e "${BLUE}=== Error Handling Test ===${NC}"
    echo "This test validates error handling under stress"
    echo ""
    run_test "error-handling" "testErrorHandlingUnderStress" "Error handling validation"
fi

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Load Testing Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${BLUE}Results available at:${NC}"
echo -e "  Logs: ${RESULTS_DIR}/"
echo -e "  HTML Report: ${PROJECT_ROOT}/src/bindings/java/build/reports/tests/test/index.html"
echo ""

# Generate summary
echo -e "${BLUE}Test Summary:${NC}"
for log_file in "${RESULTS_DIR}"/*.log; do
    if [ -f "$log_file" ]; then
        test_name=$(basename "$log_file" .log)

        # Extract key metrics from log
        throughput=$(grep -oP 'Throughput: \K[0-9.]+' "$log_file" || echo "N/A")
        success_rate=$(grep -oP 'Success rate: \K[0-9.]+' "$log_file" || echo "N/A")

        echo -e "  ${test_name}:"
        echo -e "    - Throughput: ${throughput} routes/sec"
        echo -e "    - Success Rate: ${success_rate}%"
    fi
done

echo ""
