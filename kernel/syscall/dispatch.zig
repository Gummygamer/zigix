//! Syscall dispatcher and Phase 6 handler set.

const std = @import("std");

const arch = @import("arch");
const fs = @import("fs");

const errno = @import("errno.zig");
const numbers = @import("numbers.zig");

const serial = arch.serial;

const MAX_FDS: usize = 16;
const MAX_PATH_BYTES: usize = 256;

const SEEK_SET: u64 = 0;
const SEEK_CUR: u64 = 1;
const SEEK_END: u64 = 2;

pub const Stat = extern struct {
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 1,
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    rdev: u64 = 0,
    size: i64 = 0,
    blksize: i64 = 4096,
    blocks: i64 = 0,
};

var fd_table: [MAX_FDS]?fs.vfs.File = [_]?fs.vfs.File{null} ** MAX_FDS;
var last_exit_status: i32 = 0;

pub fn init() void {
    for (&fd_table) |*slot| slot.* = null;
    last_exit_status = 0;
}

pub fn invoke(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    _ = arg5;
    _ = arg4;
    _ = arg3;
    return switch (num) {
        numbers.read => sysRead(arg0, arg1, arg2),
        numbers.write => sysWrite(arg0, arg1, arg2),
        numbers.open => sysOpen(arg0, arg1, arg2),
        numbers.close => sysClose(arg0),
        numbers.stat => sysStat(arg0, arg1),
        numbers.fstat => sysFstat(arg0, arg1),
        numbers.lseek => sysLseek(arg0, arg1, arg2),
        numbers.exit => sysExit(arg0),
        else => errno.fail(errno.NOSYS),
    };
}

pub fn selfTestWriteMarker() bool {
    const marker = "[ZIGIX:SYSCALL:OK]\n";
    const ret = issueInt80(numbers.write, 1, @intFromPtr(marker.ptr), marker.len, 0, 0, 0);
    return ret == marker.len;
}

export fn x86_64_handle_int80(frame: *TrapFrame) callconv(.c) void {
    const ret = invoke(
        frame.rax,
        frame.rdi,
        frame.rsi,
        frame.rdx,
        frame.r10,
        frame.r8,
        frame.r9,
    );
    frame.rax = @bitCast(ret);
}

const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
};

fn sysRead(fd_arg: u64, buf_ptr: u64, len: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (len == 0) return 0;
    const dest = userBytesMut(buf_ptr, len) orelse return errno.fail(errno.FAULT);

    if (fd == 0) return 0;
    if (fd < 3) return errno.fail(errno.BADF);

    var file = fd_table[fd] orelse return errno.fail(errno.BADF);
    const amount = file.read(dest) catch |err| return mapFsError(err);
    fd_table[fd] = file;
    return @intCast(amount);
}

fn sysWrite(fd_arg: u64, buf_ptr: u64, len: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (len == 0) return 0;
    const bytes = userBytesConst(buf_ptr, len) orelse return errno.fail(errno.FAULT);

    if (fd == 1 or fd == 2) {
        serial.write(bytes);
        return @intCast(bytes.len);
    }
    return errno.fail(errno.BADF);
}

fn sysOpen(path_ptr: u64, flags: u64, mode: u64) i64 {
    _ = mode;
    if (flags != 0) return errno.fail(errno.INVAL);

    const path = userCString(path_ptr) orelse return errno.fail(errno.FAULT);
    const slot = allocFd() orelse return errno.fail(errno.NFILE);
    fd_table[slot] = fs.vfs.open(path) catch |err| return mapFsError(err);
    return @intCast(slot);
}

fn sysClose(fd_arg: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (fd < 3) return 0;
    if (fd_table[fd] == null) return errno.fail(errno.BADF);
    fd_table[fd] = null;
    return 0;
}

fn sysLseek(fd_arg: u64, offset_arg: u64, whence: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (fd < 3) return errno.fail(errno.BADF);
    var file = fd_table[fd] orelse return errno.fail(errno.BADF);

    const offset: i64 = @bitCast(offset_arg);
    const base: i64 = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => @intCast(file.offset),
        SEEK_END => @intCast(file.inode.data.len),
        else => return errno.fail(errno.INVAL),
    };
    const next = base + offset;
    if (next < 0) return errno.fail(errno.INVAL);

    file.offset = @intCast(next);
    fd_table[fd] = file;
    return next;
}

fn sysStat(path_ptr: u64, stat_ptr: u64) i64 {
    const path = userCString(path_ptr) orelse return errno.fail(errno.FAULT);
    const out = userStat(stat_ptr) orelse return errno.fail(errno.FAULT);
    const inode = fs.vfs.lookup(path) catch |err| return mapFsError(err);
    out.* = statFor(inode);
    return 0;
}

fn sysFstat(fd_arg: u64, stat_ptr: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    const out = userStat(stat_ptr) orelse return errno.fail(errno.FAULT);

    if (fd == 0 or fd == 1 or fd == 2) {
        out.* = .{ .mode = 0o020000 };
        return 0;
    }

    const file = fd_table[fd] orelse return errno.fail(errno.BADF);
    out.* = statFor(file.inode);
    return 0;
}

fn sysExit(status: u64) i64 {
    last_exit_status = @intCast(status & 0xff);
    return 0;
}

fn statFor(inode: *const fs.vfs.Inode) Stat {
    const is_dir = inode.kind == .dir;
    return .{
        .mode = if (is_dir) 0o040555 else 0o100444,
        .size = if (is_dir) 0 else @intCast(inode.data.len),
        .blocks = if (is_dir) 0 else @intCast((inode.data.len + 511) / 512),
    };
}

fn allocFd() ?usize {
    var fd: usize = 3;
    while (fd < fd_table.len) : (fd += 1) {
        if (fd_table[fd] == null) return fd;
    }
    return null;
}

fn fdIndex(fd: u64) ?usize {
    if (fd >= fd_table.len) return null;
    return @intCast(fd);
}

fn userBytesConst(ptr: u64, len: u64) ?[]const u8 {
    if (len > std.math.maxInt(usize)) return null;
    const size: usize = @intCast(len);
    if (size == 0) return &.{};
    if (ptr == 0) return null;
    const raw: [*]const u8 = @ptrFromInt(ptr);
    return raw[0..size];
}

fn userBytesMut(ptr: u64, len: u64) ?[]u8 {
    if (len > std.math.maxInt(usize)) return null;
    const size: usize = @intCast(len);
    if (size == 0) return &.{};
    if (ptr == 0) return null;
    const raw: [*]u8 = @ptrFromInt(ptr);
    return raw[0..size];
}

fn userCString(ptr: u64) ?[]const u8 {
    if (ptr == 0) return null;

    const raw: [*]const u8 = @ptrFromInt(ptr);
    var len: usize = 0;
    while (len < MAX_PATH_BYTES) : (len += 1) {
        if (raw[len] == 0) return raw[0..len];
    }
    return null;
}

fn userStat(ptr: u64) ?*Stat {
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

fn mapFsError(err: fs.vfs.Error) i64 {
    return errno.fail(switch (err) {
        error.NotMounted => errno.IO,
        error.NotFound => errno.NOENT,
        error.NotDirectory => errno.NOTDIR,
        error.IsDirectory => errno.ISDIR,
        error.AlreadyExists => errno.INVAL,
        error.InvalidPath => errno.INVAL,
        error.PathTooLong => errno.NAMETOOLONG,
        error.TooManyNodes => errno.NFILE,
        error.NameStorageFull => errno.NFILE,
        error.MalformedInitramfs => errno.IO,
    });
}

fn issueInt80(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) u64 {
    return asm volatile ("int $0x80"
        : [ret] "={rax}" (-> u64),
        : [num] "{rax}" (num),
          [arg0] "{rdi}" (arg0),
          [arg1] "{rsi}" (arg1),
          [arg2] "{rdx}" (arg2),
          [arg3] "{r10}" (arg3),
          [arg4] "{r8}" (arg4),
          [arg5] "{r9}" (arg5),
        : .{ .rcx = true, .r11 = true, .memory = true });
}
