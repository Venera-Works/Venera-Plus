cmake_minimum_required(VERSION 3.14)
project(windows_native_tests LANGUAGES CXX)

set(RUNNER_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../runner")
set(FLUTTER_EPHEMERAL "${CMAKE_CURRENT_SOURCE_DIR}/../flutter/ephemeral")
if(NOT EXISTS "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib")
  message(FATAL_ERROR "Run flutter build windows --debug before these tests.")
endif()

add_executable(windows_startup_tests
  startup_test.cpp
  "${RUNNER_DIR}/startup_log.cpp"
  "${RUNNER_DIR}/win32_window.cpp"
  "${RUNNER_DIR}/window_startup.cpp"
)
add_executable(windows_hotkey_tests
  window_hotkey_test.cpp
  "${RUNNER_DIR}/window_hotkey.cpp"
)
foreach(test_target IN ITEMS windows_startup_tests windows_hotkey_tests)
  target_compile_features(${test_target} PRIVATE cxx_std_17)
  target_compile_definitions(${test_target} PRIVATE UNICODE _UNICODE NOMINMAX)
  target_compile_options(${test_target} PRIVATE /W4 /WX /wd4100 /EHsc)
  target_include_directories(${test_target} PRIVATE "${RUNNER_DIR}")
endforeach()
target_link_libraries(windows_hotkey_tests PRIVATE user32)
target_include_directories(windows_startup_tests PRIVATE
  "${RUNNER_DIR}" "${FLUTTER_EPHEMERAL}"
)
target_link_libraries(windows_startup_tests PRIVATE
  "${FLUTTER_EPHEMERAL}/flutter_windows.dll.lib"
  dwmapi shell32 ole32 uuid
)
add_custom_command(TARGET windows_startup_tests POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${FLUTTER_EPHEMERAL}/flutter_windows.dll"
    "$<TARGET_FILE_DIR:windows_startup_tests>"
)
enable_testing()
add_test(NAME windows_startup COMMAND windows_startup_tests)
add_test(NAME windows_hotkey COMMAND windows_hotkey_tests)
set_tests_properties(windows_startup windows_hotkey PROPERTIES TIMEOUT 30)
