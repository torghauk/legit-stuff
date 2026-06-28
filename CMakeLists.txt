cmake_minimum_required(VERSION 3.16)
project(diag_viewer CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(json GIT_REPOSITORY https://github.com/nlohmann/json GIT_TAG v3.11.3)
FetchContent_MakeAvailable(json)
set(GLFW_BUILD_DOCS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GLFW_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_Declare(glfw GIT_REPOSITORY https://github.com/glfw/glfw GIT_TAG 3.4)
FetchContent_MakeAvailable(glfw)
FetchContent_Declare(imgui GIT_REPOSITORY https://github.com/ocornut/imgui GIT_TAG v1.91.5)
FetchContent_MakeAvailable(imgui)
find_package(OpenGL REQUIRED)
find_package(Threads REQUIRED)

# ---- viewer (consumer UI) ----
add_executable(viewer viewer.cpp
  ${imgui_SOURCE_DIR}/imgui.cpp ${imgui_SOURCE_DIR}/imgui_draw.cpp
  ${imgui_SOURCE_DIR}/imgui_tables.cpp ${imgui_SOURCE_DIR}/imgui_widgets.cpp
  ${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp ${imgui_SOURCE_DIR}/backends/imgui_impl_opengl3.cpp)
target_include_directories(viewer PRIVATE ${imgui_SOURCE_DIR} ${imgui_SOURCE_DIR}/backends ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(viewer PRIVATE glfw OpenGL::GL nlohmann_json::nlohmann_json Threads::Threads)

# ---- ingest CLI (consumer, headless; doubles as a test harness) ----
add_executable(ingest_main ingest_main.cpp)
target_include_directories(ingest_main PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ingest_main PRIVATE nlohmann_json::nlohmann_json)

# ---- reference producer (links the dependency-free diag.hpp; needs C++23 stacktrace) ----
add_executable(dummy_compiler dummy_compiler.cpp)
target_compile_features(dummy_compiler PRIVATE cxx_std_23)
target_link_libraries(dummy_compiler PRIVATE stdc++exp)   # GCC 13/14 on Ubuntu 24.04

# ---- optional: large-output producer for stress-testing the viewer's virtualization ----
add_executable(big_compiler big_compiler.cpp)
target_compile_features(big_compiler PRIVATE cxx_std_23)
target_link_libraries(big_compiler PRIVATE stdc++exp)
