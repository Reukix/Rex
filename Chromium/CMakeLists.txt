cmake_minimum_required(VERSION 3.21)
project(RexChromiumBridge LANGUAGES C CXX OBJC OBJCXX)

if(NOT CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
  message(FATAL_ERROR "Rex supports Apple Silicon (arm64) only")
endif()

set(CMAKE_CONFIGURATION_TYPES Debug Release)
set(PROJECT_ARCH arm64 CACHE STRING "Rex only supports arm64" FORCE)
set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../Vendor/CEF/current")
set(CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

add_library(RexChromiumBridge STATIC
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexChromiumRuntime.mm"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexChromiumRuntime.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexExtensionReconcilePolicy.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexMessagePumpPolicy.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexNavigationPolicy.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/Privacy/RexPrivacyEngine.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/Privacy/RexPrivacyEngine.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/Privacy/RexThoriumFlags.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/Privacy/RexThoriumFlags.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/Privacy/RexThoriumPolicy.h"
)
target_include_directories(RexChromiumBridge PUBLIC
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge"
  "${CEF_ROOT}"
)
target_compile_features(RexChromiumBridge PRIVATE cxx_std_20)
target_compile_options(RexChromiumBridge PRIVATE -fobjc-arc -fno-exceptions -fno-rtti)
target_compile_definitions(RexChromiumBridge PRIVATE CEF_USE_SANDBOX)

target_link_libraries(RexChromiumBridge PUBLIC
  libcef_dll_wrapper
  "-framework AppKit"
  "-framework Cocoa"
  "-framework IOSurface"
  "-framework Security"
  "-framework CoreFoundation"
  "-lc++"
)

enable_testing()
add_executable(RexNavigationPolicyTests
  "${CMAKE_CURRENT_SOURCE_DIR}/../Tests/ChromiumBridge/RexNavigationPolicyTests.cpp"
)
target_include_directories(RexNavigationPolicyTests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge"
)
target_compile_features(RexNavigationPolicyTests PRIVATE cxx_std_20)
add_test(NAME RexNavigationPolicyTests COMMAND RexNavigationPolicyTests)

add_executable(RexExtensionReconcilePolicyTests
  "${CMAKE_CURRENT_SOURCE_DIR}/../Tests/ChromiumBridge/RexExtensionReconcilePolicyTests.cpp"
)
target_include_directories(RexExtensionReconcilePolicyTests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge"
)
target_compile_features(RexExtensionReconcilePolicyTests PRIVATE cxx_std_20)
add_test(NAME RexExtensionReconcilePolicyTests COMMAND RexExtensionReconcilePolicyTests)

add_executable(RexCEFHelper MACOSX_BUNDLE
  "${CMAKE_CURRENT_SOURCE_DIR}/../ChromiumBridge/RexHelperMain.mm"
)
target_include_directories(RexCEFHelper PRIVATE "${CEF_ROOT}")
target_compile_features(RexCEFHelper PRIVATE cxx_std_20)
target_compile_options(RexCEFHelper PRIVATE -fobjc-arc -fno-exceptions -fno-rtti)
target_compile_definitions(RexCEFHelper PRIVATE CEF_USE_SANDBOX)
target_link_libraries(RexCEFHelper PRIVATE
  libcef_dll_wrapper
  "-framework AppKit"
  "-framework Cocoa"
  "-framework IOSurface"
)
