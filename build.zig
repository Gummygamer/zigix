//! Zigix build orchestration.
//!
//! Phase 14 steps:
//!   * `check-toolchain`     -- runs the host-side toolchain check script.
//!   * `kernel`              -- builds zig-out/bin/zigix-kernel (multiboot1 ELF).
//!   * `validate-kernel-elf` -- sanity-checks the ELF (32-bit ELF check, multiboot magic).
//!   * `qemu-smoke`          -- boots the kernel headlessly and parses Phase 14 serial markers.
//!   * `qemu-smoke-scripted` -- boots with scripted COM1 input and parses Phase 12 markers.
//!   * `host-test`           -- runs host-side unit tests.
//!
//! IMPORTANT: invoke this build via `tools/toolchain/zig-bun build <step>`,
//! not `zig build` directly. The wrapper enforces the Bun-fork toolchain
//! contract; calling `zig` directly silently bypasses it.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // ── Kernel target ────────────────────────────────────────────────────
    // Freestanding x86_64. We disable every SIMD/x87 feature the kernel
    // doesn't have an FXSAVE area for, and enable soft-float so the
    // compiler doesn't emit SSE for floating-point lowering. `code_model`
    // = kernel keeps generated code addressable from the high half later,
    // and is the conventional choice for ring-0 code.
    const Feature = std.Target.x86.Feature;
    var disabled = std.Target.Cpu.Feature.Set.empty;
    disabled.addFeature(@intFromEnum(Feature.mmx));
    disabled.addFeature(@intFromEnum(Feature.sse));
    disabled.addFeature(@intFromEnum(Feature.sse2));
    disabled.addFeature(@intFromEnum(Feature.sse3));
    disabled.addFeature(@intFromEnum(Feature.ssse3));
    disabled.addFeature(@intFromEnum(Feature.sse4_1));
    disabled.addFeature(@intFromEnum(Feature.sse4_2));
    disabled.addFeature(@intFromEnum(Feature.avx));
    disabled.addFeature(@intFromEnum(Feature.avx2));
    disabled.addFeature(@intFromEnum(Feature.x87));

    var enabled = std.Target.Cpu.Feature.Set.empty;
    enabled.addFeature(@intFromEnum(Feature.soft_float));

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = disabled,
        .cpu_features_add = enabled,
    });

    const arch_module = b.createModule(.{
        .root_source_file = b.path("kernel/arch/x86_64/arch.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
    });

    const multiboot_module = b.createModule(.{
        .root_source_file = b.path("kernel/core/multiboot.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
    });

    const mm_module = b.createModule(.{
        .root_source_file = b.path("kernel/mm/mm.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
            .{ .name = "multiboot", .module = multiboot_module },
        },
    });

    const fs_module = b.createModule(.{
        .root_source_file = b.path("kernel/fs/fs.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "multiboot", .module = multiboot_module },
        },
    });

    const proc_module = b.createModule(.{
        .root_source_file = b.path("kernel/proc/process.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
            .{ .name = "mm", .module = mm_module },
        },
    });

    const elf_module = b.createModule(.{
        .root_source_file = b.path("kernel/elf/elf.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
            .{ .name = "mm", .module = mm_module },
            .{ .name = "proc", .module = proc_module },
        },
    });

    const syscall_module = b.createModule(.{
        .root_source_file = b.path("kernel/syscall/syscall.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
            .{ .name = "elf", .module = elf_module },
            .{ .name = "fs", .module = fs_module },
            .{ .name = "proc", .module = proc_module },
        },
    });

    const kernel_module = b.createModule(.{
        .root_source_file = b.path("kernel/core/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "arch", .module = arch_module },
            .{ .name = "fs", .module = fs_module },
            .{ .name = "elf", .module = elf_module },
            .{ .name = "mm", .module = mm_module },
            .{ .name = "multiboot", .module = multiboot_module },
            .{ .name = "proc", .module = proc_module },
            .{ .name = "syscall", .module = syscall_module },
        },
    });

    const kernel_exe = b.addExecutable(.{
        .name = "zigix-kernel",
        .root_module = kernel_module,
        // Force the LLVM backend. The Zig self-hosted x86_64 backend at
        // 0.15.2 emits SIMD instructions (`movups`) for some lowerings even
        // with SSE features subtracted, which a freestanding kernel has no
        // FXSAVE area for. LLVM honors the feature subtraction strictly.
        .use_llvm = true,
        .use_lld = true,
    });
    kernel_exe.setLinkerScript(b.path("kernel/arch/x86_64/linker.ld"));
    kernel_exe.entry = .{ .symbol_name = "_start" };
    kernel_exe.addAssemblyFile(b.path("kernel/arch/x86_64/boot/start.S"));
    kernel_exe.addAssemblyFile(b.path("kernel/arch/x86_64/interrupt_stubs.S"));
    // Multiboot1 requires the header to live in the first 8 KiB of the
    // file. The linker script places `.multiboot` first, but we also tell
    // the linker not to page-pad the file so the offset stays small.
    kernel_exe.link_z_max_page_size = 0x1000;

    const install_kernel = b.addInstallArtifact(kernel_exe, .{});

    // ── Multiboot1 trampoline form ──────────────────────────────────────
    // QEMU's `-kernel` multiboot loader rejects ELF64 ("Cannot load x86-64
    // image, give a 32bit one."). The bytes we need are the same; we just
    // have to lie in the ELF header. `objcopy -O elf32-i386` rewrites the
    // class to ELFCLASS32 and the machine to i386; all our load addresses
    // already fit in 32 bits, so the conversion is loss-free for the
    // loader's purposes. The 64-bit code in the file is unchanged and
    // executes only after `start.S` has set CR0.PG | EFER.LME.
    const objcopy = b.addSystemCommand(&.{ "objcopy", "-O", "elf32-i386" });
    objcopy.addArtifactArg(kernel_exe);
    const kernel32_path = objcopy.addOutputFileArg("zigix-kernel.mb");
    objcopy.setName("kernel-elf32");

    const install_kernel32 = b.addInstallFileWithDir(
        kernel32_path,
        .bin,
        "zigix-kernel.mb",
    );

    // ── Phase 8/14 userspace init + initramfs ───────────────────────────
    const userspace_sys_module = b.createModule(.{
        .root_source_file = b.path("userspace/lib/sys.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
    });

    const libc_shim_newlib_module = b.createModule(.{
        .root_source_file = b.path("userspace/libc_shim/newlib.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "zigix_sys", .module = userspace_sys_module },
        },
    });

    const init_module = b.createModule(.{
        .root_source_file = b.path("userspace/init/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "zigix_sys", .module = userspace_sys_module },
            .{ .name = "zigix_newlib", .module = libc_shim_newlib_module },
        },
    });

    const init_exe = b.addExecutable(.{
        .name = "init",
        .root_module = init_module,
        .use_llvm = true,
        .use_lld = true,
    });
    init_exe.setLinkerScript(b.path("userspace/init/linker.ld"));
    init_exe.entry = .{ .symbol_name = "_start" };

    const install_init = b.addInstallArtifact(init_exe, .{});

    const init_interactive_module = b.createModule(.{
        .root_source_file = b.path("userspace/init-interactive/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "zigix_sys", .module = userspace_sys_module },
        },
    });

    const init_interactive_exe = b.addExecutable(.{
        .name = "init-interactive",
        .root_module = init_interactive_module,
        .use_llvm = true,
        .use_lld = true,
    });
    init_interactive_exe.setLinkerScript(b.path("userspace/init/linker.ld"));
    init_interactive_exe.entry = .{ .symbol_name = "_start" };

    const install_init_interactive = b.addInstallArtifact(init_interactive_exe, .{});

    const exec_ok_module = b.createModule(.{
        .root_source_file = b.path("userspace/exec-ok/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "zigix_sys", .module = userspace_sys_module },
        },
    });

    const exec_ok_exe = b.addExecutable(.{
        .name = "exec-ok",
        .root_module = exec_ok_module,
        .use_llvm = true,
        .use_lld = true,
    });
    exec_ok_exe.setLinkerScript(b.path("userspace/init/linker.ld"));
    exec_ok_exe.entry = .{ .symbol_name = "_start" };

    const install_exec_ok = b.addInstallArtifact(exec_ok_exe, .{});

    const tinysh_module = b.createModule(.{
        .root_source_file = b.path("userspace/tinysh/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
        .red_zone = false,
        .pic = false,
        .stack_protector = false,
        .stack_check = false,
        .single_threaded = true,
        .strip = false,
        .omit_frame_pointer = false,
        .imports = &.{
            .{ .name = "zigix_sys", .module = userspace_sys_module },
        },
    });

    const tinysh_exe = b.addExecutable(.{
        .name = "tinysh",
        .root_module = tinysh_module,
        .use_llvm = true,
        .use_lld = true,
    });
    tinysh_exe.setLinkerScript(b.path("userspace/init/linker.ld"));
    tinysh_exe.entry = .{ .symbol_name = "_start" };

    const install_tinysh = b.addInstallArtifact(tinysh_exe, .{});

    const pack_initramfs = b.addSystemCommand(&.{ "python3", "tools/mkinitramfs/pack.py" });
    const initramfs_path = pack_initramfs.addOutputFileArg("initramfs.zixr");
    pack_initramfs.addArg("--entry");
    pack_initramfs.addArg("init");
    pack_initramfs.addFileArg(init_exe.getEmittedBin());
    pack_initramfs.addArg("--entry");
    pack_initramfs.addArg("exec-ok");
    pack_initramfs.addFileArg(exec_ok_exe.getEmittedBin());
    pack_initramfs.addArg("--entry");
    pack_initramfs.addArg("tinysh");
    pack_initramfs.addFileArg(tinysh_exe.getEmittedBin());
    pack_initramfs.setName("mkinitramfs");

    const install_initramfs = b.addInstallFileWithDir(
        initramfs_path,
        .bin,
        "initramfs.zixr",
    );

    const pack_interactive_initramfs = b.addSystemCommand(&.{ "python3", "tools/mkinitramfs/pack.py" });
    const interactive_initramfs_path = pack_interactive_initramfs.addOutputFileArg("initramfs-interactive.zixr");
    pack_interactive_initramfs.addArg("--entry");
    pack_interactive_initramfs.addArg("init");
    pack_interactive_initramfs.addFileArg(init_interactive_exe.getEmittedBin());
    pack_interactive_initramfs.addArg("--entry");
    pack_interactive_initramfs.addArg("exec-ok");
    pack_interactive_initramfs.addFileArg(exec_ok_exe.getEmittedBin());
    pack_interactive_initramfs.addArg("--entry");
    pack_interactive_initramfs.addArg("tinysh");
    pack_interactive_initramfs.addFileArg(tinysh_exe.getEmittedBin());
    pack_interactive_initramfs.setName("mkinitramfs-interactive");

    const install_interactive_initramfs = b.addInstallFileWithDir(
        interactive_initramfs_path,
        .bin,
        "initramfs-interactive.zixr",
    );

    const kernel_step = b.step(
        "kernel",
        "Build the Zigix kernel ELF and the multiboot1-loadable elf32 form",
    );
    kernel_step.dependOn(&install_kernel.step);
    kernel_step.dependOn(&install_kernel32.step);
    kernel_step.dependOn(&install_init.step);
    kernel_step.dependOn(&install_init_interactive.step);
    kernel_step.dependOn(&install_exec_ok.step);
    kernel_step.dependOn(&install_tinysh.step);
    kernel_step.dependOn(&install_initramfs.step);
    kernel_step.dependOn(&install_interactive_initramfs.step);

    // ── check-toolchain ──────────────────────────────────────────────────
    const check = b.addSystemCommand(&.{"tools/toolchain/check-bun-zig.sh"});
    check.setName("check-bun-zig");
    const check_step = b.step(
        "check-toolchain",
        "Verify the Bun Zig toolchain is configured (logs identity)",
    );
    check_step.dependOn(&check.step);

    // ── validate-kernel-elf ──────────────────────────────────────────────
    // We validate the elf32 form since that is the file QEMU's `-kernel`
    // loader actually consumes.
    const validate = b.addSystemCommand(&.{"tools/kernel/validate-elf.sh"});
    validate.addFileArg(kernel32_path);
    validate.setName("validate-kernel-elf");
    const validate_step = b.step(
        "validate-kernel-elf",
        "Verify the multiboot1 ELF has the magic dword in the first 8 KiB",
    );
    validate_step.dependOn(&validate.step);
    validate_step.dependOn(&install_kernel32.step);

    // ── qemu-smoke ───────────────────────────────────────────────────────
    const qemu_run = b.addSystemCommand(&.{"tools/qemu/run.sh"});
    qemu_run.addFileArg(kernel32_path);
    qemu_run.addFileArg(initramfs_path);
    qemu_run.setName("qemu-run");
    qemu_run.has_side_effects = true;
    qemu_run.step.dependOn(&install_kernel32.step);

    const smoke = b.addSystemCommand(&.{
        "tools/qemu/smoke_test.py",
        "zig-out/serial.log",
        "--phase",
        "phase14",
    });
    smoke.setName("qemu-smoke-parse");
    smoke.step.dependOn(&qemu_run.step);

    const qemu_step = b.step(
        "qemu-smoke",
        "Boot the kernel in QEMU and verify Phase 14 markers on COM1",
    );
    qemu_step.dependOn(&smoke.step);

    const qemu_run_scripted = b.addSystemCommand(&.{"tools/qemu/run.sh"});
    qemu_run_scripted.addFileArg(kernel32_path);
    qemu_run_scripted.addFileArg(interactive_initramfs_path);
    qemu_run_scripted.addFileArg(b.path("tests/qemu/phase12-serial-input.txt"));
    qemu_run_scripted.addArg("zig-out/serial-scripted.log");
    qemu_run_scripted.setName("qemu-run-scripted");
    qemu_run_scripted.has_side_effects = true;
    qemu_run_scripted.step.dependOn(&install_kernel32.step);

    const smoke_scripted = b.addSystemCommand(&.{
        "tools/qemu/smoke_test.py",
        "zig-out/serial-scripted.log",
        "--phase",
        "phase12",
    });
    smoke_scripted.setName("qemu-smoke-scripted-parse");
    smoke_scripted.step.dependOn(&qemu_run_scripted.step);

    const qemu_scripted_step = b.step(
        "qemu-smoke-scripted",
        "Boot QEMU with scripted serial input and verify Phase 12 stdin groundwork",
    );
    qemu_scripted_step.dependOn(&smoke_scripted.step);

    // ── host-test ────────────────────────────────────────────────────────
    const host_path_module = b.createModule(.{
        .root_source_file = b.path("tests/host/path.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "fs_path",
                .module = b.createModule(.{
                    .root_source_file = b.path("kernel/fs/path.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                }),
            },
        },
    });
    const host_path_tests = b.addTest(.{
        .root_module = host_path_module,
    });
    const run_host_path_tests = b.addRunArtifact(host_path_tests);

    const host_elf_module = b.createModule(.{
        .root_source_file = b.path("tests/host/elf_parse.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "elf_parse",
                .module = b.createModule(.{
                    .root_source_file = b.path("kernel/elf/parse.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                }),
            },
        },
    });
    const host_elf_tests = b.addTest(.{
        .root_module = host_elf_module,
    });
    const run_host_elf_tests = b.addRunArtifact(host_elf_tests);

    const host_step = b.step(
        "host-test",
        "Run host-side unit tests",
    );
    host_step.dependOn(&run_host_path_tests.step);
    host_step.dependOn(&run_host_elf_tests.step);

    const host_libc_shim_module = b.createModule(.{
        .root_source_file = b.path("tests/host/libc_shim.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "libc_shim_abi",
                .module = b.createModule(.{
                    .root_source_file = b.path("userspace/libc_shim/abi.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                }),
            },
        },
    });
    const host_libc_shim_tests = b.addTest(.{
        .root_module = host_libc_shim_module,
    });
    const run_host_libc_shim_tests = b.addRunArtifact(host_libc_shim_tests);
    host_step.dependOn(&run_host_libc_shim_tests.step);
}
