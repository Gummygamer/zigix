//! Minimal VFS contracts for Phase 5.

const std = @import("std");

pub const Error = error{
    NotMounted,
    NotFound,
    NotDirectory,
    IsDirectory,
    AlreadyExists,
    InvalidPath,
    PathTooLong,
    TooManyNodes,
    NameStorageFull,
    MalformedInitramfs,
};

pub const NodeKind = enum {
    dir,
    file,
};

pub const Inode = struct {
    name: []const u8,
    kind: NodeKind,
    data: []const u8 = &.{},
    parent: ?usize = null,
    first_child: ?usize = null,
    next_sibling: ?usize = null,
};

pub const DirEntry = struct {
    name: []const u8,
    kind: NodeKind,
};

pub const Operations = struct {
    lookup: *const fn (ctx: *anyopaque, absolute_path: []const u8) Error!*const Inode,
    read: *const fn (ctx: *anyopaque, inode: *const Inode, offset: usize, dest: []u8) Error!usize,
    readdir: *const fn (ctx: *anyopaque, inode: *const Inode, cookie: *usize) Error!?DirEntry,
};

pub const Mount = struct {
    ctx: *anyopaque,
    ops: *const Operations,
};

pub const File = struct {
    mount: Mount,
    inode: *const Inode,
    offset: usize = 0,

    pub fn read(self: *File, dest: []u8) Error!usize {
        const amount = try self.mount.ops.read(self.mount.ctx, self.inode, self.offset, dest);
        self.offset += amount;
        return amount;
    }
};

pub const Dir = struct {
    mount: Mount,
    inode: *const Inode,
    cookie: usize = 0,

    pub fn next(self: *Dir) Error!?DirEntry {
        return self.mount.ops.readdir(self.mount.ctx, self.inode, &self.cookie);
    }
};

var root_mount: ?Mount = null;

pub fn mountRoot(mount: Mount) void {
    root_mount = mount;
}

pub fn lookup(absolute_path: []const u8) Error!*const Inode {
    const mount = root_mount orelse return error.NotMounted;
    return mount.ops.lookup(mount.ctx, absolute_path);
}

pub fn open(absolute_path: []const u8) Error!File {
    const mount = root_mount orelse return error.NotMounted;
    const inode = try mount.ops.lookup(mount.ctx, absolute_path);
    if (inode.kind != .file) return error.IsDirectory;
    return .{ .mount = mount, .inode = inode };
}

pub fn opendir(absolute_path: []const u8) Error!Dir {
    const mount = root_mount orelse return error.NotMounted;
    const inode = try mount.ops.lookup(mount.ctx, absolute_path);
    if (inode.kind != .dir) return error.NotDirectory;
    return .{ .mount = mount, .inode = inode };
}

pub fn read(inode: *const Inode, offset: usize, dest: []u8) Error!usize {
    const mount = root_mount orelse return error.NotMounted;
    return mount.ops.read(mount.ctx, inode, offset, dest);
}

pub fn readdir(inode: *const Inode, cookie: *usize) Error!?DirEntry {
    const mount = root_mount orelse return error.NotMounted;
    return mount.ops.readdir(mount.ctx, inode, cookie);
}
