//! Architecture-independent filesystem facade.

const multiboot = @import("multiboot");

pub const initramfs = @import("initramfs.zig");
pub const memfs = @import("memfs.zig");
pub const path = @import("path.zig");
pub const vfs = @import("vfs.zig");

var root_memfs: memfs.FileSystem = undefined;

pub fn initFromMultiboot(info: *const multiboot.Info) vfs.Error!void {
    root_memfs = memfs.FileSystem.init();

    const module = multiboot.firstModule(info) orelse return error.MalformedInitramfs;
    try initramfs.mount(&root_memfs, module.bytes());
    vfs.mountRoot(root_memfs.mount());
}
