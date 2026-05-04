//! Canonical early kernel tests.

const arch = @import("arch");
const serial = arch.serial;

const testing = @import("testing.zig");

pub const TEST_kernel_smoke = testing.Test{
    .name = "kernel_smoke",
    .run = kernelSmoke,
};

fn kernelSmoke() testing.TestError!void {
    if (!serial.scratchRoundTrip(0x5A)) return error.SerialScratchMismatch;

    const before = serial.writtenByteCount();
    serial.writeLine("[ZIGIX:TEST:SERIAL_WRITE:kernel_smoke]");
    const after = serial.writtenByteCount();
    if (after - before != "[ZIGIX:TEST:SERIAL_WRITE:kernel_smoke]".len + 1) {
        return error.SerialWriteLineTruncated;
    }
}
