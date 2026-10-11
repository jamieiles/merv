add_library(merv-iss STATIC Hart.cpp RiscVELF.cpp)
target_include_directories(merv-iss PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(merv-sim main.cpp)
target_link_libraries(merv-sim merv-iss)
target_compile_definitions(merv-sim PRIVATE MERV_FFW_PATH="${MERV_FFW_ELF}")
add_dependencies(merv-sim ffw)
if(MERV_HAVE_RTL)
    target_link_libraries(merv-sim merv-rtl)
    target_compile_definitions(merv-sim PRIVATE MERV_HAVE_RTL)
    # The Verilator runtime headers aren't warning clean.
    target_compile_options(merv-sim PRIVATE -Wno-unused-parameter -Wno-sign-compare)
endif()

add_subdirectory(bootrom)
