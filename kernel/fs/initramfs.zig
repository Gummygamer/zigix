//! Zigix initramfs parser.
//!
//! Format:
//!   header: magic "ZIXR", version u16, entry_count u16, total_size u32,
//!           reserved u32
//!   entry : kind u8, reserved u8, path_len u16, data_len u32, then path
//!           bytes and data bytes. All integers are little-endian.

const std = @import("std");

const memfs = @import("memfs.zig");
const vfs = @import("vfs.zig");

pub const MAGIC = "ZIXR";
pub const VERSION: u16 = 1;

const HEADER_SIZE: usize = 16;
const ENTRY_HEADER_SIZE: usize = 8;

const EntryKind = enum(u8) {
    file = 1,
    dir = 2,
    _,
};

pub fn mount(fs: *memfs.FileSystem, blob: []const u8) vfs.Error!void {
    if (blob.len < HEADER_SIZE) return error.MalformedInitramfs;
    if (!std.mem.eql(u8, blob[0..4], MAGIC)) return error.MalformedInitramfs;
    if (readU16(blob, 4) != VERSION) return error.MalformedInitramfs;

    const entry_count = readU16(blob, 6);
    const total_size = readU32(blob, 8);
    if (total_size != blob.len) return error.MalformedInitramfs;

    var cursor: usize = HEADER_SIZE;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        if (cursor + ENTRY_HEADER_SIZE > blob.len) return error.MalformedInitramfs;
        const kind: EntryKind = @enumFromInt(blob[cursor]);
        const path_len = readU16(blob, cursor + 2);
        const data_len = readU32(blob, cursor + 4);
        cursor += ENTRY_HEADER_SIZE;

        const path_end = cursor + @as(usize, path_len);
        const data_end = path_end + @as(usize, data_len);
        if (path_end > blob.len or data_end > blob.len) return error.MalformedInitramfs;

        const entry_path = blob[cursor..path_end];
        const data = blob[path_end..data_end];
        cursor = data_end;

        switch (kind) {
            .file => _ = try fs.addFile(entry_path, data),
            .dir => {
                if (data.len != 0) return error.MalformedInitramfs;
                _ = try fs.mkdir(entry_path);
            },
            _ => return error.MalformedInitramfs,
        }
    }

    if (cursor != blob.len) return error.MalformedInitramfs;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}
