//! Syscall dispatcher and Phase 6 handler set.

const std = @import("std");

const arch = @import("arch");
const elf = @import("elf");
const fs = @import("fs");
const proc = @import("proc");

const errno = @import("errno.zig");
const numbers = @import("numbers.zig");

const serial = arch.serial;
const cpu = arch.cpu;

const MAX_FDS: usize = 16;
const MAX_OPEN_FILES: usize = 16;
const MAX_PIPES: usize = 8;
const MAX_PATH_BYTES: usize = 256;
const MAX_EXEC_ARGS: usize = 8;
const MAX_EXEC_ENVS: usize = 8;
const MAX_EXEC_STRING_BYTES: usize = 256;
const PIPE_BUFFER_SIZE: usize = 4096;

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

const Pipe = struct {
    used: bool = false,
    buffer: [PIPE_BUFFER_SIZE]u8 = undefined,
    head: usize = 0,
    len: usize = 0,
    read_refs: usize = 0,
    write_refs: usize = 0,

    fn read(self: *Pipe, dest: []u8) usize {
        const amount = @min(dest.len, self.len);
        var copied: usize = 0;
        while (copied < amount) : (copied += 1) {
            dest[copied] = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
        }
        self.len -= amount;
        if (self.len == 0) self.head = 0;
        return amount;
    }

    fn write(self: *Pipe, bytes: []const u8) usize {
        const available = self.buffer.len - self.len;
        const amount = @min(bytes.len, available);
        var copied: usize = 0;
        while (copied < amount) : (copied += 1) {
            const index = (self.head + self.len + copied) % self.buffer.len;
            self.buffer[index] = bytes[copied];
        }
        self.len += amount;
        return amount;
    }
};

const FdTarget = union(enum) {
    stdin,
    stdout,
    stderr,
    file: *OpenFile,
    pipe_read: *Pipe,
    pipe_write: *Pipe,
};

const Descriptor = struct {
    target: FdTarget,
    close_on_exec: bool = false,
};

pub const ExecCopyError = error{
    Fault,
    TooLong,
    TooMany,
};

const ExecString = struct {
    buffer: [MAX_EXEC_STRING_BYTES]u8 = [_]u8{0} ** MAX_EXEC_STRING_BYTES,
    len: usize = 0,

    fn slice(self: *const ExecString) []const u8 {
        return self.buffer[0..self.len];
    }
};

pub const ExecArgs = struct {
    argv_storage: [MAX_EXEC_ARGS]ExecString = [_]ExecString{.{}} ** MAX_EXEC_ARGS,
    envp_storage: [MAX_EXEC_ENVS]ExecString = [_]ExecString{.{}} ** MAX_EXEC_ENVS,
    argc: usize = 0,
    envc: usize = 0,

    pub fn argv(self: *const ExecArgs, out: *[MAX_EXEC_ARGS][]const u8) []const []const u8 {
        var index: usize = 0;
        while (index < self.argc) : (index += 1) {
            out[index] = self.argv_storage[index].slice();
        }
        return out[0..self.argc];
    }

    pub fn envp(self: *const ExecArgs, out: *[MAX_EXEC_ENVS][]const u8) []const []const u8 {
        var index: usize = 0;
        while (index < self.envc) : (index += 1) {
            out[index] = self.envp_storage[index].slice();
        }
        return out[0..self.envc];
    }
};

pub const PreparedSpawn = struct {
    pid: proc.Pid,
    entry: usize,
    stack_top: usize,
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

    fn closeOnExec(self: *Process) void {
        for (&self.fd_table) |*slot| {
            const descriptor = slot.* orelse continue;
            if (!descriptor.close_on_exec) continue;
            releaseTarget(descriptor.target);
            slot.* = null;
        }
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
var pipes: [MAX_PIPES]Pipe = [_]Pipe{.{}} ** MAX_PIPES;
var current_process: Process = .{};
var exec_args_scratch: ExecArgs = .{};

pub fn init() void {
    for (&open_files) |*slot| slot.* = .{};
    for (&pipes) |*slot| slot.* = .{};
    proc.init();
    current_process.init();
}

pub fn invoke(num: u64, arg0: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64) i64 {
    _ = arg5;
    _ = arg4;
    return switch (num) {
        numbers.read => sysRead(arg0, arg1, arg2),
        numbers.write => sysWrite(arg0, arg1, arg2),
        numbers.open => sysOpen(arg0, arg1, arg2),
        numbers.close => sysClose(arg0),
        numbers.stat => sysStat(arg0, arg1),
        numbers.fstat => sysFstat(arg0, arg1),
        numbers.lseek => sysLseek(arg0, arg1, arg2),
        numbers.pipe => sysPipe(arg0),
        numbers.dup => sysDup(arg0),
        numbers.execve => sysExecve(arg0, arg1, arg2),
        numbers.exit => sysExit(arg0),
        numbers.wait4 => sysWait4(arg0, arg1, arg2, arg3),
        numbers.exit_group => sysExit(arg0),
        numbers.posix_spawn => sysPosixSpawn(arg0, arg1, arg2),
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
        .pipe_read => |pipe| pipe.read(dest),
        .pipe_write => return errno.fail(errno.BADF),
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
        .pipe_write => |pipe| {
            if (pipe.read_refs == 0) return errno.fail(errno.PIPE);
            return @intCast(pipe.write(bytes));
        },
        .stdin, .file, .pipe_read => return errno.fail(errno.BADF),
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
        .stdin, .stdout, .stderr, .pipe_read, .pipe_write => return errno.fail(errno.BADF),
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
        .pipe_read, .pipe_write => .{ .mode = 0o010000 },
        .file => |open_file| statFor(open_file.file.inode),
    };
    return 0;
}

fn sysPipe(pipefd_ptr: u64) i64 {
    const pipefd = userFdPair(pipefd_ptr) orelse return errno.fail(errno.FAULT);
    const pipe = allocPipe() orelse return errno.fail(errno.NFILE);

    const read_fd = current_process.install(.{ .target = .{ .pipe_read = pipe } }) orelse {
        releasePipeRead(pipe);
        releasePipeWrite(pipe);
        return errno.fail(errno.NFILE);
    };
    const write_fd = current_process.install(.{ .target = .{ .pipe_write = pipe } }) orelse {
        _ = current_process.close(read_fd);
        releasePipeWrite(pipe);
        return errno.fail(errno.NFILE);
    };

    pipefd[0] = @intCast(read_fd);
    pipefd[1] = @intCast(write_fd);
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

fn sysExecve(path_ptr: u64, argv_ptr: u64, envp_ptr: u64) i64 {
    const path = userCString(path_ptr) orelse return errno.fail(errno.FAULT);
    const args = copyExecArgs(argv_ptr, envp_ptr) catch |err| return errno.fail(switch (err) {
        error.Fault => errno.FAULT,
        error.TooLong, error.TooMany => errno.BIG,
    });
    const inode = fs.vfs.lookup(path) catch |err| return mapFsError(err);

    var segments: [8]elf.parse.Segment = undefined;
    var argv_slices: [MAX_EXEC_ARGS][]const u8 = undefined;
    var envp_slices: [MAX_EXEC_ENVS][]const u8 = undefined;
    const image = elf.loader.replaceStaticUserWithStack(inode.data, &segments, .{
        .argv = args.argv(&argv_slices),
        .envp = args.envp(&envp_slices),
    }) catch |err| return mapExecError(err);

    current_process.closeOnExec();
    arch.user.enter(image.entry, image.stack_top);
}

fn sysPosixSpawn(path_ptr: u64, argv_ptr: u64, envp_ptr: u64) i64 {
    const image = preparePosixSpawn(path_ptr, argv_ptr, envp_ptr) catch |err| return mapSpawnError(err);

    current_process.closeOnExec();
    proc.switchTo(image.pid) catch |err| {
        cleanupPreparedSpawn(image.pid);
        return errno.fail(switch (err) {
            error.NoProcess => errno.SRCH,
            else => errno.INVAL,
        });
    };
    arch.user.enter(image.entry, image.stack_top);
}

fn sysWait4(pid_arg: u64, status_ptr: u64, options: u64, rusage_ptr: u64) i64 {
    if (rusage_ptr != 0) return errno.fail(errno.INVAL);
    const requested_pid: i64 = @bitCast(pid_arg);
    const status_out = if (status_ptr == 0) null else userInt(status_ptr) orelse return errno.fail(errno.FAULT);
    const waited = proc.wait4(proc.currentPid(), requested_pid, status_out, options) catch |err| {
        return errno.fail(switch (err) {
            error.InvalidArgument => errno.INVAL,
            error.NoChild => errno.CHILD,
            error.WouldBlock => errno.AGAIN,
            error.NoProcess => errno.SRCH,
            error.OutOfMemory, error.RegionTableFull, error.TableFull => errno.NFILE,
            error.Unsupported => errno.INVAL,
        });
    };
    return @intCast(waited);
}

fn sysExit(status: u64) noreturn {
    _ = proc.markExited(proc.currentPid(), status);
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

fn allocPipe() ?*Pipe {
    for (&pipes) |*pipe| {
        if (!pipe.used) {
            pipe.* = .{
                .used = true,
                .read_refs = 1,
                .write_refs = 1,
            };
            return pipe;
        }
    }
    return null;
}

fn retainTarget(target: FdTarget) void {
    switch (target) {
        .file => |open_file| open_file.ref_count += 1,
        .pipe_read => |pipe| pipe.read_refs += 1,
        .pipe_write => |pipe| pipe.write_refs += 1,
        .stdin, .stdout, .stderr => {},
    }
}

fn releaseTarget(target: FdTarget) void {
    switch (target) {
        .file => |open_file| releaseOpenFile(open_file),
        .pipe_read => |pipe| releasePipeRead(pipe),
        .pipe_write => |pipe| releasePipeWrite(pipe),
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

fn releasePipeRead(pipe: *Pipe) void {
    if (pipe.read_refs > 0) pipe.read_refs -= 1;
    releasePipeIfUnused(pipe);
}

fn releasePipeWrite(pipe: *Pipe) void {
    if (pipe.write_refs > 0) pipe.write_refs -= 1;
    releasePipeIfUnused(pipe);
}

fn releasePipeIfUnused(pipe: *Pipe) void {
    if (pipe.read_refs == 0 and pipe.write_refs == 0) pipe.* = .{};
}

pub fn fdCloseOnExecForTest(fd_arg: u64) ?bool {
    const fd = fdIndex(fd_arg) orelse return null;
    const descriptor = current_process.get(fd) orelse return null;
    return descriptor.close_on_exec;
}

pub fn closeOnExecForTest() void {
    current_process.closeOnExec();
}

pub fn execvePlanForTest(path: []const u8) bool {
    const inode = fs.vfs.lookup(path) catch return false;
    var segments: [8]elf.parse.Segment = undefined;
    _ = elf.loader.planStaticUser(inode.data, &segments) catch return false;
    return true;
}

pub fn execArgsForTest(argv_ptr: u64, envp_ptr: u64) ExecCopyError!*const ExecArgs {
    return copyExecArgs(argv_ptr, envp_ptr);
}

pub fn preparePosixSpawnForTest(path_ptr: u64, argv_ptr: u64, envp_ptr: u64) ?PreparedSpawn {
    return preparePosixSpawn(path_ptr, argv_ptr, envp_ptr) catch null;
}

pub fn cleanupPreparedSpawnForTest(pid: proc.Pid) void {
    cleanupPreparedSpawn(pid);
}

fn preparePosixSpawn(path_ptr: u64, argv_ptr: u64, envp_ptr: u64) !PreparedSpawn {
    const parent = proc.currentPid();
    const path = userCString(path_ptr) orelse return error.Fault;
    const args = try copyExecArgs(argv_ptr, envp_ptr);
    const inode = try fs.vfs.lookup(path);
    const child = try proc.spawnChild(parent);
    errdefer cleanupPreparedSpawn(child);

    var segments: [8]elf.parse.Segment = undefined;
    var argv_slices: [MAX_EXEC_ARGS][]const u8 = undefined;
    var envp_slices: [MAX_EXEC_ENVS][]const u8 = undefined;
    const image = try elf.loader.loadStaticUserForProcess(child, inode.data, &segments, .{
        .argv = args.argv(&argv_slices),
        .envp = args.envp(&envp_slices),
    });

    return .{
        .pid = child,
        .entry = image.entry,
        .stack_top = image.stack_top,
    };
}

fn cleanupPreparedSpawn(pid: proc.Pid) void {
    elf.loader.releaseProcessPages(pid);
    _ = proc.markExited(pid, 127);
    _ = proc.wait4(proc.currentPid(), @intCast(pid), null, 0) catch {};
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

fn copyExecArgs(argv_ptr: u64, envp_ptr: u64) ExecCopyError!*const ExecArgs {
    exec_args_scratch = .{};
    exec_args_scratch.argc = try copyExecVector(argv_ptr, MAX_EXEC_ARGS, &exec_args_scratch.argv_storage);
    exec_args_scratch.envc = try copyExecVector(envp_ptr, MAX_EXEC_ENVS, &exec_args_scratch.envp_storage);
    return &exec_args_scratch;
}

fn copyExecVector(ptr: u64, comptime max_items: usize, storage: *[max_items]ExecString) ExecCopyError!usize {
    if (ptr == 0) return 0;

    const raw: [*]const u64 = @ptrFromInt(ptr);
    var count: usize = 0;
    while (count < max_items) : (count += 1) {
        const item_ptr = raw[count];
        if (item_ptr == 0) return count;
        storage[count] = try copyExecString(item_ptr);
    }
    return error.TooMany;
}

fn copyExecString(ptr: u64) ExecCopyError!ExecString {
    if (ptr == 0) return error.Fault;

    const raw: [*]const u8 = @ptrFromInt(ptr);
    var out: ExecString = .{};
    while (out.len < out.buffer.len) : (out.len += 1) {
        const byte = raw[out.len];
        if (byte == 0) return out;
        out.buffer[out.len] = byte;
    }
    return error.TooLong;
}

fn userStat(ptr: u64) ?*Stat {
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

fn userFdPair(ptr: u64) ?*[2]i32 {
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

fn userInt(ptr: u64) ?*i32 {
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

fn mapExecError(err: elf.loader.Error) i64 {
    return errno.fail(switch (err) {
        error.OutOfMemory, error.RegionTableFull => errno.NFILE,
        error.UserStackOverflow => errno.BIG,
        error.NoProcess => errno.SRCH,
        error.NotAligned, error.AlreadyMapped, error.NotMapped, error.Unsupported => errno.INVAL,
        else => errno.NOEXEC,
    });
}

fn mapSpawnError(err: anyerror) i64 {
    return errno.fail(switch (err) {
        error.Fault => errno.FAULT,
        error.TooLong, error.TooMany, error.UserStackOverflow => errno.BIG,
        error.NotMounted => errno.IO,
        error.NotFound => errno.NOENT,
        error.NotDirectory => errno.NOTDIR,
        error.IsDirectory => errno.ISDIR,
        error.AlreadyExists, error.InvalidPath => errno.INVAL,
        error.PathTooLong => errno.NAMETOOLONG,
        error.TooManyNodes,
        error.NameStorageFull,
        error.MalformedInitramfs,
        error.OutOfMemory,
        error.RegionTableFull,
        error.TableFull,
        => errno.NFILE,
        error.NoProcess => errno.SRCH,
        error.InvalidArgument,
        error.NotAligned,
        error.AlreadyMapped,
        error.NotMapped,
        error.Unsupported,
        => errno.INVAL,
        else => errno.NOEXEC,
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
