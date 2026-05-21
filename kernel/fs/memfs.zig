//! Fixed-capacity in-memory filesystem used as the Phase 5 root.

const std = @import("std");

const path = @import("path.zig");
const vfs = @import("vfs.zig");

pub const MAX_NODES: usize = 64;
const MAX_NAME_BYTES: usize = 2048;
const MAX_FILE_BYTES: usize = 4096;

pub const FileSystem = struct {
    nodes: [MAX_NODES]vfs.Inode = undefined,
    file_storage: [MAX_NODES][MAX_FILE_BYTES]u8 = undefined,
    file_owned: [MAX_NODES]bool = [_]bool{false} ** MAX_NODES,
    node_count: usize = 0,
    name_storage: [MAX_NAME_BYTES]u8 = undefined,
    name_used: usize = 0,

    pub fn init(self: *FileSystem) void {
        self.node_count = 1;
        self.name_used = 0;
        @memset(&self.file_owned, false);
        self.nodes[0] = .{ .name = "", .kind = .dir };
    }

    pub fn mount(self: *FileSystem) vfs.Mount {
        return .{
            .ctx = self,
            .ops = &ops,
        };
    }

    pub fn mkdir(self: *FileSystem, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
        var path_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const location = try self.resolveParent(absolute_path, &path_buffer);
        if (self.findChild(location.parent, location.name) != null) return error.AlreadyExists;
        const index = try self.createNode(location.parent, location.name, .dir);
        return &self.nodes[index];
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

    pub fn createFile(self: *FileSystem, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
        var path_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const location = try self.resolveParent(absolute_path, &path_buffer);
        if (self.findChild(location.parent, location.name) != null) return error.AlreadyExists;
        const index = try self.createNode(location.parent, location.name, .file);
        self.file_owned[index] = true;
        self.nodes[index].data = self.file_storage[index][0..0];
        return &self.nodes[index];
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

    pub fn write(self: *FileSystem, inode: *const vfs.Inode, offset: usize, bytes: []const u8) vfs.Error!usize {
        if (inode.kind != .file) return error.IsDirectory;
        const index = self.indexOf(inode) orelse return error.NotFound;
        const end = offset + bytes.len;
        if (end > MAX_FILE_BYTES) return error.FileTooLarge;
        try self.ensureOwnedFile(index);
        const current_len = self.nodes[index].data.len;
        if (offset > current_len) {
            @memset(self.file_storage[index][current_len..offset], 0);
        }
        @memcpy(self.file_storage[index][offset..end], bytes);
        if (end > current_len) self.nodes[index].data = self.file_storage[index][0..end];
        return bytes.len;
    }

    pub fn truncate(self: *FileSystem, inode: *const vfs.Inode, len: usize) vfs.Error!void {
        if (inode.kind != .file) return error.IsDirectory;
        if (len > MAX_FILE_BYTES) return error.FileTooLarge;
        const index = self.indexOf(inode) orelse return error.NotFound;
        try self.ensureOwnedFile(index);
        const current_len = self.nodes[index].data.len;
        if (len > current_len) {
            @memset(self.file_storage[index][current_len..len], 0);
        }
        self.nodes[index].data = self.file_storage[index][0..len];
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

    pub fn unlink(self: *FileSystem, absolute_path: []const u8) vfs.Error!void {
        var path_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const location = try self.resolveParent(absolute_path, &path_buffer);
        const index = self.findChild(location.parent, location.name) orelse return error.NotFound;
        if (self.nodes[index].kind == .dir) {
            if (self.nodes[index].first_child != null) return error.DirectoryNotEmpty;
        }
        self.unlinkChild(location.parent, index);
    }

    pub fn rename(self: *FileSystem, old_path: []const u8, new_path: []const u8) vfs.Error!void {
        var old_path_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        var new_path_buffer: [path.MAX_PATH_BYTES]u8 = undefined;
        const old_location = try self.resolveParent(old_path, &old_path_buffer);
        const index = self.findChild(old_location.parent, old_location.name) orelse return error.NotFound;
        const new_location = try self.resolveParent(new_path, &new_path_buffer);
        if (self.findChild(new_location.parent, new_location.name) != null) return error.AlreadyExists;

        self.unlinkChild(old_location.parent, index);
        self.nodes[index].parent = new_location.parent;
        self.nodes[index].name = try self.internName(new_location.name);
        self.nodes[index].next_sibling = self.nodes[new_location.parent].first_child;
        self.nodes[new_location.parent].first_child = index;
    }

    fn ensureChild(self: *FileSystem, parent_index: usize, name: []const u8, kind: vfs.NodeKind) vfs.Error!usize {
        if (self.findChild(parent_index, name)) |child_index| {
            if (self.nodes[child_index].kind != kind) return error.NotDirectory;
            return child_index;
        }
        return self.createNode(parent_index, name, kind);
    }

    const Location = struct {
        parent: usize,
        name: []const u8,
    };

    fn resolveParent(self: *FileSystem, absolute_path: []const u8, normalized_buffer: *[path.MAX_PATH_BYTES]u8) vfs.Error!Location {
        const normalized = path.normalizeInto(absolute_path, normalized_buffer) catch |err| return mapPathError(err);
        if (std.mem.eql(u8, normalized, "/")) return error.InvalidPath;

        var parent_index: usize = 0;
        var it = path.iterator(normalized);
        var component = it.next() orelse return error.InvalidPath;
        while (true) {
            if (it.next()) |next_component| {
                const child_index = self.findChild(parent_index, component) orelse return error.NotFound;
                if (self.nodes[child_index].kind != .dir) return error.NotDirectory;
                parent_index = child_index;
                component = next_component;
                continue;
            }
            return .{ .parent = parent_index, .name = component };
        }
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
        self.file_owned[index] = false;
        self.nodes[parent_index].first_child = index;
        return index;
    }

    fn ensureOwnedFile(self: *FileSystem, index: usize) vfs.Error!void {
        if (self.file_owned[index]) return;
        if (self.nodes[index].data.len > MAX_FILE_BYTES) return error.FileTooLarge;
        @memcpy(self.file_storage[index][0..self.nodes[index].data.len], self.nodes[index].data);
        self.nodes[index].data = self.file_storage[index][0..self.nodes[index].data.len];
        self.file_owned[index] = true;
    }

    fn unlinkChild(self: *FileSystem, parent_index: usize, child_index: usize) void {
        var cursor = &self.nodes[parent_index].first_child;
        while (cursor.*) |index| {
            if (index == child_index) {
                cursor.* = self.nodes[index].next_sibling;
                self.nodes[index].next_sibling = null;
                self.nodes[index].parent = null;
                return;
            }
            cursor = &self.nodes[index].next_sibling;
        }
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
    .create_file = createFileOp,
    .mkdir = mkdirOp,
    .unlink = unlinkOp,
    .rename = renameOp,
    .read = readOp,
    .write = writeOp,
    .truncate = truncateOp,
    .readdir = readdirOp,
};

fn lookupOp(ctx: *anyopaque, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.lookup(absolute_path);
}

fn createFileOp(ctx: *anyopaque, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.createFile(absolute_path);
}

fn mkdirOp(ctx: *anyopaque, absolute_path: []const u8) vfs.Error!*const vfs.Inode {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.mkdir(absolute_path);
}

fn unlinkOp(ctx: *anyopaque, absolute_path: []const u8) vfs.Error!void {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.unlink(absolute_path);
}

fn renameOp(ctx: *anyopaque, old_path: []const u8, new_path: []const u8) vfs.Error!void {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.rename(old_path, new_path);
}

fn readOp(ctx: *anyopaque, inode: *const vfs.Inode, offset: usize, dest: []u8) vfs.Error!usize {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.read(inode, offset, dest);
}

fn writeOp(ctx: *anyopaque, inode: *const vfs.Inode, offset: usize, bytes: []const u8) vfs.Error!usize {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.write(inode, offset, bytes);
}

fn truncateOp(ctx: *anyopaque, inode: *const vfs.Inode, len: usize) vfs.Error!void {
    const fs: *FileSystem = @ptrCast(@alignCast(ctx));
    return fs.truncate(inode, len);
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
