#!/bin/bash

################################################################################
# Valhalla JNI Performance Benchmarking Script
################################################################################
# Phase 5: Testing & Monitoring
#
# This script runs JMH performance benchmarks
#
# Usage:
#   ./scripts/run-benchmarks.sh [benchmark-name]
#
# Benchmark names:
#   simple       - Simple route (2 points)
#   medium       - Medium route (3 points)
#   complex      - Complex route (5 waypoints)
#   concurrent   - Concurrent routing (thread safety)
#   all          - Run all benchmarks
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
RESULTS_DIR="${PROJECT_ROOT}/build/reports/jmh"

# Parse arguments
BENCHMARK_NAME="${1:-all}"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Valhalla JNI Performance Benchmarks${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"

cd "${PROJECT_ROOT}/src/bindings/java"

# Build JMH benchmarks
echo -e "${GREEN}Building JMH benchmarks...${NC}"
./gradlew jmhJar

# Run benchmarks
echo -e "${GREEN}Running benchmarks...${NC}"
echo ""

case "$BENCHMARK_NAME" in
    simple)
        echo -e "${YELLOW}Running: Simple Route Benchmark${NC}"
        ./gradlew jmh -Pjmh.includes='.*benchmarkSimpleRoute.*'
        ;;

    medium)
        echo -e "${YELLOW}Running: Medium Route Benchmark${NC}"
        ./gradlew jmh -Pjmh.includes='.*benchmarkMediumRoute.*'
        ;;

    complex)
        echo -e "${YELLOW}Running: Complex Route Benchmark${NC}"
        ./gradlew jmh -Pjmh.includes='.*benchmarkComplexRoute.*'
        ;;

    concurrent)
        echo -e "${YELLOW}Running: Concurrent Routing Benchmark${NC}"
        ./gradlew jmh -Pjmh.includes='.*ConcurrentRouteBenchmark.*'
        ;;

    initialization)
        echo -e "${YELLOW}Running: Actor Initialization Benchmark${NC}"
        ./gradlew jmh -Pjmh.includes='.*ActorInitializationBenchmark.*'
        ;;

    all)
        echo -e "${YELLOW}Running: All Benchmarks${NC}"
        ./gradlew jmh
        ;;

    *)
        echo -e "${RED}Unknown benchmark: $BENCHMARK_NAME${NC}"
        echo -e "${YELLOW}Available benchmarks: simple, medium, complex, concurrent, initialization, all${NC}"
        exit 1
        ;;
esac

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}Benchmarks Complete!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${BLUE}Results available at:${NC}"
echo -e "  JSON: ${RESULTS_DIR}/results.json"
echo -e "  Text: ${RESULTS_DIR}/results.txt"
echo ""

# Parse and display results
if [ -f "${RESULTS_DIR}/results.json" ]; then
    echo -e "${BLUE}Benchmark Summary:${NC}"
    echo ""

    # Extract key metrics (requires jq)
    if command -v jq &> /dev/null; then
        jq -r '.[] | "\(.benchmark) - \(.mode): \(.primaryMetric.score) \(.primaryMetric.scoreUnit)"' "${RESULTS_DIR}/results.json"
    else
        echo -e "${YELLOW}Install 'jq' to see formatted results${NC}"
        echo -e "Raw results available in: ${RESULTS_DIR}/results.json"
    fi

    echo ""
fi

# Performance targets
echo -e "${BLUE}Performance Targets:${NC}"
echo -e "  Simple Route (2 points):  <  20ms (target: 15ms)"
echo -e "  Medium Route (3 points):  <  35ms (target: 25ms)"
echo -e "  Complex Route (5 points): <  80ms (target: 50ms)"
echo -e "  Concurrent Throughput:    > 400 routes/sec"
echo -e "  Actor Initialization:     < 250ms (target: 150ms)"
echo ""
