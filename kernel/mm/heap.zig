//! Tiny early kernel heap backed by the physical page allocator.
//!
//! This is a page-local bump allocator. It satisfies Zig's allocator
//! interface for early users that allocate small objects; freeing is a no-op
//! until Phase 3 grows a real freelist.

const std = @import("std");

const physical = @import("physical.zig");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const State = struct {
    current: usize = 0,
    end: usize = 0,
    allocations: usize = 0,
};

var state = State{};

pub fn init() void {
    state = .{};
}

pub fn allocator() Allocator {
    return .{
        .ptr = &state,
        .vtable = &vtable,
    };
}

pub fn allocationCount() usize {
    return state.allocations;
}

const vtable = Allocator.VTable{
    .alloc = alloc,
    .resize = Allocator.noResize,
    .remap = Allocator.noRemap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ret_addr;
    if (len == 0 or len > physical.PAGE_SIZE) return null;
    if (alignment.toByteUnits() > physical.PAGE_SIZE) return null;

    const s: *State = @ptrCast(@alignCast(ctx));
    const aligned = alignment.forward(s.current);
    if (aligned + len > s.end) {
        const page = physical.allocPage() catch return null;
        s.current = page;
        s.end = page + physical.PAGE_SIZE;
    }

    const result = alignment.forward(s.current);
    if (result + len > s.end) return null;

    s.current = result + len;
    s.allocations += 1;
    return @ptrFromInt(result);
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = memory;
    _ = alignment;
    _ = ret_addr;
}
