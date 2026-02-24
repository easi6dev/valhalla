# Quick Build Reference

## One-Line Build Command

```bash
wsl -d Ubuntu-22.04 -e bash -c "cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java && ./gradlew clean build"
```

---

## Automated Script

```bash
# From Windows or WSL
wsl -d Ubuntu-22.04 -e bash /mnt/c/Users/Vibin/Workspace/valhallaV3/build-jni-bindings.sh
```

---

## Manual Build Steps (WSL)

```bash
# 1. Enter WSL
wsl -d Ubuntu-22.04

# 2. Navigate to project
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java

# 3. Set environment (if not in ~/.bashrc)
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export LD_LIBRARY_PATH=/mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java/src/main/resources/lib/linux-amd64:$LD_LIBRARY_PATH

# 4. Build native library (if needed)
cd build
rm -rf *
cmake .. -DCMAKE_BUILD_TYPE=Release -DVALHALLA_SOURCE_DIR=/mnt/c/Users/Vibin/Workspace/valhallaV3
cmake --build . --config Release
cp libs/native/libvalhalla_jni.so ../src/main/resources/lib/linux-amd64/

# 5. Build JAR
cd /mnt/c/Users/Vibin/Workspace/valhallaV3/src/bindings/java
./gradlew clean build
```

---

## Common Commands

| Task | Command |
|------|---------|
| Full build | `./gradlew clean build` |
| Build without tests | `./gradlew assemble` |
| Run tests only | `./gradlew test` |
| Clean | `./gradlew clean` |
| Publish to local Maven | `./gradlew publishToMavenLocal` |
| Stop Gradle daemon | `./gradlew --stop` |

---

## Key Files

| File | Purpose |
|------|---------|
| `build-jni-bindings.sh` | Automated build script |
| `BUILD_JNI_GUIDE.md` | Detailed step-by-step guide |
| `src/bindings/java/CMakeLists.txt` | Native library build config |
| `src/bindings/java/build.gradle.kts` | Gradle build config |

---

## Output Locations

| Artifact | Path |
|----------|------|
| JAR files | `src/bindings/java/build/libs/*.jar` |
| Native JNI lib | `src/bindings/java/src/main/resources/lib/linux-amd64/libvalhalla_jni.so` |
| Test reports | `src/bindings/java/build/reports/tests/test/index.html` |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Build fails on Windows | Use WSL: `wsl -d Ubuntu-22.04` |
| CMake errors | Check C++20 support in CMakeLists.txt |
| Tests fail | Rebuild native lib in WSL first |
| Gradle errors | Run `./gradlew --stop` then rebuild |

---

## Prerequisites Checklist

- [ ] WSL Ubuntu 22.04 installed
- [ ] Build tools: `build-essential`, `cmake`, `git`
- [ ] Dependencies: `libboost-all-dev`, `libprotobuf-dev`, etc.
- [ ] Java 17: `openjdk-17-jdk`
- [ ] JAVA_HOME set in `~/.bashrc`
- [ ] Pre-built `libvalhalla.so.3.6.2` in resources directory
- [ ] Protobuf headers in `build/src/valhalla/proto/`

---

## Build Time

- **First build**: ~2-3 minutes
- **Incremental build**: ~30 seconds
- **Tests only**: ~3 seconds

---

## Success Check

```bash
# Check build success
echo $?  # Should return 0

# Verify JAR files
ls -lh build/libs/*.jar

# Check test results
cat build/reports/tests/test/index.html
```
