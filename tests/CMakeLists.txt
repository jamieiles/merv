set(DIRECTED_TESTS isolation counters csr_emul vm mip)

foreach(t ${DIRECTED_TESTS})
    add_riscv_elf(test-${t}
        LINKER_SCRIPT asm/test.ld
        MARCH rv32ima_zicsr_zifencei
        SOURCES asm/${t}.S
        INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/asm)
endforeach()

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
        separate_arguments(args)
    endif()
    foreach(t ${DIRECTED_TESTS})
        if(name MATCHES "^rtl-")
            set(test_name ${name}-directed-${t})
        else()
            set(test_name iss-directed-${t}-${name})
        endif()
        add_test(NAME ${test_name}
                 COMMAND $<TARGET_FILE:merv-sim> --elf ${CMAKE_CURRENT_BINARY_DIR}/test-${t}.elf
                         --compliance --max-steps 5000000 --trace-last 30 ${args})
    endforeach()
endforeach()

# SMP on the ISS, the RTL simulation has a single hart.
add_riscv_elf(test-smp
    LINKER_SCRIPT asm/test.ld
    MARCH rv32ima_zicsr_zifencei
    SOURCES asm/smp.S
    INCLUDES ${CMAKE_CURRENT_SOURCE_DIR}/asm)
foreach(cfg ${MERV_TEST_CONFIGS})
    string(REPLACE "|" ";" parts "${cfg}")
    list(GET parts 0 name)
    list(LENGTH parts n)
    set(args "")
    if(n GREATER 1)
        list(GET parts 1 args)
        separate_arguments(args)
    endif()
    add_test(NAME iss-directed-smp-${name}
             COMMAND $<TARGET_FILE:merv-sim> --elf ${CMAKE_CURRENT_BINARY_DIR}/test-smp.elf
                     --compliance --harts 4 --max-steps 5000000 --trace-last 30 ${args})
endforeach()
