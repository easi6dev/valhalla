# Testing Checklist for Multi-Region Refactoring

Use this checklist to verify all changes are working correctly.

---

## 🎯 Prerequisites

- [ ] Build directory exists: `build/src/libvalhalla.so`
- [ ] JNI library exists: `build/src/bindings/java/libs/native/libvalhalla_jni.so`
- [ ] Singapore tiles exist: `data/valhalla_tiles/singapore/*.gph`
- [ ] Gradle wrapper works: `cd src/bindings/java && ./gradlew --version`

---

## 🧪 Test 1: Backward Compatibility (Critical)

**Purpose:** Ensure existing code still works without changes.

### Test 1.1: Old Test Runner Script
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3
./run-singapore-tests.sh
```

**Expected:**
- [ ] Shows deprecation warning
- [ ] Redirects to new script
- [ ] Runs Singapore tests successfully
- [ ] No errors

### Test 1.2: Old Java API (if you have existing Java code)
```kotlin
// Old API - should still work
val actor = Actor.createSingapore()
val result = actor.route(request)
actor.close()
```

**Expected:**
- [ ] Compiles with deprecation warning
- [ ] Works exactly as before
- [ ] No runtime errors

---

## 🧪 Test 2: New Multi-Region API

### Test 2.1: New Test Runner Script
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3

# Test with explicit region
./run-region-tests.sh singapore

# Test default (should be singapore)
./run-region-tests.sh
```

**Expected:**
- [ ] Color-coded output
- [ ] Shows region name in header
- [ ] Validates tiles before running
- [ ] Runs tests successfully
- [ ] Creates log file: `singapore-test-results.log`

### Test 2.2: Region Discovery API
```kotlin
import global.tada.valhalla.config.RegionConfigFactory

// List supported regions
val regions = RegionConfigFactory.getSupportedRegions()
println("Supported: $regions")
// Expected output: [singapore, thailand]

// Check if region is supported
val isSupported = RegionConfigFactory.isSupported("singapore")
println("Singapore supported: $isSupported")
// Expected: true

// Get region info
val info = RegionConfigFactory.getRegionInfo("singapore")
println("Region: ${info["name"]}")
println("Timezone: ${info["timezone"]}")
// Expected: Region: Singapore, Timezone: Asia/Singapore
```

**Expected:**
- [ ] Lists all regions correctly
- [ ] isSupported() returns correct boolean
- [ ] getRegionInfo() returns complete data
- [ ] No errors

### Test 2.3: New Actor Creation API
```kotlin
import global.tada.valhalla.Actor

// Create actor for Singapore
val sgActor = Actor.createForRegion("singapore")
println("Created Singapore actor")

// Test with alias
val sgActor2 = Actor.createForRegion("sg")
println("Created Singapore actor with alias")

// Test with custom path
val sgActor3 = Actor.createForRegion(
    "singapore",
    "/custom/path/to/tiles"
)

sgActor.close()
sgActor2.close()
// sgActor3.close() // Only if custom path exists
```

**Expected:**
- [ ] Creates actor successfully
- [ ] Alias "sg" works
- [ ] Custom path works (if path exists)
- [ ] No exceptions

---

## 🧪 Test 3: Setup Script

### Test 3.1: Singapore Setup
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3

# Full setup (skip if already done)
./scripts/regions/setup-valhalla.sh --region singapore --skip-install --skip-download --skip-build --skip-validate
```

**Expected:**
- [ ] Shows region name (not hardcoded "Singapore")
- [ ] Success message mentions `Actor.createForRegion("singapore")`
- [ ] Points to MULTI_REGION_USAGE.md
- [ ] No Singapore-specific terrain messages
- [ ] Runs tests successfully

### Test 3.2: Help Text
```bash
./scripts/regions/setup-valhalla.sh --help
```

**Expected:**
- [ ] Shows region parameter
- [ ] Examples for multiple regions
- [ ] No hardcoded Singapore references

---

## 🧪 Test 4: JAR Bundling

### Test 4.1: Bundle for Singapore
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3

# Bundle JAR (this will rebuild)
./bundle-production-jar.sh singapore
```

**Expected:**
- [ ] Shows region in header: "Region: Singapore"
- [ ] Copies all libraries
- [ ] Builds JAR successfully
- [ ] Runs SingaporeRideHaulingTest
- [ ] Shows usage with `Actor.createForRegion("singapore")`
- [ ] Creates JAR in `src/bindings/java/build/libs/`

### Test 4.2: Verify JAR Contents
```bash
cd src/bindings/java/build/libs
jar tf valhalla-jni-*.jar | grep "\.so$"
```

**Expected:**
- [ ] Contains libvalhalla_jni.so
- [ ] Contains libvalhalla.so.3
- [ ] Contains system libraries
- [ ] All .so files in lib/linux-amd64/

---

## 🧪 Test 5: Region Configuration

### Test 5.1: Get Singapore Config
```kotlin
import global.tada.valhalla.config.SingaporeConfig

val config = SingaporeConfig
println("Name: ${config.regionName}")
println("Timezone: ${config.timezone}")
println("Currency: ${config.currency}")

// Check bounds
val isValid = config.bounds.isValidLocation(1.3, 103.8)
println("Location valid: $isValid")

// Get center
val (lat, lon) = config.bounds.center()
println("Center: $lat, $lon")

// Get area
val area = config.bounds.approximateArea()
println("Area: $area km²")
```

**Expected:**
- [ ] Returns "Singapore" as name
- [ ] Timezone is "Asia/Singapore"
- [ ] Currency is "SGD"
- [ ] Location validation works
- [ ] Center is approximately (1.315, 103.8)
- [ ] Area is approximately 700-800 km²

### Test 5.2: Get Thailand Config
```kotlin
import global.tada.valhalla.config.ThailandConfig

val config = ThailandConfig
println("Name: ${config.regionName}")
println("Timezone: ${config.timezone}")
println("Currency: ${config.currency}")

// Check bounds
val isBangkok = config.bounds.isValidLocation(13.7, 100.5)
println("Bangkok in bounds: $isBangkok")

val area = config.bounds.approximateArea()
println("Area: $area km²")
```

**Expected:**
- [ ] Returns "Thailand" as name
- [ ] Timezone is "Asia/Bangkok"
- [ ] Currency is "THB"
- [ ] Bangkok coordinates validate correctly
- [ ] Area is approximately 513,000 km²

---

## 🧪 Test 6: Thailand Support (Optional - Only if Tiles Built)

### Test 6.1: Download Thailand Data
```bash
cd /mnt/c/Users/Vibin/Workspace/valhallaV3
./scripts/regions/download-region-osm.sh thailand
```

**Expected:**
- [ ] Downloads from Geofabrik
- [ ] Verifies MD5 checksum
- [ ] Saves to data/osm/thailand-latest.osm.pbf
- [ ] Shows next steps for building tiles

### Test 6.2: Build Thailand Tiles
```bash
./scripts/regions/build-tiles.sh thailand --no-elevation
```

**Expected:**
- [ ] Creates temp config
- [ ] Builds tiles successfully
- [ ] Creates data/valhalla_tiles/thailand/
- [ ] Contains .gph files
- [ ] Shows tile statistics

### Test 6.3: Validate Thailand Tiles
```bash
./scripts/regions/validate-tiles.sh thailand
```

**Expected:**
- [ ] Finds tile directory
- [ ] Counts .gph files
- [ ] Shows tile hierarchy
- [ ] All validation tests pass

### Test 6.4: Run Thailand Tests
```bash
./run-region-tests.sh thailand
```

**Expected:**
- [ ] Creates Thailand actor
- [ ] Shows Thailand in header
- [ ] Runs tests (if ThailandRideHaulingTest exists)
- [ ] Or shows "test class not found" (expected if not created yet)

### Test 6.5: Use Thailand in Code
```kotlin
val actor = Actor.createForRegion("thailand")

// Route from Bangkok to Chiang Mai
val request = """
{
  "locations": [
    {"lat": 13.756, "lon": 100.502},
    {"lat": 18.788, "lon": 98.986}
  ],
  "costing": "auto"
}
"""

val result = actor.route(request)
println(result)

actor.close()
```

**Expected:**
- [ ] Creates actor successfully
- [ ] Returns valid route
- [ ] Distance ~600-800 km
- [ ] No errors

---

## 🧪 Test 7: Error Handling

### Test 7.1: Invalid Region
```kotlin
try {
    Actor.createForRegion("invalid-region")
} catch (e: IllegalArgumentException) {
    println("Error: ${e.message}")
}
```

**Expected:**
- [ ] Throws IllegalArgumentException
- [ ] Error message lists supported regions
- [ ] Suggests valid options

### Test 7.2: Tiles Not Found
```kotlin
try {
    Actor.createForRegion("thailand", "/nonexistent/path")
} catch (e: Exception) {
    println("Error: ${e.message}")
}
```

**Expected:**
- [ ] Throws exception
- [ ] Clear error message about missing tiles

### Test 7.3: Test Runner with Missing Tiles
```bash
./run-region-tests.sh thailand  # If tiles not built
```

**Expected:**
- [ ] Checks for tiles directory
- [ ] Shows helpful error message
- [ ] Suggests download and build commands
- [ ] Exits with error code

---

## 🧪 Test 8: Documentation

### Test 8.1: Check Documentation Files
```bash
ls -la *.md
ls -la docs/*.md
```

**Expected:**
- [ ] REFACTORING_SUMMARY.md exists
- [ ] MEDIUM_PRIORITY_CHANGES.md exists
- [ ] REFACTORING_COMPLETE.md exists
- [ ] TESTING_CHECKLIST.md exists (this file)
- [ ] docs/MULTI_REGION_USAGE.md exists

### Test 8.2: Verify Examples in Docs
```bash
# Check if examples compile
grep -A 10 "```kotlin" docs/MULTI_REGION_USAGE.md
```

**Expected:**
- [ ] Examples are syntactically correct
- [ ] Use current API (createForRegion)
- [ ] Include multiple regions

---

## 📊 Test Summary

### Critical Tests (Must Pass):
- [ ] Test 1: Backward Compatibility
- [ ] Test 2: New Multi-Region API
- [ ] Test 4: JAR Bundling
- [ ] Test 5: Region Configuration

### Important Tests (Should Pass):
- [ ] Test 3: Setup Script
- [ ] Test 7: Error Handling

### Optional Tests (Nice to Have):
- [ ] Test 6: Thailand Support (only if tiles built)
- [ ] Test 8: Documentation

---

## 🐛 Known Issues / Expected Warnings

### Deprecation Warnings:
- ✅ `Actor.createSingapore()` shows deprecation - **EXPECTED**
- ✅ `SingaporeConfig.Bounds` shows deprecation - **EXPECTED**
- ✅ `SingaporeConfig.Costing` shows deprecation - **EXPECTED**

These are intentional to guide migration to new API.

### Test Class Not Found:
- ✅ ThailandRideHaulingTest not found - **EXPECTED** (low priority task)

This is expected if low-priority tasks not completed.

---

## ✅ Sign-Off Checklist

Before considering testing complete, verify:

- [ ] All critical tests pass
- [ ] No unexpected errors
- [ ] Backward compatibility confirmed
- [ ] New API works as documented
- [ ] JAR bundles successfully
- [ ] Error messages are helpful
- [ ] Documentation is accurate

---

## 🚨 What to Do If Tests Fail

### If backward compatibility fails:
1. Check git status - ensure all files committed
2. Verify SingaporeConfig still has deprecated objects
3. Check Actor.kt has deprecated createSingapore()

### If new API fails:
1. Check RegionConfigFactory registration
2. Verify config files are in correct location
3. Check import statements

### If JAR bundling fails:
1. Verify build directory exists
2. Check library paths
3. Ensure gradlew is executable

### If tests can't find tiles:
1. Check tile directory: `data/valhalla_tiles/singapore/`
2. Verify .gph files exist
3. Rebuild if necessary: `./scripts/regions/build-tiles.sh singapore`

---

## 📞 Getting Help

If tests fail and you can't resolve:
1. Check error messages carefully
2. Review REFACTORING_COMPLETE.md
3. Check MULTI_REGION_USAGE.md for examples
4. Verify file locations match documentation

---

**Good luck with testing! 🎉**

*Last Updated: 2026-02-20*
