//! Fixed-capacity in-memory filesystem used as the Phase 5 root.

const std = @import("std");

const path = @import("path.zig");
const vfs = @import("vfs.zig");

pub const MAX_NODES: usize = 64;
const MAX_NAME_BYTES: usize = 2048;

pub const FileSystem = struct {
    nodes: [MAX_NODES]vfs.Inode = undefined,
    node_count: usize = 0,
    name_storage: [MAX_NAME_BYTES]u8 = undefined,
    name_used: usize = 0,

    pub fn init() FileSystem {
        var fs = FileSystem{};
        fs.nodes[0] = .{ .name = "", .kind = .dir };
        fs.node_count = 1;
        return fs;
    }

    pub fn mount(self: *FileSystem) vfs.Mount {
        return .{
            .ctx = self,
            .ops = &ops,
        };
    }

    pub fn mkdir(self: *FileSystem, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
        var normalized_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const normalized = path.normalizeInto(absolute_path, &normalized_buffer) catch |err| return mapPathError(err);
        if (std.mem.eql(u8, normalized, "/")) return &self.nodes[0];

        var parent_index: usize = 0;
        var it = path.iterator(normalized);
        while (it.next()) |component| {
            parent_index = try self.ensureChild(parent_index, component, .dir);
        }
        return &self.nodes[parent_index];
    }

    pub fn addFile(self: *FileSystem, absolute_path: []const u8, data: []const u8) vfs.Error!*const vfs.Inode {
        var normalized_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const normalized = path.normalizeInto(absolute_path, &normalized_buffer) catch |err| return mapPathError(err);
        if (std.mem.eql(u8, normalized, "/")) return error.AlreadyExists;

        var parent_index: usize = 0;
        var it = path.iterator(normalized);
        var component = it.next() orelse return error.InvalidPath;
        while (true) {
            if (it.next()) |next_component| {
                parent_index = try self.ensureChild(parent_index, component, .dir);
                component = next_component;
                continue;
            }

            if (self.findChild(parent_index, component)) |existing| {
                _ = existing;
                return error.AlreadyExists;
            }
            const index = try self.createNode(parent_index, component, .file);
            self.nodes[index].data = data;
            return &self.nodes[index];
        }
    }

    pub fn lookup(self: *FileSystem, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
        var normalized_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const normalized = path.normalizeInto(absolute_path, &normalized_buffer) catch |err| return mapPathError(err);
        if (std.mem.eql(u8, normalized, "/")) return &self.nodes[0];

        var index: usize = 0;
        var it = path.iterator(normalized);
        while (it.next()) |component| {
            index = self.findChild(index, component) orelse return error.NotFound;
        }
        return &self.nodes[index];
    }

    pub fn read(self: *FileSystem, inode: *const vfs.Inode, offset: usize, dest: []u8) vfs.Error!usize {
        _ = self;
        if (inode.kind != .file) return error.IsDirectory;
        if (offset >= inode.data.len) return 0;
        const amount = @min(dest.len, inode.data.len - offset);
        @memcpy(dest[0..amount], inode.data[offset .. offset + amount]);
        return amount;
    }

    pub fn readdir(self: *FileSystem, inode: *const vfs.Inode, cookie: *usize) vfs.Error!?vfs.DirEntry {
        if (inode.kind != .dir) return error.NotDirectory;
        const index = self.indexOf(inode) orelse return error.NotFound;

        var child = self.nodes[index].first_child;
        var skipped: usize = 0;
        while (child) |child_index| {
            if (skipped == cookie.*) {
                cookie.* += 1;
                const node = &self.nodes[child_index];
                return .{ .name = node.name, .kind = node.kind };
            }
            skipped += 1;
            child = self.nodes[child_index].next_sibling;
        }
        return null;
    }

    fn ensureChild(self: *FileSystem, parent_index: usize, name: []const u8, kind: vfs.NodeKind) vfs.Error!usize {
        if (self.findChild(parent_index, name)) |child_index| {
            if (self.nodes[child_index].kind != kind) return error.NotDirectory;
            return child_index;
        }
        return self.createNode(parent_index, name, kind);
    }

    fn createNode(self: *FileSystem, parent_index: usize, name: []const u8, kind: vfs.NodeKind) vfs.Error!usize {
        if (self.node_count == self.nodes.len) return error.TooManyNodes;

        const index = self.node_count;
        self.node_count += 1;
        self.nodes[index] = .{
            .name = try self.internName(name),
            .kind = kind,
            .parent = parent_index,
            .next_sibling = self.nodes[parent_index].first_child,
        };
        self.nodes[parent_index].first_child = index;
        return index;
    }

    fn findChild(self: *const FileSystem, parent_index: usize, name: []const u8) ?usize {
        var child = self.nodes[parent_index].first_child;
        while (child) |child_index| {
            if (std.mem.eql(u8, self.nodes[child_index].name, name)) return child_index;
            child = self.nodes[child_index].next_sibling;
        }
        return null;
    }

    fn indexOf(self: *const FileSystem, inode: *const vfs.Inode) ?usize {
        for (self.nodes[0..self.node_count], 0..) |*node, index| {
            if (node == inode) return index;
        }
        return null;
    }

    fn internName(self: *FileSystem, name: []const u8) vfs.Error![]const u8 {
        if (self.name_used + name.len > self.name_storage.len) return error.NameStorageFull;
        const start = self.name_used;
        @memcpy(self.name_storage[start .. start + name.len], name);
        self.name_used += name.len;
        return self.name_storage[start..self.name_used];
    }
};

const ops = vfs.Operations{
    .lookup = lookupOp,
    .read = readOp,
    .readdir = readdirOp,
};

fn lookupOp(ctx: *anyopaque, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.lookup(absolute_path);
}

fn readOp(ctx: *anyopaque, inode: *const vfs.Inode, offset: usize, dest: []u8) vfs.Error!usize {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.read(inode, offset, dest);
}

fn readdirOp(ctx: *anyopaque, inode: *const vfs.Inode, cookie: *usize) vfs.Error!?vfs.DirEntry {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.readdir(inode, cookie);
}

fn mapPathError(err: path.Error) vfs.Error {
    return switch (err) {
        error.EmptyPath, error.NotAbsolute => error.InvalidPath,
        error.PathTooLong => error.PathTooLong,
        error.TooManyComponents => error.PathTooLong,
    };
}
