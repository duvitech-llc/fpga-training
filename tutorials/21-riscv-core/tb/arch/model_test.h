// The target header for the RISC-V architecture tests, for this course's core.
// Each test includes it before the suite's own arch_test.h. It says how to start,
// how to stop, and where the signature is. Nothing here comes from the suite.
//
// Start: the core leaves reset at address 0, and tb/arch/link.ld puts the test's
// entry point there. No set-up is needed, since there are no CSRs to set.
//
// Stop: ebreak. This core has no trap handler, so ebreak stops it with
// trap_cause 3, and tb_arch.v takes that as the end of the test. Any other trap
// is a failure.
//
// Signature: the words from begin_signature to end_signature. The Makefile reads
// both addresses from the ELF with nm and gives them to tb_arch.v. Both are
// aligned to 16 bytes, as the suite's own Sail target does, so the region has
// the same length as the reference.
#ifndef MODEL_TEST_H
#define MODEL_TEST_H

#define RVMODEL_BOOT

#define RVMODEL_HALT \
    ebreak;

#define RVMODEL_DATA_BEGIN \
    .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END \
    .align 4; .global end_signature; end_signature:

// The tests can also print and check registers as they go. This target only
// uses the signature, so these do nothing.
#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

// jalr-01 writes `la x0, label` for its rd = x0 case, and the assembler in GCC 15
// rejects that. This macro takes the place of la. For x0 it makes two instructions
// that write x0, so do nothing, the same size as la. For any other register it is
// lla, which is what la means without -fPIC.
.macro la rd, sym
  .ifc \rd, x0
    auipc x0, 0
    addi  x0, x0, 0
  .else
    lla   \rd, \sym
  .endif
.endm

// Interrupts. The core has none.
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif
