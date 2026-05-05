//! x86_64 ring-3 entry helpers.

extern fn zigix_enter_user(entry: usize, stack_top: usize) callconv(.c) noreturn;

pub fn enter(entry: usize, stack_top: usize) noreturn {
    zigix_enter_user(entry, stack_top);
}
