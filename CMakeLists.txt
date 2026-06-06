cmake_minimum_required(VERSION 3.10)
project(Application)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(app src/main.cpp src/installer.cpp)

add_custom_command(TARGET app POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E echo "Build complete. Running application..."
    COMMAND app
    WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
)
