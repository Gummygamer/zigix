//! Early kernel logger.
//!
//! This stays deliberately small: no allocator, no heap-backed formatting,
//! and no buffering beyond one stack line.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;

const MAX_LINE_BYTES = 512;

pub const Level = enum {
    info,
    warn,
    err,

    fn label(self: Level) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warn => "WARN",
            .err => "ERR",
        };
    }
};

pub fn print(level: Level, comptime fmt: []const u8, args: anytype) void {
    println(level, fmt, args);
}

pub fn println(level: Level, comptime fmt: []const u8, args: anytype) void {
    var buf: [MAX_LINE_BYTES]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, fmt, args) catch "[format-truncated]";

    serial.write("[ZIGIX:");
    serial.write(level.label());
    serial.write("] ");
    serial.write(rendered);
    serial.writeByte('\n');
}

pub fn rawLine(bytes: []const u8) void {
    serial.writeLine(bytes);
}
