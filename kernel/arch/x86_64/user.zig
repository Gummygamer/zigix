//! x86_64 ring-3 entry helpers.

extern fn zigix_enter_user(entry: usize, stack_top: usize) callconv(.c) noreturn;
extern fn zigix_enter_user_with_context(context: *KernelContext, entry: usize, stack_top: usize) callconv(.c) usize;
extern fn zigix_resume_kernel_context(context: *KernelContext, value: usize) callconv(.c) noreturn;

pub const KernelContext = extern struct {
    rsp: usize = 0,
    rbx: usize = 0,
    rbp: usize = 0,
    r12: usize = 0,
    r13: usize = 0,
    r14: usize = 0,
    r15: usize = 0,
};

pub fn enter(entry: usize, stack_top: usize) noreturn {
    zigix_enter_user(entry, stack_top);
}

pub fn enterWithContext(context: *KernelContext, entry: usize, stack_top: usize) usize {
    return zigix_enter_user_with_context(context, entry, stack_top);
}

pub fn resumeKernelContext(context: *KernelContext, value: usize) noreturn {
    zigix_resume_kernel_context(context, value);
}
