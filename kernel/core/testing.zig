//! In-kernel test registry and serial marker runner.
//!
//! Test modules expose declarations named `TEST_<name>` with value `Test`.
//! The runner walks those declarations at comptime and emits stable markers
//! for the QEMU smoke parser.

const std = @import("std");

const arch = @import("arch");
const serial = arch.serial;

pub const TestError = anyerror;

pub const Test = struct {
    name: []const u8,
    run: *const fn () TestError!void,
};

pub fn runAll(comptime registry: type) void {
    inline for (@typeInfo(registry).@"struct".decls) |decl| {
        if (std.mem.startsWith(u8, decl.name, "TEST_")) {
            const test_case: Test = @field(registry, decl.name);
            runOne(test_case);
        }
    }
}

fn runOne(test_case: Test) void {
    test_case.run() catch |err| {
        serial.write("[ZIGIX:TEST:FAIL:");
        serial.write(test_case.name);
        serial.write(":");
        serial.write(@errorName(err));
        serial.writeLine("]");
        return;
    };

    serial.write("[ZIGIX:TEST:PASS:");
    serial.write(test_case.name);
    serial.writeLine("]");
}
