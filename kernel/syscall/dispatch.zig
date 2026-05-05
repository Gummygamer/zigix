//! Syscall dispatcher and Phase 6 handler set.

const std = @import("std");

const arch = @import("arch");
const fs = @import("fs");

const errno = @import("errno.zig");
const numbers = @import("numbers.zig");

const serial = arch.serial;
const cpu = arch.cpu;

const MAX_FDS: usize = 16;
const MAX_OPEN_FILES: usize = 16;
const MAX_PATH_BYTES: usize = 256;

pub const O_CLOEXEC: u64 = 0o2000000;

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

const OpenFile = struct {
    used: bool = false,
    file: fs.vfs.File = undefined,
    ref_count: usize = 0,
};

const FdTarget = union(enum) {
    stdin,
    stdout,
    stderr,
    file: *OpenFile,
};

const Descriptor = struct {
    target: FdTarget,
    close_on_exec: bool = false,
};

pub const Process = struct {
    fd_table: [MAX_FDS]?Descriptor = [_]?Descriptor{null} ** MAX_FDS,

    pub fn init(self: *Process) void {
        for (&self.fd_table) |*slot| slot.* = null;
        self.fd_table[0] = .{ .target = .stdin };
        self.fd_table[1] = .{ .target = .stdout };
        self.fd_table[2] = .{ .target = .stderr };
    }

    fn get(self: *Process, fd: usize) ?Descriptor {
        if (fd >= self.fd_table.len) return null;
        return self.fd_table[fd];
    }

    fn install(self: *Process, descriptor: Descriptor) ?usize {
        const fd = self.allocFd() orelse return null;
        self.fd_table[fd] = descriptor;
        return fd;
    }

    fn dup(self: *Process, fd: usize) ?usize {
        var descriptor = self.get(fd) orelse return null;
        descriptor.close_on_exec = false;
        retainTarget(descriptor.target);
        return self.install(descriptor) orelse {
            releaseTarget(descriptor.target);
            return null;
        };
    }

    fn close(self: *Process, fd: usize) bool {
        const descriptor = self.get(fd) orelse return false;
        releaseTarget(descriptor.target);
        self.fd_table[fd] = null;
        return true;
    }

    fn allocFd(self: *Process) ?usize {
        var fd: usize = 0;
        while (fd < self.fd_table.len) : (fd += 1) {
            if (self.fd_table[fd] == null) return fd;
        }
        return null;
    }
};

var open_files: [MAX_OPEN_FILES]OpenFile = [_]OpenFile{.{}} ** MAX_OPEN_FILES;
var current_process: Process = .{};

pub fn init() void {
    for (&open_files) |*slot| slot.* = .{};
    current_process.init();
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
        numbers.dup => sysDup(arg0),
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

    const descriptor = current_process.get(fd) orelse return errno.fail(errno.BADF);
    const amount = switch (descriptor.target) {
        .stdin => 0,
        .stdout, .stderr => return errno.fail(errno.BADF),
        .file => |open_file| open_file.file.read(dest) catch |err| return mapFsError(err),
    };
    return @intCast(amount);
}

fn sysWrite(fd_arg: u64, buf_ptr: u64, len: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (len == 0) return 0;
    const bytes = userBytesConst(buf_ptr, len) orelse return errno.fail(errno.FAULT);

    const descriptor = current_process.get(fd) orelse return errno.fail(errno.BADF);
    switch (descriptor.target) {
        .stdout, .stderr => {
            serial.write(bytes);
            return @intCast(bytes.len);
        },
        .stdin, .file => return errno.fail(errno.BADF),
    }
}

fn sysOpen(path_ptr: u64, flags: u64, mode: u64) i64 {
    _ = mode;
    if ((flags & ~O_CLOEXEC) != 0) return errno.fail(errno.INVAL);

    const path = userCString(path_ptr) orelse return errno.fail(errno.FAULT);
    const file = fs.vfs.open(path) catch |err| return mapFsError(err);
    const open_file = allocOpenFile(file) orelse return errno.fail(errno.NFILE);
    const slot = current_process.install(.{
        .target = .{ .file = open_file },
        .close_on_exec = (flags & O_CLOEXEC) != 0,
    }) orelse {
        releaseOpenFile(open_file);
        return errno.fail(errno.NFILE);
    };
    return @intCast(slot);
}

fn sysClose(fd_arg: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    if (!current_process.close(fd)) return errno.fail(errno.BADF);
    return 0;
}

fn sysLseek(fd_arg: u64, offset_arg: u64, whence: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    const descriptor = current_process.get(fd) orelse return errno.fail(errno.BADF);
    const open_file = switch (descriptor.target) {
        .file => |open_file| open_file,
        .stdin, .stdout, .stderr => return errno.fail(errno.BADF),
    };

    const offset: i64 = @bitCast(offset_arg);
    const base: i64 = switch (whence) {
        SEEK_SET => 0,
        SEEK_CUR => @intCast(open_file.file.offset),
        SEEK_END => @intCast(open_file.file.inode.data.len),
        else => return errno.fail(errno.INVAL),
    };
    const next = base + offset;
    if (next < 0) return errno.fail(errno.INVAL);

    open_file.file.offset = @intCast(next);
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

    const descriptor = current_process.get(fd) orelse return errno.fail(errno.BADF);
    out.* = switch (descriptor.target) {
        .stdin, .stdout, .stderr => .{ .mode = 0o020000 },
        .file => |open_file| statFor(open_file.file.inode),
    };
    return 0;
}

fn sysDup(fd_arg: u64) i64 {
    const fd = fdIndex(fd_arg) orelse return errno.fail(errno.BADF);
    const new_fd = current_process.dup(fd) orelse {
        if (current_process.get(fd) == null) return errno.fail(errno.BADF);
        return errno.fail(errno.NFILE);
    };
    return @intCast(new_fd);
}

fn sysExit(status: u64) noreturn {
    _ = status;
    arch.interrupts.disable();
    cpu.outb(0xF4, 0x10);
    cpu.halt();
}

fn statFor(inode: *const fs.vfs.Inode) Stat {
    const is_dir = inode.kind == .dir;
    return .{
        .mode = if (is_dir) 0o040555 else 0o100444,
        .size = if (is_dir) 0 else @intCast(inode.data.len),
        .blocks = if (is_dir) 0 else @intCast((inode.data.len + 511) / 512),
    };
}

fn allocOpenFile(file: fs.vfs.File) ?*OpenFile {
    for (&open_files) |*open_file| {
        if (!open_file.used) {
            open_file.* = .{
                .used = true,
                .file = file,
                .ref_count = 1,
            };
            return open_file;
        }
    }
    return null;
}

fn retainTarget(target: FdTarget) void {
    switch (target) {
        .file => |open_file| open_file.ref_count += 1,
        .stdin, .stdout, .stderr => {},
    }
}

fn releaseTarget(target: FdTarget) void {
    switch (target) {
        .file => |open_file| releaseOpenFile(open_file),
        .stdin, .stdout, .stderr => {},
    }
}

fn releaseOpenFile(open_file: *OpenFile) void {
    if (open_file.ref_count > 1) {
        open_file.ref_count -= 1;
        return;
    }
    open_file.* = .{};
}

pub fn fdCloseOnExecForTest(fd_arg: u64) ?bool {
    const fd = fdIndex(fd_arg) orelse return null;
    const descriptor = current_process.get(fd) orelse return null;
    return descriptor.close_on_exec;
}

fn fdIndex(fd: u64) ?usize {
    if (fd >= MAX_FDS) return null;
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
