.section .text
.code64

.global zigix_lgdt_reload
.type zigix_lgdt_reload, @function
zigix_lgdt_reload:
    lgdt    (%rdi)
    pushq   $0x08
    leaq    1f(%rip), %rax
    pushq   %rax
    lretq
1:
    movw    $0x10, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    xorl    %eax, %eax
    movw    %ax, %fs
    movw    %ax, %gs
    retq
.size zigix_lgdt_reload, . - zigix_lgdt_reload

.global zigix_lidt
.type zigix_lidt, @function
zigix_lidt:
    lidt    (%rdi)
    retq
.size zigix_lidt, . - zigix_lidt

.global zigix_ltr
.type zigix_ltr, @function
zigix_ltr:
    movw    %di, %ax
    ltr     %ax
    retq
.size zigix_ltr, . - zigix_ltr

.global zigix_enter_user
.type zigix_enter_user, @function
zigix_enter_user:
    movw    $0x23, %ax
    movw    %ax, %ds
    movw    %ax, %es
    pushq   $0x23
    pushq   %rsi
    pushfq
    orq     $0x200, (%rsp)
    pushq   $0x1b
    pushq   %rdi
    iretq
.size zigix_enter_user, . - zigix_enter_user

.macro SAVE_GPRS
    pushq   %rax
    pushq   %rbx
    pushq   %rcx
    pushq   %rdx
    pushq   %rsi
    pushq   %rdi
    pushq   %rbp
    pushq   %r8
    pushq   %r9
    pushq   %r10
    pushq   %r11
    pushq   %r12
    pushq   %r13
    pushq   %r14
    pushq   %r15
.endm

.macro RESTORE_GPRS
    popq    %r15
    popq    %r14
    popq    %r13
    popq    %r12
    popq    %r11
    popq    %r10
    popq    %r9
    popq    %r8
    popq    %rbp
    popq    %rdi
    popq    %rsi
    popq    %rdx
    popq    %rcx
    popq    %rbx
    popq    %rax
.endm

.macro ALIGN_AND_CALL target
    movq    %rsp, %rbx
    andq    $-16, %rsp
    callq   \target
    movq    %rbx, %rsp
.endm

.global zigix_isr_ud
.type zigix_isr_ud, @function
zigix_isr_ud:
    movq    %rsp, %rdi
    SAVE_GPRS
    ALIGN_AND_CALL x86_64_handle_ud
    RESTORE_GPRS
    iretq
.size zigix_isr_ud, . - zigix_isr_ud

.global zigix_irq0_timer
.type zigix_irq0_timer, @function
zigix_irq0_timer:
    SAVE_GPRS
    ALIGN_AND_CALL x86_64_handle_timer
    RESTORE_GPRS
    iretq
.size zigix_irq0_timer, . - zigix_irq0_timer

.global zigix_int80_syscall
.type zigix_int80_syscall, @function
zigix_int80_syscall:
    SAVE_GPRS
    movq    %rsp, %rdi
    ALIGN_AND_CALL x86_64_handle_int80
    RESTORE_GPRS
    iretq
.size zigix_int80_syscall, . - zigix_int80_syscall

.macro EXCEPTION_NO_ERROR name, vector
.global \name
.type \name, @function
\name:
    cli
    movq    $\vector, %rdi
    xorq    %rsi, %rsi
    movq    %rsp, %rdx
    andq    $-16, %rsp
    callq   x86_64_handle_exception
1:
    hlt
    jmp     1b
.size \name, . - \name
.endm

.macro EXCEPTION_WITH_ERROR name, vector
.global \name
.type \name, @function
\name:
    cli
    movq    $\vector, %rdi
    movq    (%rsp), %rsi
    leaq    8(%rsp), %rdx
    andq    $-16, %rsp
    callq   x86_64_handle_exception
1:
    hlt
    jmp     1b
.size \name, . - \name
.endm

EXCEPTION_NO_ERROR zigix_isr_de, 0
EXCEPTION_WITH_ERROR zigix_isr_df, 8
EXCEPTION_WITH_ERROR zigix_isr_gp, 13
EXCEPTION_WITH_ERROR zigix_isr_pf, 14

.section .note.GNU-stack, "", @progbits
