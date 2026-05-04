//! Architecture-independent memory-management facade.

pub const heap = @import("heap.zig");
pub const paging = @import("paging.zig");
pub const physical = @import("physical.zig");
