cmake_minimum_required(VERSION 3.15 FATAL_ERROR)

project(valhalla-jni)

# Determine if we're being built as part of the main Valhalla project or standalone
if(NOT DEFINED VALHALLA_SOURCE_DIR)
    # Standalone build - set VALHALLA_SOURCE_DIR to parent directory
    get_filename_component(VALHALLA_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
    message(STATUS "Standalone build detected, VALHALLA_SOURCE_DIR: ${VALHALLA_SOURCE_DIR}")

    # For standalone builds, we need to find the valhalla library
    # Assume it's already built in the parent project
    if(NOT TARGET valhalla)
        message(WARNING "valhalla target not found. Make sure Valhalla is built first in the parent directory.")
    endif()
else()
    message(STATUS "Building as part of main Valhalla project")
endif()

# Find JNI
find_package(JNI REQUIRED)

if(NOT JNI_FOUND)
    message(FATAL_ERROR "JNI not found. Please install JDK and set JAVA_HOME environment variable.")
endif()

message(STATUS "JNI include directories: ${JNI_INCLUDE_DIRS}")
message(STATUS "JNI libraries: ${JNI_LIBRARIES}")

# Add JNI native library
add_library(valhalla_jni SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/valhalla_jni.cc
)

# Set library output directory
set_target_properties(valhalla_jni PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/libs/native
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/libs/native
)

# Include directories
target_include_directories(valhalla_jni PRIVATE
    ${JNI_INCLUDE_DIRS}
    ${VALHALLA_SOURCE_DIR}           # For valhalla/baldr/*, valhalla/midgard/*, etc.
    ${VALHALLA_SOURCE_DIR}/src       # For config.h and other src headers
    ${VALHALLA_SOURCE_DIR}/third_party/rapidjson/include
)

# Link libraries
target_link_libraries(valhalla_jni PRIVATE
    valhalla
    $<$<BOOL:${ENABLE_COVERAGE}>:gcov>
)

# Platform-specific settings
if(APPLE)
    set_target_properties(valhalla_jni PROPERTIES
        INSTALL_RPATH "@loader_path"
        SUFFIX ".dylib"
    )
elseif(UNIX AND NOT APPLE)
    set_target_properties(valhalla_jni PROPERTIES
        INSTALL_RPATH "\$ORIGIN"
    )
elseif(WIN32)
    # Windows-specific settings
    set_target_properties(valhalla_jni PROPERTIES
        SUFFIX ".dll"
    )
endif()

# Ensure valhalla library is position independent
set_target_properties(valhalla_jni PROPERTIES
    POSITION_INDEPENDENT_CODE ON
)

# Installation
install(TARGETS valhalla_jni
    LIBRARY DESTINATION lib
    RUNTIME DESTINATION bin
    COMPONENT java
)

message(STATUS "Java JNI bindings configured successfully")
