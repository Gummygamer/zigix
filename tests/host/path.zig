const std = @import("std");

const path = @import("fs_path");

fn expectNormalize(input: []const u8, expected: []const u8) !void {
    var buffer: [path.MAX_PATH_BYTES]u8 = undefined;
    const actual = try path.normalizeInto(input, &buffer);
    try std.testing.expectEqualStrings(expected, actual);
}

test "path normalization collapses edge cases" {
    try expectNormalize("/", "/");
    try expectNormalize("/init", "/init");
    try expectNormalize("/bin//init", "/bin/init");
    try expectNormalize("/bin/./init/", "/bin/init");
    try expectNormalize("/bin/../init", "/init");
    try expectNormalize("/../../init", "/init");
    try expectNormalize("/a/b/c/../../", "/a");
}

test "path normalization rejects invalid inputs" {
    var buffer: [path.MAX_PATH_BYTES]u8 = undefined;
    try std.testing.expectError(error.EmptyPath, path.normalizeInto("", &buffer));
    try std.testing.expectError(error.NotAbsolute, path.normalizeInto("relative", &buffer));

    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.PathTooLong, path.normalizeInto("/abcd", &tiny));
}

fn expectResolve(cwd: []const u8, input: []const u8, expected: []const u8) !void {
    var buffer: [path.MAX_PATH_BYTES]u8 = undefined;
    const actual = try path.resolveInto(cwd, input, &buffer);
    try std.testing.expectEqualStrings(expected, actual);
}

test "path resolution applies cwd to relative inputs" {
    try expectResolve("/", "init", "/init");
    try expectResolve("/bin", "init", "/bin/init");
    try expectResolve("/bin/tools", "../init", "/bin/init");
    try expectResolve("/bin", "./../init", "/init");
    try expectResolve("/bin", "/absolute/../init", "/init");
}
