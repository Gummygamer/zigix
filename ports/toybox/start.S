.section .text
.global _start
.type _start, @function
_start:
    movq (%rsp), %rdi
    leaq 8(%rsp), %rsi
    andq $-16, %rsp
    call main
    movl %eax, %edi
    call _exit
.size _start, . - _start
