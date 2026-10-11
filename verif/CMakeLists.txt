find_package(Python3 REQUIRED COMPONENTS Interpreter)

# riscv-tests: the env/v tests need some libc headers, a bare-metal toolchain
# without newlib can use the generic newlib headers.
set(RISCV_TESTS_EXTRA_CFLAGS "" CACHE STRING "Extra flags for building riscv-tests")
if(NOT RISCV_TESTS_EXTRA_CFLAGS AND EXISTS /usr/include/newlib/string.h)
    set(RISCV_TESTS_EXTRA_CFLAGS "-isystem /usr/include/newlib")
endif()
set(RISCV_TESTS_SRC ${PROJECT_SOURCE_DIR}/vendor/riscv-tests/isa)
set(RISCV_TESTS_DIR ${CMAKE_CURRENT_BINARY_DIR}/riscv-tests)
add_custom_command(
    OUTPUT ${RISCV_TESTS_DIR}/.stamp
    COMMAND ${CMAKE_COMMAND} -E make_directory ${RISCV_TESTS_DIR}
    COMMAND make -s -C ${RISCV_TESTS_DIR} -f ${RISCV_TESTS_SRC}/Makefile
            src_dir=${RISCV_TESTS_SRC} XLEN=32 RISCV_PREFIX=${RISCV_PREFIX}
            "RISCV_GCC_OPTS=-static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles ${RISCV_TESTS_EXTRA_CFLAGS}"
            rv32ui rv32um rv32ua rv32si rv32mi
    COMMAND ${CMAKE_COMMAND} -E touch ${RISCV_TESTS_DIR}/.stamp
    COMMENT "Building riscv-tests")
add_custom_target(riscv-tests ALL DEPENDS ${RISCV_TESTS_DIR}/.stamp)

set(configs ${MERV_TEST_CONFIGS})
if(MERV_HAVE_RTL)
    list(APPEND configs ${MERV_RTL_TEST_CONFIGS})
endif()

foreach(cfg ${configs})
    string(REPLACE "|" ";" parts "${cfg}")
    list(GET parts 0 name)
    list(LENGTH parts n)
    set(args "")
    if(n GREATER 1)
        list(GET parts 1 args)
    endif()
    if(name MATCHES "^rtl-")
        set(prefix ${name})
        set(suffix "")
    else()
        set(prefix iss)
        set(suffix -${name})
    endif()
    add_test(NAME ${prefix}-riscv-tests${suffix}
             COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/scripts/run-isa-tests.py
                     $<TARGET_FILE:merv-sim> ${RISCV_TESTS_DIR} --sim-args=${args}
                     --timeout 900)
    add_test(NAME ${prefix}-arch-test${suffix}
             COMMAND ${Python3_EXECUTABLE} ${PROJECT_SOURCE_DIR}/scripts/run-compliance-tests.py
                     $<TARGET_FILE:merv-sim> ${PROJECT_SOURCE_DIR}/vendor/riscv-arch-test
                     ${CMAKE_CURRENT_BINARY_DIR}/arch-test-${name}
                     ${CMAKE_CURRENT_SOURCE_DIR}/arch-test-target --sim-args=${args})
endforeach()

# Linux boot on the ISS, skipped unless scripts/build-software.sh has been run.
set(MERV_SW_DIR ${CMAKE_BINARY_DIR}/sw CACHE PATH "Output of scripts/build-software.sh")
foreach(cfg ${MERV_TEST_CONFIGS})
    string(REPLACE "|" ";" parts "${cfg}")
    list(GET parts 0 name)
    list(LENGTH parts n)
    set(args "")
    if(n GREATER 1)
        list(GET parts 1 args)
        separate_arguments(args)
    endif()
    add_test(NAME iss-linux-boot-${name}
             COMMAND ${PROJECT_SOURCE_DIR}/scripts/run-linux-boot.sh
                     $<TARGET_FILE:merv-sim>
                     ${CMAKE_BINARY_DIR}/sim/bootrom/sim-bootrom.elf
                     ${MERV_SW_DIR} ${args})
    set_tests_properties(iss-linux-boot-${name} PROPERTIES SKIP_RETURN_CODE 77)
endforeach()

add_subdirectory(rtl)
