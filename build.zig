//! Zigix build orchestration.
//!
//! Phase 4 steps:
//!   * `check-toolchain`     -- runs the host-side toolchain check script.
//!   * `kernel`              -- builds zig-out/bin/zigix-kernel (multiboot1 ELF).
//!   * `validate-kernel-elf` -- sanity-checks the ELF (32-bit ELF check, multiboot magic).
//!   * `qemu-smoke`          -- boots the kernel headlessly and parses Phase 4 serial markers.
//!   * `host-test`           -- placeholder (no host tests yet).
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
            .{ .name = "mm", .module = mm_module },
            .{ .name = "multiboot", .module = multiboot_module },
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

    const kernel_step = b.step(
        "kernel",
        "Build the Zigix kernel ELF and the multiboot1-loadable elf32 form",
    );
    kernel_step.dependOn(&install_kernel.step);
    kernel_step.dependOn(&install_kernel32.step);

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
    qemu_run.setName("qemu-run");
    qemu_run.has_side_effects = true;
    qemu_run.step.dependOn(&install_kernel32.step);

    const smoke = b.addSystemCommand(&.{
        "tools/qemu/smoke_test.py",
        "zig-out/serial.log",
        "--phase",
        "phase4",
    });
    smoke.setName("qemu-smoke-parse");
    smoke.step.dependOn(&qemu_run.step);

    const qemu_step = b.step(
        "qemu-smoke",
        "Boot the kernel in QEMU and verify Phase 4 markers on COM1",
    );
    qemu_step.dependOn(&smoke.step);

    // ── host-test placeholder ────────────────────────────────────────────
    _ = b.step(
        "host-test",
        "Run host-side unit tests (none registered yet)",
    );
}
