cmake_minimum_required(VERSION 3.5.0)
project(sscore)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})
set(ENTRY_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../../../)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

if(NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH arm64-v8a)
endif()

# Go runtime lives in libssgo.so (not a NAPI module). A thin NAPI wrapper
# libssengine.so is loaded by Harmony and then dlopens libssgo.so from $ORIGIN.
# Do NOT DT_NEEDED-link Go into libentry.so.
set(SSGO_SO ${ENTRY_ROOT_PATH}/libs/${OHOS_ARCH}/libssgo.so)
if(NOT EXISTS ${SSGO_SO})
    message(FATAL_ERROR "missing ${SSGO_SO}; run native/ssengine/build.sh")
endif()

add_library(entry SHARED napi_init.cpp)
target_link_libraries(entry PUBLIC libace_napi.z.so libhilog_ndk.z.so)

# Harmony loads libssengine.so as NAPI; DT_NEEDED libssgo.so is resolved from
# the same HAP libs/ dir. Do not embed host rpath via IMPORTED_LOCATION.
add_library(ssengine SHARED ssengine_napi.cpp)
target_link_directories(ssengine PRIVATE ${ENTRY_ROOT_PATH}/libs/${OHOS_ARCH})
target_link_libraries(ssengine PUBLIC libace_napi.z.so libhilog_ndk.z.so ssgo)
set_target_properties(ssengine PROPERTIES BUILD_RPATH "$ORIGIN" INSTALL_RPATH "$ORIGIN")
