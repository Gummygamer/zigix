const std = @import("std");

const abi = @import("libc_shim_abi");

test "phase 13 chooses newlib first" {
    try std.testing.expectEqual(abi.Strategy.newlib, abi.strategy);
}

test "syscallResult maps negative kernel returns to libc errno" {
    var errno: i32 = 0;
    try std.testing.expectEqual(@as(isize, 3), abi.syscallResult(3, &errno));
    try std.testing.expectEqual(@as(i32, 0), errno);

    try std.testing.expectEqual(@as(isize, -1), abi.syscallResult(-14, &errno));
    try std.testing.expectEqual(@as(i32, 14), errno);
}

test "stdio fd classification matches serial console policy" {
    try std.testing.expect(abi.isStdioFd(0));
    try std.testing.expect(abi.isStdioFd(1));
    try std.testing.expect(abi.isStdioFd(2));
    try std.testing.expect(!abi.isStdioFd(-1));
    try std.testing.expect(!abi.isStdioFd(3));
}
