//! Path normalization shared by kernel VFS code and host tests.

const std = @import("std");

pub const MAX_PATH_BYTES: usize = 256;
const MAX_COMPONENTS: usize = 64;

pub const Error = error{
    EmptyPath,
    NotAbsolute,
    PathTooLong,
    TooManyComponents,
};

const Component = struct {
    start: usize,
    len: usize,
};

pub fn normalizeInto(input: []const u8, out: []u8) Error![]const u8 {
    if (input.len == 0) return error.EmptyPath;
    if (input[0] != '/') return error.NotAbsolute;
    if (out.len == 0) return error.PathTooLong;

    var components: [MAX_COMPONENTS]Component = undefined;
    var component_count: usize = 0;

    var cursor: usize = 1;
    while (cursor < input.len) {
        while (cursor < input.len and input[cursor] == '/') cursor += 1;
        if (cursor >= input.len) break;

        const start = cursor;
        while (cursor < input.len and input[cursor] != '/') cursor += 1;
        const component = input[start..cursor];

        if (std.mem.eql(u8, component, ".")) {
            continue;
        } else if (std.mem.eql(u8, component, "..")) {
            if (component_count > 0) component_count -= 1;
        } else {
            if (component_count == components.len) return error.TooManyComponents;
            components[component_count] = .{ .start = start, .len = component.len };
            component_count += 1;
        }
    }

    out[0] = '/';
    var used: usize = 1;

    for (components[0..component_count], 0..) |component, index| {
        if (index != 0) {
            if (used == out.len) return error.PathTooLong;
            out[used] = '/';
            used += 1;
        }
        if (used + component.len > out.len) return error.PathTooLong;
        @memcpy(out[used .. used + component.len], input[component.start .. component.start + component.len]);
        used += component.len;
    }

    return out[0..used];
}

pub fn resolveInto(cwd: []const u8, input: []const u8, out: []u8) Error![]const u8 {
    if (input.len == 0) return error.EmptyPath;
    if (input[0] == '/') return normalizeInto(input, out);

    var joined: [MAX_PATH_BYTES]u8 = undefined;
    if (cwd.len == 0 or cwd[0] != '/') return error.NotAbsolute;
    if (cwd.len > joined.len) return error.PathTooLong;

    @memcpy(joined[0..cwd.len], cwd);
    var used = cwd.len;
    if (used != 1) {
        if (used == joined.len) return error.PathTooLong;
        joined[used] = '/';
        used += 1;
    }
    if (used + input.len > joined.len) return error.PathTooLong;
    @memcpy(joined[used .. used + input.len], input);
    used += input.len;

    return normalizeInto(joined[0..used], out);
}

pub const Iterator = struct {
    path: []const u8,
    cursor: usize = 1,

    pub fn next(self: *Iterator) ?[]const u8 {
        while (self.cursor < self.path.len and self.path[self.cursor] == '/') self.cursor += 1;
        if (self.cursor >= self.path.len) return null;

        const start = self.cursor;
        while (self.cursor < self.path.len and self.path[self.cursor] != '/') self.cursor += 1;
        return self.path[start..self.cursor];
    }
};

pub fn iterator(normalized_absolute_path: []const u8) Iterator {
    return .{ .path = normalized_absolute_path };
}
