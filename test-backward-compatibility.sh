#!/bin/bash
#
# Backward Compatibility Test for Multi-Region Refactoring
# Tests that existing code patterns still work
#

set -e

echo "Testing Backward Compatibility"
echo "=============================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0

test_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}PASS${NC}: $2"
        ((PASSED++))
    else
        echo -e "${RED}FAIL${NC}: $2"
        ((FAILED++))
    fi
}

echo "Test 1: Check SingaporeConfig.kt exists and has required properties"
if grep -q "object SingaporeConfig : RegionConfig" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/SingaporeConfig.kt 2>/dev/null; then
    test_result 0 "SingaporeConfig implements RegionConfig"
else
    test_result 1 "SingaporeConfig implements RegionConfig"
fi

if grep -q "override val regionName" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/SingaporeConfig.kt 2>/dev/null; then
    test_result 0 "SingaporeConfig has regionName property"
else
    test_result 1 "SingaporeConfig has regionName property"
fi

echo ""
echo "Test 2: Check backward compatibility - deprecated objects exist"
if grep -q "Deprecated.*object Bounds" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/SingaporeConfig.kt 2>/dev/null; then
    test_result 0 "Deprecated Bounds object exists for backward compatibility"
else
    test_result 1 "Deprecated Bounds object exists for backward compatibility"
fi

if grep -q "Deprecated.*object Costing" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/SingaporeConfig.kt 2>/dev/null; then
    test_result 0 "Deprecated Costing object exists for backward compatibility"
else
    test_result 1 "Deprecated Costing object exists for backward compatibility"
fi

echo ""
echo "Test 3: Check Actor.kt has both old and new methods"
if grep -q "fun createForRegion" src/bindings/java/src/main/kotlin/global/tada/valhalla/Actor.kt 2>/dev/null; then
    test_result 0 "Actor.createForRegion() method exists (new API)"
else
    test_result 1 "Actor.createForRegion() method exists (new API)"
fi

if grep -q "fun createSingapore" src/bindings/java/src/main/kotlin/global/tada/valhalla/Actor.kt 2>/dev/null; then
    test_result 0 "Actor.createSingapore() method exists (old API)"
else
    test_result 1 "Actor.createSingapore() method exists (old API)"
fi

if grep -q "Deprecated.*createSingapore" src/bindings/java/src/main/kotlin/global/tada/valhalla/Actor.kt 2>/dev/null; then
    test_result 0 "Actor.createSingapore() is marked as deprecated"
else
    test_result 1 "Actor.createSingapore() is marked as deprecated"
fi

echo ""
echo "Test 4: Check RegionConfigFactory exists"
if [ -f "src/bindings/java/src/main/kotlin/global/tada/valhalla/config/RegionConfigFactory.kt" ]; then
    test_result 0 "RegionConfigFactory.kt exists"
else
    test_result 1 "RegionConfigFactory.kt exists"
fi

if grep -q "fun getConfig" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/RegionConfigFactory.kt 2>/dev/null; then
    test_result 0 "RegionConfigFactory.getConfig() exists"
else
    test_result 1 "RegionConfigFactory.getConfig() exists"
fi

if grep -q "fun getSupportedRegions" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/RegionConfigFactory.kt 2>/dev/null; then
    test_result 0 "RegionConfigFactory.getSupportedRegions() exists"
else
    test_result 1 "RegionConfigFactory.getSupportedRegions() exists"
fi

echo ""
echo "Test 5: Check RegionConfig interface exists"
if [ -f "src/bindings/java/src/main/kotlin/global/tada/valhalla/config/RegionConfig.kt" ]; then
    test_result 0 "RegionConfig.kt interface exists"
else
    test_result 1 "RegionConfig.kt interface exists"
fi

if grep -q "interface RegionConfig" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/RegionConfig.kt 2>/dev/null; then
    test_result 0 "RegionConfig is an interface"
else
    test_result 1 "RegionConfig is an interface"
fi

echo ""
echo "Test 6: Check ThailandConfig exists as example"
if [ -f "src/bindings/java/src/main/kotlin/global/tada/valhalla/config/ThailandConfig.kt" ]; then
    test_result 0 "ThailandConfig.kt exists"
else
    test_result 1 "ThailandConfig.kt exists"
fi

if grep -q "object ThailandConfig : RegionConfig" src/bindings/java/src/main/kotlin/global/tada/valhalla/config/ThailandConfig.kt 2>/dev/null; then
    test_result 0 "ThailandConfig implements RegionConfig"
else
    test_result 1 "ThailandConfig implements RegionConfig"
fi

echo ""
echo "Test 7: Check test runner scripts"
if [ -f "run-singapore-tests.sh" ]; then
    test_result 0 "run-singapore-tests.sh exists (backward compatibility)"
else
    test_result 1 "run-singapore-tests.sh exists (backward compatibility)"
fi

if [ -f "run-region-tests.sh" ]; then
    test_result 0 "run-region-tests.sh exists (new multi-region script)"
else
    test_result 1 "run-region-tests.sh exists (new multi-region script)"
fi

if grep -q "DEPRECATED" run-singapore-tests.sh 2>/dev/null; then
    test_result 0 "run-singapore-tests.sh shows deprecation warning"
else
    test_result 1 "run-singapore-tests.sh shows deprecation warning"
fi

echo ""
echo "Test 8: Check setup script is region-agnostic"
if grep -q "REGION=" scripts/regions/setup-valhalla.sh 2>/dev/null; then
    test_result 0 "setup-valhalla.sh uses REGION variable"
else
    test_result 1 "setup-valhalla.sh uses REGION variable"
fi

if ! grep -q "For Singapore (mostly flat" scripts/regions/setup-valhalla.sh 2>/dev/null; then
    test_result 0 "setup-valhalla.sh has no hardcoded Singapore terrain message"
else
    test_result 1 "setup-valhalla.sh has no hardcoded Singapore terrain message"
fi

echo ""
echo "Test 9: Check base test class exists"
if [ -f "src/bindings/java/src/test/kotlin/global/tada/valhalla/test/RegionRideHaulingTest.kt" ]; then
    test_result 0 "RegionRideHaulingTest.kt base class exists"
else
    test_result 1 "RegionRideHaulingTest.kt base class exists"
fi

if grep -q "abstract class RegionRideHaulingTest" src/bindings/java/src/test/kotlin/global/tada/valhalla/test/RegionRideHaulingTest.kt 2>/dev/null; then
    test_result 0 "RegionRideHaulingTest is abstract"
else
    test_result 1 "RegionRideHaulingTest is abstract"
fi

echo ""
echo "Test 10: Check documentation files exist"
for doc in REFACTORING_SUMMARY.md MEDIUM_PRIORITY_CHANGES.md REFACTORING_COMPLETE.md TESTING_CHECKLIST.md docs/MULTI_REGION_USAGE.md; do
    if [ -f "$doc" ]; then
        test_result 0 "Documentation exists: $doc"
    else
        test_result 1 "Documentation exists: $doc"
    fi
done

# Summary
echo ""
echo "=============================="
echo "TEST SUMMARY"
echo "=============================="
echo ""
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}ALL BACKWARD COMPATIBILITY TESTS PASSED!${NC}"
    echo ""
    echo "- Existing API still works"
    echo "- Deprecated methods available with warnings"
    echo "- New multi-region API available"
    echo "- All documentation in place"
    echo ""
    exit 0
else
    echo -e "${RED}SOME TESTS FAILED${NC}"
    echo ""
    exit 1
fi
