/*
 * Copyright (c) 2019-2026 Jamie Iles
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
 * either express or implied.
 *
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

#ifndef _COMPLIANCE_IO_H
#define _COMPLIANCE_IO_H

#define STRINGIFY(x) #x
#define TOSTRING(x)  STRINGIFY(x)

/*
 * Use a nop instruction to signal to the simulator that we have a potential
 * IO request and put mapping from PC to string in a well defined section
 * name.  The simulator can then find the string in memory and print it to
 * stderr.
 */
#define RVMODEL_IO_WRITE_STR(_SP, _STR)					\
800000:									\
	nop;								\
.pushsection ".rodata.str1.1", "a";					\
800001:									\
	.asciz _STR;							\
.popsection;								\
.pushsection ".rvtest_io_write";					\
	.word 800000b;							\
	.word 800001b;							\
.popsection

/*
 * Similar to RVTEST_IO_WRITE_STR, but build a table mapping instructions to
 * register names and expected values.  This means the simulator can perform
 * the assertion itself rather than relying on the model to correctly perform
 * the test.
 */
#define RVMODEL_IO_ASSERT_GPR_EQ(_SP, _R, _I)				\
900000:									\
	nop;								\
.pushsection ".rodata.str1.1", "a";					\
900001:									\
	.asciz TOSTRING(_R);						\
900002:									\
	.ascii __FILE__, ":", TOSTRING(__LINE__), "\0";			\
.popsection;								\
.pushsection ".rvtest_gpr_assert";					\
	.word 900000b;							\
	.word 900001b;							\
	.word _I;							\
	.word 900002b;							\
.popsection
#define RVTEST_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVTEST_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#define RVMODEL_HALT                                              \
	li gp, 1;						  \
        sw gp, tohost, t5;                                        \
	self_loop:  j self_loop;

#define RVMODEL_DATA_BEGIN                                              \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                      \
  .align 4; .global end_signature; end_signature:                             \
  RVMODEL_DATA_SECTION                                                        

#define RVMODEL_SET_MSW_INT

#define RVMODEL_CLEAR_MSW_INT

#define RVMODEL_CLEAR_MTIMER_INT

#define RVMODEL_CLEAR_MEXT_INT

#define RVMODEL_BOOT \
	.global _start; _start:

#endif // _COMPLIANCE_IO_H
