const std = @import("std");

const newlib = @import("libc_shim_newlib");

test "time hooks fail explicitly until Zigix exposes a userspace clock" {
    newlib.errno = 0;
    try std.testing.expectEqual(@as(i32, -1), newlib._gettimeofday(null, null));
    try std.testing.expectEqual(newlib.ENOSYS, newlib.errno);

    newlib.errno = 0;
    try std.testing.expectEqual(@as(isize, -1), newlib._times(null));
    try std.testing.expectEqual(newlib.ENOSYS, newlib.errno);
}
