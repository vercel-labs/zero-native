const std = @import("std");
const web_engine_tool = @import("src/tooling/web_engine.zig");

fn repositoryScriptcBin(b: *std.Build) []const u8 {
    return b.pathFromRoot(if (b.graph.host.result.os.tag == .windows)
        "packages/core/node_modules/.bin/scriptc.cmd"
    else
        "packages/core/node_modules/.bin/scriptc");
}

const PlatformOption = enum {
    auto,
    null,
    macos,
    linux,
    windows,
};

const TraceOption = enum {
    off,
    events,
    runtime,
    all,
};

const WebEngineOption = enum {
    system,
    chromium,
};

const PackageTarget = enum {
    macos,
    windows,
    linux,
    ios,
    android,
};

const SigningMode = enum {
    none,
    adhoc,
    identity,
};

pub const AppOptions = @import("build/app.zig").AppOptions;
pub const addApp = @import("build/app.zig").addApp;
pub const AppArtifacts = @import("build/app.zig").AppArtifacts;
pub const addAppArtifacts = @import("build/app.zig").addAppArtifacts;
pub const MobileLibOptions = @import("build/app.zig").MobileLibOptions;
pub const addMobileLib = @import("build/app.zig").addMobileLib;
const mobile_export_symbol_names = @import("build/app.zig").mobile_export_symbol_names;

test "service archive support matches ScriptC localized object formats" {
    const app_build = @import("build/app.zig");
    const host = @import("builtin").target;
    const resolved = struct {
        fn target(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch, abi: std.Target.Abi) std.Build.ResolvedTarget {
            var result = host;
            result.os.tag = os;
            result.cpu.arch = arch;
            result.abi = abi;
            return .{
                .query = .{ .os_tag = os, .cpu_arch = arch, .abi = abi },
                .result = result,
            };
        }
    }.target;

    var macos_host = host;
    macos_host.os.tag = .macos;
    macos_host.cpu.arch = .aarch64;
    macos_host.abi = .none;
    try std.testing.expect(app_build.serviceArchiveSupported(macos_host, resolved(.windows, .x86_64, .gnu)));
    try std.testing.expect(!app_build.serviceArchiveSupported(macos_host, resolved(.windows, .x86_64, .msvc)));
    try std.testing.expect(!app_build.serviceArchiveSupported(macos_host, resolved(.windows, .aarch64, .gnu)));
    try std.testing.expect(app_build.serviceArchiveSupported(macos_host, resolved(.linux, .x86_64, .musl)));
    try std.testing.expect(app_build.serviceArchiveSupported(macos_host, resolved(.linux, .aarch64, .musl)));
    try std.testing.expect(!app_build.serviceArchiveSupported(macos_host, resolved(.linux, .riscv64, .musl)));
    try std.testing.expect(app_build.serviceArchiveSupported(macos_host, resolved(.macos, .x86_64, .none)));

    var linux_host = host;
    linux_host.os.tag = .linux;
    linux_host.cpu.arch = .riscv64;
    linux_host.abi = .musl;
    try std.testing.expect(app_build.serviceArchiveSupported(linux_host, .{ .query = .{}, .result = linux_host }));
    try std.testing.expect(!app_build.serviceArchiveSupported(linux_host, resolved(.macos, .aarch64, .none)));

    var gnu_linux_host = host;
    gnu_linux_host.os.tag = .linux;
    gnu_linux_host.cpu.arch = .x86_64;
    gnu_linux_host.abi = .gnu;
    const explicit_same_triple_gnu = resolved(.linux, .x86_64, .gnu);
    try std.testing.expect(!app_build.scriptcTargetIsCross(gnu_linux_host, explicit_same_triple_gnu));
    try std.testing.expect(app_build.linuxGlibcSpellingHitsDefaultFloor(explicit_same_triple_gnu));
    try std.testing.expect(!app_build.linuxGlibcSpellingHitsDefaultFloor(.{ .query = .{}, .result = gnu_linux_host }));

    var windows_host = host;
    windows_host.os.tag = .windows;
    windows_host.cpu.arch = .x86_64;
    windows_host.abi = .gnu;
    const native_windows_msvc = resolved(.windows, .x86_64, .msvc);
    try std.testing.expect(!app_build.scriptcTargetIsCross(windows_host, native_windows_msvc));
    try std.testing.expect(app_build.scriptcCompileSupported(windows_host, native_windows_msvc));
    try std.testing.expect(app_build.serviceArchiveSupported(windows_host, native_windows_msvc));
}

test "root TypeScript markup discovery classification and resolver budgets" {
    const app_build = @import("build/app.zig");
    try std.testing.expect(app_build.isRootMarkupSourcePath("components/card.native"));
    try std.testing.expect(app_build.isRootMarkupSourcePath("feature/nested/panel.native"));
    try std.testing.expect(!app_build.isRootMarkupSourcePath("app.native"));
    try std.testing.expect(!app_build.isRootMarkupSourcePath("windows/settings.native"));
    try std.testing.expect(!app_build.isRootMarkupSourcePath("components/card.ts"));

    // The authored paths are relative to src/, while native check and the
    // desktop hot-reload resolver see the leading `src/` too. Pin the exact
    // source-relative boundaries that keep those full paths within 24
    // segments and 200 bytes.
    const max_segments_path = "a/" ** 22 ++ "a";
    try std.testing.expect(app_build.markupSourcePathWithinBudget(max_segments_path));
    try std.testing.expect(!app_build.markupSourcePathWithinBudget(max_segments_path ++ "/a"));
    try std.testing.expect(app_build.markupSourcePathWithinBudget("a" ** 196));
    try std.testing.expect(!app_build.markupSourcePathWithinBudget("a" ** 197));
}

test "generated TypeScript runners install the compiled root markup view" {
    const desktop = @embedFile("src/app_runner/ts_core_main.zig");
    try std.testing.expect(std.mem.indexOf(u8, desktop, "TsUiAppWithFeatures(core, .{ .runtime_markup = dev })") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "if (dev) void else @import(\"app_markup_root\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, "CompiledMarkupImports(core.Model, core.Msg, \"app.native\", &app_markup_sources)") != null);
    try std.testing.expect(std.mem.indexOf(u8, desktop, ".view = CompiledAppView.build") != null);

    const mobile = @embedFile("src/app_runner/ts_core_mobile.zig");
    try std.testing.expect(std.mem.indexOf(u8, mobile, "pub const features: native_sdk.UiAppFeatures = .{ .runtime_markup = false }") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile, "TsUiAppWithFeatures(core, features)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile, "const app_markup_root = @import(\"app_markup_root\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile, "CompiledMarkupImports(core.Model, core.Msg, \"app.native\", &app_markup_sources)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile, ".view = CompiledAppView.build") != null);
    try std.testing.expect(std.mem.indexOf(u8, mobile, ".markup =") == null);
}

test "Debug TypeScript root markup stays outside the staged app module" {
    const source = @embedFile("build/app.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "_ = staged.addCopyFile(b.path(appPath(b, app_root, \"src/app.native\")), \"app.native\");",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "_ = release_markup.addCopyFile(b.path(appPath(b, app_root, \"src/app.native\")), \"app.native\");",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "if (optimize != .Debug)") != null);
}

test "native check preserves the app markup root for component files" {
    const source = @embedFile("tools/native-sdk/main.zig");
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "checkFiles(allocator, io, markup_files.items, .{\n            .import_root_for_file = markup_cli.importRootForFile,\n        })",
    ) != null);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const host_target = b.graph.host;
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    _ = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    _ = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    _ = b.option(bool, "webview", "Deprecated compatibility flag; native surfaces are always enabled") orelse true;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
    _ = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux, ios, android") orelse .macos;
    const signing_mode = b.option(SigningMode, "signing", "Signing mode: none, adhoc, identity") orelse .none;
    const signing_identity = b.option([]const u8, "identity", "Code signing identity for distribution packages");
    const signing_entitlements = b.option([]const u8, "entitlements", "Entitlements plist for identity signing");
    const notary_profile = b.option([]const u8, "notary-profile", "notarytool Keychain profile for notarization");
    const package_version = packageVersion(b);
    const optimize_name = @tagName(optimize);
    // Resolve against THIS build's root: as a dependency of a user app the
    // build runner's cwd is the app project, and a cwd-relative "app.zon"
    // would read (and panic on) the user's manifest instead of ours.
    const app_web_engine = web_engine_tool.readManifestConfig(b.allocator, b.graph.io, b.pathFromRoot("app.zon")) catch |err| {
        std.debug.panic("failed to read the framework's own app.zon web engine config: {s}", .{@errorName(err)});
    };
    const resolved_web_engine = web_engine_tool.resolve(app_web_engine, .{
        .web_engine = if (web_engine_override) |value| webEngineFromBuildOption(value) else null,
        .cef_dir = cef_dir_override,
        .cef_auto_install = cef_auto_install_override,
    }) catch |err| {
        std.debug.panic("invalid app.zon web engine config: {s}", .{@errorName(err)});
    };
    const web_engine = buildWebEngineFromResolved(resolved_web_engine.engine);
    const browser_web_engine: WebEngineOption = web_engine_override orelse .system;
    const cef_auto_install = resolved_web_engine.cef_auto_install;
    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .null,
        else => platform_option,
    };
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, resolved_web_engine.cef_dir);
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    if (selected_platform == .linux and target.result.os.tag != .linux) {
        @panic("-Dplatform=linux requires a Linux target");
    }
    if (selected_platform == .windows and target.result.os.tag != .windows) {
        @panic("-Dplatform=windows requires a Windows target");
    }
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }

    const geometry_mod = module(b, target, optimize, "src/primitives/geometry/root.zig");
    const assets_mod = module(b, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs_mod = module(b, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace_mod = module(b, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest_mod = module(b, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = module(b, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = module(b, target, optimize, "src/primitives/platform_info/root.zig");
    const json_mod = module(b, target, optimize, "src/primitives/json/root.zig");
    const app_runner_assets_mod = module(b, target, optimize, "src/app_runner/app_assets.zig");
    const canvas_mod = module(b, target, optimize, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    if (target.result.os.tag == .macos) {
        // The estimator-vs-CoreText agreement test (text_metrics_tests.zig)
        // shapes the bundled face through CoreText; apps already link these
        // transitively via AppKit.
        canvas_mod.linkFramework("CoreFoundation", .{});
        canvas_mod.linkFramework("CoreGraphics", .{});
        canvas_mod.linkFramework("CoreText", .{});
        canvas_mod.linkSystemLibrary("c", .{});
    }
    const debug_mod = module(b, target, optimize, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const geometry_tests = testArtifact(b, geometry_mod);
    const assets_tests = testArtifact(b, assets_mod);
    const app_dirs_tests = testArtifact(b, app_dirs_mod);
    const trace_tests = testArtifact(b, trace_mod);
    const app_manifest_tests = testArtifact(b, app_manifest_mod);
    const diagnostics_tests = testArtifact(b, diagnostics_mod);
    const platform_info_tests = testArtifact(b, platform_info_mod);
    const json_tests = testArtifact(b, json_mod);
    const app_runner_assets_tests = testArtifact(b, app_runner_assets_mod);
    const canvas_tests = testArtifact(b, canvas_mod);

    const desktop_mod = module(b, target, optimize, "src/root.zig");
    desktop_mod.addImport("geometry", geometry_mod);
    desktop_mod.addImport("app_dirs", app_dirs_mod);
    desktop_mod.addImport("assets", assets_mod);
    desktop_mod.addImport("trace", trace_mod);
    desktop_mod.addImport("app_manifest", app_manifest_mod);
    desktop_mod.addImport("diagnostics", diagnostics_mod);
    desktop_mod.addImport("platform_info", platform_info_mod);
    desktop_mod.addImport("json", json_mod);
    desktop_mod.addImport("canvas", canvas_mod);
    desktop_mod.addImport("terminal_vt", terminalVtModule(b, target, optimize));
    desktop_mod.addIncludePath(b.path("third_party/sqlite"));
    desktop_mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        // Mobile -Dtargets (the mobile e2e battery) compile the
        // amalgamation against the platform SDK/NDK sysroot; desktop
        // targets keep Zig's ordinary libc discovery.
        .flags = if (target.result.os.tag == .ios or target.result.abi.isAndroid())
            @import("build/app.zig").sqliteCFlags(b, target)
        else
            sqliteCompileFlags(),
    });
    const app_runner_window_placement_mod = module(b, target, optimize, "src/app_runner/window_placement.zig");
    app_runner_window_placement_mod.addImport("native_sdk", desktop_mod);
    const app_runner_window_placement_tests = testArtifact(b, app_runner_window_placement_mod);
    const app_runner_options = b.addOptions();
    app_runner_options.addOption([]const u8, "platform", "null");
    app_runner_options.addOption([]const u8, "trace", "off");
    app_runner_options.addOption([]const u8, "web_engine", "system");
    app_runner_options.addOption(bool, "debug_overlay", false);
    app_runner_options.addOption(bool, "automation", false);
    app_runner_options.addOption(bool, "web_layer", false);
    const app_runner_mod = module(b, target, optimize, "src/app_runner/root.zig");
    app_runner_mod.addImport("native_sdk", desktop_mod);
    app_runner_mod.addImport("build_options", app_runner_options.createModule());
    app_runner_mod.addImport("app_manifest_zon", b.createModule(.{ .root_source_file = b.path("tests/app-runner/menu_commands_fixture.zon") }));
    const app_runner_migrations_mod = module(b, target, optimize, "src/app_runner/no_migrations.zig");
    app_runner_migrations_mod.addImport("native_sdk", desktop_mod);
    app_runner_mod.addImport("relational_migrations", app_runner_migrations_mod);
    const app_runner_tests = testArtifact(b, app_runner_mod);
    const app_runner_test_run = b.addRunArtifact(app_runner_tests);
    const app_runner_test_step = b.step("test-app-runner", "Run framework app-runner manifest fallback tests");
    app_runner_test_step.dependOn(&app_runner_test_run.step);
    desktop_mod.link_libc = true;
    if (target.result.os.tag == .macos) {
        const flags: []const []const u8 = if (b.sysroot) |sysroot|
            &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, b.fmt("-I{s}/usr/include", .{sysroot}) }
        else
            &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
        desktop_mod.addCSourceFile(.{ .file = b.path("src/platform/macos/image_fit_test.m"), .flags = flags });
        desktop_mod.addCSourceFile(.{ .file = b.path("src/platform/macos/text_baseline_test.m"), .flags = flags });
        desktop_mod.linkFramework("AppKit", .{});
        desktop_mod.linkFramework("CoreGraphics", .{});
        desktop_mod.linkFramework("CoreText", .{});
        desktop_mod.linkFramework("Foundation", .{});
        desktop_mod.linkFramework("ImageIO", .{});
        desktop_mod.linkSystemLibrary("objc", .{});
    }
    const desktop_tests = testArtifact(b, desktop_mod);
    const desktop_test_shards = desktopTestShardArtifacts(b, desktop_mod);
    // Tier-5 crash battery: a child uses the public streamed sink, signals
    // after a chunk is durable only in the atomic temporary, then the parent
    // kills it and verifies the destination still names the old generation.
    const file_crash_helper_mod = module(b, target, optimize, "src/runtime/file_effect_crash_helper.zig");
    file_crash_helper_mod.addImport("native_sdk", desktop_mod);
    const file_crash_helper = b.addExecutable(.{ .name = "file-effect-crash-helper", .root_module = file_crash_helper_mod });
    const file_crash_tests_mod = module(b, target, optimize, "src/runtime/file_effect_crash_tests.zig");
    file_crash_tests_mod.addImport("native_sdk", desktop_mod);
    const file_crash_options = b.addOptions();
    file_crash_options.addOptionPath("helper_executable", file_crash_helper.getEmittedBin());
    file_crash_tests_mod.addOptions("file_crash_options", file_crash_options);
    const file_crash_tests = testArtifact(b, file_crash_tests_mod);
    const file_crash_run = b.addRunArtifact(file_crash_tests);
    const file_crash_step = b.step("test-file-effect-crash", "Kill a streamed writer before close and verify atomic destination visibility");
    file_crash_step.dependOn(&file_crash_run.step);
    const tier5_tests = filteredTestArtifact(b, desktop_mod, "storage-tier-5-tests", &.{
        "runtime.effects_file_tests.test",
        "runtime.file_access.test",
        "runtime.session_record.test.recorder moves streamed file chunks",
        "runtime.session_tests.test.a multi-megabyte file stream",
    });
    const tier5_run = b.addRunArtifact(tier5_tests);
    const tier5_step = b.step("test-storage-tier-5", "Run file streaming, bounds, replay/blob, gating, and crash-atomicity batteries");
    tier5_step.dependOn(&tier5_run.step);
    tier5_step.dependOn(&file_crash_run.step);

    // SQLite is capability-shed from ordinary app artifacts. Its focused
    // engine/store suite gets a dedicated module that explicitly compiles the
    // vendored amalgamation, so framework tests cover it without making every
    // unrelated example carry the database object.
    const record_store_mod = module(b, target, optimize, "src/runtime/record_store.zig");
    record_store_mod.addIncludePath(b.path("third_party/sqlite"));
    record_store_mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = sqliteCompileFlags(),
    });
    record_store_mod.link_libc = true;
    const record_store_tests = testArtifact(b, record_store_mod);

    // The embeddable static library's root module carries only the C ABI
    // exports (fixed WebView shell host); user-app canvas libraries are
    // produced by `addMobileLib` from src/embed/app_exports.zig instead.
    const embed_exports_mod = module(b, target, optimize, "src/embed/c_exports.zig");
    embed_exports_mod.addImport("native_sdk", desktop_mod);
    embed_exports_mod.export_symbol_names = &mobile_export_symbol_names;
    const embed_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "native-sdk",
        .root_module = embed_exports_mod,
        // The embed C ABI (`native_sdk_app_viewport`) is exactly the
        // f32-heavy SysV signature Zig 0.16.0's self-hosted x86_64 backend
        // miscompiles (see useLlvmWorkaround in build/app.zig): without
        // this, Debug x86_64 libs (Android emulators, Intel simulators)
        // hand clang hosts corrupted inset/keyboard floats. addMobileLib
        // already forces LLVM there; the fixed-shell lib must match.
        .use_llvm = @import("build/app.zig").useLlvmWorkaround(target),
    });
    b.installArtifact(embed_lib);

    const automation_protocol_mod = module(b, target, optimize, "src/automation/protocol.zig");
    const automation_protocol_tests = testArtifact(b, automation_protocol_mod);
    // The app-icon pipeline as a standalone module: tooling needs only
    // the vector core + PNG codec slice of canvas, not the full canvas
    // module (which links platform frameworks on macOS and would weigh
    // down the cross-compiled CLI).
    const app_icon_mod = module(b, target, optimize, "src/primitives/canvas/app_icon.zig");
    app_icon_mod.addImport("geometry", geometry_mod);
    // The iOS and Android host sources as embedded bytes: the tooling
    // module writes and compiles them for `native dev|package --target
    // ios|android`.
    const ios_host_mod = module(b, target, optimize, "src/platform/ios/files.zig");
    const android_host_mod = module(b, target, optimize, "src/platform/android/files.zig");
    const tooling_mod = module(b, target, optimize, "src/tooling/root.zig");
    const update_feed_mod = module(b, target, optimize, "src/updater/feed.zig");
    tooling_mod.addImport("assets", assets_mod);
    tooling_mod.addImport("app_dirs", app_dirs_mod);
    tooling_mod.addImport("app_manifest", app_manifest_mod);
    tooling_mod.addImport("diagnostics", diagnostics_mod);
    tooling_mod.addImport("debug", debug_mod);
    tooling_mod.addImport("platform_info", platform_info_mod);
    tooling_mod.addImport("trace", trace_mod);
    tooling_mod.addImport("app_icon", app_icon_mod);
    tooling_mod.addImport("ios_host", ios_host_mod);
    tooling_mod.addImport("android_host", android_host_mod);
    tooling_mod.addImport("sqlite_engine", module(b, target, optimize, "src/runtime/sqlite_engine.zig"));
    tooling_mod.addImport("update_feed", update_feed_mod);
    tooling_mod.addIncludePath(b.path("third_party/sqlite"));
    tooling_mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = sqliteCompileFlags(),
    });
    tooling_mod.link_libc = true;
    const tooling_tests = testArtifact(b, tooling_mod);

    // Ejected-component identity proofs: a separate test module because
    // the canonical component sources under src/tooling/components/
    // import `native_sdk` exactly as they will inside an app after
    // `native eject component <name>` copies them there.
    const eject_components_mod = module(b, target, optimize, "src/tooling/components/identity_tests.zig");
    eject_components_mod.addImport("native_sdk", desktop_mod);
    const eject_components_tests = testArtifact(b, eject_components_mod);

    // corewire, the contract-sidecar shim generator (tools/corewire):
    // std-only unit suites, one test root per source file (tests live
    // in the file they cover, and imported files' tests do not run
    // under an importer's root). The conformance suite — every fixture's
    // generated mirror validated over its frontend-emitted contract —
    // rides the ts-core e2e block, since it needs node and the frontend
    // toolchain.
    const corewire_sidecar_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/sidecar.zig"));
    const corewire_emit_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/emit.zig"));
    const corewire_facade_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/emit_facade.zig"));
    const corewire_profile_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/emit_profile.zig"));
    const corewire_service_contract_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/service_contract.zig"));
    const corewire_service_emit_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/emit_service.zig"));
    const corewire_shim_rt_tests = testArtifact(b, module(b, target, optimize, "tools/corewire/shim_rt.zig"));

    // TypeScript-core end-to-end suite: each fixture core is compiled
    // through the external core compiler AT BUILD TIME (never a
    // committed archive) and its e2e battery drives the linked archive
    // through the real runtime via `TsCoreHost` over the generated
    // mirror. Gated on node plus the package's installed dependencies
    // (`npm ci` in packages/core — the compiler and the frontend
    // toolchain arrive together): absent either, the suite is skipped
    // (the bridge itself stays covered by
    // src/runtime/ts_core_host_tests.zig against a hand-written
    // core-ABI module).
    const ts_core_e2e_tests = tsCoreE2eArtifact(b, target, optimize, desktop_mod, tooling_mod);

    const ui_markup_mod = module(b, target, optimize, "src/primitives/canvas/ui_markup.zig");
    const markup_lsp_mod = module(b, target, optimize, "tools/native-sdk/markup_lsp.zig");
    markup_lsp_mod.addImport("ui_markup", ui_markup_mod);
    const markup_lsp_tests = testArtifact(b, markup_lsp_mod);

    const automation_cli_mod = module(b, target, optimize, "tools/native-sdk/automation.zig");
    automation_cli_mod.addImport("automation_protocol", automation_protocol_mod);
    automation_cli_mod.addImport("ui_markup", ui_markup_mod);
    const automation_cli_tests = testArtifact(b, automation_cli_mod);

    const markup_cli_mod = module(b, target, optimize, "tools/native-sdk/markup.zig");
    markup_cli_mod.addImport("ui_markup", ui_markup_mod);
    markup_cli_mod.addImport("markup_lsp", markup_lsp_mod);
    const markup_cli_tests = testArtifact(b, markup_cli_mod);

    const skills_cli_mod = module(b, target, optimize, "tools/native-sdk/skills.zig");
    const skills_cli_tests = testArtifact(b, skills_cli_mod);

    // The evals harness's Cmd wire-format decoder (copied next to every
    // ts-track case harness at grading time). Its own tests run here —
    // NOT at eval time — because a decoder that lags a
    // cmd_format_version bump panics mid-eval inside case harnesses,
    // where the failure reads as the graded app's, not the tooling's.
    const evals_cmdview_mod = module(b, target, optimize, "evals/harness-lib/cmdview.zig");
    const evals_cmdview_tests = testArtifact(b, evals_cmdview_mod);
    const build_graph_tests = testArtifact(b, module(b, host_target, optimize, "build.zig"));
    const invalid_import_compile_mod = module(b, target, optimize, "tests/ts-core/invalid_import_compile.zig");
    invalid_import_compile_mod.addImport("canvas", canvas_mod);
    const invalid_import_compile = b.addObject(.{
        .name = "ts-invalid-import-compile",
        .root_module = invalid_import_compile_mod,
    });
    invalid_import_compile.expect_errors = .{ .contains = "imported files define templates only - this file has a view root element; move the view to its own file and import just the templates" };

    // `native version` names the commit the binary was built from, so
    // binary/framework skew ("your native binary may be stale") is a
    // one-command check. Falls back to "unknown" outside a git checkout.
    const cli_build_info = b.addOptions();
    cli_build_info.addOption([]const u8, "build_commit", cliBuildCommit(b));

    const cli_mod = module(b, target, optimize, "tools/native-sdk/main.zig");
    cli_mod.addImport("tooling", tooling_mod);
    cli_mod.addImport("automation_protocol", automation_protocol_mod);
    cli_mod.addImport("ui_markup", ui_markup_mod);
    cli_mod.addImport("markup_lsp", markup_lsp_mod);
    cli_mod.addOptions("cli_build_info", cli_build_info);
    const cli_exe = b.addExecutable(.{
        .name = "native",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // `zig build cli` builds and installs ONLY the CLI executable. The
    // release pipeline cross-compiles it for every supported platform
    // (packages/native-sdk/scripts/build-binaries.sh), and skipping the
    // framework libraries, examples, and docs artifacts keeps that
    // eight-target loop fast.
    const cli_step = b.step("cli", "Build only the native CLI executable (cross-compile friendly)");
    cli_step.dependOn(&b.addInstallArtifact(cli_exe, .{}).step);

    const host_assets_mod = module(b, host_target, optimize, "src/primitives/assets/root.zig");
    const host_app_dirs_mod = module(b, host_target, optimize, "src/primitives/app_dirs/root.zig");
    const host_app_manifest_mod = module(b, host_target, optimize, "src/primitives/app_manifest/root.zig");
    const host_diagnostics_mod = module(b, host_target, optimize, "src/primitives/diagnostics/root.zig");
    const host_platform_info_mod = module(b, host_target, optimize, "src/primitives/platform_info/root.zig");
    const host_trace_mod = module(b, host_target, optimize, "src/primitives/trace/root.zig");
    const host_debug_mod = module(b, host_target, optimize, "src/debug/root.zig");
    host_debug_mod.addImport("app_dirs", host_app_dirs_mod);
    host_debug_mod.addImport("trace", host_trace_mod);
    const host_automation_protocol_mod = module(b, host_target, optimize, "src/automation/protocol.zig");
    const host_geometry_mod = module(b, host_target, optimize, "src/primitives/geometry/root.zig");
    const host_app_icon_mod = module(b, host_target, optimize, "src/primitives/canvas/app_icon.zig");
    host_app_icon_mod.addImport("geometry", host_geometry_mod);
    const host_ios_host_mod = module(b, host_target, optimize, "src/platform/ios/files.zig");
    const host_android_host_mod = module(b, host_target, optimize, "src/platform/android/files.zig");
    const host_tooling_mod = module(b, host_target, optimize, "src/tooling/root.zig");
    const host_update_feed_mod = module(b, host_target, optimize, "src/updater/feed.zig");
    host_tooling_mod.addImport("assets", host_assets_mod);
    host_tooling_mod.addImport("app_dirs", host_app_dirs_mod);
    host_tooling_mod.addImport("app_manifest", host_app_manifest_mod);
    host_tooling_mod.addImport("diagnostics", host_diagnostics_mod);
    host_tooling_mod.addImport("debug", host_debug_mod);
    host_tooling_mod.addImport("platform_info", host_platform_info_mod);
    host_tooling_mod.addImport("trace", host_trace_mod);
    host_tooling_mod.addImport("app_icon", host_app_icon_mod);
    host_tooling_mod.addImport("ios_host", host_ios_host_mod);
    host_tooling_mod.addImport("android_host", host_android_host_mod);
    host_tooling_mod.addImport("sqlite_engine", module(b, host_target, optimize, "src/runtime/sqlite_engine.zig"));
    host_tooling_mod.addImport("update_feed", host_update_feed_mod);
    host_tooling_mod.addIncludePath(b.path("third_party/sqlite"));
    host_tooling_mod.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = sqliteCompileFlags(),
    });
    host_tooling_mod.link_libc = true;
    const host_ui_markup_mod = module(b, host_target, optimize, "src/primitives/canvas/ui_markup.zig");
    const host_markup_lsp_mod = module(b, host_target, optimize, "tools/native-sdk/markup_lsp.zig");
    host_markup_lsp_mod.addImport("ui_markup", host_ui_markup_mod);
    const host_cli_mod = module(b, host_target, optimize, "tools/native-sdk/main.zig");
    host_cli_mod.addImport("tooling", host_tooling_mod);
    host_cli_mod.addImport("automation_protocol", host_automation_protocol_mod);
    host_cli_mod.addImport("ui_markup", host_ui_markup_mod);
    host_cli_mod.addImport("markup_lsp", host_markup_lsp_mod);
    host_cli_mod.addOptions("cli_build_info", cli_build_info);
    const host_cli_exe = b.addExecutable(.{
        .name = "native",
        .root_module = host_cli_mod,
    });
    // Docs component-preview generator: renders the built-in component
    // catalog offscreen through the deterministic reference renderer and
    // writes theme-aware webp pairs plus the markup vocabulary JSON into
    // docs/. Regenerate with `zig build docs-component-previews`.
    const docs_previews_mod = module(b, target, optimize, "tools/docs_component_previews.zig");
    docs_previews_mod.addImport("native_sdk", desktop_mod);
    // The eject registry as its own lean module (its imports stay inside
    // src/tooling/), so the vocab JSON's `ejectable` table is written from
    // the same rows `native eject component` dispatches on — the docs'
    // <EjectSection> resolves from that JSON and can never drift.
    docs_previews_mod.addImport("eject_components", module(b, target, optimize, "src/tooling/eject_components.zig"));
    const docs_previews_exe = b.addExecutable(.{
        .name = "docs-component-previews",
        .root_module = docs_previews_mod,
    });
    const run_docs_previews = b.addRunArtifact(docs_previews_exe);
    run_docs_previews.addArg(b.pathFromRoot("docs/public/components"));
    run_docs_previews.addArg(b.pathFromRoot("docs/src/lib/component-vocab.json"));
    run_docs_previews.has_side_effects = true;
    const docs_previews_step = b.step("docs-component-previews", "Render built-in component previews and vocab JSON into docs/");
    docs_previews_step.dependOn(&run_docs_previews.step);

    // Render macro-benchmark: deterministic scenarios through the REAL
    // engine pipeline (UiApp + Runtime + null-platform binary packet
    // presents), reporting end-to-end and per-stage p50/p90 per
    // interaction. Baselines should come from
    // `zig build bench-render -Doptimize=ReleaseFast`.
    const bench_render_mod = module(b, target, optimize, "tools/bench_render.zig");
    bench_render_mod.addImport("native_sdk", desktop_mod);
    const bench_render_exe = b.addExecutable(.{
        .name = "bench-render",
        .root_module = bench_render_mod,
    });
    const run_bench_render = b.addRunArtifact(bench_render_exe);
    run_bench_render.has_side_effects = true;
    // Repo root as cwd so the relative budgets path in the docs/gate
    // invocation resolves regardless of where `zig build` ran from.
    run_bench_render.setCwd(b.path("."));
    // Ratchet mode: `zig build bench-render -Doptimize=ReleaseFast --
    // --check tools/bench-render-budgets.txt` compares the median e2e
    // p50 of three suite passes against the committed budgets (the
    // benchmark refuses --check outside ReleaseFast).
    if (b.args) |bench_args| run_bench_render.addArgs(bench_args);
    const bench_render_step = b.step("bench-render", "Run the render macro-benchmark (deterministic scenarios; pass -Doptimize=ReleaseFast for baselines, `-- --check tools/bench-render-budgets.txt` for the budget ratchet)");
    bench_render_step.dependOn(&run_bench_render.step);

    // Live docs previews: the same scene catalog compiled to
    // wasm32-freestanding (tools/docs_wasm_preview.zig) so the docs
    // upgrade the static webp tiles to interactive engine instances.
    // ReleaseSmall + strip keep the module small enough to lazy-load.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    const wasm_geometry_mod = module(b, wasm_target, wasm_optimize, "src/primitives/geometry/root.zig");
    const wasm_json_mod = module(b, wasm_target, wasm_optimize, "src/primitives/json/root.zig");
    const wasm_canvas_mod = module(b, wasm_target, wasm_optimize, "src/primitives/canvas/root.zig");
    wasm_canvas_mod.addImport("geometry", wasm_geometry_mod);
    wasm_canvas_mod.addImport("json", wasm_json_mod);
    const wasm_native_mod = module(b, wasm_target, wasm_optimize, "src/root.zig");
    wasm_native_mod.addImport("geometry", wasm_geometry_mod);
    wasm_native_mod.addImport("json", wasm_json_mod);
    wasm_native_mod.addImport("canvas", wasm_canvas_mod);
    wasm_native_mod.addImport("app_dirs", module(b, wasm_target, wasm_optimize, "src/primitives/app_dirs/root.zig"));
    wasm_native_mod.addImport("assets", module(b, wasm_target, wasm_optimize, "src/primitives/assets/root.zig"));
    wasm_native_mod.addImport("trace", module(b, wasm_target, wasm_optimize, "src/primitives/trace/root.zig"));
    wasm_native_mod.addImport("app_manifest", module(b, wasm_target, wasm_optimize, "src/primitives/app_manifest/root.zig"));
    wasm_native_mod.addImport("diagnostics", module(b, wasm_target, wasm_optimize, "src/primitives/diagnostics/root.zig"));
    wasm_native_mod.addImport("platform_info", module(b, wasm_target, wasm_optimize, "src/primitives/platform_info/root.zig"));
    // The docs preview never runs an emulator: the stub keeps the wasm
    // module free of the ghostty graph (and of pty transports it could
    // not use anyway).
    wasm_native_mod.addImport("terminal_vt", module(b, wasm_target, wasm_optimize, "src/runtime/terminal_vt_stub.zig"));
    const docs_wasm_preview_mod = module(b, wasm_target, wasm_optimize, "tools/docs_wasm_preview.zig");
    docs_wasm_preview_mod.addImport("native_sdk", wasm_native_mod);
    docs_wasm_preview_mod.strip = true;
    const docs_wasm_preview_exe = b.addExecutable(.{
        .name = "component-preview",
        .root_module = docs_wasm_preview_mod,
    });
    docs_wasm_preview_exe.entry = .disabled;
    docs_wasm_preview_exe.rdynamic = true;
    // The engine trades heap for fixed capacity but still builds some
    // sizable stack temporaries (NullPlatform alone is ~800 KB); the
    // 1 MB wasm default overflows into linear memory silently.
    docs_wasm_preview_exe.stack_size = 16 * 1024 * 1024;
    const copy_docs_wasm_preview = b.addUpdateSourceFiles();
    copy_docs_wasm_preview.addCopyFileToSource(docs_wasm_preview_exe.getEmittedBin(), "docs/public/wasm/component-preview.wasm");
    const docs_wasm_preview_step = b.step("docs-wasm-preview", "Compile the live component-preview wasm module into docs/public/wasm/");
    docs_wasm_preview_step.dependOn(&copy_docs_wasm_preview.step);

    const file_contains_checker_mod = module(b, host_target, optimize, "tools/check_file_contains.zig");
    const file_contains_checker = b.addExecutable(.{
        .name = "check-file-contains",
        .root_module = file_contains_checker_mod,
    });

    // Registry pin printer: emits the ui_schema table counts and
    // fingerprints in the exact form ui_schema_tests.zig pins, plus the
    // next free code per table for reserving codes ahead of parallel
    // work, plus this build's layout fingerprints (session journal
    // format, automation protocol). `zig build print-pins` after
    // registry additions. The journal fingerprint lives in the full
    // framework module, and the tool runs on the build HOST by
    // construction (addRunArtifact), so it builds against a host clone
    // of the framework module — cross-compiled `-Dtarget` builds keep a
    // runnable print-pins, and the fingerprints are layout identities
    // (type shapes, never target-sized values), identical either way.
    const pins_json_mod = module(b, host_target, optimize, "src/primitives/json/root.zig");
    const pins_canvas_mod = module(b, host_target, optimize, "src/primitives/canvas/root.zig");
    pins_canvas_mod.addImport("geometry", host_geometry_mod);
    pins_canvas_mod.addImport("json", pins_json_mod);
    if (host_target.result.os.tag == .macos) {
        // Same CoreText linkage the target canvas module carries (see
        // canvas_mod above): the shaping path calls it on macOS hosts.
        pins_canvas_mod.linkFramework("CoreFoundation", .{});
        pins_canvas_mod.linkFramework("CoreGraphics", .{});
        pins_canvas_mod.linkFramework("CoreText", .{});
        pins_canvas_mod.linkSystemLibrary("c", .{});
    }
    const pins_native_mod = module(b, host_target, optimize, "src/root.zig");
    pins_native_mod.addImport("geometry", host_geometry_mod);
    pins_native_mod.addImport("app_dirs", host_app_dirs_mod);
    pins_native_mod.addImport("assets", host_assets_mod);
    pins_native_mod.addImport("trace", host_trace_mod);
    pins_native_mod.addImport("app_manifest", host_app_manifest_mod);
    pins_native_mod.addImport("diagnostics", host_diagnostics_mod);
    pins_native_mod.addImport("platform_info", host_platform_info_mod);
    pins_native_mod.addImport("json", pins_json_mod);
    pins_native_mod.addImport("canvas", pins_canvas_mod);
    // The pin printer reflects registry tables and layout fingerprints —
    // type shapes, never emulator state — so the stub keeps it light.
    pins_native_mod.addImport("terminal_vt", module(b, host_target, optimize, "src/runtime/terminal_vt_stub.zig"));
    const print_pins_mod = module(b, host_target, optimize, "tools/print_pins.zig");
    print_pins_mod.addImport("native_sdk", pins_native_mod);
    const print_pins_exe = b.addExecutable(.{
        .name = "print-pins",
        .root_module = print_pins_mod,
    });
    const run_print_pins = b.addRunArtifact(print_pins_exe);
    run_print_pins.has_side_effects = true;
    const print_pins_step = b.step("print-pins", "Print registry counts and fingerprints in pin-ready form");
    print_pins_step.dependOn(&run_print_pins.step);

    const platform_arg = switch (selected_platform) {
        .auto => unreachable,
        .null => "null",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
    };

    const test_step = b.step("test", "Run package and framework tests");
    test_step.dependOn(&invalid_import_compile.step);
    test_step.dependOn(&b.addRunArtifact(build_graph_tests).step);
    test_step.dependOn(&b.addRunArtifact(geometry_tests).step);
    test_step.dependOn(&b.addRunArtifact(assets_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_dirs_tests).step);
    test_step.dependOn(&b.addRunArtifact(trace_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_manifest_tests).step);
    test_step.dependOn(&b.addRunArtifact(diagnostics_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_info_tests).step);
    test_step.dependOn(&b.addRunArtifact(json_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_runner_assets_tests).step);
    test_step.dependOn(&b.addRunArtifact(app_runner_window_placement_tests).step);
    test_step.dependOn(&app_runner_test_run.step);
    test_step.dependOn(&b.addRunArtifact(canvas_tests).step);
    test_step.dependOn(&b.addRunArtifact(record_store_tests).step);
    test_step.dependOn(&file_crash_run.step);
    for (desktop_test_shards) |shard_tests| {
        test_step.dependOn(&b.addRunArtifact(shard_tests).step);
    }
    test_step.dependOn(&b.addRunArtifact(automation_protocol_tests).step);
    test_step.dependOn(&b.addRunArtifact(tooling_tests).step);
    test_step.dependOn(&b.addRunArtifact(eject_components_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_sidecar_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_emit_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_facade_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_profile_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_service_contract_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_service_emit_tests).step);
    test_step.dependOn(&b.addRunArtifact(corewire_shim_rt_tests).step);
    const ts_services_e2e_step = b.step("test-ts-services-e2e", "Run both TypeScript service carriers end to end: the out-of-process child (crash recovery, timeout, replay) and the in-process pool (parallel keys, FIFO, trap isolation, replay)");
    if (ts_core_e2e_tests) |ts_core_artifacts| {
        const ts_core_e2e_step = b.step("test-ts-core-e2e", "Run the TypeScript-core end-to-end suites over externally compiled fixture cores (requires node and `npm ci` in packages/core)");
        const host_e2e_run = b.addRunArtifact(ts_core_artifacts.host);
        const persist_e2e_run = b.addRunArtifact(ts_core_artifacts.persist);
        const markup_e2e_run = b.addRunArtifact(ts_core_artifacts.markup);
        const kanban_e2e_run = b.addRunArtifact(ts_core_artifacts.kanban);
        const soundboard_e2e_run = b.addRunArtifact(ts_core_artifacts.soundboard);
        const monitor_e2e_run = b.addRunArtifact(ts_core_artifacts.system_monitor);
        const scaffold_ide_e2e_run = b.addRunArtifact(ts_core_artifacts.scaffold_ide);
        // The suite scaffolds and typechecks real trees under .zig-cache;
        // no build inputs/outputs to hash, so always run it.
        scaffold_ide_e2e_run.has_side_effects = true;
        const ai_chat_e2e_run = b.addRunArtifact(ts_core_artifacts.ai_chat);
        const feed_reader_e2e_run = b.addRunArtifact(ts_core_artifacts.feed_reader);
        const services_e2e_run = b.addRunArtifact(ts_core_artifacts.services);
        const markup_components_e2e_step = b.step("test-ts-markup-components-e2e", "Run root component-file compiled, interpreter, automation, and replay coverage");
        markup_components_e2e_step.dependOn(&markup_e2e_run.step);
        markup_components_e2e_step.dependOn(&kanban_e2e_run.step);
        markup_components_e2e_step.dependOn(&invalid_import_compile.step);
        ts_services_e2e_step.dependOn(&feed_reader_e2e_run.step);
        ts_services_e2e_step.dependOn(&services_e2e_run.step);
        // The same fixture through the in-process carrier (ServicePool over
        // the linked service archive): parallel keys, per-key FIFO,
        // cooperative cancellation/deadlines, trap isolation, streaming,
        // and replay without initializing the archive.
        const services_pool_e2e_run: ?*std.Build.Step.Run = if (ts_core_artifacts.services_pool) |pool_tests| pool: {
            const run = b.addRunArtifact(pool_tests);
            ts_services_e2e_step.dependOn(&run.step);
            break :pool run;
        } else null;
        // Service carrier benchmark: cold start, warm round-trip latency
        // for small and large payloads, and queued throughput, through the
        // production carrier bindings of BOTH carriers — the out-of-process
        // child and the in-process pool — against one bytes-echo service
        // (see tools/bench_service_host.zig).
        const bench_service_host_run = b.addRunArtifact(ts_core_artifacts.service_host_bench);
        bench_service_host_run.has_side_effects = true;
        // Repo root as cwd so the generated service executable path and the
        // benchmark's scratch directory resolve regardless of where
        // `zig build` ran from.
        bench_service_host_run.setCwd(b.path("."));
        const bench_service_host_step = b.step("bench-service-host", "Run the service carrier benchmark over both carriers (cold start, round-trip latency, queued throughput; requires node and `npm ci` in packages/core; pass -Doptimize=ReleaseFast for baselines)");
        bench_service_host_step.dependOn(&bench_service_host_run.step);
        const sidecar_conformance_run = b.addRunArtifact(ts_core_artifacts.sidecar_conformance);
        const sidecar_conformance_step = b.step("sidecar-conformance", "Validate corewire-generated mirrors over every fixture's frontend-emitted contract (requires node)");
        sidecar_conformance_step.dependOn(&sidecar_conformance_run.step);
        // ABI-law suites over real compiled cores: the broad markup fixture
        // plus the focused mixed bare-Model/[Model, Cmd] return regression.
        const abi_laws_run = b.addRunArtifact(ts_core_artifacts.external_core_abi_laws);
        const mixed_return_abi_run = b.addRunArtifact(ts_core_artifacts.mixed_return_abi_laws);
        const abi_laws_step = b.step("test-external-core-abi", "Run the compiled-core ABI-law suites, including mixed update returns (requires node and `npm ci` in packages/core)");
        abi_laws_step.dependOn(&abi_laws_run.step);
        abi_laws_step.dependOn(&mixed_return_abi_run.step);
        test_step.dependOn(&abi_laws_run.step);
        test_step.dependOn(&mixed_return_abi_run.step);
        // The cross-execution battery staging: the host-fixture and
        // markup batteries (update/snapshot/effects and the markup view
        // over genuinely compiled cores) plus, where the target admits
        // the in-process archive, the service pool battery, installed
        // under <prefix>/e2e for execution on the target machine. Pair
        // with -Dtarget and -p; scripts/cross-e2e.sh is the driver.
        const cross_e2e_step = b.step("stage-cross-e2e", "Install the TS-core e2e batteries under <prefix>/e2e for execution on the build target (pair with -Dtarget and -p; see scripts/cross-e2e.sh)");
        const e2e_dir: std.Build.Step.InstallArtifact.Options.Dir = .{ .override = .{ .custom = "e2e" } };
        cross_e2e_step.dependOn(&b.addInstallArtifact(ts_core_artifacts.host, .{ .dest_dir = e2e_dir }).step);
        cross_e2e_step.dependOn(&b.addInstallArtifact(ts_core_artifacts.markup, .{ .dest_dir = e2e_dir }).step);
        if (ts_core_artifacts.services_pool) |pool_tests| {
            cross_e2e_step.dependOn(&b.addInstallArtifact(pool_tests, .{ .dest_dir = e2e_dir }).step);
        }
        // The mobile execution battery staging: one static library the
        // platform toolchain (xcrun clang / NDK clang) links around a tiny
        // harness for execution on the simulator or emulator. Registered
        // only for a mobile -Dtarget; scripts/mobile-e2e.sh is the driver.
        if (ts_core_artifacts.mobile_battery) |battery| {
            const mobile_e2e_step = b.step("stage-mobile-e2e", "Install the TS mobile e2e battery archive under <prefix>/e2e (pair with -Dtarget=aarch64-ios-simulator or aarch64-linux-android and -p; see scripts/mobile-e2e.sh)");
            mobile_e2e_step.dependOn(&b.addInstallFileWithDir(battery, .{ .custom = "e2e" }, "libts-mobile-e2e.a").step);
        }
        // The corpus contract artifacts an external core toolchain
        // consumes: per fixture, the frontend-emitted contract sidecar
        // (after projection), the generated entry module, and the
        // compiler profile that builds it, under zig-out/core-contracts.
        const contracts_step = b.step("stage-core-contracts", "Install each ts-core fixture's contract sidecar, generated entry module, and compiler profile under zig-out/core-contracts (requires node)");
        for (ts_core_artifacts.core_contracts) |contract| {
            const dir: std.Build.InstallDir = .{ .custom = b.fmt("core-contracts/{s}", .{contract.name}) };
            contracts_step.dependOn(&b.addInstallFileWithDir(contract.sidecar, dir, "core.contract.json").step);
            contracts_step.dependOn(&b.addInstallFileWithDir(contract.facade, dir, "core_facade.ts").step);
            contracts_step.dependOn(&b.addInstallFileWithDir(contract.profile, dir, "core_profile.json").step);
        }
        ts_core_e2e_step.dependOn(&host_e2e_run.step);
        ts_core_e2e_step.dependOn(&persist_e2e_run.step);
        ts_core_e2e_step.dependOn(&markup_e2e_run.step);
        ts_core_e2e_step.dependOn(&kanban_e2e_run.step);
        ts_core_e2e_step.dependOn(&soundboard_e2e_run.step);
        ts_core_e2e_step.dependOn(&monitor_e2e_run.step);
        ts_core_e2e_step.dependOn(&scaffold_ide_e2e_run.step);
        ts_core_e2e_step.dependOn(&ai_chat_e2e_run.step);
        ts_core_e2e_step.dependOn(&feed_reader_e2e_run.step);
        ts_core_e2e_step.dependOn(&services_e2e_run.step);
        if (services_pool_e2e_run) |run| ts_core_e2e_step.dependOn(&run.step);
        test_step.dependOn(&host_e2e_run.step);
        test_step.dependOn(&persist_e2e_run.step);
        test_step.dependOn(&markup_e2e_run.step);
        test_step.dependOn(&kanban_e2e_run.step);
        test_step.dependOn(&soundboard_e2e_run.step);
        test_step.dependOn(&monitor_e2e_run.step);
        test_step.dependOn(&scaffold_ide_e2e_run.step);
        test_step.dependOn(&ai_chat_e2e_run.step);
        test_step.dependOn(&feed_reader_e2e_run.step);
        test_step.dependOn(&services_e2e_run.step);
        if (services_pool_e2e_run) |run| test_step.dependOn(&run.step);
        test_step.dependOn(&sidecar_conformance_run.step);
    }
    test_step.dependOn(&b.addRunArtifact(markup_lsp_tests).step);
    test_step.dependOn(&b.addRunArtifact(automation_cli_tests).step);
    test_step.dependOn(&b.addRunArtifact(markup_cli_tests).step);
    test_step.dependOn(&b.addRunArtifact(skills_cli_tests).step);
    test_step.dependOn(&b.addRunArtifact(evals_cmdview_tests).step);
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-package-types", "Verify package TypeScript platform feature names", &.{
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkCommandInfo" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "list(): Promise<NativeSdkCommandInfo[]>" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkCreateWebViewViewOptions" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "Stable runtime view id" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "update(label: string" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "focus(options: string | NativeSdkViewSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "close(options: string | NativeSdkViewSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "kind: \"webview\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "url: string" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "NativeSdkPlatformFeatureSelector" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "supports(value: NativeSdkPlatformFeature | NativeSdkPlatformFeatureSelector)" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"native_control_commands\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"nativeControlCommands\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"recent_documents\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"recentDocuments\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"file_drops\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"fileDrops\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"app_activation_events\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"appActivationEvents\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"gpu_surfaces\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "\"gpuSurfaces\"" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "gpuFirstFrameLatencyNs: number" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "gpuBackend: NativeSdkGpuSurfaceBackend;" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "export type NativeSdkGpuSurfaceBackendRequest = \"metal\" | \"software\";" },
        .{ .path = "packages/native-sdk/native-sdk.d.ts", .pattern = "gpuBackend?: NativeSdkGpuSurfaceBackendRequest;" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-ts-toolchain-twins", "Verify the CLI's toolchain-resolution gate and its direct-`zig build` twin stay in lockstep (both resolve the aliased real compiler @typescript/old from packages/core — the same origin runtime imports it from — hold its resolved version against the manifest-read pin, never probe a stray compat wrapper, and teach instead of panicking)", &.{
        // The resolution twins probe the aliased REAL compiler
        // (@typescript/old — the package typed_ast.ts and ts_run.mjs
        // actually load) — manifest AND entrypoint, in lockstep. The
        // @typescript/typescript6 wrapper is never probed: nothing
        // imports it at run time, and validating it false-rejects
        // healthy conflict trees.
        .{ .path = "src/tooling/ts_core.zig", .pattern = "\"node_modules\", \"@typescript\", \"old\", \"package.json\"" },
        .{ .path = "src/tooling/ts_core.zig", .pattern = "\"node_modules\", \"@typescript\", \"old\", \"lib\", \"typescript.js\"" },
        .{ .path = "build/app.zig", .pattern = "\"node_modules\", \"@typescript\", \"old\", \"package.json\"" },
        .{ .path = "build/app.zig", .pattern = "\"node_modules\", \"@typescript\", \"old\", \"lib\", \"typescript.js\"" },
        // The doctrine both twins document at their predicates: validate
        // only what runtime loads, from runtime's own walk origin, and
        // leave the declared-but-unimported wrapper out of the verdict.
        .{ .path = "src/tooling/ts_core.zig", .pattern = "Validation tracks ONLY what runtime loads" },
        .{ .path = "src/tooling/ts_core.zig", .pattern = "deliberately NOT probed" },
        .{ .path = "build/app.zig", .pattern = "Validation tracks ONLY what runtime loads" },
        .{ .path = "build/app.zig", .pattern = "deliberately NOT probed" },
        // The reciprocal cross-references that keep the twins findable
        // from each other.
        .{ .path = "src/tooling/ts_core.zig", .pattern = "build/app.zig's tsToolchainResolution" },
        .{ .path = "build/app.zig", .pattern = "transpilerResolution, this predicate's deliberate twin" },
        // The version pin: both twins read the alias's RESOLVED
        // package.json version and hold it against the exact
        // `npm:typescript@X.Y.Z` pin read from the SDK's own
        // packages/core/package.json (never hardcoded), and both carry
        // the mismatch outcome plus its teaching naming the two versions.
        .{ .path = "src/tooling/ts_core.zig", .pattern = "parseAliasedCompilerPin" },
        .{ .path = "src/tooling/ts_core.zig", .pattern = "version_mismatch" },
        .{ .path = "src/tooling/ts_core.zig", .pattern = "npm:typescript@{s}" },
        .{ .path = "build/app.zig", .pattern = "tsPinnedCompilerVersion" },
        .{ .path = "build/app.zig", .pattern = "version_mismatch" },
        .{ .path = "build/app.zig", .pattern = "npm:typescript@{s}" },
        // The teachings: the checkout's one production-config-safe npm ci
        // command in both surfaces, the reinstall for npm layouts, and the
        // build graph's clean configure-time failure (never a panic).
        .{ .path = "src/tooling/ts_core.zig", .pattern = "pub const npm_ci_teaching_command = \"npm ci --include=dev\";" },
        .{ .path = "src/tooling/ts_core.zig", .pattern = "reinstall @native-sdk/cli" },
        .{ .path = "build/app.zig", .pattern = "npm ci --include=dev" },
        .{ .path = "build/app.zig", .pattern = "cannot resolve its TypeScript toolchain" },
        .{ .path = "build/app.zig", .pattern = "std.process.exit(1);" },
        // SQLite schema generation shares node/toolchain resolution but
        // never the TS-core-only src/app.native shape assertion: Zig cores
        // may own their view in code while still embedding migrations.
        .{ .path = "build/app.zig", .pattern = "return tsToolingPreflight(b, dep, .app_core);" },
        .{ .path = "build/app.zig", .pattern = "const node = tsToolingPreflight(b, dep, .sqlite_schema);" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-scriptc-pin-cache-inputs", "Verify both TypeScript service build graphs invalidate frontend contracts when the exact scriptc pin changes", &.{
        .{ .path = "build.zig", .pattern = "if (spec.emit_services) check.addFileInput(b.path(\"packages/core/package.json\"));" },
        .{ .path = "build/app.zig", .pattern = "if (has_services) check.addFileInput(dep.path(\"packages/core/package.json\"));" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-ts-build-invalidation-boundaries", "Verify generated TypeScript contracts stabilize by content and service implementation inputs cannot dirty the core compiler lane", &.{
        .{ .path = "build/app.zig", .pattern = "pub fn stabilizeGeneratedFile" },
        .{ .path = "build/app.zig", .pattern = "const contract = stabilizeGeneratedFile(b, contract_raw, \"core.contract.json\", build_trace);" },
        .{ .path = "build/app.zig", .pattern = "break :services_contract stabilizeGeneratedFile(b, raw, \"services.contract.json\", build_trace);" },
        .{ .path = "build/app.zig", .pattern = "addAppCoreTsDirInputs(b, stage_run, appPath(b, app_root, \"src\"));" },
        .{ .path = "build/app.zig", .pattern = "addStagedCoreSdkInputs(b, dep.builder, stage_run);" },
        .{ .path = "build/app.zig", .pattern = "for ([_][]const u8{ \"text.ts\", \"events.ts\" }) |source|" },
        .{ .path = "build.zig", .pattern = "app_build.addStagedCoreSdkInputs(b, b, stage_run);" },
        .{ .path = "packages/core/scripts/stage_external_core.mjs", .pattern = "for (const sdkFile of [\"text.ts\", \"events.ts\"])" },
        .{ .path = "build/app.zig", .pattern = "if (std.mem.startsWith(u8, normalized, \"services/\")) continue;" },
        .{ .path = "tools/corewire/emit_service.zig", .pattern = "native-sdk.services.abi.v3" },
        .{ .path = "tools/corewire/emit_service.zig", .pattern = "implementation-only fingerprint" },
        .{ .path = "build/app.zig", .pattern = "link_mod.addObject(markupDataObject(b, target, app_optimize, stage.markup_c));" },
        .{ .path = "build/app.zig", .pattern = "addPlatformLinkSearchPaths(b, selected_platform, web_engine, cef_dir, link_mod);" },
        .{ .path = "build/app.zig", .pattern = "mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, \"System/Library/Frameworks\" }) });" },
        .{ .path = "build/app.zig", .pattern = "b.fmt(\"{s}-app-code\", .{app_options.name})" },
        .{ .path = "src/app_runner/ts_core_main.zig", .pattern = "extern const native_sdk_app_markup: u8;" },
        .{ .path = "packages/core/scripts/embed_markup_c.mjs", .pattern = "const unsigned char native_sdk_app_markup[]" },
        .{ .path = "build/app.zig", .pattern = "node_modules\", \"scriptc\", \"dist\", \"bootstrap.js\"" },
        .{ .path = "build/app.zig", .pattern = "setEnvironmentVariable(\"SCRIPTC_TIMING\", \"1\")" },
        .{ .path = "build/app.zig", .pattern = "service_compile.addArg(\"--compiler-package-origin\")" },
        .{ .path = "build/app.zig", .pattern = "compile.addArg(\"--compiler-package-origin\")" },
        .{ .path = "packages/core/scripts/run_external_core_compiler.mjs", .pattern = "publishedScriptcArgv(args[\"compiler-package-origin\"])" },
        .{ .path = "packages/core/scripts/run_external_service_compiler.mjs", .pattern = "publishedScriptcArgv(args[\"compiler-package-origin\"])" },
        .{ .path = "build/app.zig", .pattern = "addFileInput(dep.path(\"packages/core/scripts/compiler_command.mjs\"))" },
        .{ .path = "packages/core/scripts/run_external_core_compiler.mjs", .pattern = "compilerArgv(args.compiler)" },
        .{ .path = "packages/core/scripts/run_external_service_compiler.mjs", .pattern = "compilerArgv(args.compiler)" },
        .{ .path = "packages/core/scripts/compiler_command.mjs", .pattern = "npmTarget !== null" },
        .{ .path = "build.zig", .pattern = "fn repositoryScriptcBin" },
        .{ .path = "build.zig", .pattern = "packages/core/node_modules/.bin/scriptc.cmd" },
        .{ .path = "build.zig", .pattern = "compile.addArgs(&.{ \"--compiler\", repositoryScriptcBin(b) });" },
        .{ .path = "src/tooling/verbs.zig", .pattern = "Zig's full summary reports each named build step's duration" },
        .{ .path = "src/tooling/verbs.zig", .pattern = "fn rebuildPathIgnored" },
        .{ .path = "src/tooling/verbs.zig", .pattern = "var walker = try root.walkSelectively(allocator);" },
        .{ .path = "src/tooling/verbs.zig", .pattern = "if (!rebuildPathIgnored(path)) try walker.enter(io, entry);" },
        .{ .path = "tools/native-sdk/main.zig", .pattern = "--explain-rebuild" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-scriptc-cross-target-plumbing", "Verify core and service archives share the target-aware ScriptC lane, and every direct Windows archive consumer links its runtime import libraries", &.{
        .{ .path = "build/app.zig", .pattern = ".linux => !cross or target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64" },
        .{ .path = "build/app.zig", .pattern = ".windows => !cross or target.result.abi == .gnu" },
        .{ .path = "build/app.zig", .pattern = ".windows => target.result.cpu.arch == .x86_64" },
        .{ .path = "build/app.zig", .pattern = "if (linuxGlibcSpellingHitsDefaultFloor(target)) {" },
        .{ .path = "build.zig", .pattern = "if (!app_build.linuxGlibcSpellingHitsDefaultFloor(target)) return;" },
        .{ .path = "build/app.zig", .pattern = "scriptcPlatformTriple(b, target),\n        // Keep the core and service archives on the same cross compiler" },
        .{ .path = "build.zig", .pattern = "app_build.scriptcPlatformTriple(b, target),\n        \"--zig-exe\",\n        b.graph.zig_exe," },
        .{ .path = "build.zig", .pattern = "compile.addArgs(&.{ \"--host-platform\", host_platform, \"--target-platform\", app_build.scriptcPlatformTriple(b, target), \"--zig-exe\", b.graph.zig_exe });\n    app_build.addScriptcAndroidNdk(b, compile, target);\n    addScriptcGlibcFloorTeaching(b, target, &compile.step);" },
        .{ .path = "build.zig", .pattern = "app_build.scriptcPlatformTriple(b, target),\n        \"--zig-exe\",\n        b.graph.zig_exe,\n    });\n    app_build.addScriptcAndroidNdk(b, compile, target);\n    addScriptcGlibcFloorTeaching(b, target, &compile.step);" },
        .{ .path = "build.zig", .pattern = "abi_laws_mod.addObjectFile(markup_fixture.archive);\n    addScriptcArchiveSystemLibs(abi_laws_mod, target);" },
        // Both drivers map the build graph's Zig triple onto the compiler's
        // own mobile spellings and thread the NDK like --zig-exe.
        .{ .path = "packages/core/scripts/run_external_core_compiler.mjs", .pattern = "SCRIPTC_TARGET: scriptcTarget" },
        .{ .path = "packages/core/scripts/run_external_service_compiler.mjs", .pattern = "SCRIPTC_TARGET: scriptcTarget" },
        .{ .path = "packages/core/scripts/run_external_core_compiler.mjs", .pattern = "ANDROID_NDK_ROOT: args[\"android-ndk\"]" },
        .{ .path = "packages/core/scripts/run_external_service_compiler.mjs", .pattern = "ANDROID_NDK_ROOT: args[\"android-ndk\"]" },
        .{ .path = "build/app.zig", .pattern = ".ios => host.os.tag == .macos and target.result.cpu.arch == .aarch64" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-app-test-entry-analysis", "Verify the managed app test step force-analyzes the entry point (UiApp.create's Model-defaults rule must teach at `native test`, not ambush at `native build`)", &.{
        .{ .path = "build/app.zig", .pattern = "app_analysis.zig" },
        .{ .path = "build/app.zig", .pattern = "if (@hasDecl(app, \"main\")) _ = &app.main;" },
        .{ .path = "build/app.zig", .pattern = "test_step.dependOn(&analysis_obj.step);" },
        .{ .path = "src/runtime/ui_app.zig", .pattern = "has no default value - give every Model field a default" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-owned-runner-window-placement", "Verify owned example runners preserve explicit origins and distinguish successful state restoration", &.{
        .{ .path = "examples/hello/src/runner.zig", .pattern = ".initial_placement = if (@hasField(@TypeOf(window), \"x\") or @hasField(@TypeOf(window), \"y\")) .explicit else .default" },
        .{ .path = "examples/hello/src/runner.zig", .pattern = "window.initial_placement = .restored;" },
        .{ .path = "examples/hello/src/runner.zig", .pattern = "app_info.main_window.initial_placement = .restored;" },
        .{ .path = "examples/capabilities/src/runner.zig", .pattern = "info.main_window.default_frame = manifestShellStartupFrame(info.main_window.default_frame);" },
        .{ .path = "examples/capabilities/src/runner.zig", .pattern = "info.main_window.restore_state = manifestShellStartupRestoreState(info.main_window.restore_state);" },
        .{ .path = "examples/capabilities/src/runner.zig", .pattern = "info.main_window.restore_policy = manifestShellStartupRestorePolicy(info.main_window.restore_policy);" },
        .{ .path = "examples/capabilities/src/runner.zig", .pattern = "info.main_window.initial_placement = manifestShellStartupInitialPlacement(info.main_window.initial_placement);" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-macos-window-placement-contracts", "Verify both macOS hosts use the primary display and restore persisted content frames without titlebar growth", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return [NSScreen screens].firstObject ?: [NSScreen mainScreen];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "return [NSScreen screens].firstObject ?: [NSScreen mainScreen];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[window frameRectForContentRect:restoredContentFrame]" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[window frameRectForContentRect:restoredContentFrame]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[window setFrame:restoredWindowFrame display:NO];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[window setFrame:restoredWindowFrame display:NO];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[window setFrame:NativeSdkCenterFrameOnScreen(window.frame, primaryScreen) display:NO];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[window setFrame:NativeSdkCenterFrameOnScreen(window.frame, primaryScreen) display:NO];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "else if (initialPlacement == 1) {\n        // Fresh authored dimensions are content size" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "else if (initialPlacement == 1) {\n        // AppKit adds titlebar chrome" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[window setFrame:NativeSdkConstrainFrame(window.frame) display:NO];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[window setFrame:NativeSdkConstrainFrame(window.frame) display:NO];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "initWithFrame:window.contentView.bounds" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "initWithFrame:window.contentView.bounds" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-bridge-view-selector-helpers", "Verify injected view helpers accept string selectors", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "viewSelectorPayload(options)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "focus:function(options){return invoke('native-sdk.view.focus',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "close:function(options){return invoke('native-sdk.view.close',viewSelectorPayload(options))" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-command-contracts", "Verify command docs match native view update contracts", &.{
        .{ .path = "docs/src/app/docs/commands/page.mdx", .pattern = ".text = \"Refreshed\"" },
        .{ .path = "docs/src/app/docs/commands/page.mdx", .pattern = "const commands = await window.zero.commands.list();" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-native-view-contracts", "Verify native surface docs describe view identity", &.{
        .{ .path = "docs/src/app/docs/native-surfaces/page.mdx", .pattern = "ViewInfo.id" },
        .{ .path = "docs/src/app/docs/native-surfaces/page.mdx", .pattern = "window.zero.views.update(\"status\"" },
        .{ .path = "docs/src/app/docs/native-surfaces/page.mdx", .pattern = "first-frame latency budget" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-shell-manifest-contracts", "Verify app.zon docs describe shell compatibility window labels", &.{
        .{ .path = "docs/src/app/docs/app-zon/page.mdx", .pattern = "labels must stay unique across both lists" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-media-producer-contracts", "Verify the media producer docs' typed callback stays mirrored by the compile-shaped pin in media_surface_tests.zig", &.{
        .{ .path = "docs/src/app/docs/media-producers/page.mdx", .pattern = "producer: media.MediaSurfaceProducer" },
        .{ .path = "src/runtime/media_surface_tests.zig", .pattern = "producer: media.MediaSurfaceProducer" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-session-replay-image-codec", "Verify the replay runner installs the host image codec headlessly (the desktop arms cannot link in unit tests; the null-fallback arm is covered in session_tests.zig)", &.{
        .{ .path = "src/app_runner/root.zig", .pattern = "native_sdk.platform.installHeadlessImageCodec(build_options.platform, null_platform, &replay_platform.services);" },
        .{ .path = "src/platform/macos/root.zig", .pattern = "pub fn installHeadlessImageCodec(services: *platform_mod.PlatformServices) void {\n    services.decode_image_fn = decodeImage;\n}" },
        .{ .path = "src/platform/linux/root.zig", .pattern = "pub fn installHeadlessImageCodec(services: *platform_mod.PlatformServices) void {\n    services.decode_image_fn = decodeImage;\n}" },
        .{ .path = "src/platform/windows/root.zig", .pattern = "pub fn installHeadlessImageCodec(services: *platform_mod.PlatformServices) void {\n    services.decode_image_fn = decodeImage;\n}" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-js-view-helper-contracts", "Verify injected view helpers support label-first updates", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "update:function(options,patch)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "update:function(options,patch)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-linux-gpu-frame-emission-below-paint", "Verify the Linux GPU frame emission is scheduled below layout and paint priorities", &.{
        // A saturated demand-driven frame loop (cycle cost > frame
        // interval => every present re-arms at delay 0) scheduled at
        // G_PRIORITY_DEFAULT would be ready on every main-loop
        // iteration and starve GTK's layout/paint sources: presents
        // land and queue_draw keeps inviting a repaint, but the glass
        // freezes on stale pixels for as long as the loop stays armed.
        // The emission must stay below GDK_PRIORITY_REDRAW so every
        // presented frame paints before the next frame event.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "view->gpu_emit_source = g_timeout_add_full(G_PRIORITY_DEFAULT_IDLE," },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "paint (GDK_PRIORITY_REDRAW," },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "static void native_sdk_gpu_surface_schedule_frame_emission" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-linux-audio-buffering-clears-on-noop-resume", "Verify the Linux audio buffering flag drops when the 100% resume completes synchronously", &.{
        // The buffering flag normally drops at the PLAYING
        // state-changed message. When the refill's earlier PAUSED
        // request never completed, the 100% resume is a no-op that
        // posts no message; a non-ASYNC set_state result is the only
        // signal, and the flag must drop on it or it rides every
        // position tick for the rest of the track.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "const int change = gst->element_set_state(audio->playbin, NATIVE_SDK_GST_STATE_PLAYING);" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "change != NATIVE_SDK_GST_STATE_CHANGE_ASYNC" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "#define NATIVE_SDK_GST_STATE_CHANGE_ASYNC 2" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-linux-init-close-policy-refusal", "Verify the Linux platform init refuses a .hide main window with the one shared teaching (the pre-created startup window never passes the runtime's create gate, so a silent drop here meant quit-on-close for direct-SDK users)", &.{
        // The gate itself is unit-tested cross-host (it is extern-free);
        // this pins its WIRING into initWithOptions, which only a Linux
        // link can execute.
        .{ .path = "src/platform/linux/root.zig", .pattern = "try refuseUnsupportedMainWindowClosePolicy(window_options);" },
        // One message, all seams: the platform-init refusal and the
        // generated runner's comptime refusal teach with the same text.
        .{ .path = "src/platform/linux/root.zig", .pattern = "close_policy \\\"hide\\\" is not supported on linux: the GTK host has no status item (tray), so nothing could bring the hidden window back - declare \\\"quit\\\" (the default), or scope the .hide declaration to macos/windows builds" },
        .{ .path = "src/app_runner/root.zig", .pattern = "close_policy \\\"hide\\\" is not supported on linux: the GTK host has no status item (tray), so nothing could bring the hidden window back - declare \\\"quit\\\" (the default), or scope the .hide declaration to macos/windows builds" },
        .{ .path = "src/tooling/templates.zig", .pattern = "close_policy \\\\\\\"hide\\\\\\\" is not supported on linux" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-macos-close-clears-policy-hidden", "Verify every macOS close exit leaves the policy-hidden set before its open=false emit (both hosts derive the frame event's hidden flag from set membership, and the Dock reopen re-shows every member — a close exit that skips the cleanup emits {open=false, hidden=true} and lets the reopen resurrect an app-closed window)", &.{
        // AppKit: every close routes through NSWindow close/performClose,
        // so the delegate's windowWillClose is the one cleanup site.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self.host.policyHiddenWindows removeObject:@(self.windowId)];\n    [self.host emitWindowFrameForWindowId:self.windowId open:NO];" },
        // CEF: the delegate cleanup covers the [window close] fallback,
        // and the app-driven close of a browser-bearing window exits
        // through orderOut WITHOUT reaching windowWillClose — that
        // branch must do the set cleanup itself, before its emit.
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[self.host.policyHiddenWindows removeObject:@(self.windowId)];\n    [self.host emitWindowFrameForWindowId:self.windowId open:NO];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[self.policyHiddenWindows removeObject:@(windowId)];\n                [window orderOut:nil];\n                [self emitWindowFrameForWindowId:windowId open:NO];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-macos-cef-window-verbs-synchronous", "Verify the CEF host's show and minimize verbs run synchronously on the main thread, the close verb's discipline (a dispatch_async show returns success while the window is still in policyHiddenWindows — the runtime's post-success focus flip then emits {focused:true, hidden:true} until the queued block lands — and a show-then-close in one dispatch re-orders: the queued show lands AFTER the synchronous close and puts a retained ordered-out closed window back on the glass)", &.{
        // The show verb: direct on main, dispatch_sync hop otherwise,
        // with the window lookup INSIDE the block so a window closed
        // before an off-main hop lands is a no-op, not a resurrection.
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if ([NSThread isMainThread]) {\n        showBlock();\n    } else {\n        dispatch_sync(dispatch_get_main_queue(), showBlock);\n    }" },
        // The minimize twin (a queued miniaturize captured past a
        // synchronous close genies an app-closed window into the Dock).
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if ([NSThread isMainThread]) {\n        miniaturizeBlock();\n    } else {\n        dispatch_sync(dispatch_get_main_queue(), miniaturizeBlock);\n    }" },
        // The C shims return success only after the synchronous verb —
        // no dispatch_async between the lookup and the method call.
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if (!object.windows[@(window_id)]) return 0;\n    [object miniaturizeWindowWithId:window_id];\n    return 1;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[object showWindowWithId:window_id];\n    return 1;" },
        // The AppKit host's twins are already synchronous direct calls
        // (its runtime callbacks arrive on the main thread); these pins
        // hold that symmetry.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[object showWindowWithId:window_id];\n    return 1;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[object miniaturizeWindowWithId:window_id];\n    return 1;" },
    });
    // The embedded-WebView layer must stay real AND declare-to-use: the
    // standard build graph puts the vendored WebView2 SDK header on the
    // include path exactly when app.zon declares web use (`if
    // (web_layer)`), and only the native-only branch passes the stub
    // define. In the guard the stub define is tested FIRST, before
    // header visibility: on a machine where the WebView2 SDK headers are
    // reachable through the system include paths, an
    // include-path-decides guard would compile the full layer into a
    // native-only build and reintroduce the WebView2Loader.dll reference
    // its executable must not carry. Without the define the header is
    // required — a web build that cannot see it fails at compile time
    // instead of quietly shipping the stubbed host (whose WebView loads
    // report WebViewNotFound at runtime).
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-webview2-vendor", "Verify the vendored WebView2 SDK stays wired into every web-declaring Windows build graph", &.{
        .{ .path = "third_party/webview2/include/WebView2.h", .pattern = "CreateCoreWebView2EnvironmentWithOptions" },
        .{ .path = "third_party/webview2/include/EventToken.h", .pattern = "EventRegistrationToken" },
        .{ .path = "third_party/webview2/LICENSE.txt", .pattern = "Redistribution and use in source and binary forms" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "#if defined(NATIVE_SDK_ALLOW_WEBVIEW2_STUB)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "#elif __has_include(<WebView2.h>) && __has_include(<wrl.h>)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "#error \"WebView2.h not found" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "LoadLibraryW(L\"WebView2Loader.dll\")" },
        .{ .path = "build/app.zig", .pattern = ".system => if (web_layer) {" },
        .{ .path = "build/app.zig", .pattern = "app_mod.addIncludePath(dep.path(\"third_party/webview2/include\"));" },
        .{ .path = "build/app.zig", .pattern = "third_party/webview2/x64/WebView2Loader.dll" },
        .{ .path = "build/app.zig", .pattern = "\"-DNATIVE_SDK_ALLOW_WEBVIEW2_STUB\"" },
        .{ .path = "src/tooling/templates.zig", .pattern = "third_party/webview2/include" },
        .{ .path = "src/tooling/templates.zig", .pattern = "third_party/webview2/x64/WebView2Loader.dll" },
    });
    // The Linux mirror of the Windows seam: the stub define wins over
    // header visibility (a native-only build never reintroduces the
    // libwebkitgtk link even where the dev package is installed), the
    // header is required for web builds, and both build graphs compile
    // gtk_host.c with the stub and drop the webkitgtk-6.0 link when the
    // web layer is excluded.
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-linux-webkitgtk-seam", "Verify the WebKitGTK compile seam stays wired through the GTK host and both Linux build graphs", &.{
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "#if defined(NATIVE_SDK_ALLOW_WEBKITGTK_STUB)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "#elif __has_include(<webkit/webkit.h>)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "#error \"webkit/webkit.h not found" },
        .{ .path = "build/app.zig", .pattern = "\"-DNATIVE_SDK_ALLOW_WEBKITGTK_STUB\"" },
        .{ .path = "src/tooling/templates.zig", .pattern = "\"-DNATIVE_SDK_ALLOW_WEBKITGTK_STUB\"" },
    });
    addLayoutCheckStep(b, test_step, "test-windows-webview2-loader-layout", "Verify the vendored WebView2 loader binaries are present", &.{
        "third_party/webview2/x64/WebView2Loader.dll",
        "third_party/webview2/arm64/WebView2Loader.dll",
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-packaged-assets-webview2", "Verify Windows packaged assets are served through WebView2 request interception", &.{
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "constexpr const char *kAssetVirtualOrigin = \"https://native-sdk-app.localhost\";" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "return virtualAssetEntryUrl(webview.asset_entry);" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "AddWebResourceRequestedFilter(L\"https://native-sdk-app.localhost/*\"" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "assetWebResourceResponse(environment_ref.Get(), found->second, uri)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "bridgeOriginForWebViewUrl(source_webview->second, source_url)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "webview.spa_fallback = spa_fallback != 0;" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-macos-cef-packaged-assets-webviews", "Verify macOS CEF child WebViews resolve packaged asset URLs before loading", &.{
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "self.assetRoots = [[NSMutableDictionary alloc] init];" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "resolvedWebViewURLString:(NSString *)url windowId:(uint64_t)windowId" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "CefBrowserHost::CreateBrowser(windowInfo, client.get(), std::string(resolvedURL.UTF8String)" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "self.webviewPendingURLs[[self webViewKeyForWindow:windowId label:label]] = resolvedURL;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "bridgeOriginForWindowId:window_id_ webViewLabel:labelString sourceURL:sourceURLString" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-native-accessibility-roles", "Verify AppKit native views publish accessibility roles", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkAccessibilityRoleForNativeViewKind" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSAccessibilityToolbarRole" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSAccessibilityProgressIndicatorRole" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "view.accessibilityRole = NativeSdkAccessibilityRoleForNativeViewKind(kind)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-audio-capture-start-stop-serialized", "Verify asynchronous ScreenCaptureKit startup cannot publish a stream after stop returns", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@property(nonatomic, strong) NSLock *lifecycleLock;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[strongSelf.lifecycleLock lock];\n            if (![strongSelf.target isCaptureActive]) {\n                [strongSelf.lifecycleLock unlock];\n                return;\n            }\n            strongSelf.stream = stream;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self.lifecycleLock lock];\n        SCStream *stream = self.stream;\n        self.stream = nil;\n        [self.lifecycleLock unlock];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-input-repaints-retained-canvas", "Verify GPU input wakes retained canvas frames", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)requestRetainedCanvasFrame" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self requestRetainedCanvasFrame];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-pinch-terminal-delta", "Verify the macOS pinch stream forwards a terminal Ended/Cancelled magnification as a change before the end marker", &.{
        // AppKit documents every magnifyWithEvent: as carrying the
        // magnification since the previous event — the terminal one
        // included. The Ended/Cancelled branch must forward a nonzero
        // terminal magnification as PINCH_CHANGE before PINCH_END (zero
        // magnification: end only), or the cumulative product of
        // (1 + delta) diverges from what the OS delivered. Cancelled
        // deliberately shares the path: pinch applies deltas
        // incrementally with no rollback.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (phase & (NSEventPhaseEnded | NSEventPhaseCancelled)) {" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self emitPinchChangeForEvent:event];\n        [self emitPinchInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_PINCH_END event:event magnification:0];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "PINCH_END event:event magnification:0];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-pinch-magnification-doctrine", "Verify the macOS host forwards raw NSEvent.magnification as the multiplicative pinch delta (the engine convention), with the per-event floor", &.{
        // The reading of NSEvent.magnification is SETTLED and this step
        // exists to keep it settled: Apple's API-reference prose says
        // "add", Apple's own Event Handling Guide example multiplies,
        // and every browser engine (WebKit, Chromium) treats raw
        // magnification as the multiplicative per-event delta. The
        // doctrine comment at magnifyWithEvent: carries the receipts;
        // these pins hold both the comment and the code to it. Any
        // sum-based "additive normalization" of magnification must
        // change emitPinchChangeForEvent:'s pinned body — and thereby
        // fail this step, on purpose. Re-read the doctrine comment
        // before touching either.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "m_magnification += m_magnification * scaleWithResistance;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "pinch_update.scale = event.magnification + 1.0;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "Ruling: raw event.magnification IS the multiplicative per-event" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "Do NOT reintroduce a running-sum" },
        // The raw forwarding, pinned as one body: the only transform
        // between the OS and the wire is the per-event floor (a single
        // magnification at or below -1 would emit a factor <= 0 — a
        // zoom inverted through zero scale, physically impossible).
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static const double NativeSdkPinchMagnificationFloor = -1.0 + 0x1p-10;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return magnification < NativeSdkPinchMagnificationFloor ? NativeSdkPinchMagnificationFloor : magnification;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)emitPinchChangeForEvent:(NSEvent *)event {\n    const double magnification = NativeSdkClampedPinchMagnification(event.magnification);\n    if (magnification == 0) return;\n    [self emitPinchInputEventWithKind:NATIVE_SDK_APPKIT_GPU_INPUT_PINCH_CHANGE event:event magnification:magnification];\n}" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-input-paces-retained-canvas", "Verify GPU input frame requests are paced to the display interval", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkRetainedFrameIntervalNanoseconds" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "retainedFrameLastEmitNs" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "queuePointerMotionInputEvent:(NSEvent *)event" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "pendingPointerMotionKind = kind" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitQueuedPointerMotionInputEvent" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "queueScrollInputEvent:(NSEvent *)event" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "pendingScrollDeltaY += deltaY" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitQueuedScrollInputEvent" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "dispatch_after(dispatch_time(DISPATCH_TIME_NOW" },
        // The single per-surface frame-event scheduler: every producer
        // (requests, completions, occluded completions) coalesces into
        // one paced emission per display interval.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)scheduleFrameEventEmission" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)emitScheduledFrameEvent" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-quit-stop-queued", "Verify the quit verb's stop is queued to the next loop turn on every synchronous-emit host (a synchronous emitShutdown nests the shutdown dispatch inside the requesting command's dispatch, seals the session journal before the command commits, and replay diverges)", &.{
        // macOS (AppKit and CEF hosts): the main-queue hop, with the
        // pre-run-loop inline fallback the failed-START precedent needs.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (!NSApp.running) {" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if (!NSApp.running) {" },
        // Linux: the idle hop — the same seam the wake and
        // frame-request paths ride.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "static gboolean native_sdk_stop_idle(gpointer data)" },
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "g_idle_add(native_sdk_stop_idle, host);" },
        // Windows was queued from the start: stop posts, the loop
        // exits, and the shutdown emits after the loop at top level.
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "void native_sdk_windows_stop(Host *host) {" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "PostQuitMessage(0);" },
        // The runtime ordering the queue protects: the recorder seals
        // on the shutdown dispatch's exit, and the modeled host's
        // queued seam keeps the runtime suites honest about it.
        .{ .path = "src/runtime/flow.zig", .pattern = "if (event_value == .app_shutdown) recorder.finish();" },
        .{ .path = "src/platform/null_platform.zig", .pattern = "pub fn takeQueuedQuit" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-quit-pre-run-pending", "Verify a PRE-RUN quit verb on the macOS hosts parks as a pending flag drained at top level, never the inline emit (an inline pre-run emit nests the shutdown inside the boot dispatch that requested it — the recorder seals the journal before that dispatch commits, the same bug the running-path queue fixes)", &.{
        // The quit verb's own landing point: pre-run it PARKS — the
        // inline emitShutdown+stop stays exclusive to
        // native_sdk_appkit_stop, the host-side failure request the
        // failed-START precedent rides (runWithCallback's didShutdown
        // check).
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "void native_sdk_appkit_request_stop(native_sdk_appkit_host_t *host) {" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "object.pendingPreRunStop = YES;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "void native_sdk_appkit_request_stop(native_sdk_appkit_host_t *host) {" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "object.pendingPreRunStop = YES;" },
        // The drains: after the START dispatch (at the didShutdown
        // decision point) and after the remaining pre-run dispatches
        // (appearance/resize/window-frame, and AppKit's synchronous
        // first canvas frame) — emitShutdown + stop at TOP LEVEL, once.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (BOOL)drainPendingPreRunStop {\n    if (!self.pendingPreRunStop) return NO;\n    self.pendingPreRunStop = NO;\n    if (self.didShutdown) return NO;\n    [self emitShutdown];\n    [self stop];\n    return YES;\n}" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self drainPendingPreRunStop];\n    // A failed START handler requests shutdown synchronously" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if ([self drainPendingPreRunStop]) return;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "- (BOOL)drainPendingPreRunStop {\n    if (!self.pendingPreRunStop) return NO;\n    self.pendingPreRunStop = NO;\n    if (self.didShutdown) return NO;\n    [self emitShutdown];\n    [self stop];\n    return YES;\n}" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "[self drainPendingPreRunStop];\n    // A failed START handler requests shutdown synchronously" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if ([self drainPendingPreRunStop]) {\n        shutdownCefIfNeeded();\n        return;\n    }" },
        // The Zig split: the quit verb rides request_stop; the failed
        // emit keeps the byte-for-byte host-side stop.
        .{ .path = "src/platform/macos/root.zig", .pattern = "native_sdk_appkit_request_stop(self.host);" },
        .{ .path = "src/platform/macos/root.zig", .pattern = "if (self.self) |mac| native_sdk_appkit_stop(mac.host);" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-gtk-stop-idle-tracked", "Verify the GTK quit-stop idle source is tracked on the host, coalesced while pending, skipped after shutdown, and removed at destroy (an untracked second g_idle_add leaves a source holding a freed host after the loop quits)", &.{
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "guint stop_idle_source;" },
        // The idle retires its own tracking before it emits.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "host->stop_idle_source = 0;\n    if (!host->did_shutdown) {" },
        // Coalesce + post-shutdown skip, then the tracked add.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "if (host->did_shutdown || host->stop_idle_source) return;\n    host->stop_idle_source = g_idle_add(native_sdk_stop_idle, host);" },
        // Destroy removes a still-pending stop turn.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "if (host->stop_idle_source) {\n        g_source_remove(host->stop_idle_source);\n        host->stop_idle_source = 0;\n    }" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-gpu-occluded-frame-heartbeat", "Verify occluded windows throttle frame completions to a heartbeat and restore full cadence on reveal", &.{
        // macOS: occluded surfaces pace logical completions on the ~1 Hz
        // heartbeat (never stopping — on_frame-driven models stay gently
        // current), de-occlusion supersedes the parked emission for an
        // immediate return to the display grid, and heartbeat completions
        // are flagged so the runtime never stamps input latency from them.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkOccludedFrameHeartbeatNs = 1000000000ull" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (BOOL)occludedFramePacingActive" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "heartbeatPaced ? NativeSdkOccludedFrameHeartbeatNs" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "self.frameEventEmissionGeneration += 1" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "occluded:[self occludedFramePacingActive]" },
        // Exempt producers (a real present's completion, an input's
        // responding frame) fire at grid promptness — neither can
        // sustain a spin.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "scheduleFrameEventEmissionForPresentCompletion:YES" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)noteGpuSurfaceInputActivity" },
        // Windows: the same throttle keyed on the two reliable
        // occlusion facts — minimize (IsIconic) and the close_policy
        // .hide hide (policy_hidden: a hidden menu-bar app must not
        // spin its frame loop or its spectrum emissions full-rate for
        // days). Restore re-arms the pending one-shot timer at the
        // frame-grid delay through WM_SIZE, re-show through the show
        // verb (SW_SHOW dispatches no WM_SIZE), and the input /
        // first-present exemptions ride one prompt-frame flag.
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuOccludedHeartbeatNs = 1000000000ull" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "gpuSurfaceOccludedPacingActive" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "owner->second.policy_hidden) return true;" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "IsIconic(root)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "!IsIconic(entry.second.hwnd) && !entry.second.policy_hidden" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "Re-show returns full frame cadence without dropping a beat" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "gpu_prompt_frame_pending" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "native_sdk_windows_note_gpu_surface_input" },
        // The runtime side of the measurement honesty: occluded logical
        // completions resolve pending inputs without a latency stamp,
        // and every dispatched input notes the host for a prompt
        // responding frame.
        .{ .path = "src/runtime/gpu_surface_events.zig", .pattern = "resolveGpuSurfaceInputForOccludedFrame" },
        .{ .path = "src/runtime/gpu_surface_events.zig", .pattern = "noteGpuSurfaceInput" },
        // GTK: no reliable cross-backend occlusion signal — the decision
        // to leave full cadence is documented at the scheduler, not
        // implicit.
        .{ .path = "src/platform/linux/gtk_host.c", .pattern = "No occluded/minimized throttle here, DELIBERATELY" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-drawable-integral-pixels", "Verify AppKit GPU surfaces use integral drawable pixels", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "ceil(size.width * scale)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "ceil(size.height * scale)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "self.metalLayer.drawableSize = drawableSize" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-resize-repaints-retained-canvas", "Verify AppKit GPU resize requests a correctly sized retained frame", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "_metalLayer.contentsGravity = kCAGravityTopLeft" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (changed) {" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[self requestRetainedCanvasFrame];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "canvasTextureMatchesDrawable" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-transforms", "Verify AppKit GPU packet presenter applies command transforms", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketApplyTransform(command[@\"transform\"])" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[affine setTransformStruct:transform]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[affine concat]" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-paths", "Verify AppKit GPU packet presenter draws path commands", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"path\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[verb isEqualToString:@\"quad_to\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"fill_path\"]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[kind isEqualToString:@\"stroke_path\"]" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-corner-radii", "Verify AppKit GPU packet presenter honors per-corner radii", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketRoundedRectPath" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGFloat topRight = NativeSdkPacketRadiusAt(radiusValue, 1, maxRadius)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGFloat bottomLeft = NativeSdkPacketRadiusAt(radiusValue, 3, maxRadius)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return NativeSdkPacketRoundedRectPath(rect, shape[@\"radius\"])" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-load-frames", "Verify AppKit GPU packet presenter handles retained load frames", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "canvasPacketPixels" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[loadAction isEqualToString:@\"load\"]" },
        // Retained-backing discipline: dirty updates require the validity
        // flag, and every present that mutates the backing clears it until
        // the draw succeeds — a failed draw can never leak stale pixels
        // around a later scissor.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "!self.canvasPacketPixelsValid" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "self.canvasPacketPixelsValid = YES" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "hasDirtyRect:uploadDirtyRect" },
    });
    // Version prose is machine-checked: the wire-format v2/v3 drift (spec
    // comments and changelog naming a version the constant had moved past)
    // shipped once, so the constant and every prose site that names the
    // version are pinned together. Bumping `binary_packet_version` fails
    // this step until the encoder comment, the host decoder comment, and
    // the patterns below move with it.
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-wire-format-version-prose", "Verify wire-format version prose matches the packet version constant", &.{
        .{ .path = "src/primitives/canvas/serialization.zig", .pattern = "pub const binary_packet_version: u8 = 5;" },
        .{ .path = "src/primitives/canvas/serialization.zig", .pattern = "Compact binary gpu-surface packet encoding (wire format v5)." },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "Compact binary gpu-surface packet decoding (wire format v5)." },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "Compact binary gpu-surface packet decoding (wire format v5)." },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-gpu-packet-presenter", "Verify Windows uses retained Direct2D packets with recovery, bounded resources, and dirty-region pixel fallback", &.{
        .{ .path = "src/platform/windows/root.zig", .pattern = ".present_gpu_surface_packet_binary_fn = presentGpuSurfacePacketBinary" },
        .{ .path = "src/platform/windows/root.zig", .pattern = ".backend = if (event.gpu_backend == 1) .direct2d else .software" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "view.gpu_surface->present(request, &info)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "InvalidateRect(view.hwnd, &info.dirty_rects[index], FALSE)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "for (size_t y_index = y0; y_index < y1; ++y_index)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "InvalidateRect(view.hwnd, partial_update ? &dirty_pixels : nullptr, FALSE)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "D2D1_RENDER_TARGET_TYPE_HARDWARE" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "retained_commands_ = std::move(next_retained)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "PushAxisAlignedClip(d2dRect(requested)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "const float expansion = effect.spread + blur" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "releaseImageBitmap(action.id)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "resumeAndDrawBlur" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "const Rect target = blurTarget(*command, outer_clip)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "blur_snapshot_->CopyFromBitmap" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "command.effect.blur * transformScale(command.transform)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "D2D1_EXTEND_MODE_CLAMP" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "!GetClientRect(view.hwnd, &client) || !PtInRect(&client, sample)" },
        .{ .path = "src/platform/windows/gpu_surface_renderer.cpp", .pattern = "draw_line(text.text, text.origin.x, text.origin.y)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "gpuSurfaceUpdateRegionRects" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "info.dirty_rect_count > 0" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "view->gpu_force_full_repaint_pending = true" },
        .{ .path = "src/platform/windows/root.zig", .pattern = ".canvas_frame_full_repaint = event.force_full_repaint != 0" },
        .{ .path = ".github/scripts/windows-canvas-smoke.sh", .pattern = "gpu_backend=direct2d" },
        .{ .path = ".github/scripts/windows-effects-smoke.sh", .pattern = "gpu_backend=direct2d" },
        .{ .path = "build/app.zig", .pattern = "app_mod.linkSystemLibrary(\"d2d1\", .{})" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-blur-effects", "Verify AppKit GPU packet presenter applies blur effects", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketApplyBlur" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CGBitmapContextGetData(context)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkGaussianBoxRadii" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "vImageBoxConvolve_ARGB8888" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSIntersectionRect(rect, clipRect)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTransformRect(transformValue, NativeSdkPacketRect(effect[@\"rect\"]))" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return NativeSdkPacketApplyBlur(effect, opacity, context, scale, transformValue, hasClip, clipRect)" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-text-layout", "Verify AppKit GPU packet presenter honors text layout metadata", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSMutableParagraphStyle" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTextLineBreakMode" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketTextAlignment" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static BOOL NativeSdkPacketDrawAttributedText(" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return NativeSdkAppKitDrawAttributedText(value, attributes, x, baseline, width, height, NULL)" },
        .{ .path = "src/platform/macos/appkit_text_baseline.h", .pattern = "drawGlyphsForGlyphRange:glyphRange atPoint:" },
        .{ .path = "src/platform/macos/appkit_text_baseline.h", .pattern = "glyphRangeForTextContainer:container" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketNumber(layout[@\"maxWidth\"], 0)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "native_sdk_appkit_measure_text_ink(" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-font-assets", "Verify AppKit GPU packet text registers bundled font assets", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "#import <CoreText/CoreText.h>" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "CTFontManagerRegisterFontsForURL" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@[ @\"fonts\", @\"Fonts\", @\"assets/fonts\" ]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkRegisterBundledFonts();" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkPacketPreferredFont(text, size)" },
        .{ .path = "src/tooling/templates.zig", .pattern = "app_mod.linkFramework(\"CoreText\", .{});" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-packet-span-fonts", "Verify AppKit packet text resolves reserved span font ids to real weighted and italic faces", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSFont *NativeSdkItalicSansFont(NSFont *font)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSFont *NativeSdkWeightedSansFont(" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Medium\", @\"Geist Medium\" ], base, NSFontWeightMedium, NO, size)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], base, NSFontWeightBold, YES, size)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkItalicSansFont(base)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], base, NSFontWeightBold, YES, size))" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-registered-font-cache-eviction", "Verify the AppKit host invalidates BOTH per-process registered-font caches at registration (the caches are per-process while font-id permanence is per-runtime, so a new runtime re-registering an id must never resolve the previous runtime's face or its measured widths): the NSFont size cache by prefix eviction and the measured-width NSCache by a process-global registration token in its key", &.{
        // No SDK test tier links appkit_host.m (only managed app builds
        // compile it), so the eviction wiring is pinned textually like
        // the other AppKit host contracts: the shared accessor both the
        // resolve and registration paths use, the prefix eviction inside
        // register_font, and the honest lifetime comment.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSMutableDictionary<NSString *, NSFont *> *NativeSdkRegisteredFontSizeCache(void)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSString *stalePrefix = [NSString stringWithFormat:@\"%llu/\", (unsigned long long)font_id];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if ([cachedKey hasPrefix:stalePrefix]) [sizeCache removeObjectForKey:cachedKey];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "an id is only permanent within" },
        // The width-cache half: NSCache cannot enumerate keys, so the
        // measured-width cache is invalidated by a registration token
        // drawn from one process-global monotonic counter (tokens never
        // repeat, which is what lets unregister DELETE an id's record
        // instead of retaining a bumped one per retired id) — the token
        // table, the fresh stamp inside register_font, and the
        // token-carrying key inside measure_text.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSMutableDictionary<NSNumber *, NSNumber *> *NativeSdkRegisteredFontTokens(void)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "unsigned long long token = ++NativeSdkRegisteredFontTokenCounter;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkRegisteredFontTokens()[@(font_id)] = @(token);" },
        // The stamp is also the registration's OWNERSHIP token: register
        // reports it to the caller (`*out_token`), the runtime stores it
        // beside the captured unregister owner, and unregister removes
        // the id's state only while the id's current registration still
        // carries it — an older runtime's deinit must never tear down a
        // newer runtime's live face under a shared id (ids are
        // per-runtime, host font state is per-process, last wins).
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "*out_token = token;" },
        // The token and the registered face reach measure_text from ONE
        // critical section (the snapshot helper): separate acquisitions
        // let a registration land between the token read and the face
        // resolution, pairing token 0 with the new registered face and
        // caching registered widths under the reusable token-0 key —
        // stale registered widths served after teardown. The snapshot
        // signature and its measure_text call site are pinned so the
        // two-acquisition shape cannot quietly return.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSFont *NativeSdkRegisteredFontSnapshot(unsigned long long value, CGFloat size, unsigned long long *out_token)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSFont *registered = NativeSdkRegisteredFontSnapshot((unsigned long long)font_id, clamped, &token);" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSFont *font = registered ?: NativeSdkBuiltInFontForFontId(font_id, clamped);" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[NSString stringWithFormat:@\"%llu/%llu/%.3f/%@\", (unsigned long long)font_id, token, (double)clamped, value]" },
        // The width-cache WRITE is token-rechecked. Shaping runs outside
        // the guard, so an unregister can land inside the shaping window:
        // it clears the whole width cache (its only possible eviction),
        // and an unconditional post-shape write would then repopulate the
        // cleared cache with a retired-token entry — unreachable for
        // serving (tokens never repeat) but resident until memory
        // pressure, breaking the zero-retained-state teardown the clear
        // exists to guarantee. measure_text therefore re-enters the
        // descriptor guard after shaping and writes only while the id's
        // current token still equals the snapshotted one; token 0
        // (built-in resolution — never registered, so never cleared)
        // caches without the recheck. Both branches are pinned so the
        // unconditional-write shape cannot quietly return.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (token == 0) {" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSNumber *currentToken = NativeSdkRegisteredFontTokens()[@(font_id)];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (currentToken && currentToken.unsignedLongLongValue == token) {" },
        // The teardown half: Runtime.deinit returns the host-side
        // registration through the unregister owner each font entry
        // captured at registration time (never live `options.platform`,
        // which is publicly mutable), and the ObjC removal drops the
        // descriptor, the size-cache entries, AND the token record —
        // zero retained state per retired id. Pinned like the
        // registration half (appkit_host.m has no SDK test tier); the
        // capture and the deinit call site are pinned too so the seam
        // can never silently lose its one caller or regress to the live
        // read, and the embed cycle and platform-swap tests assert both
        // behaviorally against null platform recorders.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "int native_sdk_appkit_unregister_font(uint64_t font_id, uint64_t token) {" },
        // The token-match guard itself: reverting removal to id-keyed
        // (deleting whatever the id currently holds, whoever registered
        // it) must fail here — the embed suite's survives-teardown test
        // pins the same guard behaviorally against the null platform's
        // host-font mirror.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (!current || current.unsignedLongLongValue != token) return 1;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[NativeSdkRegisteredFontTokens() removeObjectForKey:@(font_id)];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[table removeObjectForKey:@(font_id)];" },
        // Teardown must also CLEAR the measured-width NSCache: a
        // retiring token's entries can never be served again (tokens
        // never repeat) but they stay resident until memory pressure,
        // and NSCache cannot enumerate keys, so the whole-cache clear on
        // the token-matched path is the only release. Pinned textually
        // because no behavioral tier can observe it — only managed app
        // builds compile appkit_host.m, so no SDK test can watch the
        // ObjC cache empty. The shared accessor and its measure_text
        // call site are pinned with the clear so the cache cannot
        // quietly retreat to a function-local static the unregister
        // path has no way to reach.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "static NSCache<NSString *, NSNumber *> *NativeSdkMeasuredWidthCache(void)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "[NativeSdkMeasuredWidthCache() removeAllObjects];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSCache<NSString *, NSNumber *> *widthCache = NativeSdkMeasuredWidthCache();" },
        .{ .path = "src/runtime/canvas_fonts.zig", .pattern = ".host_unregister_fn = services.unregister_gpu_surface_font_fn," },
        .{ .path = "src/runtime/canvas_fonts.zig", .pattern = ".host_registration_token = host_token," },
        .{ .path = "src/runtime/core.zig", .pattern = "host_unregister_fn(entry.host_unregister_context, entry.id, entry.host_registration_token) catch {};" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-cursor-bridge", "Verify AppKit GPU widgets apply retained cursor intent", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "native_sdk_appkit_set_view_cursor" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "resetCursorRects" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSTrackingMouseMoved" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_GPU_INPUT_POINTER_CANCEL" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "_surfaceCursor = cursor ?: [NSCursor arrowCursor]" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSCursor pointingHandCursor" },
        // A full-bounds canvas cursor rect geometrically overlaps a
        // higher-layer webview even though hit testing does not. The
        // workbench needs both halves: subtract the overlay from the
        // cursor rects and refuse a direct canvas cursor set there.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSMutableArray<NSValue *> *visibleCursorRects" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "surfaceView.coveredMouseRects = coveredRects" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (!covered && NSPointInRect(mousePoint, self.bounds)) [_surfaceCursor set]" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-actions", "Verify AppKit GPU widget accessibility actions route to the runtime", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityPerformPress" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitWidgetAccessibilityActionWithId" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_EVENT_WIDGET_ACCESSIBILITY_ACTION" },
        // The per-element action gate: without it AppKit derives the
        // advertised action list from the CLASS's selectors, so every
        // widget element (a static label included) offers
        // press/increment/decrement/cancel and performing an
        // unsupported one reports success while actuating nothing.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "isAccessibilitySelectorAllowed" },
        // An assistive client's AXFocused WRITE must move the app's
        // real focus, not just flip a flag on the snapshot element.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "setAccessibilityFocused" },
        // Native Edit-menu validation follows the retained editor's actual
        // history directions instead of merely checking text focus.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "focusedText.canUndo" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "focusedText.canRedo" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-text-ranges", "Verify AppKit GPU widget accessibility publishes text selection ranges", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilitySelectedTextRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilitySelectedTextRanges" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityVisibleCharacterRange" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-accessibility-grid-metrics", "Verify AppKit GPU widget accessibility publishes grid and scroll metrics", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityRowIndexRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityColumnIndexRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityRowCount" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityMaxValue" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-ime-bridge", "Verify AppKit GPU widgets route native text input and IME composition", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSTextInputClient" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "insertText:(id)string replacementRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "setMarkedText:(id)string selectedRange" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_GPU_INPUT_IME_SET_COMPOSITION" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-gpu-widget-ime-bridge", "Verify the Windows GPU host routes WM_IME composition onto the shared IME event kinds", &.{
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_STARTCOMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_COMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "case WM_IME_ENDCOMPOSITION:" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeSetComposition = 8" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeCommitComposition = 9" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "kGpuInputImeCancelComposition = 10" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "gpuImeCommitAction(pending, result)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "ISC_SHOWUICOMPOSITIONWINDOW" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-windows-view-frame-rounding", "Verify Windows native view frames accumulate logical coordinates before rounding and declare the full DPI awareness fallback chain", &.{
        // The frame policy: every physical edge is the once-rounded
        // product of an ACCUMULATED logical coordinate and the window
        // scale, with width/height as edge differences. Per-level
        // rounding drifts from the round of the sum (the static_asserts
        // beside nativeViewCoord carry the numeric proof, compiled on
        // every Windows host build).
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "static void nativeViewLogicalOrigin(Host *host, const NativeView &view, double *logical_x, double *logical_y)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "frame.right = nativeViewCoord((logical_x + view.width) * scale);" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "static_assert(nativeViewCoord(10.4 * 1.5) + nativeViewCoord(10.4 * 1.5) == 32 && nativeViewCoord((10.4 + 10.4) * 1.5) == 31," },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "MoveWindow(view.hwnd, frame.left, frame.top, frame.right - frame.left, frame.bottom - frame.top, TRUE);" },
        // The embedded manifest's DPI declarations: the ordered
        // dpiAwareness list degrades PerMonitorV2 to PerMonitor, and the
        // legacy dpiAware element covers systems that ignore dpiAwareness
        // entirely.
        .{ .path = "assets/native-sdk.manifest", .pattern = "<dpiAware xmlns=\"http://schemas.microsoft.com/SMI/2005/WindowsSettings\">true/pm</dpiAware>" },
        .{ .path = "assets/native-sdk.manifest", .pattern = "<dpiAwareness xmlns=\"http://schemas.microsoft.com/SMI/2016/WindowsSettings\">PerMonitorV2, PerMonitor</dpiAwareness>" },
        // The host's runtime DPI resolution mirrors that manifest chain:
        // GetDpiForWindow, then shcore's GetDpiForMonitor (per-monitor v1),
        // then the system DPI. Without the per-monitor-v1 and system rungs
        // an aware process on a pre-1607 system would render at real
        // physical pixels while the host still scaled everything at 1x.
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "GetProcAddress(shcore, \"GetDpiForMonitor\")" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)" },
        .{ .path = "src/platform/windows/webview2_host.cpp", .pattern = "return systemDpi();" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-gpu-widget-text-command-bridge", "Verify AppKit GPU text widgets route native text commands", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)selectAll:(id)sender" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@selector(selectAll:)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitSyntheticKeyDownWithKey:@\"a\" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)undo:(id)sender" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "- (void)redo:(id)sender" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitSyntheticKeyDownWithKey:@\"z\" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "emitSyntheticKeyDownWithKey:@\"z\" modifiers:(NativeSdkShortcutModifierPrimary | NativeSdkShortcutModifierCommand | NativeSdkShortcutModifierShift)" },
        // Modified horizontal navigation must bypass AppKit's selector
        // rewrite: the shared editor consumes the raw modifiers, and a
        // terminal translates them to its shell/protocol bindings.
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NativeSdkTextNavigationNeedsRawKeyEvent(event)" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NSEventModifierFlagCommand | NSEventModifierFlagOption" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-widget-accessibility-hierarchy", "Verify AppKit preserves retained-widget accessibility parentage", &.{
        .{ .path = "src/platform/macos/appkit_host.h", .pattern = "uint64_t parent_id;" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".parent_id = node.parent_id orelse 0" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "element.accessibilityParent = parent;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "parent.accessibilityChildren = [childrenByParentId objectForKey:parentId];" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "return self.widgetAccessibilityRootElements ?: @[];" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-appearance-bridge", "Verify AppKit reports system light and dark appearance changes", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "effectiveAppearance" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityDisplayShouldReduceMotion" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "accessibilityDisplayShouldIncreaseContrast" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "NATIVE_SDK_APPKIT_EVENT_APPEARANCE_CHANGED" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".reduce_motion = event.reduce_motion != 0" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".high_contrast = event.high_contrast != 0" },
        .{ .path = "src/platform/macos/root.zig", .pattern = ".appearance_changed => state.emit" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-appkit-tray-segment-source-selection", "Verify both macOS tray hosts keep segmented selection model-owned", &.{
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "@property(nonatomic, assign) NSInteger sourceSelectedSegment;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "if (options[i].selected != 0) control.sourceSelectedSegment = (NSInteger)i;" },
        .{ .path = "src/platform/macos/appkit_host.m", .pattern = "for (NSInteger index = 0; index < control.segmentCount; index++) {\n        [control setSelected:index == sourceSelected forSegment:index];\n    }\n    self.trayCallback" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "@property(nonatomic, assign) NSInteger sourceSelectedSegment;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "if (options[i].selected != 0) control.sourceSelectedSegment = (NSInteger)i;" },
        .{ .path = "src/platform/macos/cef_host.mm", .pattern = "for (NSInteger index = 0; index < control.segmentCount; index++) {\n        [control setSelected:index == sourceSelected forSegment:index];\n    }\n    self.trayCallback" },
    });
    addFileContainsCheckStep(b, file_contains_checker, test_step, "test-docs-builtin-bridge-policy", "Verify bridge policy docs include guarded dialog commands", &.{
        .{ .path = "docs/src/app/docs/security/page.mdx", .pattern = ".{ .name = \"native-sdk.dialog.saveFile\"" },
        .{ .path = "docs/src/app/docs/bridge/builtin-commands/page.mdx", .pattern = ".{ .name = \"native-sdk.dialog.saveFile\"" },
    });

    addTestStep(b, "test-geometry", "Run geometry module tests", geometry_tests);
    addTestStep(b, "test-assets", "Run assets module tests", assets_tests);
    addTestStep(b, "test-app-dirs", "Run app directory module tests", app_dirs_tests);
    addTestStep(b, "test-trace", "Run trace module tests", trace_tests);
    addTestStep(b, "test-app-manifest", "Run app manifest module tests", app_manifest_tests);
    addTestStep(b, "test-diagnostics", "Run diagnostics module tests", diagnostics_tests);
    addTestStep(b, "test-platform-info", "Run platform info module tests", platform_info_tests);
    addTestStep(b, "test-json", "Run JSON primitive tests", json_tests);
    addTestStep(b, "test-app-runner-window-placement", "Run app-runner window placement decision tests", app_runner_window_placement_tests);
    addTestStep(b, "test-canvas", "Run canvas display list tests", canvas_tests);
    addTestStep(b, "test-desktop", "Run Native SDK framework tests", desktop_tests);
    for (desktop_test_shard_specs, desktop_test_shards) |spec, shard_tests| {
        addTestStep(b, b.fmt("test-desktop-{s}", .{spec.name}), spec.description, shard_tests);
    }
    // The font-registry suite as its own step so CI lanes on real
    // Windows hardware can run it natively: the whole font pipeline
    // (TrueType parsing, glyph rasterization, the reference renderer)
    // is platform-neutral Zig, and this suite's Chinese-receipt test
    // registers a committed CJK face through the app-fonts seam and
    // proves the rendered string is real glyphs, not tofu — running it
    // on a Windows runner makes that a Windows-native receipt. The same
    // tests also run inside `zig build test` via the canvas-frame shard.
    addTestStep(b, "test-canvas-fonts", "Run the runtime font-registry tests (includes the registered-CJK Chinese receipt)", filteredTestArtifact(b, desktop_mod, "canvas-fonts-tests", &.{"runtime.canvas_font_tests.test"}));
    // The console-attachment regression is Windows-only, so the general
    // Linux `zig build test` lane can only compile and skip it. Expose the
    // exact test as a focused step for the real-Windows CI runner; this
    // keeps CREATE_NO_WINDOW behavior covered without making that runner
    // execute the entire framework runtime suite.
    addTestStep(b, "test-windows-effects-no-console", "Verify Windows effect spawns run without an attached console", filteredTestArtifact(b, desktop_mod, "windows-effects-no-console-tests", &.{"runtime.effects_tests.test.Windows background spawns run without an attached console"}));
    addTestStep(b, "test-automation-protocol", "Run automation protocol tests", automation_protocol_tests);
    addTestStep(b, "test-automation-cli", "Run native automate CLI tests", automation_cli_tests);
    addTestStep(b, "test-markup-cli", "Run native markup CLI tests", markup_cli_tests);
    addTestStep(b, "test-skills-cli", "Run native skills CLI tests", skills_cli_tests);
    addTestStep(b, "test-evals-cmdview", "Run the evals harness Cmd wire decoder tests", evals_cmdview_tests);
    addTestStep(b, "test-tooling", "Run Native SDK tooling tests", tooling_tests);
    addTestStep(b, "test-eject-components", "Run ejected-component widget-identity tests", eject_components_tests);

    const run_hello = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}) });
    run_hello.setCwd(b.path("examples/hello"));
    const run_hello_step = b.step("run-hello", "Run the native-sdk hello WebView example");
    run_hello_step.dependOn(&run_hello.step);

    const run_webview = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}), b.fmt("-Dweb-engine={s}", .{@tagName(web_engine)}), b.fmt("-Dcef-dir={s}", .{exampleCefDir(b, cef_dir)}) });
    run_webview.setCwd(b.path("examples/webview"));
    const run_webview_step = b.step("run-webview", "Run the native-sdk WebView example");
    run_webview_step.dependOn(&run_webview.step);

    const browser_cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, "third_party/cef/macos");
    const run_browser = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}), b.fmt("-Dtrace={s}", .{@tagName(trace_option)}), b.fmt("-Dweb-engine={s}", .{@tagName(browser_web_engine)}), b.fmt("-Dcef-dir={s}", .{exampleCefDir(b, browser_cef_dir)}) });
    run_browser.setCwd(b.path("examples/browser"));
    const run_browser_step = b.step("run-browser", "Run the native-sdk browser example");
    run_browser_step.dependOn(&run_browser.step);

    const build_webview_system = b.addSystemCommand(&.{ "zig", "build", b.fmt("-Dplatform={s}", .{platform_arg}), "-Dweb-engine=system" });
    build_webview_system.setCwd(b.path("examples/webview"));
    const webview_system_link_step = b.step("test-webview-system-link", "Build the WebView example with the system engine");
    webview_system_link_step.dependOn(&build_webview_system.step);

    const build_browser_system = b.addSystemCommand(&.{ "zig", "build", b.fmt("-Dplatform={s}", .{platform_arg}), "-Dweb-engine=system" });
    build_browser_system.setCwd(b.path("examples/browser"));
    const browser_system_link_step = b.step("test-browser-system-link", "Build the browser example with the system engine");
    browser_system_link_step.dependOn(&build_browser_system.step);

    // Windows web-layer PE cross-audit: the declare-to-use inference,
    // proven on real executables from any host via cross-compile.
    // ui-inbox's manifest declares no web use, so its exe must carry no
    // WebView2Loader.dll reference (the whole embedded layer compiles
    // out) and no loader may land beside it; the webview example declares
    // the "webview" capability, so its exe must keep the reference. The
    // loader string lives as UTF-16 in the host, so the audit is a
    // dedicated scanner (tools/audit_web_layer.zig), not a text grep.
    const web_layer_auditor = b.addExecutable(.{
        .name = "audit-web-layer",
        .root_module = module(b, host_target, optimize, "tools/audit_web_layer.zig"),
    });
    // A loader installed by a build predating the inference would fail
    // the absence check below without being this build's fault; clear it
    // so the assertion tests what THIS build installs.
    const clean_native_only_loader = b.addSystemCommand(&.{ "sh", "-c", "rm -f examples/ui-inbox/zig-out/bin/WebView2Loader.dll" });
    const build_native_only_windows = b.addSystemCommand(&.{ "zig", "build", "-Dtarget=x86_64-windows-gnu", "-Dplatform=windows" });
    build_native_only_windows.setCwd(b.path("examples/ui-inbox"));
    build_native_only_windows.step.dependOn(&clean_native_only_loader.step);
    const build_webview_windows = b.addSystemCommand(&.{ "zig", "build", "-Dtarget=x86_64-windows-gnu", "-Dplatform=windows", "-Dweb-engine=system" });
    build_webview_windows.setCwd(b.path("examples/webview"));
    const audit_native_only_exe = b.addRunArtifact(web_layer_auditor);
    audit_native_only_exe.addArgs(&.{ "examples/ui-inbox/zig-out/bin/ui-inbox.exe", "absent" });
    audit_native_only_exe.has_side_effects = true;
    audit_native_only_exe.step.dependOn(&build_native_only_windows.step);
    const audit_webview_exe = b.addRunArtifact(web_layer_auditor);
    audit_webview_exe.addArgs(&.{ "examples/webview/zig-out/bin/webview.exe", "present" });
    audit_webview_exe.has_side_effects = true;
    audit_webview_exe.step.dependOn(&build_webview_windows.step);
    const audit_native_only_loader = b.addSystemCommand(&.{
        "sh", "-c",
        \\test ! -f examples/ui-inbox/zig-out/bin/WebView2Loader.dll || {
        \\  echo "web-layer audit FAILED: the native-only build installed WebView2Loader.dll" >&2
        \\  exit 1
        \\}
    });
    audit_native_only_loader.step.dependOn(&build_native_only_windows.step);
    const web_layer_audit_step = b.step("test-windows-web-layer-audit", "Cross-compile a native-only and a web example for Windows and audit the web layer in each exe");
    web_layer_audit_step.dependOn(&audit_native_only_exe.step);
    web_layer_audit_step.dependOn(&audit_webview_exe.step);
    web_layer_audit_step.dependOn(&audit_native_only_loader.step);

    // Linux web-layer ELF cross-audit: the same declare-to-use proof on
    // real Linux executables. Unlike the Windows step this cannot
    // cross-compile from any host — the GTK host needs the system GTK4
    // (and, for the web example, WebKitGTK) development headers — so the
    // step runs on Linux with both packages installed and proves the
    // SEAM, not the environment: the native-only exe must carry no
    // libwebkitgtk DT_NEEDED entry and no webkit_/jsc_ dynamic symbol
    // even though the dev package was right there, while the web example
    // must keep them. The environment half (a native-only app building
    // on a runner with no WebKitGTK dev package at all) is proven by the
    // linux-canvas-smoke CI job.
    const build_native_only_linux = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=linux" });
    build_native_only_linux.setCwd(b.path("examples/ui-inbox"));
    const build_webview_linux = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=linux", "-Dweb-engine=system" });
    build_webview_linux.setCwd(b.path("examples/webview"));
    const audit_native_only_elf = b.addRunArtifact(web_layer_auditor);
    audit_native_only_elf.addArgs(&.{ "examples/ui-inbox/zig-out/bin/ui-inbox", "absent" });
    audit_native_only_elf.has_side_effects = true;
    audit_native_only_elf.step.dependOn(&build_native_only_linux.step);
    const audit_webview_elf = b.addRunArtifact(web_layer_auditor);
    audit_webview_elf.addArgs(&.{ "examples/webview/zig-out/bin/webview", "present" });
    audit_webview_elf.has_side_effects = true;
    audit_webview_elf.step.dependOn(&build_webview_linux.step);
    const linux_web_layer_audit_step = b.step("test-linux-web-layer-audit", "Build a native-only and a web example for Linux (Linux host with GTK4 + WebKitGTK dev packages) and audit the web layer in each ELF");
    linux_web_layer_audit_step.dependOn(&audit_native_only_elf.step);
    linux_web_layer_audit_step.dependOn(&audit_webview_elf.step);

    const frontend_examples_step = b.step("test-examples-frontends", "Run frontend example tests");
    _ = addExampleTestStep(b, host_cli_exe, frontend_examples_step, "test-example-next", "Run Next example tests", "examples/next", .owned);
    _ = addExampleTestStep(b, host_cli_exe, frontend_examples_step, "test-example-react", "Run React example tests", "examples/react", .owned);
    _ = addExampleTestStep(b, host_cli_exe, frontend_examples_step, "test-example-svelte", "Run Svelte example tests", "examples/svelte", .owned);
    _ = addExampleTestStep(b, host_cli_exe, frontend_examples_step, "test-example-vue", "Run Vue example tests", "examples/vue", .owned);
    addFileContainsCheckStep(b, file_contains_checker, frontend_examples_step, "test-example-frontend-positioning", "Verify frontend example native shell positioning", &.{
        .{ .path = "examples/next/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/react/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/svelte/README.md", .pattern = "opens the native app shell with WebView content." },
        .{ .path = "examples/vue/README.md", .pattern = "opens the native app shell with WebView content." },
    });

    const native_examples_step = b.step("test-examples-native", "Run native-first example tests");
    const native_example_shard_steps = [_]*std.Build.Step{
        b.step("test-examples-native-shard-1", "Run the first native-first example test shard"),
        b.step("test-examples-native-shard-2", "Run the second native-first example test shard"),
        b.step("test-examples-native-shard-3", "Run the third native-first example test shard"),
        b.step("test-examples-native-shard-4", "Run the fourth native-first example test shard"),
    };
    const native_example_steps = [_]*std.Build.Step{
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-command-app", "Run command app example tests", "examples/command-app", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-native-shell", "Run native shell example tests", "examples/native-shell", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-native-panels", "Run native panels example tests", "examples/native-panels", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-gpu-surface", "Run GPU surface example tests", "examples/gpu-surface", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-gpu-dashboard", "Run GPU dashboard example tests", "examples/gpu-dashboard", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-gpu-components", "Run GPU components example tests", "examples/gpu-components", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-record-store", "Run record-store example tests", "examples/record-store", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-relational-notes", "Run relational notes example tests", "examples/relational-notes", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-ui-inbox", "Run ui builder inbox example tests", "examples/ui-inbox", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-kanban", "Run ui builder kanban example tests", "examples/kanban", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-habits", "Run markup habits example tests", "examples/habits", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-soundboard", "Run soundboard example tests", "examples/soundboard", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-video-player", "Run video player example tests", "examples/video-player", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-soundboard-ts", "Run soundboard-ts example tests", "examples/soundboard-ts", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-voice-memo", "Run voice memo example tests", "examples/voice-memo", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-deck", "Run deck example tests", "examples/deck", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-markdown-viewer", "Run markdown viewer example tests", "examples/markdown-viewer", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-code-editor", "Run code editor example tests", "examples/code-editor", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-calculator", "Run calculator example tests", "examples/calculator", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-notes", "Run notes example tests", "examples/notes", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-split-collapse", "Run split collapse example tests", "examples/split-collapse", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-system-monitor", "Run system monitor example tests", "examples/system-monitor", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-terminal", "Run terminal example tests", "examples/terminal", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-workbench", "Run workbench example tests", "examples/workbench", .owned),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-system-monitor-ts", "Run system-monitor-ts example tests", "examples/system-monitor-ts", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-effects-probe", "Run effects probe example tests", "examples/effects-probe", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-channel-monitor", "Run channel monitor example tests", "examples/channel-monitor", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-menu-bar", "Run menu-bar lifecycle example tests", "examples/menu-bar", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-feed", "Run feed example tests", "examples/feed", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-service-feed-reader", "Run TypeScript service feed-reader example tests", "examples/service-feed-reader", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-canvas-preview", "Run canvas preview example tests", "examples/canvas-preview", .managed),
        addExampleTestStep(b, host_cli_exe, native_examples_step, "test-example-capabilities", "Run capabilities example tests", "examples/capabilities", .owned),
    };
    for (native_example_shard_steps) |shard_step| {
        native_examples_step.dependOn(shard_step);
    }
    for (native_example_steps, 0..) |example_step, index| {
        native_example_shard_steps[index % native_example_shard_steps.len].dependOn(example_step);
    }
    // Keep this companion check in the same shard as capabilities. The
    // aggregate step depends on every shard, so `test-examples-native`
    // retains exactly the same coverage as before.
    addFileContainsCheckStep(b, file_contains_checker, native_example_shard_steps[2], "test-example-capabilities-events", "Verify capabilities example event bridge names", &.{
        .{ .path = "examples/capabilities/src/main.zig", .pattern = "native-sdk:drop:files" },
    });

    const mobile_examples_step = b.step("test-examples-mobile", "Verify mobile example project layouts");
    addLayoutCheckStep(b, mobile_examples_step, "test-example-ios-layout", "Verify iOS example layout", &.{
        "examples/ios/README.md",
        "examples/ios/app.zon",
        "examples/ios/NativeSdkIOSExample.xcodeproj/project.pbxproj",
        "examples/ios/NativeSdkIOSExample/AppDelegate.swift",
        "examples/ios/NativeSdkIOSExample/SceneDelegate.swift",
        "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift",
        "examples/ios/NativeSdkIOSExample/native_sdk.h",
        "examples/ios/NativeSdkIOSExample/NativeSdkDyldShim.c",
    });
    addLayoutCheckStep(b, mobile_examples_step, "test-example-android-layout", "Verify Android example layout", &.{
        "examples/android/README.md",
        "examples/android/app.zon",
        "examples/android/settings.gradle",
        "examples/android/build.gradle",
        "examples/android/app/build.gradle",
        "examples/android/app/src/main/AndroidManifest.xml",
        "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt",
        "examples/android/app/src/main/cpp/CMakeLists.txt",
        "examples/android/app/src/main/cpp/native_sdk_jni.c",
        "examples/android/app/src/main/cpp/native_sdk.h",
    });
    addLayoutCheckStep(b, mobile_examples_step, "test-example-mobile-shell-layout", "Verify shared mobile-shell metadata", &.{
        "examples/mobile-shell/README.md",
        "examples/mobile-shell/app.zon",
    });

    // Host-tier packaged project pin: `native package --target ios` must
    // keep emitting the complete, deterministic Xcode project (toolkit
    // host sources, Info.plist, asset catalog, scheme) — drift is caught
    // here. --binary stubs the embed library with the fixed-shell lib so
    // the check needs no iOS cross-compile.
    const package_ios_layout_run = b.addRunArtifact(host_cli_exe);
    package_ios_layout_run.setCwd(b.path("examples/calculator"));
    package_ios_layout_run.setEnvironmentVariable("NATIVE_SDK_PATH", b.pathFromRoot("."));
    package_ios_layout_run.addArgs(&.{ "package", "--target", "ios", "--output", "zig-out/package/test-ios-layout", "--binary" });
    package_ios_layout_run.addFileArg(embed_lib.getEmittedBin());
    package_ios_layout_run.has_side_effects = true;
    const package_ios_layout_step = b.step("test-package-ios-layout", "Verify the generated iOS host project layout");
    const package_ios_layout_paths = [_][]const u8{
        "examples/calculator/zig-out/package/test-ios-layout/calculator.xcodeproj/project.pbxproj",
        "examples/calculator/zig-out/package/test-ios-layout/calculator.xcodeproj/xcshareddata/xcschemes/calculator.xcscheme",
        "examples/calculator/zig-out/package/test-ios-layout/Host/uikit_host.m",
        "examples/calculator/zig-out/package/test-ios-layout/Host/native_sdk_app.h",
        "examples/calculator/zig-out/package/test-ios-layout/Host/apple_image_fit.h",
        "examples/calculator/zig-out/package/test-ios-layout/Host/Info.plist",
        "examples/calculator/zig-out/package/test-ios-layout/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
        "examples/calculator/zig-out/package/test-ios-layout/Assets.xcassets/AppIcon.appiconset/Contents.json",
        "examples/calculator/zig-out/package/test-ios-layout/Libraries/libnative-sdk.a",
        "examples/calculator/zig-out/package/test-ios-layout/README.md",
        "examples/calculator/zig-out/package/test-ios-layout/package-manifest.zon",
    };
    for (package_ios_layout_paths) |path| {
        const check = b.addSystemCommand(&.{ "test", "-f", path });
        check.step.dependOn(&package_ios_layout_run.step);
        package_ios_layout_step.dependOn(&check.step);
        mobile_examples_step.dependOn(&check.step);
    }
    const package_ios_layout_contents = [_]FileContainsCheck{
        .{ .path = "examples/calculator/zig-out/package/test-ios-layout/calculator.xcodeproj/project.pbxproj", .pattern = "PRODUCT_BUNDLE_IDENTIFIER = \"dev.native-sdk.calculator\";" },
        .{ .path = "examples/calculator/zig-out/package/test-ios-layout/Host/Info.plist", .pattern = "UILaunchScreen" },
        .{ .path = "examples/calculator/zig-out/package/test-ios-layout/Host/uikit_host.m", .pattern = "native_sdk_app_render_pixels" },
    };
    for (package_ios_layout_contents) |check_value| {
        const check = b.addRunArtifact(file_contains_checker);
        check.setCwd(b.path("."));
        check.addArg(check_value.path);
        check.addArg(check_value.pattern);
        check.step.dependOn(&package_ios_layout_run.step);
        package_ios_layout_step.dependOn(&check.step);
        mobile_examples_step.dependOn(&check.step);
    }
    // Host-tier packaged project pin, Android: `native package --target
    // android` must keep emitting the complete generated host project
    // (toolkit host sources, app.zon-derived manifest, launcher icons) —
    // drift is caught here. --binary stubs the embed library with the
    // fixed-shell lib so the check needs no Android cross-compile, and
    // ANDROID_HOME points at a nonexistent SDK so the deterministic
    // project-only path runs everywhere (the APK assembly is exercised
    // by the live loops, not CI).
    const package_android_layout_run = b.addRunArtifact(host_cli_exe);
    package_android_layout_run.setCwd(b.path("examples/calculator"));
    package_android_layout_run.setEnvironmentVariable("NATIVE_SDK_PATH", b.pathFromRoot("."));
    package_android_layout_run.setEnvironmentVariable("ANDROID_HOME", b.pathFromRoot("zig-out/no-android-sdk"));
    package_android_layout_run.addArgs(&.{ "package", "--target", "android", "--output", "zig-out/package/test-android-layout", "--binary" });
    package_android_layout_run.addFileArg(embed_lib.getEmittedBin());
    package_android_layout_run.has_side_effects = true;
    const package_android_layout_step = b.step("test-package-android-layout", "Verify the generated Android host project layout");
    const package_android_layout_paths = [_][]const u8{
        "examples/calculator/zig-out/package/test-android-layout/AndroidManifest.xml",
        "examples/calculator/zig-out/package/test-android-layout/Host/NativeSdkActivity.java",
        "examples/calculator/zig-out/package/test-android-layout/Host/android_host.c",
        "examples/calculator/zig-out/package/test-android-layout/Host/native_sdk_app.h",
        "examples/calculator/zig-out/package/test-android-layout/res/mipmap-mdpi/ic_launcher.png",
        "examples/calculator/zig-out/package/test-android-layout/res/mipmap-xxxhdpi/ic_launcher.png",
        "examples/calculator/zig-out/package/test-android-layout/Libraries/libnative-sdk.a",
        "examples/calculator/zig-out/package/test-android-layout/README.md",
        "examples/calculator/zig-out/package/test-android-layout/package-manifest.zon",
    };
    for (package_android_layout_paths) |path| {
        const check = b.addSystemCommand(&.{ "test", "-f", path });
        check.step.dependOn(&package_android_layout_run.step);
        package_android_layout_step.dependOn(&check.step);
        mobile_examples_step.dependOn(&check.step);
    }
    const package_android_layout_contents = [_]FileContainsCheck{
        .{ .path = "examples/calculator/zig-out/package/test-android-layout/AndroidManifest.xml", .pattern = "package=\"dev.native_sdk.calculator\"" },
        .{ .path = "examples/calculator/zig-out/package/test-android-layout/AndroidManifest.xml", .pattern = "dev.native_sdk.host.NativeSdkActivity" },
        .{ .path = "examples/calculator/zig-out/package/test-android-layout/Host/NativeSdkActivity.java", .pattern = "InputMethodManager" },
        .{ .path = "examples/calculator/zig-out/package/test-android-layout/Host/android_host.c", .pattern = "native_sdk_app_render_pixels" },
    };
    for (package_android_layout_contents) |check_value| {
        const check = b.addRunArtifact(file_contains_checker);
        check.setCwd(b.path("."));
        check.addArg(check_value.path);
        check.addArg(check_value.pattern);
        check.step.dependOn(&package_android_layout_run.step);
        package_android_layout_step.dependOn(&check.step);
        mobile_examples_step.dependOn(&check.step);
    }
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-shell-metadata", "Verify shared mobile-shell metadata values", &.{
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".platforms = .{ \"ios\", \"android\" }" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".capabilities = .{ \"webview\", \"native_views\", \"native_module\" }" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".label = \"mobile-header\"" },
        .{ .path = "examples/mobile-shell/app.zon", .pattern = ".label = \"workspace\", .kind = \"webview\"" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-host-commands", "Verify mobile host command metadata values", &.{
        .{ .path = "examples/ios/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/ios/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/ios/app.zon", .pattern = ".label = \"mobile-header\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".id = \"mobile.back\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".id = \"mobile.refresh\"" },
        .{ .path = "examples/android/app.zon", .pattern = ".label = \"mobile-header\"" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-android-widget-ime", "Verify Android retained widget IME and action bridge", &.{
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "override fun onCreateInputConnection" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeIme(nativeApp, kind, text, cursor)" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_KIND_SET_COMPOSITION = 7" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_DRAG = 1 shl 8" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ACTION_DROP_FILES = 1 shl 9" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-widget-abi", "Verify mobile examples use stable widget ABI lookups", &.{
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_viewport_state_t" },
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "NATIVE_SDK_WIDGET_ROLE_RADIOGROUP = 21" },
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_app_scroll" },
        .{ .path = "examples/ios/NativeSdkIOSExample/native_sdk.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk.h", .pattern = "NATIVE_SDK_WIDGET_ROLE_RADIOGROUP = 21" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/mobile-canvas/ios/native_sdk_app.h", .pattern = "native_sdk_app_set_text_measure" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "NATIVE_SDK_WIDGET_ROLE_RADIO" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "childrenByParentId[node.parentId, default: []].append(element)" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "parent.accessibilityContainerType = .semanticGroup" },
        .{ .path = "examples/ios/NativeSdkIOSExample/NativeSdkHostViewController.swift", .pattern = "parent.isAccessibilityElement = false" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk.h", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeScroll(nativeApp" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "WIDGET_ROLE_RADIOGROUP -> \"android.widget.RadioGroup\"" },
        .{ .path = "examples/android/app/src/main/java/dev/native_sdk/examples/android/MainActivity.kt", .pattern = "nativeWidgetSemanticsByIdFields" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk_jni.c", .pattern = "native_sdk_app_widget_semantics_by_id" },
        .{ .path = "examples/android/app/src/main/cpp/native_sdk_jni.c", .pattern = "native_sdk_app_scroll" },
    });
    addFileContainsCheckStep(b, file_contains_checker, mobile_examples_step, "test-example-mobile-canvas-span-fonts", "Verify the iOS embed shim measures reserved span font ids with the macOS face mapping", &.{
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "static UIFont *NativeSdkItalicSansFont(UIFont *font)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "static UIFont *NativeSdkWeightedSansFont(" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Medium\", @\"Geist Medium\" ], UIFontWeightMedium, size)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], UIFontWeightBold, size)" },
        .{ .path = "examples/mobile-canvas/ios/main.m", .pattern = "NativeSdkItalicSansFont(NativeSdkWeightedSansFont(@[ @\"Geist-Bold\", @\"Geist Bold\" ], UIFontWeightBold, size))" },
    });

    const build_mobile_canvas_lib = b.addSystemCommand(&.{ "zig", "build", "lib" });
    build_mobile_canvas_lib.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_lib_step = b.step("test-example-mobile-canvas-lib", "Build the mobile-canvas embed static library through addMobileLib");
    mobile_canvas_lib_step.dependOn(&build_mobile_canvas_lib.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_lib.step);

    const build_mobile_canvas_store_lib = b.addSystemCommand(&.{ "zig", "build", "lib", "-Dstore=true" });
    build_mobile_canvas_store_lib.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_store_lib_step = b.step("test-example-mobile-canvas-lib-store", "Build a record-store-capable mobile embed static library");
    mobile_canvas_store_lib_step.dependOn(&build_mobile_canvas_store_lib.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_store_lib.step);

    const build_mobile_canvas_relational_lib = b.addSystemCommand(&.{ "zig", "build", "lib", "-Dsqlite=true", "--prefix", "zig-out/test-relational" });
    build_mobile_canvas_relational_lib.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_relational_lib_step = b.step("test-example-mobile-canvas-lib-sqlite", "Build a relational-SQLite-capable mobile embed static library");
    mobile_canvas_relational_lib_step.dependOn(&build_mobile_canvas_relational_lib.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_relational_lib.step);

    const build_mobile_canvas_both_storage_lib = b.addSystemCommand(&.{ "zig", "build", "lib", "-Dstore=true", "-Dsqlite=true", "--prefix", "zig-out/test-both-storage" });
    build_mobile_canvas_both_storage_lib.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_both_storage_lib_step = b.step("test-example-mobile-canvas-lib-storage", "Build both SQLite-backed mobile tiers with one vendored engine object");
    mobile_canvas_both_storage_lib_step.dependOn(&build_mobile_canvas_both_storage_lib.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_both_storage_lib.step);

    // Android cross-compile proofs: the capability-free archive remains pure
    // Zig, while the store variant must discover the NDK sysroot and compile
    // the vendored SQLite amalgamation for bionic. Keeping both catches a
    // capability branch that a host-only store build cannot exercise.
    const build_mobile_canvas_lib_android = b.addSystemCommand(&.{ "zig", "build", "lib", "-Dtarget=aarch64-linux-android" });
    build_mobile_canvas_lib_android.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_lib_android_step = b.step("test-example-mobile-canvas-lib-android", "Cross-compile the mobile-canvas embed static library for aarch64-linux-android");
    mobile_canvas_lib_android_step.dependOn(&build_mobile_canvas_lib_android.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_lib_android.step);

    const build_mobile_canvas_store_lib_android = b.addSystemCommand(&.{
        "zig",      "build",                      "lib", "-Dstore=true", "-Dtarget=aarch64-linux-android",
        "--prefix", "zig-out/test-android-store",
    });
    build_mobile_canvas_store_lib_android.setCwd(b.path("examples/mobile-canvas"));
    const mobile_canvas_store_lib_android_step = b.step("test-example-mobile-canvas-lib-android-store", "Cross-compile SQLite-backed mobile storage for aarch64-linux-android");
    mobile_canvas_store_lib_android_step.dependOn(&build_mobile_canvas_store_lib_android.step);
    mobile_examples_step.dependOn(&build_mobile_canvas_store_lib_android.step);

    // Apple SDK headers only exist on macOS. This is still part of the local
    // mobile aggregate there, and CI invokes the named step on its macOS tier.
    if (b.graph.host.result.os.tag == .macos) {
        const build_mobile_canvas_store_lib_ios = b.addSystemCommand(&.{
            "zig",      "build",                  "lib", "-Dstore=true", "-Dtarget=aarch64-ios-simulator",
            "--prefix", "zig-out/test-ios-store",
        });
        build_mobile_canvas_store_lib_ios.setCwd(b.path("examples/mobile-canvas"));
        const build_mobile_canvas_store_lib_ios_device = b.addSystemCommand(&.{
            "zig",      "build",                         "lib", "-Dstore=true", "-Dtarget=aarch64-ios",
            "--prefix", "zig-out/test-ios-device-store",
        });
        build_mobile_canvas_store_lib_ios_device.setCwd(b.path("examples/mobile-canvas"));
        const mobile_canvas_store_lib_ios_step = b.step("test-example-mobile-canvas-lib-ios-store", "Cross-compile SQLite-backed mobile storage for iOS simulator and device");
        mobile_canvas_store_lib_ios_step.dependOn(&build_mobile_canvas_store_lib_ios.step);
        mobile_canvas_store_lib_ios_step.dependOn(&build_mobile_canvas_store_lib_ios_device.step);
        mobile_examples_step.dependOn(&build_mobile_canvas_store_lib_ios.step);
        mobile_examples_step.dependOn(&build_mobile_canvas_store_lib_ios_device.step);
    }

    const examples_step = b.step("test-examples", "Run all example tests and layout checks");
    examples_step.dependOn(frontend_examples_step);
    examples_step.dependOn(native_examples_step);
    examples_step.dependOn(mobile_examples_step);

    const build_webview_cef = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=chromium", b.fmt("-Dcef-dir={s}", .{exampleCefDir(b, cef_dir)}) });
    build_webview_cef.setCwd(b.path("examples/webview"));
    const webview_cef_link_step = b.step("test-webview-cef-link", "Build the WebView example with Chromium/CEF");
    webview_cef_link_step.dependOn(&build_webview_cef.step);

    const webview_smoke_step = b.step("test-webview-smoke", "Run macOS WebView automation smoke test");
    const webview_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Djs-bridge=true" });
    webview_smoke_build.setCwd(b.path("examples/webview"));
    const webview_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/webview
        \\app="zig-out/bin/webview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\request='{"id":"smoke","command":"native.ping","payload":{"source":"smoke"}}'
        \\response_file=".zig-cache/native-sdk-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/native-sdk-automation
        \\rm -f .zig-cache/native-sdk-automation/snapshot.txt .zig-cache/native-sdk-automation/windows.txt .zig-cache/native-sdk-automation/command*.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/native-sdk-automation/command-1.txt
        \\"$app" > .zig-cache/native-sdk-webview-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-webview-smoke.log) ----" >&2; cat .zig-cache/native-sdk-webview-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && ! grep -q 'name="webview.load"' .zig-cache/native-sdk-webview-smoke.log; do attempts=$((attempts + 1)); sleep 0.1; done
        \\grep -q 'name="webview.load"' .zig-cache/native-sdk-webview-smoke.log || { echo "main window never loaded its webview source (blank window)" >&2; exit 1; }
        \\if grep -q 'name="dispatch.error"' .zig-cache/native-sdk-webview-smoke.log; then echo "runtime recorded a dispatch error during startup" >&2; exit 1; fi
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "native.ping did not succeed: $response" >&2; exit 1 ;; esac
        \\case "$response" in *'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-create","command":"native-sdk.webview.create","payload":{"label":"smoke","url":"https://example.com","frame":{"x":24,"y":24,"width":320,"height":220}}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview create did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-resize","command":"native-sdk.webview.setFrame","payload":{"label":"smoke","frame":{"x":36,"y":36,"width":420,"height":260}}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview resize did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-navigate","command":"native-sdk.webview.navigate","payload":{"label":"smoke","url":"https://example.com/?smoke=1"}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview navigate did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-close","command":"native-sdk.webview.close","payload":{"label":"smoke"}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "webview close did not succeed: $response" >&2; exit 1 ;; esac
        \\echo "webview smoke ok"
        ,
        "sh",
    });
    webview_smoke_run.addFileArg(cli_exe.getEmittedBin());
    webview_smoke_run.step.dependOn(&webview_smoke_build.step);
    webview_smoke_run.step.dependOn(&cli_exe.step);
    webview_smoke_step.dependOn(&webview_smoke_run.step);

    const native_shell_smoke_step = b.step("test-native-shell-smoke", "Run macOS native-shell automation smoke test");
    const native_shell_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Djs-bridge=true" });
    native_shell_smoke_build.setCwd(b.path("examples/native-shell"));
    const native_shell_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/native-shell
        \\app="zig-out/bin/native-shell"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\response_file="$automation_dir/bridge-response.txt"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir"/command*.txt "$response_file"
        \\"$app" > .zig-cache/native-sdk-native-shell-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-native-shell-smoke.log) ----" >&2; cat .zig-cache/native-sdk-native-shell-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "native-shell automation snapshot was not ready" >&2; exit 1 ;; esac
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$snapshot" in *'window @w1 "Native SDK Native Shell"'*) ;; *) echo "native-shell window was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*) ;; *) echo "toolbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/sidebar kind=sidebar'*) ;; *) echo "sidebar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/main kind=webview'*) ;; *) echo "main WebView was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/statusbar kind=statusbar'*) ;; *) echo "statusbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/refresh-icon kind=icon_button'*'accessibility_label="Refresh workspace"'*) ;; *) echo "refresh icon accessibility metadata was missing from snapshot" >&2; exit 1 ;; esac
        \\"$cli" automate focus refresh-button >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/refresh-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell refresh button did not receive focus" >&2; exit 1 ;; esac
        \\"$cli" automate focus-next >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/palette-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell focus-next did not move focus to palette button" >&2; exit 1 ;; esac
        \\"$cli" automate focus-previous >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  focus_line="$(printf '%s\n' "$snapshot" | grep -F 'view @w1/refresh-button kind=button' || true)"
        \\  case "$focus_line" in *'focused=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$focus_line" in *'focused=true'*) ;; *) echo "native-shell focus-previous did not return focus to refresh button" >&2; exit 1 ;; esac
        \\"$cli" automate resize 900 640 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK Native Shell" bounds=('*' 900x640)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK Native Shell" bounds=('*' 900x640)'*) ;; *) echo "native-shell window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*'bounds=(0,0 900x52)'*) ;; *) echo "native-shell toolbar did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/main kind=webview'*'bounds=(240,52 660x548)'*) ;; *) echo "native-shell main WebView did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/statusbar kind=statusbar'*'bounds=(240,600 660x40)'*) ;; *) echo "native-shell statusbar did not relayout after resize" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"native-shell-refresh","command":"native-sdk.command.invoke","payload":{"name":"app.refresh"}}' > "$automation_dir/command-1.txt"
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*'"name":"app.refresh"'*'"source":"bridge"'*) ;; *) echo "native-shell command bridge did not succeed: $response" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from bridge. Count 1.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from bridge. Count 1.'*) ;; *) echo "native-shell status view did not reflect bridge refresh" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from menu. Count 2.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from menu. Count 2.'*) ;; *) echo "native-shell menu command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate native-command app.refresh refresh-button >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from toolbar. Count 3.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from toolbar. Count 3.'*) ;; *) echo "native-shell toolbar command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate shortcut app.refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'Refreshed from shortcut. Count 4.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'Refreshed from shortcut. Count 4.'*) ;; *) echo "native-shell shortcut command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.preview.open >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'view @w1/preview kind=webview'*'bounds=(520,96 320x220)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/preview kind=webview'*'bounds=(520,96 320x220)'*) ;; *) echo "native-shell preview WebView was not created" >&2; exit 1 ;; esac
        \\"$cli" automate menu-command app.preview.close >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'view @w1/preview kind=webview'*) ;; *) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/preview kind=webview'*) echo "native-shell preview WebView was not closed" >&2; exit 1 ;; *) ;; esac
        \\echo "native-shell smoke ok"
        ,
        "sh",
    });
    native_shell_smoke_run.addFileArg(cli_exe.getEmittedBin());
    native_shell_smoke_run.step.dependOn(&native_shell_smoke_build.step);
    native_shell_smoke_run.step.dependOn(&cli_exe.step);
    native_shell_smoke_step.dependOn(&native_shell_smoke_run.step);

    const menu_bar_smoke_step = b.step("test-menu-bar-smoke", "Run zero-config TypeScript app-menu automation smoke test");
    const menu_bar_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    menu_bar_smoke_build.setCwd(b.path("examples/menu-bar"));
    const menu_bar_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/menu-bar
        \\app="zig-out/bin/menu-bar"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir"/command*.txt
        \\"$app" > .zig-cache/native-sdk-menu-bar-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-menu-bar-smoke.log) ----" >&2; cat .zig-cache/native-sdk-menu-bar-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "menu-bar automation snapshot was not ready" >&2; exit 1 ;; esac
        \\before="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$before" in *'command id="player.next" title="Next Track" enabled=true checked=false'*) ;; *) echo "app.zon command catalog was not loaded by the zero-config runner" >&2; exit 1 ;; esac
        \\case "$before" in *'app-menu title="Player" items=6'*) ;; *) echo "app.zon Player menu was not loaded by the zero-config runner" >&2; exit 1 ;; esac
        \\case "$before" in *'app-menu-item label="Next Track" command="player.next" enabled=true checked=false key="n" modifiers=(primary=true,command=false,control=false,option=false,shift=false)'*) ;; *) echo "app.zon player.next menu item was not loaded by the zero-config runner" >&2; exit 1 ;; esac
        \\case "$before" in
        \\  *'Ambient Coast'*) expected='Night Drive' ;;
        \\  *'Night Drive'*) expected='Paper Planes' ;;
        \\  *'Paper Planes'*) expected='Ambient Coast' ;;
        \\  *) echo "menu-bar snapshot did not expose the current TypeScript model track" >&2; exit 1 ;;
        \\esac
        \\"$cli" automate menu-command player.next >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *"$expected"*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *"$expected"*) ;; *) echo "app.zon menu command did not reach the zero-config TypeScript commandMsg mapper" >&2; exit 1 ;; esac
        \\echo "menu-bar smoke ok"
        ,
        "sh",
    });
    menu_bar_smoke_run.addFileArg(cli_exe.getEmittedBin());
    menu_bar_smoke_run.step.dependOn(&menu_bar_smoke_build.step);
    menu_bar_smoke_run.step.dependOn(&cli_exe.step);
    menu_bar_smoke_step.dependOn(&menu_bar_smoke_run.step);

    const gpu_surface_smoke_step = b.step("test-gpu-surface-smoke", "Run macOS GPU surface automation smoke test");
    // The GPU smoke apps are managed examples (no build.zig of their own),
    // so their binaries come from the CLI verb. -Doptimize=Debug keeps the
    // smoke binary at the debug shape the in-dir builds used (`native
    // build` injects ReleaseFast when no optimize flag is passed).
    const gpu_surface_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    gpu_surface_smoke_build.setCwd(b.path("examples/gpu-surface"));
    const gpu_surface_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-surface
        \\app="zig-out/bin/gpu-surface"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\# Startup latencies are load-sensitive on shared CI/agent machines.
        \\# NATIVE_SDK_SMOKE_BUDGET_MS raises the first-frame latency budget (default
        \\# stays 150 ms) and the automation-ready ceiling (default stays
        \\# 500 ms; the ceiling never drops below it) without weakening the
        \\# local defaults; every correctness assertion stays strict.
        \\smoke_budget_ms="${NATIVE_SDK_SMOKE_BUDGET_MS:-150}"
        \\case "$smoke_budget_ms" in ''|*[!0-9]*) echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1 ;; esac
        \\if [ "$smoke_budget_ms" -le 0 ]; then echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1; fi
        \\smoke_budget_ns=$((smoke_budget_ms * 1000000))
        \\ready_budget_ms="$smoke_budget_ms"
        \\if [ "$ready_budget_ms" -lt 500 ]; then ready_budget_ms=500; fi
        \\ready_budget_ns=$((ready_budget_ms * 1000000))
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir"/command*.txt
        \\"$app" > .zig-cache/native-sdk-gpu-surface-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-surface-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-surface-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "gpu-surface automation snapshot was not ready" >&2; exit 1 ;; esac
        \\ready_uptime="$(printf '%s\n' "$ready" | sed -n 's/.*runtime_uptime_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$ready_uptime" in ''|*[!0-9]*) echo "gpu-surface automation ready uptime was missing" >&2; exit 1 ;; esac
        \\if [ "$ready_uptime" -le 0 ] || [ "$ready_uptime" -gt "$ready_budget_ns" ]; then echo "gpu-surface automation ready exceeded $ready_budget_ms ms: $ready_uptime ns" >&2; exit 1; fi
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Surface"'*) ;; *) echo "gpu-surface window was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'accessibility_label="Animated GPU surface"'*) ;; *) echo "gpu_surface view was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/inspector kind=webview'*) ;; *) echo "inspector WebView was missing from snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/toolbar kind=toolbar'*) ;; *) echo "toolbar view was missing from snapshot" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'GPU frame 1 from canvas.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'GPU frame 1 from canvas.'*) ;; *) echo "gpu-surface frame event did not reach the runtime" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_nonblank=true'*) ;; *) echo "gpu-surface frame was not verified as nonblank" >&2; exit 1 ;; esac
        \\first_frame_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/canvas kind=gpu_surface.* gpu_first_frame_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$first_frame_latency" in ''|*[!0-9]*) echo "gpu-surface first frame latency was missing" >&2; exit 1 ;; esac
        \\if [ "$first_frame_latency" -le 0 ] || [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then echo "gpu-surface first frame exceeded $smoke_budget_ms ms: $first_frame_latency ns" >&2; exit 1; fi
        \\# The runtime publishes its own fixed 150 ms budget verdict. Within that
        \\# budget the verdict must agree exactly; beyond it (reachable only when
        \\# NATIVE_SDK_SMOKE_BUDGET_MS > 150) the runtime must report the overrun honestly.
        \\if [ "$first_frame_latency" -le 150000000 ]; then
        \\  case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_exceeded=0'*'gpu_first_frame_latency_budget_ok=true'*) ;; *) echo "gpu-surface first frame exceeded the latency budget" >&2; exit 1 ;; esac
        \\else
        \\  case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_ok=false'*) ;; *) echo "gpu-surface runtime did not report the first-frame budget overrun" >&2; exit 1 ;; esac
        \\fi
        \\"$cli" automate native-command gpu.refresh refresh >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'GPU surface refreshed from toolbar. Count 1.'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'view @w1/status-label kind=label'*'GPU surface refreshed from toolbar. Count 1.'*) ;; *) echo "gpu-surface refresh command did not update status" >&2; exit 1 ;; esac
        \\"$cli" automate resize 960 620 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Surface" bounds=('*' 960x620)'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Surface" bounds=('*' 960x620)'*) ;; *) echo "gpu-surface window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/canvas kind=gpu_surface'*'bounds=(0,0 680x534)'*) ;; *) echo "gpu_surface view did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/inspector kind=webview'*'bounds=(680,52 280x534)'*) ;; *) echo "inspector WebView did not relayout after resize" >&2; exit 1 ;; esac
        \\echo "gpu-surface smoke ok"
        ,
        "sh",
    });
    gpu_surface_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_surface_smoke_run.step.dependOn(&gpu_surface_smoke_build.step);
    gpu_surface_smoke_run.step.dependOn(&cli_exe.step);
    gpu_surface_smoke_step.dependOn(&gpu_surface_smoke_run.step);

    const writeback_smoke_step = b.step("test-writeback-smoke", "Run macOS provenance + write-back automation smoke test");
    // Debug on purpose: the write-back loop lives on the markup
    // interpreter + hot-reload watch, which apps enable in Debug
    // (including the generated TS-core wiring) - the release engine is
    // compiled and watchless by design.
    const writeback_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    writeback_smoke_build.setCwd(b.path("examples/kanban"));
    const writeback_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/kanban
        \\app="zig-out/bin/kanban"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir"/command*.txt "$automation_dir/provenance.txt"
        \\# The smoke edits src/app.native through the write-back verb and restores
        \\# it through the same verb; the trap restores from the backup on ANY
        \\# failure so an aborted run never leaves the example dirty.
        \\cp src/app.native .zig-cache/app.native.smoke-backup
        \\"$app" > .zig-cache/native-sdk-writeback-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; cp .zig-cache/app.native.smoke-backup src/app.native; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-writeback-smoke.log) ----" >&2; cat .zig-cache/native-sdk-writeback-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\"$cli" automate assert --timeout-ms 30000 'ready=true' >/dev/null
        \\snapshot="$(cat "$automation_dir/snapshot.txt")"
        \\button_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/kanban-canvas#\([0-9][0-9]*\) role=button name="Add card".*/\1/p' | head -n 1)"
        \\case "$button_id" in ''|*[!0-9]*) echo "writeback smoke: Add card button id was missing from the snapshot" >&2; exit 1 ;; esac
        \\heading_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/kanban-canvas#\([0-9][0-9]*\) role=text name="Todo".*/\1/p' | head -n 1)"
        \\case "$heading_id" in ''|*[!0-9]*) echo "writeback smoke: Todo heading id was missing from the snapshot" >&2; exit 1 ;; esac
        \\# 1. Provenance: the button reports its authored span in the root file.
        \\provenance="$("$cli" automate provenance kanban-canvas "$button_id" 2>/dev/null)"
        \\case "$provenance" in *"authored=markup"*"root=src/app.native"*) ;; *) echo "writeback smoke: button provenance was not markup-authored: $provenance" >&2; exit 1 ;; esac
        \\case "$provenance" in *"node file=src/app.native"*) ;; *) echo "writeback smoke: button provenance named the wrong file: $provenance" >&2; exit 1 ;; esac
        \\# 2. Imported-loop provenance: a card title reports its authored
        \\# component file plus its iteration key.
        \\card_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/kanban-canvas#\([0-9][0-9]*\) role=text name="Retry failed agent runs".*/\1/p' | head -n 1)"
        \\case "$card_id" in ''|*[!0-9]*) echo "writeback smoke: card text id was missing from the snapshot" >&2; exit 1 ;; esac
        \\card_provenance="$("$cli" automate provenance kanban-canvas "$card_id" 2>/dev/null)"
        \\case "$card_provenance" in *"node file=src/components/board-column.native"*) ;; *) echo "writeback smoke: card provenance named the wrong file: $card_provenance" >&2; exit 1 ;; esac
        \\case "$card_provenance" in *"keys="*) ;; *) echo "writeback smoke: card provenance missed the iteration key: $card_provenance" >&2; exit 1 ;; esac
        \\# 3. Write-back: flip the Todo heading through the verb; the app's own
        \\# hot-reload watch picks the file change up and repaints.
        \\"$cli" automate edit kanban-canvas "$heading_id" set-text "Backlog" >/dev/null 2>&1
        \\"$cli" automate assert --timeout-ms 15000 'role=text name="Backlog"' >/dev/null
        \\# The file diff is byte-exact: exactly the heading bytes changed.
        \\sed 's/>Todo</>Backlog</' .zig-cache/app.native.smoke-backup > .zig-cache/app.native.smoke-expected
        \\cmp -s .zig-cache/app.native.smoke-expected src/app.native || { echo "writeback smoke: the edit was not minimal-diff" >&2; exit 1; }
        \\# 4. Flip it back through the same verb: the structural id survived the
        \\# reload (text is not identity), and the file restores byte-identical.
        \\"$cli" automate edit kanban-canvas "$heading_id" set-text "Todo" >/dev/null 2>&1
        \\"$cli" automate assert --timeout-ms 15000 'role=text name="Todo"' >/dev/null
        \\cmp -s .zig-cache/app.native.smoke-backup src/app.native || { echo "writeback smoke: the flip-back did not restore the file byte-identically" >&2; exit 1; }
        \\# 5. Refusal: an edit that fails validation leaves the file untouched.
        \\if "$cli" automate edit kanban-canvas "$button_id" set-attr bogus 1 >/dev/null 2>&1; then echo "writeback smoke: an invalid edit was not refused" >&2; exit 1; fi
        \\cmp -s .zig-cache/app.native.smoke-backup src/app.native || { echo "writeback smoke: a refused edit touched the file" >&2; exit 1; }
        \\echo "writeback smoke ok"
        ,
        "sh",
    });
    writeback_smoke_run.addFileArg(cli_exe.getEmittedBin());
    writeback_smoke_run.step.dependOn(&writeback_smoke_build.step);
    writeback_smoke_run.step.dependOn(&cli_exe.step);
    writeback_smoke_step.dependOn(&writeback_smoke_run.step);

    const gpu_dashboard_smoke_step = b.step("test-gpu-dashboard-smoke", "Run macOS GPU dashboard automation smoke test");
    const gpu_dashboard_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    gpu_dashboard_smoke_build.setCwd(b.path("examples/gpu-dashboard"));
    const gpu_dashboard_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-dashboard
        \\app="zig-out/bin/gpu-dashboard"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\# First-frame latency is load-sensitive: a cold file cache or CI/agent
        \\# machine contention can blow the 150 ms budget while the frame itself
        \\# is presented and correct. Load tolerance without weakening the proof:
        \\#   (a) NATIVE_SDK_SMOKE_BUDGET_MS raises the smoke's latency budget (default
        \\#       stays 150 ms) and the automation-ready ceiling (default stays
        \\#       500 ms; the ceiling never drops below it), and
        \\#   (b) a budget-only overrun relaunches the app once and re-measures.
        \\# Every correctness assertion (frame presented, packet-representable,
        \\# retained content, widget semantics) stays strict on whichever launch
        \\# survives, and the runtime's own fixed 150 ms budget verdict is still
        \\# asserted verbatim whenever the measured latency is within 150 ms.
        \\smoke_budget_ms="${NATIVE_SDK_SMOKE_BUDGET_MS:-150}"
        \\case "$smoke_budget_ms" in ''|*[!0-9]*) echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1 ;; esac
        \\if [ "$smoke_budget_ms" -le 0 ]; then echo "NATIVE_SDK_SMOKE_BUDGET_MS must be a positive integer of milliseconds: $smoke_budget_ms" >&2; exit 1; fi
        \\smoke_budget_ns=$((smoke_budget_ms * 1000000))
        \\ready_budget_ms="$smoke_budget_ms"
        \\if [ "$ready_budget_ms" -lt 500 ]; then ready_budget_ms=500; fi
        \\ready_budget_ns=$((ready_budget_ms * 1000000))
        \\# gpu-dashboard is a native-only app (nothing in app.zon declares web
        \\# use), so its macOS host must never boot the WebKit stack: WKWebView
        \\# instantiation spawns com.apple.WebKit.* XPC helpers. They are
        \\# launchd-parented (not app children), so the honest cheap probe is
        \\# the machine-wide helper set before launch vs at the end of the
        \\# session — a NEW helper during this headless smoke window means the
        \\# lazy main-WebView path regressed (the failure lists the processes
        \\# so a coincidental web app launched mid-smoke is tellable apart).
        \\webkit_helpers() { pgrep -f 'com\.apple\.WebKit\.(WebContent|Networking|GPU)' 2>/dev/null | tr '\n' ' '; }
        \\webkit_before="$(webkit_helpers)"
        \\pid=""
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-dashboard-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-dashboard-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\stop_app() {
        \\  kill "$pid" >/dev/null 2>&1 || true
        \\  wait "$pid" >/dev/null 2>&1 || true
        \\  pid=""
        \\}
        \\launch_and_measure_first_frame() {
        \\  rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir"/command*.txt
        \\  "$app" > .zig-cache/native-sdk-gpu-dashboard-smoke.log 2>&1 &
        \\  pid=$!
        \\  ready="$("$cli" automate wait 2>&1)"
        \\  case "$ready" in *"ready=true"*) ;; *) echo "gpu-dashboard automation snapshot was not ready" >&2; exit 1 ;; esac
        \\  ready_uptime="$(printf '%s\n' "$ready" | sed -n 's/.*runtime_uptime_ns=\([0-9][0-9]*\).*/\1/p')"
        \\  case "$ready_uptime" in ''|*[!0-9]*) echo "gpu-dashboard automation ready uptime was missing" >&2; exit 1 ;; esac
        \\  if [ "$ready_uptime" -le 0 ] || [ "$ready_uptime" -gt "$ready_budget_ns" ]; then echo "gpu-dashboard automation ready exceeded $ready_budget_ms ms: $ready_uptime ns" >&2; exit 1; fi
        \\  attempts=0
        \\  while [ "$attempts" -lt 50 ]; do
        \\    snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\    case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard"'*'view @w1/dashboard-canvas kind=gpu_surface'*'accessibility_label="Native-rendered product dashboard canvas"'*) break ;; esac
        \\    attempts=$((attempts + 1))
        \\    sleep 0.1
        \\  done
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard"'*) ;; *) echo "gpu-dashboard window was missing from snapshot" >&2; exit 1 ;; esac
        \\  case "$snapshot" in *'view @w1/main kind=webview'*) echo "dashboard should not create an implicit main WebView" >&2; exit 1 ;; *) ;; esac
        \\  case "$snapshot" in *'source kind=html bytes=0'*) echo "dashboard should not publish an empty default WebView source" >&2; exit 1 ;; *) ;; esac
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'accessibility_label="Native-rendered product dashboard canvas"'*) ;; *) echo "dashboard GPU canvas was missing from snapshot" >&2; exit 1 ;; esac
        \\  attempts=0
        \\  while [ "$attempts" -lt 50 ]; do
        \\    snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\    case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=68'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\    attempts=$((attempts + 1))
        \\    sleep 0.1
        \\  done
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=68'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard GPU canvas did not present the retained display list as a packet" >&2; exit 1 ;; esac
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'canvas_commands=68'*'widget_semantics=48'*) ;; *) echo "dashboard GPU canvas was missing retained commands or widget semantics" >&2; exit 1 ;; esac
        \\  first_frame_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_first_frame_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\  case "$first_frame_latency" in ''|*[!0-9]*) echo "dashboard GPU first frame latency was missing" >&2; exit 1 ;; esac
        \\  if [ "$first_frame_latency" -le 0 ]; then echo "dashboard GPU first frame latency was not recorded" >&2; exit 1; fi
        \\}
        \\launch_and_measure_first_frame
        \\if [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then
        \\  echo "dashboard GPU first frame exceeded $smoke_budget_ms ms ($first_frame_latency ns); relaunching once to rule out machine load" >&2
        \\  stop_app
        \\  launch_and_measure_first_frame
        \\fi
        \\if [ "$first_frame_latency" -gt "$smoke_budget_ns" ]; then echo "dashboard GPU first frame exceeded $smoke_budget_ms ms on both launches: $first_frame_latency ns" >&2; exit 1; fi
        \\# The runtime publishes its own fixed 150 ms budget verdict. Within that
        \\# budget the verdict must agree exactly; beyond it (reachable only when
        \\# NATIVE_SDK_SMOKE_BUDGET_MS > 150) the runtime must report the overrun honestly.
        \\if [ "$first_frame_latency" -le 150000000 ]; then
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_exceeded=0'*'gpu_first_frame_latency_budget_ok=true'*) ;; *) echo "dashboard GPU first frame exceeded the latency budget" >&2; exit 1 ;; esac
        \\else
        \\  case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_first_frame_latency_budget_ns=150000000'*'gpu_first_frame_latency_budget_ok=false'*) ;; *) echo "dashboard runtime did not report the first-frame budget overrun" >&2; exit 1 ;; esac
        \\fi
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'role=text name="Canvas frame:'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\widget_line() {
        \\  printf '%s\n' "$snapshot" | grep -F "$1" | head -1
        \\}
        \\line="$(widget_line 'role=tab name="Dashboard mode"')"
        \\case "$line" in *'actions=[focus,press,select]'*) ;; *) echo "dashboard toolbar mode semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=button name="Refresh dashboard"')"
        \\case "$line" in *'actions=[focus,press]'*) ;; *) echo "dashboard toolbar refresh semantics were missing" >&2; exit 1 ;; esac
        \\# CoreText-backed layout metrics: the refresh button must be sized by the
        \\# platform text measure provider, not the deterministic estimator
        \\# (estimateTextWidthForFont sizes "Refresh" at 14px to 51.842 -> 75.841995 wide).
        \\case "$line" in *'75.841995x34'*) echo "dashboard refresh button was sized by the estimator; platform text measurement is inactive" >&2; exit 1 ;; esac
        \\refresh_width="$(printf '%s\n' "$line" | sed -n 's/.*bounds=([0-9.,-]* \([0-9.]*\)x[0-9.]*).*/\1/p')"
        \\case "$refresh_width" in ''|*[!0-9.]*) echo "dashboard refresh button width was missing" >&2; exit 1 ;; esac
        \\if [ "$(printf '%s\n' "$refresh_width < 50 || $refresh_width > 110" | bc)" -eq 1 ]; then echo "dashboard refresh button width was implausible: $refresh_width" >&2; exit 1; fi
        \\line="$(widget_line 'role=button name="Live render status"')"
        \\case "$line" in *'actions=[focus,press]'*) ;; *) echo "dashboard live render button semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=textbox name="Forecast amount"')"
        \\case "$line" in *'text="$13.4M"'*) ;; *) echo "dashboard forecast textbox semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=dialog name="Revenue filter popover"')"
        \\case "$line" in '') echo "dashboard popover semantics were missing" >&2; exit 1 ;; esac
        \\line="$(widget_line 'role=text name="Canvas frame:')"
        \\case "$line" in *'packet ok'*) ;; *) echo "dashboard canvas status semantics were missing" >&2; exit 1 ;; esac
        \\gpu_frame_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_frame=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\canvas_revision_from_snapshot() {
        \\  printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* canvas_revision=\([0-9][0-9]*\).*/\1/p'
        \\}
        \\snapshot_contains() {
        \\  case "$snapshot" in *"$1"*) return 0 ;; *) return 1 ;; esac
        \\}
        \\canvas_revision_before_resize="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_before_resize" in ''|*[!0-9]*) echo "dashboard canvas revision was missing before resize" >&2; exit 1 ;; esac
        \\"$cli" automate resize 1120 700 >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard" bounds=('*' 1120x700)'*'view @w1/dashboard-canvas kind=gpu_surface'*'bounds=(0,0 1120x700)'*'gpu_nonblank=true'*'canvas_commands=68'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$snapshot" in *'window @w1 "Native SDK GPU Dashboard" bounds=('*' 1120x700)'*) ;; *) echo "dashboard window resize was not reflected in snapshot" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'bounds=(0,0 1120x700)'*) ;; *) echo "dashboard GPU canvas did not relayout after resize" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_commands=68'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard GPU canvas did not remain packet-renderable after resize" >&2; exit 1 ;; esac
        \\canvas_revision_after_resize="$(canvas_revision_from_snapshot)"
        \\case "$canvas_revision_after_resize" in ''|*[!0-9]*) echo "dashboard canvas revision was missing after resize" >&2; exit 1 ;; esac
        \\if [ "$canvas_revision_after_resize" -lt "$canvas_revision_before_resize" ]; then echo "dashboard canvas revision went backwards after resize: $canvas_revision_before_resize -> $canvas_revision_after_resize" >&2; exit 1; fi
        \\gpu_frame_before="$(gpu_frame_from_snapshot)"
        \\case "$gpu_frame_before" in ''|*[!0-9]*) gpu_frame_before=0 ;; esac
        \\gpu_frame_after="$gpu_frame_before"
        \\switch_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/dashboard-canvas#\([0-9][0-9]*\) role=switch name="Auto refresh".*/\1/p' | head -1)"
        \\case "$switch_id" in ''|*[!0-9]*) echo "dashboard auto refresh switch id was missing from snapshot" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click dashboard-canvas "$switch_id" >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\  gpu_frame_after="$(gpu_frame_from_snapshot)"
        \\  case "$gpu_frame_after" in ''|*[!0-9]*) gpu_frame_after=0 ;; esac
        \\  if [ "$gpu_frame_after" -gt "$gpu_frame_before" ]; then
        \\    if snapshot_contains 'Auto refresh off.' && snapshot_contains 'view @w1/dashboard-canvas kind=gpu_surface' && snapshot_contains 'canvas_frame_full_repaint=false' && snapshot_contains 'canvas_frame_pipeline_uploads=0' && snapshot_contains 'canvas_frame_glyph_uploads=0' && snapshot_contains 'canvas_frame_text_uploads=0' && snapshot_contains 'canvas_frame_gpu_packet_unsupported=0' && snapshot_contains 'canvas_frame_gpu_packet_representable=true'; then
        \\      switch_line="$(printf '%s\n' "$snapshot" | grep -F 'role=switch name="Auto refresh"' | head -1)"
        \\      case "$switch_line" in *'value=0'*) break ;; esac
        \\    fi
        \\  fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if [ "$gpu_frame_after" -le "$gpu_frame_before" ]; then echo "dashboard switch click did not request a GPU frame" >&2; exit 1; fi
        \\case "$snapshot" in *'Auto refresh off.'*) ;; *) echo "dashboard switch click did not update status" >&2; exit 1 ;; esac
        \\switch_line="$(printf '%s\n' "$snapshot" | grep -F 'role=switch name="Auto refresh"' | head -1)"
        \\case "$switch_line" in *'value=0'*) ;; *) echo "dashboard switch click did not route through pointer input" >&2; exit 1 ;; esac
        \\case "$snapshot" in *'view @w1/dashboard-canvas kind=gpu_surface'*'canvas_frame_full_repaint=false'*'canvas_frame_pipeline_uploads=0'*'canvas_frame_glyph_uploads=0'*'canvas_frame_text_uploads=0'*'canvas_frame_gpu_packet_unsupported=0'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "dashboard switch click did not present an incremental GPU packet without interaction-time uploads" >&2; exit 1 ;; esac
        \\input_timestamp="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_input_timestamp_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_timestamp" in ''|*[!0-9]*) echo "dashboard GPU input timestamp was missing after widget interaction" >&2; exit 1 ;; esac
        \\if [ "$input_timestamp" -le 0 ]; then echo "dashboard GPU input timestamp was not recorded" >&2; exit 1; fi
        \\input_latency="$(printf '%s\n' "$snapshot" | sed -n 's/.*view @w1\/dashboard-canvas kind=gpu_surface.* gpu_input_latency_ns=\([0-9][0-9]*\).*/\1/p')"
        \\case "$input_latency" in ''|*[!0-9]*) echo "dashboard GPU input latency was missing after widget interaction" >&2; exit 1 ;; esac
        \\# --- Incremental pixel equivalence: relaunch under the host's verify
        \\# mode, where every scissored dirty update is byte-compared against a
        \\# from-scratch full redraw of the retained command list. Clicks, the
        \\# live-pulse animation, and a mid-animation resize drive scissored
        \\# patches; the verify counters must show checks with zero mismatches.
        \\stop_app
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir"/command*.txt
        \\verify_log=".zig-cache/native-sdk-gpu-dashboard-verify.log"
        \\NATIVE_SDK_GPU_VERIFY_INCREMENTAL=1 "$app" > "$verify_log" 2>&1 &
        \\pid=$!
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "gpu-dashboard verify relaunch was not ready" >&2; exit 1 ;; esac
        \\snapshot="$(cat "$automation_dir/snapshot.txt" 2>/dev/null || true)"
        \\switch_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/dashboard-canvas#\([0-9][0-9]*\) role=switch name="Auto refresh".*/\1/p' | head -1)"
        \\live_id="$(printf '%s\n' "$snapshot" | sed -n 's/.*widget @w1\/dashboard-canvas#\([0-9][0-9]*\) role=button name="Live render status".*/\1/p' | head -1)"
        \\case "$switch_id" in ''|*[!0-9]*) echo "dashboard verify switch id was missing" >&2; exit 1 ;; esac
        \\case "$live_id" in ''|*[!0-9]*) echo "dashboard verify live button id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click dashboard-canvas "$switch_id" >/dev/null 2>&1
        \\sleep 0.4
        \\"$cli" automate widget-click dashboard-canvas "$live_id" >/dev/null 2>&1
        \\sleep 0.3
        \\"$cli" automate resize 1120 700 >/dev/null 2>&1
        \\sleep 0.5
        \\"$cli" automate widget-click dashboard-canvas "$live_id" >/dev/null 2>&1
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  if grep -q "gpu incremental verify view=dashboard-canvas checks=" "$verify_log" 2>/dev/null; then break; fi
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\if ! grep -q "gpu incremental verify view=dashboard-canvas checks=" "$verify_log" 2>/dev/null; then echo "dashboard verify mode recorded no incremental checks" >&2; exit 1; fi
        \\if grep -q "verify MISMATCH" "$verify_log" 2>/dev/null; then echo "dashboard incremental present diverged from a full redraw:" >&2; grep "verify MISMATCH" "$verify_log" >&2; exit 1; fi
        \\if grep "gpu incremental verify view=dashboard-canvas checks=" "$verify_log" | grep -qv "mismatches=0"; then echo "dashboard incremental verify reported mismatches" >&2; exit 1; fi
        \\# The whole session ran (two launches, clicks, resizes): a native-only
        \\# macOS app must have spawned ZERO new WebKit helper processes.
        \\webkit_after="$(webkit_helpers)"
        \\new_webkit=""
        \\for helper_pid in $webkit_after; do
        \\  case " $webkit_before " in *" $helper_pid "*) ;; *) new_webkit="$new_webkit $helper_pid" ;; esac
        \\done
        \\if [ -n "$new_webkit" ]; then
        \\  echo "native-only gpu-dashboard session spawned WebKit helper processes:$new_webkit" >&2
        \\  for helper_pid in $new_webkit; do ps -p "$helper_pid" -o pid,ppid,command >&2 || true; done
        \\  exit 1
        \\fi
        \\echo "zero new WebKit helper processes during the native-only session"
        \\echo "gpu-dashboard smoke ok"
        ,
        "sh",
    });
    gpu_dashboard_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_dashboard_smoke_run.step.dependOn(&gpu_dashboard_smoke_build.step);
    gpu_dashboard_smoke_run.step.dependOn(&cli_exe.step);
    gpu_dashboard_smoke_step.dependOn(&gpu_dashboard_smoke_run.step);

    // Percentile performance check — a single-sample gate was noise-dominated,
    // so this asserts p90 over N launches. Deliberately NOT part of
    // `zig build test` or the fast gate tier: N launches are slow and the
    // numbers only mean something on a controlled machine. Runs via
    // `scripts/gate.sh full --perf` locally and a dedicated macos-14 CI job.
    // Knobs: NATIVE_SDK_PERF_LAUNCHES, NATIVE_SDK_PERF_INTERACTIONS, NATIVE_SDK_PERF_BUDGET_MS,
    // NATIVE_SDK_PERF_INPUT_BUDGET_MS, and NATIVE_SDK_PERF_ANIMATION_* — see
    // scripts/perf-gpu-dashboard.sh.
    const gpu_dashboard_perf_step = b.step("test-gpu-dashboard-perf", "Run macOS GPU dashboard percentile performance check (N launches; slow)");
    const gpu_dashboard_perf_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    gpu_dashboard_perf_build.setCwd(b.path("examples/gpu-dashboard"));
    const gpu_dashboard_perf_run = b.addSystemCommand(&.{ "sh", "scripts/perf-gpu-dashboard.sh" });
    gpu_dashboard_perf_run.addFileArg(cli_exe.getEmittedBin());
    gpu_dashboard_perf_run.step.dependOn(&gpu_dashboard_perf_build.step);
    gpu_dashboard_perf_run.step.dependOn(&cli_exe.step);
    gpu_dashboard_perf_step.dependOn(&gpu_dashboard_perf_run.step);

    const canvas_preview_smoke_step = b.step("test-canvas-preview-smoke", "Run macOS canvas + webview (both-in-one-window) automation smoke test");
    const canvas_preview_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    canvas_preview_smoke_build.setCwd(b.path("examples/canvas-preview"));
    const canvas_preview_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/canvas-preview
        \\app="zig-out/bin/canvas-preview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir"/command*.txt "$automation_dir/screenshot-preview-canvas.png"
        \\"$app" > .zig-cache/native-sdk-canvas-preview-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-canvas-preview-smoke.log) ----" >&2; cat .zig-cache/native-sdk-canvas-preview-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "canvas-preview automation snapshot was not ready" >&2; exit 1 ;; esac
        \\# Both architectures live in window 1: a presenting Metal canvas and
        \\# a live WKWebView on a real https URL — with no implicit main webview.
        \\"$cli" automate assert 'view @w1/preview-canvas kind=gpu_surface.*gpu_nonblank=true' 'view @w1/preview kind=webview.*url="https://example.com/"'
        \\"$cli" automate assert --absent 'view @w1/main kind=webview' 'source kind=html bytes=0'
        \\# The webview pane is snapped to the canvas anchor widget: right of
        \\# the 224pt sidebar, below the 56pt toolbar.
        \\preview_line="$(grep 'view @w1/preview kind=webview' "$automation_dir/snapshot.txt" | head -1)"
        \\preview_x="$(printf '%s\n' "$preview_line" | sed -n 's/.*bounds=(\([0-9.]*\),.*/\1/p')"
        \\case "$preview_x" in ''|*[!0-9.]*) echo "canvas-preview webview x was missing" >&2; exit 1 ;; esac
        \\if [ "$(printf '%s\n' "$preview_x < 224" | bc)" -eq 1 ]; then echo "canvas-preview webview was not snapped right of the sidebar: x=$preview_x" >&2; exit 1; fi
        \\# Navigation from a Msg: the app command switches the model URL and
        \\# the runtime navigates the platform webview.
        \\"$cli" automate native-command app.docs >/dev/null 2>&1
        \\"$cli" automate assert 'view @w1/preview kind=webview.*url="https://native-sdk.dev/"' 'name="URL: https://native-sdk.dev/"'
        \\# Resize keeps the pane snapped to the anchor widget's new frame:
        \\# the panel right of the 224pt sidebar and below the 56pt toolbar.
        \\"$cli" automate resize 1200 800 >/dev/null 2>&1
        \\"$cli" automate assert 'window @w1 "Native SDK Canvas Preview" bounds=.*1200x800' 'view @w1/preview kind=webview.*bounds=.224,56 976x744'
        \\# Canvas screenshot evidence (reference-rendered PNG of the chrome).
        \\"$cli" automate screenshot preview-canvas >/dev/null 2>&1
        \\test -s "$automation_dir/screenshot-preview-canvas.png" || { echo "canvas-preview screenshot was empty" >&2; exit 1; }
        \\echo "canvas-preview smoke ok"
        ,
        "sh",
    });
    canvas_preview_smoke_run.addFileArg(cli_exe.getEmittedBin());
    canvas_preview_smoke_run.step.dependOn(&canvas_preview_smoke_build.step);
    canvas_preview_smoke_run.step.dependOn(&cli_exe.step);
    canvas_preview_smoke_step.dependOn(&canvas_preview_smoke_run.step);

    const gpu_components_smoke_step = b.step("test-gpu-components-smoke", "Run the TypeScript component gallery automation smoke test");
    const gpu_components_smoke_build = managedExampleRun(b, cli_exe, &.{ "build", "-Dplatform=macos", "-Dweb-engine=system", "-Dautomation=true", "-Doptimize=Debug" });
    gpu_components_smoke_build.setCwd(b.path("examples/gpu-components"));
    const gpu_components_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/gpu-components
        \\app="zig-out/bin/gpu-components"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\automation_dir=".zig-cache/native-sdk-automation"
        \\mkdir -p "$automation_dir"
        \\rm -f "$automation_dir/snapshot.txt" "$automation_dir/accessibility.txt" "$automation_dir/windows.txt" "$automation_dir/screenshot-components-canvas.png" "$automation_dir/screenshot-components-house.png" "$automation_dir/screenshot-components-geist.png" "$automation_dir"/command*.txt
        \\"$app" > .zig-cache/native-sdk-gpu-components-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-gpu-components-smoke.log) ----" >&2; cat .zig-cache/native-sdk-gpu-components-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\ready="$("$cli" automate wait 2>&1)"
        \\case "$ready" in *"ready=true"*) ;; *) echo "gpu-components automation snapshot was not ready" >&2; exit 1 ;; esac
        \\snapshot="$automation_dir/snapshot.txt"
        \\widget_id() {
        \\  role="$1"
        \\  name="$2"
        \\  sed -n "s/.*widget @w1\\/components-canvas#\\([0-9][0-9]*\\) role=$role name=\\\"$name\\\".*/\\1/p" "$snapshot" | head -1
        \\}
        \\attempts=0
        \\while [ "$attempts" -lt 50 ]; do
        \\  ready_snapshot="$(cat "$snapshot" 2>/dev/null || true)"
        \\  case "$ready_snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_frame_gpu_packet_representable=true'*) break ;; esac
        \\  attempts=$((attempts + 1))
        \\  sleep 0.1
        \\done
        \\case "$ready_snapshot" in *'window @w1 "Native SDK GPU Components"'*) ;; *) echo "gpu-components window was missing" >&2; exit 1 ;; esac
        \\case "$ready_snapshot" in *'view @w1/components-canvas kind=gpu_surface'*'gpu_nonblank=true'*'canvas_frame_gpu_packet_representable=true'*) ;; *) echo "component gallery GPU surface was not ready" >&2; exit 1 ;; esac
        \\case "$ready_snapshot" in *'view @w1/main kind=webview'*) echo "component gallery created an implicit WebView" >&2; exit 1 ;; *) ;; esac
        \\"$cli" automate assert 'role=tree name="Components"' 'role=treeitem name="Components".*state=\[expanded\]' 'role=treeitem name="Accordion".*state=\[selected\]' 'role=group name="Details".*state=\[selected,expanded\]' 'name="Accordion details are visible. The model owns this expanded state."'
        \\"$cli" automate assert 'role=group name="Theme pack"' 'role=group name="Color scheme"' 'role=group name="Theme accent"' 'role=button name="Default".*state=\[selected\]' 'role=button name="Geist"' 'role=button name="System".*state=\[selected\]' 'role=button name="Pink"' 'role=button name="Teal"'
        \\"$cli" automate screenshot components-canvas >/dev/null 2>&1
        \\cp "$automation_dir/screenshot-components-canvas.png" "$automation_dir/screenshot-components-house.png"
        \\rm -f "$automation_dir/screenshot-components-canvas.png"
        \\theme_geist_id="$(widget_id button Geist)"
        \\case "$theme_geist_id" in ''|*[!0-9]*) echo "Geist theme toggle id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click components-canvas "$theme_geist_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=button name="Geist".*state=\[[^]]*selected'
        \\"$cli" automate screenshot components-canvas >/dev/null 2>&1
        \\cp "$automation_dir/screenshot-components-canvas.png" "$automation_dir/screenshot-components-geist.png"
        \\test -s "$automation_dir/screenshot-components-house.png" || { echo "house theme screenshot was empty" >&2; exit 1; }
        \\test -s "$automation_dir/screenshot-components-geist.png" || { echo "Geist theme screenshot was empty" >&2; exit 1; }
        \\if cmp -s "$automation_dir/screenshot-components-house.png" "$automation_dir/screenshot-components-geist.png"; then echo "theme toggle did not change rendered pixels" >&2; exit 1; fi
        \\accordion_id="$(widget_id group Details)"
        \\case "$accordion_id" in ''|*[!0-9]*) echo "accordion id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas "$accordion_id" toggle >/dev/null 2>&1
        \\"$cli" automate assert --absent 'name="Accordion details are visible. The model owns this expanded state."'
        \\"$cli" automate widget-action components-canvas "$accordion_id" toggle >/dev/null 2>&1
        \\"$cli" automate assert 'name="Accordion details are visible. The model owns this expanded state."'
        \\accordion_row_id="$(widget_id treeitem Accordion)"
        \\case "$accordion_row_id" in ''|*[!0-9]*) echo "accordion navigation id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas "$accordion_row_id" focus >/dev/null 2>&1
        \\arrow_count=0
        \\while [ "$arrow_count" -lt 33 ]; do
        \\  "$cli" automate widget-key components-canvas arrowdown >/dev/null 2>&1
        \\  arrow_count=$((arrow_count + 1))
        \\done
        \\"$cli" automate assert 'role=treeitem name="Tree".*state=\[[^]]*selected' 'role=text name="Tree"'
        \\scroll_line="$(grep 'name="Scrollable component tree"' "$snapshot" | head -1)"
        \\case "$scroll_line" in *'scroll=[offset=0,'*) echo "tree selection did not scroll the final row into view" >&2; exit 1 ;; *'scroll=[offset='*) ;; *) echo "component tree scroll semantics were missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-key components-canvas arrowleft >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas arrowleft >/dev/null 2>&1
        \\"$cli" automate assert --absent 'role=treeitem name="Accordion"'
        \\"$cli" automate widget-key components-canvas arrowright >/dev/null 2>&1
        \\"$cli" automate assert 'role=treeitem name="Accordion"'
        \\dropdown_row_id="$(widget_id treeitem "Dropdown Menu")"
        \\case "$dropdown_row_id" in ''|*[!0-9]*) echo "dropdown navigation id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas "$dropdown_row_id" press >/dev/null 2>&1
        \\"$cli" automate assert 'role=text name="Dropdown Menu"' 'role=button name="Actions"'
        \\actions_id="$(widget_id button Actions)"
        \\case "$actions_id" in ''|*[!0-9]*) echo "dropdown trigger id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click components-canvas "$actions_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=menu name=""' 'role=menuitem name="Duplicate"' 'role=menuitem name="Rename"' 'role=menuitem name="Download"' 'role=menuitem name="Delete"'
        \\"$cli" automate widget-key components-canvas arrowdown >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas arrowdown >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas enter >/dev/null 2>&1
        \\"$cli" automate assert --absent 'role=menu name=""' 'role=menuitem name="Duplicate"'
        \\"$cli" automate assert 'role=text name="Last action: Rename"'
        \\"$cli" automate widget-click components-canvas "$actions_id" >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas arrowup >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas enter >/dev/null 2>&1
        \\"$cli" automate assert 'role=text name="Last action: Delete"'
        \\select_row_id="$(widget_id treeitem Select)"
        \\case "$select_row_id" in ''|*[!0-9]*) echo "select navigation id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas "$select_row_id" press >/dev/null 2>&1
        \\"$cli" automate assert 'role=text name="Select"' 'role=button name="Environment selector"'
        \\select_id="$(widget_id button "Environment selector")"
        \\case "$select_id" in ''|*[!0-9]*) echo "select trigger id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click components-canvas "$select_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=menuitem name="Production".*state=\[selected\]' 'role=menuitem name="Staging"' 'role=menuitem name="Development"'
        \\"$cli" automate widget-key components-canvas arrowdown >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas arrowdown >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas enter >/dev/null 2>&1
        \\"$cli" automate assert --absent 'role=menu name=""'
        \\"$cli" automate widget-click components-canvas "$select_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=menuitem name="Staging".*state=\[selected\]'
        \\"$cli" automate widget-key components-canvas arrowup >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas arrowup >/dev/null 2>&1
        \\"$cli" automate widget-key components-canvas enter >/dev/null 2>&1
        \\"$cli" automate widget-click components-canvas "$select_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=menuitem name="Production".*state=\[selected\]'
        \\"$cli" automate widget-key components-canvas escape >/dev/null 2>&1
        \\"$cli" automate assert --absent 'role=menu name=""'
        \\navigation_scroll_id="$(widget_id group "Scrollable component tree")"
        \\case "$navigation_scroll_id" in ''|*[!0-9]*) echo "component navigation scroll id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-wheel components-canvas "$navigation_scroll_id" 220 >/dev/null 2>&1
        \\switch_row_id="$(widget_id treeitem Switch)"
        \\case "$switch_row_id" in ''|*[!0-9]*) echo "switch navigation id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-action components-canvas "$switch_row_id" press >/dev/null 2>&1
        \\"$cli" automate assert 'role=text name="Switch"' 'role=switch name="Notifications".*value=1' 'role=switch name="Airplane mode".*value=0'
        \\airplane_id="$(widget_id switch "Airplane mode")"
        \\case "$airplane_id" in ''|*[!0-9]*) echo "airplane mode switch id was missing" >&2; exit 1 ;; esac
        \\"$cli" automate widget-click components-canvas "$airplane_id" >/dev/null 2>&1
        \\"$cli" automate assert 'role=switch name="Notifications".*value=1' 'role=switch name="Airplane mode".*value=1'
        \\"$cli" automate screenshot components-canvas >/dev/null 2>&1
        \\test -s "$automation_dir/screenshot-components-canvas.png" || { echo "component gallery screenshot was empty" >&2; exit 1; }
        \\echo "gpu-components smoke ok"
        ,
        "sh",
    });
    gpu_components_smoke_run.addFileArg(cli_exe.getEmittedBin());
    gpu_components_smoke_run.step.dependOn(&gpu_components_smoke_build.step);
    gpu_components_smoke_run.step.dependOn(&cli_exe.step);
    gpu_components_smoke_step.dependOn(&gpu_components_smoke_run.step);

    const webview_cef_smoke_step = b.step("test-webview-cef-smoke", "Run macOS Chromium WebView automation smoke test");
    const webview_cef_smoke_build = b.addSystemCommand(&.{ "zig", "build", "-Dplatform=macos", "-Dweb-engine=chromium", b.fmt("-Dcef-dir={s}", .{exampleCefDir(b, cef_dir)}), "-Dautomation=true", "-Djs-bridge=true" });
    webview_cef_smoke_build.setCwd(b.path("examples/webview"));
    const webview_cef_smoke_run = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\cd examples/webview
        \\app="zig-out/bin/webview"
        \\cli="$1"
        \\case "$cli" in /*) ;; *) cli="../../$cli" ;; esac
        \\request='{"id":"ping","command":"native.ping","payload":{"source":"cef-smoke"}}'
        \\response_file=".zig-cache/native-sdk-automation/bridge-response.txt"
        \\mkdir -p .zig-cache/native-sdk-automation
        \\rm -f .zig-cache/native-sdk-automation/snapshot.txt .zig-cache/native-sdk-automation/windows.txt .zig-cache/native-sdk-automation/command*.txt "$response_file"
        \\printf 'bridge %s\n' "$request" > .zig-cache/native-sdk-automation/command-1.txt
        \\"$app" > .zig-cache/native-sdk-webview-cef-smoke.log 2>&1 &
        \\pid=$!
        \\trap 'status=$?; kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true; if [ "$status" -ne 0 ]; then echo "---- app log (.zig-cache/native-sdk-webview-cef-smoke.log) ----" >&2; cat .zig-cache/native-sdk-webview-cef-smoke.log >&2 2>/dev/null || true; fi' EXIT
        \\snapshot="$("$cli" automate wait 2>&1)"
        \\case "$snapshot" in *"ready=true"*) ;; *) echo "automation snapshot was not ready" >&2; exit 1 ;; esac
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && ! grep -q 'name="webview.load"' .zig-cache/native-sdk-webview-cef-smoke.log; do attempts=$((attempts + 1)); sleep 0.1; done
        \\grep -q 'name="webview.load"' .zig-cache/native-sdk-webview-cef-smoke.log || { echo "main window never loaded its webview source (blank window)" >&2; exit 1; }
        \\if grep -q 'name="dispatch.error"' .zig-cache/native-sdk-webview-cef-smoke.log; then echo "runtime recorded a dispatch error during startup" >&2; exit 1; fi
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*'pong from Zig'*) ;; *) echo "native.ping response was unexpected: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-create","command":"native-sdk.webview.create","payload":{"label":"smoke","url":"https://example.com","frame":{"x":24,"y":24,"width":320,"height":220}}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview create did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-resize","command":"native-sdk.webview.setFrame","payload":{"label":"smoke","frame":{"x":36,"y":36,"width":420,"height":260}}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview resize did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-navigate","command":"native-sdk.webview.navigate","payload":{"label":"smoke","url":"https://example.com/?smoke=1"}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview navigate did not succeed: $response" >&2; exit 1 ;; esac
        \\rm -f "$response_file"
        \\printf 'bridge %s\n' '{"id":"webview-close","command":"native-sdk.webview.close","payload":{"label":"smoke"}}' > .zig-cache/native-sdk-automation/command-1.txt
        \\attempts=0
        \\while [ "$attempts" -lt 50 ] && [ ! -s "$response_file" ]; do attempts=$((attempts + 1)); sleep 0.1; done
        \\response="$(cat "$response_file" 2>/dev/null || true)"
        \\case "$response" in *'"ok":true'*) ;; *) echo "cef webview close did not succeed: $response" >&2; exit 1 ;; esac
        \\echo "cef webview smoke ok"
        ,
        "sh",
    });
    webview_cef_smoke_run.addFileArg(cli_exe.getEmittedBin());
    webview_cef_smoke_run.step.dependOn(&webview_cef_smoke_build.step);
    webview_cef_smoke_run.step.dependOn(&cli_exe.step);
    webview_cef_smoke_step.dependOn(&webview_cef_smoke_run.step);

    const dev_run = b.addSystemCommand(&.{ "zig", "build", "run", b.fmt("-Dplatform={s}", .{platform_arg}) });
    dev_run.setCwd(b.path("examples/webview"));
    const dev_step = b.step("dev", "Run managed frontend dev server and native shell");
    dev_step.dependOn(&dev_run.step);

    const lib_step = b.step("lib", "Build native-sdk embeddable static library");
    lib_step.dependOn(&b.addInstallArtifact(embed_lib, .{}).step);

    const doctor_run = b.addRunArtifact(host_cli_exe);
    doctor_run.addArg("doctor");
    const doctor_step = b.step("doctor", "Print native-sdk platform diagnostics");
    doctor_step.dependOn(&doctor_run.step);

    const validate_run = b.addRunArtifact(host_cli_exe);
    validate_run.addArgs(&.{ "validate", "app.zon" });
    const validate_step = b.step("validate", "Validate app.zon");
    validate_step.dependOn(&validate_run.step);

    const bundle_run = b.addRunArtifact(host_cli_exe);
    bundle_run.addArgs(&.{ "bundle-assets", "app.zon", "assets", "zig-out/assets" });
    const bundle_step = b.step("bundle-assets", "Bundle app assets");
    bundle_step.dependOn(&bundle_run.step);

    const package_run = b.addRunArtifact(host_cli_exe);
    package_run.addArgs(&.{
        "package",
        "--target",
        @tagName(package_target),
        "--output",
        b.fmt("zig-out/package/native-sdk-{s}-{s}-{s}{s}", .{ package_version, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        "--binary",
    });
    package_run.addFileArg(embed_lib.getEmittedBin());
    package_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", @tagName(signing_mode), "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (signing_identity) |identity| package_run.addArgs(&.{ "--identity", identity });
    if (signing_entitlements) |entitlements| package_run.addArgs(&.{ "--entitlements", entitlements });
    if (cef_auto_install) package_run.addArg("--cef-auto-install");
    package_run.step.dependOn(&embed_lib.step);
    package_run.step.dependOn(&bundle_run.step);
    const package_step = b.step("package", "Create local package artifact");
    package_step.dependOn(&package_run.step);

    const package_cef_run = b.addRunArtifact(host_cli_exe);
    package_cef_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/native-sdk-cef-smoke-{s}.app", .{optimize_name}),
        "--binary",
    });
    package_cef_run.addFileArg(embed_lib.getEmittedBin());
    package_cef_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--web-engine", "chromium", "--cef-dir", cef_dir });
    if (cef_auto_install) package_cef_run.addArg("--cef-auto-install");
    package_cef_run.step.dependOn(&embed_lib.step);
    package_cef_run.step.dependOn(&bundle_run.step);

    const package_cef_check = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\app="zig-out/package/native-sdk-cef-smoke-{s}.app"
            \\test -d "$app/Contents/Frameworks/Chromium Embedded Framework.framework"
            \\test -f "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Resources/icudtl.dat"
            \\test -f "$app/Contents/Frameworks/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib"
            \\test -f "$app/Contents/Resources/package-manifest.zon"
            \\echo "cef package layout ok"
        , .{optimize_name}),
    });
    package_cef_check.step.dependOn(&package_cef_run.step);
    const package_cef_smoke_step = b.step("test-package-cef-layout", "Verify macOS Chromium package layout");
    package_cef_smoke_step.dependOn(&package_cef_check.step);

    // The repository's macOS distribution helpers need a real launchable
    // executable inside the .app. Keep the notarization helper on the same
    // emitted host CLI binary that the signed-package smoke executes below;
    // the SDK embed artifact is a static `.a` library and is not a valid
    // CFBundleExecutable even though codesign can seal a bundle around it.
    const macos_distribution_executable = host_cli_exe.getEmittedBin();

    // Signed-package seal pin: package an ad-hoc signed bundle and prove
    // the signature survives packaging intact with codesign's own strict
    // verifier. This is the regression gate for the ordering bug where a
    // file written into Contents/Resources AFTER signing invalidated the
    // resource seal ("file added"), turning every quarantined install
    // into Gatekeeper's "damaged — move to Trash" dialog. The bundle
    // carries the CLI as its executable (packaging only needs a real
    // Mach-O to sign); the check skips loudly on hosts without codesign
    // (any non-macOS machine) instead of pretending to have verified.
    // Signing that claims to sign now fails the package on hosts that
    // cannot run codesign (that IS the fix this step gates), so only a
    // macOS host requests adhoc here; elsewhere the package stays
    // unsigned and the check script below skips loudly as before.
    const package_signing_mode: []const u8 = if (b.graph.host.result.os.tag == .macos) "adhoc" else "none";
    const package_signing_run = b.addRunArtifact(host_cli_exe);
    package_signing_run.addArgs(&.{ "package", "--target", "macos", "--output", "zig-out/package/native-sdk-signing-verify.app", "--binary" });
    package_signing_run.addFileArg(macos_distribution_executable);
    package_signing_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", package_signing_mode });
    package_signing_run.has_side_effects = true;
    const package_signing_check = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\app="zig-out/package/native-sdk-signing-verify.app"
        \\if ! command -v codesign >/dev/null 2>&1; then
        \\  echo "codesign unavailable on this host; skipping signed-package verification"
        \\  exit 0
        \\fi
        \\codesign --verify --strict --deep "$app"
        \\"$app/Contents/MacOS/native-sdk" version >/dev/null
        \\grep -q "ad-hoc signed" "$app/Contents/Resources/signing-plan.txt"
        \\echo "signed package verify ok"
        ,
    });
    package_signing_check.step.dependOn(&package_signing_run.step);
    const package_signing_step = b.step("test-package-signing", "Verify an ad-hoc signed macOS package passes codesign --verify --strict");
    package_signing_step.dependOn(&package_signing_check.step);

    const package_windows_run = b.addRunArtifact(host_cli_exe);
    package_windows_run.addArgs(&.{ "package-windows", "--output", b.fmt("zig-out/package/native-sdk-{s}-windows-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_windows_step = b.step("package-windows", "Create local Windows artifact directory");
    package_windows_step.dependOn(&package_windows_run.step);

    const package_linux_run = b.addRunArtifact(host_cli_exe);
    package_linux_run.addArgs(&.{ "package-linux", "--output", b.fmt("zig-out/package/native-sdk-{s}-linux-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_linux_step = b.step("package-linux", "Create local Linux artifact directory");
    package_linux_step.dependOn(&package_linux_run.step);

    const package_ios_run = b.addRunArtifact(host_cli_exe);
    package_ios_run.addArgs(&.{ "package-ios", "--output", b.fmt("zig-out/mobile/native-sdk-{s}-ios-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_ios_step = b.step("package-ios", "Create local iOS host skeleton");
    package_ios_step.dependOn(&package_ios_run.step);

    const package_android_run = b.addRunArtifact(host_cli_exe);
    package_android_run.addArgs(&.{ "package-android", "--output", b.fmt("zig-out/mobile/native-sdk-{s}-android-Debug", .{package_version}), "--manifest", "app.zon", "--assets", "assets" });
    const package_android_step = b.step("package-android", "Create local Android host project");
    package_android_step.dependOn(&package_android_run.step);

    // Default app icon: rendered from vector geometry (tools/
    // generate_app_icon.zig) through the SDK's own path rasterizer, so
    // the checked-in .icns/.ico/.png/.svg all regenerate from source.
    // The built-in app-icon pipeline assembles and round-trip-validates
    // the containers itself (no external tools, any host OS), and the
    // CLI's embedded scaffold copies are kept in sync.
    const generate_icon_step = b.step("generate-icon", "Regenerate the default app icon (.icns/.ico/.png/.svg) from vector source");
    const generate_icon_mod = module(b, target, optimize, "tools/generate_app_icon.zig");
    generate_icon_mod.addImport("native_sdk", desktop_mod);
    const generate_icon_exe = b.addExecutable(.{
        .name = "generate-app-icon",
        .root_module = generate_icon_mod,
    });
    const generate_icon_run = b.addRunArtifact(generate_icon_exe);
    generate_icon_run.addArgs(&.{
        "assets/icon.icns",
        "assets/icon.png",
        "assets/icon.ico",
        "assets/icon.svg",
        "src/tooling/default_icon.icns",
        "src/tooling/default_icon.png",
        "zig-out/icon-full-bleed.png",
        // The one committed full-bleed copy: the notes example's raw
        // one-image icon source (it demos the packaging mask + inset),
        // regenerated here so it can never drift from the default.
        "examples/notes/assets/icon.png",
    });
    generate_icon_run.has_side_effects = true;
    generate_icon_step.dependOn(&generate_icon_run.step);

    const notarize_run = b.addRunArtifact(host_cli_exe);
    notarize_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/native-sdk-{s}-macos-{s}.app", .{ package_version, optimize_name }),
        "--binary",
    });
    notarize_run.addFileArg(macos_distribution_executable);
    notarize_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", "identity", "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir, "--archive", "--notarize" });
    if (signing_identity) |identity| notarize_run.addArgs(&.{ "--identity", identity });
    if (signing_entitlements) |entitlements| notarize_run.addArgs(&.{ "--entitlements", entitlements });
    if (notary_profile) |profile| notarize_run.addArgs(&.{ "--notary-profile", profile });
    if (cef_auto_install) notarize_run.addArg("--cef-auto-install");
    notarize_run.step.dependOn(&host_cli_exe.step);
    notarize_run.step.dependOn(&bundle_run.step);
    const notarize_step = b.step("notarize", "Package, sign with identity, and notarize for macOS distribution");
    notarize_step.dependOn(&notarize_run.step);

    // Run the same styled archive path app developers get from
    // `native package --archive`: generated/custom background, Applications
    // alias, Finder geometry, then compressed UDZO output. Keeping this as a
    // CLI invocation means the repository helper cannot drift into producing
    // a plainer image than the product surface it documents.
    const dmg_run = b.addRunArtifact(host_cli_exe);
    dmg_run.addArgs(&.{
        "package",
        "--target",
        "macos",
        "--output",
        b.fmt("zig-out/package/native-sdk-{s}-macos-{s}.app", .{ package_version, optimize_name }),
        "--binary",
    });
    dmg_run.addFileArg(embed_lib.getEmittedBin());
    dmg_run.addArgs(&.{ "--manifest", "app.zon", "--assets", "assets", "--optimize", optimize_name, "--signing", @tagName(signing_mode), "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir, "--archive" });
    if (signing_identity) |identity| dmg_run.addArgs(&.{ "--identity", identity });
    if (signing_entitlements) |entitlements| dmg_run.addArgs(&.{ "--entitlements", entitlements });
    if (cef_auto_install) dmg_run.addArg("--cef-auto-install");
    dmg_run.step.dependOn(&embed_lib.step);
    dmg_run.step.dependOn(&bundle_run.step);
    dmg_run.has_side_effects = true;
    const dmg_step = b.step("dmg", "Create a styled macOS .dmg with a drag-to-Applications layout");
    dmg_step.dependOn(&dmg_run.step);

    const cef_bundle_script = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework"
            \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/"
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/"
            \\if [ -d "{s}/Resources" ]; then
            \\  mkdir -p "zig-out/bin/Resources/cef"
            \\  cp -R "{s}/Resources/"* "zig-out/bin/Resources/cef/"
            \\fi
            \\echo "CEF framework copied for local dev runs"
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
    });
    const cef_bundle_step = b.step("cef-bundle", "Copy CEF framework and resources into zig-out/bin/ for local dev runs");
    if (cef_auto_install) {
        const cef_bundle_auto = b.addRunArtifact(host_cli_exe);
        cef_bundle_auto.addArgs(&.{ "cef", "install", "--dir", cef_dir });
        cef_bundle_script.step.dependOn(&cef_bundle_auto.step);
    }
    cef_bundle_step.dependOn(&cef_bundle_script.step);
}

fn sqliteCompileFlags() []const []const u8 {
    return &.{
        "-DSQLITE_THREADSAFE=2",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_DQS=0",
        "-DSQLITE_ENABLE_FTS5",
        "-DSQLITE_ENABLE_JSON1",
        "-DSQLITE_ENABLE_UPDATE_HOOK",
        "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
    };
}

fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

/// The framework module's `terminal_vt` import for THIS repository's own
/// builds: always the stub. The emulator (libghostty-vt) is pinned by
/// the APPS that want live `<terminal>` sessions, never by this package
/// — a pin in `build.zig.zon` is materialized into every consumer's
/// package directory even when lazy and unused, and ghostty's own graph
/// walks translate_c/wuffs and pulls harfbuzz, which is exactly what a
/// scaffolded app must never carry. `AppOptions.terminal_sessions`
/// resolves the app's own pin (see build/app.zig), and the terminal
/// examples own the enabled path's test coverage.
fn terminalVtModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return module(b, target, optimize, "src/runtime/terminal_vt_stub.zig");
}

/// The short commit hash of the framework checkout the CLI is built
/// from, for `native version` staleness checks. "unknown" when
/// git is unavailable (e.g. building from a package tarball).
fn cliBuildCommit(b: *std.Build) []const u8 {
    var code: u8 = undefined;
    const output = b.runAllowFail(&.{ "git", "rev-parse", "--short", "HEAD" }, &code, .ignore) catch return "unknown";
    const trimmed = std.mem.trim(u8, output, " \n\r\t");
    if (trimmed.len == 0) return "unknown";
    return trimmed;
}

fn testArtifact(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    return filteredTestArtifact(b, mod, "test", &.{});
}

/// The two transpiled-core end-to-end test binaries: the host/markup
/// fixture suite (tests/ts-core) and the soundboard-ts example suite —
/// the launch-gate port driven as a REAL app (its committed core, its
/// shipping markup). Each runs the @native-sdk/core transpiler (node)
/// over the TS core at build time, pairs the emitted core with its rt
/// kernel in one generated module, and compiles the Zig test root
/// against it plus the framework. Returns null — the suites are
/// skipped, not failed — when node or the transpiler package's
/// installed dependency (`npm ci` in packages/core) is missing.
const TsCoreE2eArtifacts = struct {
    host: *std.Build.Step.Compile,
    persist: *std.Build.Step.Compile,
    /// The markup battery is its own binary: the compiled-core symbol
    /// set is a fixed-prefix C ABI, so one process carries ONE archive
    /// — every fixture battery links exactly its own core.
    markup: *std.Build.Step.Compile,
    kanban: *std.Build.Step.Compile,
    soundboard: *std.Build.Step.Compile,
    system_monitor: *std.Build.Step.Compile,
    /// The stock-IDE contract: a fresh scaffold (and the committed TS
    /// example ports) typecheck under the REAL tsc with zero injected
    /// paths, and builds keep working with node_modules deleted.
    scaffold_ide: *std.Build.Step.Compile,
    ai_chat: *std.Build.Step.Compile,
    /// The complete services loop over examples/service-feed-reader: a real
    /// loopback Cmd.fetch, the generated typed client into a real service
    /// child, the shipping markup, and record→replay without either.
    feed_reader: *std.Build.Step.Compile,
    /// The phase-1 service seam: a real compiled core plus a real plain-scriptc
    /// service executable driven through the out-of-process carrier.
    services: *std.Build.Step.Compile,
    /// The in-process service carrier: the same fixture compiled as a
    /// thread-instanced library archive, linked into this battery and driven
    /// through ServicePool (parallel keys, per-key FIFO, cooperative
    /// cancellation/deadlines, trap isolation, streaming, replay). Null when
    /// the target cannot carry the archive (cross or non-desktop builds).
    services_pool: ?*std.Build.Step.Compile,
    /// The mobile execution battery: the pool fixture's core and service
    /// archives linked into one static library exporting `nsme_run`, so
    /// the platform toolchain links a runnable harness for the simulator
    /// or emulator (scripts/mobile-e2e.sh). Present only for a mobile
    /// -Dtarget; the Android archive is flattened to plain objects (Zig's
    /// ELF static-library emission nests archive inputs).
    mobile_battery: ?std.Build.LazyPath,
    /// The service-host carrier benchmark: a bytes-echo service compiled
    /// through the same lane, driven directly through the production
    /// carrier bindings of BOTH carriers (cold start, round-trip latency,
    /// queued throughput).
    service_host_bench: *std.Build.Step.Compile,
    /// Sidecar-shim conformance (tests/sidecar): every fixture's
    /// generated mirror validated over its frontend-emitted contract
    /// (plus the hand-written ground-truth sidecars), and every shim
    /// fully analyzed and linked against the stub core.
    sidecar_conformance: *std.Build.Step.Compile,
    /// The ABI-law suite over a REAL compiled core: the markup
    /// fixture's archive driven directly through the C ABI bindings
    /// (boot fence, collect invariant, deterministic re-init, channel
    /// envelopes, integer classes).
    external_core_abi_laws: *std.Build.Step.Compile,
    /// The mixed-return ABI regression: a real compiled core whose update
    /// returns both bare Model and [Model, Cmd] through the generated facade.
    mixed_return_abi_laws: *std.Build.Step.Compile,
    /// Per-fixture contract artifacts for an external core toolchain:
    /// the effective contract sidecar and its TypeScript facade/profile
    /// projections, installed by the stage-core-contracts step.
    core_contracts: []const CoreContract,
};

const CoreContract = struct {
    name: []const u8,
    sidecar: std.Build.LazyPath,
    facade: std.Build.LazyPath,
    profile: std.Build.LazyPath,
};

fn tsCoreE2eArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    desktop_mod: *std.Build.Module,
    tooling_mod: *std.Build.Module,
) ?TsCoreE2eArtifacts {
    const node = b.findProgram(&.{"node"}, &.{}) catch return null;
    // Both toolchains arrive with one `npm ci` in packages/core: the
    // frontend's TypeScript compiler and the external core compiler
    // (unless NATIVE_SDK_CORE_COMPILER points at the pinned release's
    // command directly).
    b.build_root.handle.access(
        b.graph.io,
        "packages/core/node_modules/@typescript/old",
        .{},
    ) catch return null;
    if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER") == null) {
        b.build_root.handle.access(
            b.graph.io,
            repositoryScriptcBin(b),
            .{},
        ) catch return null;
    }

    // corewire (the contract-sidecar mirror/facade/profile generator),
    // compiled for the build host: the fixture compiles and the
    // conformance shims all run it, including under a cross -Dtarget
    // (the batteries compile for the target; this tool never does).
    const corewire_mod = b.createModule(.{
        .root_source_file = b.path("tools/corewire/main.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const corewire_exe = b.addExecutable(.{
        .name = "corewire",
        .root_module = corewire_mod,
        .use_llvm = @import("build/app.zig").useLlvmWorkaround(b.graph.host),
    });

    // Each fixture core compiles through the external core compiler at
    // build time; the battery drives the linked archive through the
    // generated mirror. The compiled-core symbol set is a fixed-prefix
    // C ABI, so one process carries ONE archive — each battery below is
    // its own binary linking exactly its own core. The tests/ts-core
    // fixtures are single-file cores, staged into their own
    // compile-source directories.
    const host_src = b.addWriteFiles();
    _ = host_src.addCopyFile(b.path("tests/ts-core/fixture.ts"), "fixture.ts");
    const host_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tests/ts-core/fixture.ts",
        .src_dir = host_src.getDirectory(),
        .name = "host_fixture_core",
        .store_capability = true,
        .relational_capability = true,
        .credentials_capability = true,
        // The fixture drives pastBytes to the f64-exact boundary (2^53):
        // no honest i64 declaration exists there, so the compiled
        // projection carries the slot as f64.
        .f64_slots = &.{"Model.pastBytes"},
    });
    const fixture_mod = host_fixture.module;
    const persist_src = b.addWriteFiles();
    _ = persist_src.addCopyFile(b.path("tests/ts-core/persist_fixture.ts"), "persist_fixture.ts");
    const persist_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tests/ts-core/persist_fixture.ts",
        .src_dir = persist_src.getDirectory(),
        .name = "persist_fixture_core",
        .persist_capability = true,
    });
    const persist_mod = module(b, target, optimize, "tests/ts-core/persist_e2e_tests.zig");
    persist_mod.addImport("native_sdk", desktop_mod);
    persist_mod.addImport("ts_persist_core", persist_fixture.module);
    const markup_src = b.addWriteFiles();
    _ = markup_src.addCopyFile(b.path("tests/ts-core/markup_fixture.ts"), "markup_fixture.ts");
    const markup_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tests/ts-core/markup_fixture.ts",
        .src_dir = markup_src.getDirectory(),
        .name = "markup_core",
    });
    const markup_fixture_mod = markup_fixture.module;
    const mixed_return_src = b.addWriteFiles();
    _ = mixed_return_src.addCopyFile(b.path("tests/ts-core/mixed_return_fixture.ts"), "mixed_return_fixture.ts");
    const mixed_return_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tests/ts-core/mixed_return_fixture.ts",
        .src_dir = mixed_return_src.getDirectory(),
        .name = "mixed_return_core",
    });

    const e2e_mod = module(b, target, optimize, "tests/ts-core/host_e2e_tests.zig");
    e2e_mod.addImport("native_sdk", desktop_mod);
    e2e_mod.addImport("ts_core_fixture", fixture_mod);

    // The markup battery: the imported .native view + automation +
    // record/replay guarantees over the markup fixture's compiled core.
    const markup_view_stage = b.addWriteFiles();
    const markup_view_root = markup_view_stage.addCopyFile(b.path("tests/ts-core/markup_e2e_tests.zig"), "markup_e2e_tests.zig");
    _ = markup_view_stage.addCopyFile(b.path("tests/ts-core/markup_view.native"), "markup_view.native");
    _ = markup_view_stage.addCopyFile(b.path("tests/ts-core/components/actions.native"), "components/actions.native");
    const markup_e2e_mod = b.createModule(.{
        .root_source_file = markup_view_root,
        .target = target,
        .optimize = optimize,
    });
    markup_e2e_mod.addImport("native_sdk", desktop_mod);
    markup_e2e_mod.addImport("ts_markup_fixture", markup_fixture_mod);

    // The rewritten Kanban example's real TypeScript core and self-contained
    // shipping markup. Its battery drives native multi-file drops through
    // the generated dropMsg adapter and then moves the created cards.
    const kanban_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "examples/kanban/src/core.ts",
        .src_dir = b.path("examples/kanban/src"),
        .name = "kanban_core",
    });
    const kanban_core_mod = kanban_fixture.module;
    const kanban_stage = b.addWriteFiles();
    const kanban_root = kanban_stage.addCopyFile(b.path("tests/ts-core/kanban_e2e_tests.zig"), "kanban_e2e_tests.zig");
    _ = kanban_stage.addCopyFile(b.path("examples/kanban/src/app.native"), "app.native");
    _ = kanban_stage.addCopyFile(b.path("examples/kanban/src/components/board-column.native"), "components/board-column.native");
    const kanban_mod = b.createModule(.{
        .root_source_file = kanban_root,
        .target = target,
        .optimize = optimize,
    });
    kanban_mod.addImport("native_sdk", desktop_mod);
    kanban_mod.addImport("ts_kanban_core", kanban_core_mod);

    // The soundboard-ts example's core and markup, tested as one app:
    // the test root stages beside a copy of the example's app.native so
    // the compiled markup engine builds the SHIPPING view over the
    // core's model.
    const soundboard_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "examples/soundboard-ts/src/core.ts",
        .src_dir = b.path("examples/soundboard-ts/src"),
        .name = "soundboard_core",
    });
    const soundboard_core_mod = soundboard_fixture.module;
    const soundboard_stage = b.addWriteFiles();
    const soundboard_root = soundboard_stage.addCopyFile(b.path("tests/ts-core/soundboard_e2e_tests.zig"), "soundboard_e2e_tests.zig");
    _ = soundboard_stage.addCopyFile(b.path("examples/soundboard-ts/src/app.native"), "app.native");
    const soundboard_mod = b.createModule(.{
        .root_source_file = soundboard_root,
        .target = target,
        .optimize = optimize,
    });
    soundboard_mod.addImport("native_sdk", desktop_mod);
    soundboard_mod.addImport("ts_soundboard_core", soundboard_core_mod);

    // The system-monitor-ts example's core and markup, tested the same
    // way — plus the ORIGINAL Zig example's committed sampler captures,
    // staged as fixtures so both ports parse the same recorded truth.
    const monitor_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "examples/system-monitor-ts/src/core.ts",
        .src_dir = b.path("examples/system-monitor-ts/src"),
        .name = "system_monitor_core",
    });
    const monitor_core_mod = monitor_fixture.module;
    const monitor_stage = b.addWriteFiles();
    const monitor_root = monitor_stage.addCopyFile(b.path("tests/ts-core/system_monitor_e2e_tests.zig"), "system_monitor_e2e_tests.zig");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor-ts/src/app.native"), "app.native");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor-ts/src/windows/settings.native"), "settings.native");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor-ts/src/windows/components/sampling.native"), "components/sampling.native");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor/src/fixtures/sysctl.txt"), "fixtures/sysctl.txt");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor/src/fixtures/ps.txt"), "fixtures/ps.txt");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor/src/fixtures/vm_stat.txt"), "fixtures/vm_stat.txt");
    _ = monitor_stage.addCopyFile(b.path("examples/system-monitor/src/fixtures/ps-edge.txt"), "fixtures/ps-edge.txt");
    const monitor_mod = b.createModule(.{
        .root_source_file = monitor_root,
        .target = target,
        .optimize = optimize,
    });
    monitor_mod.addImport("native_sdk", desktop_mod);
    monitor_mod.addImport("ts_system_monitor_core", monitor_core_mod);

    // The stock-IDE suite runs the CLI's scaffold + editor-package plumbing
    // (the tooling module) and shells out to node for the real tsc.
    const scaffold_ide_mod = module(b, target, optimize, "tests/ts-core/scaffold_ide_e2e_tests.zig");
    scaffold_ide_mod.addImport("tooling", tooling_mod);

    // The Chatbot example's core and markup, tested the same way:
    // the chat client for an OpenAI-compatible endpoint, driven through
    // the fake fetch feed (no network) with its shipping markup.
    const ai_chat_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "examples/chatbot/src/core.ts",
        .src_dir = b.path("examples/chatbot/src"),
        .name = "ai_chat_core",
    });
    const ai_chat_core_mod = ai_chat_fixture.module;
    const ai_chat_stage = b.addWriteFiles();
    const ai_chat_root = ai_chat_stage.addCopyFile(b.path("tests/ts-core/ai_chat_e2e_tests.zig"), "ai_chat_e2e_tests.zig");
    _ = ai_chat_stage.addCopyFile(b.path("examples/chatbot/src/app.native"), "app.native");
    const ai_chat_mod = b.createModule(.{
        .root_source_file = ai_chat_root,
        .target = target,
        .optimize = optimize,
    });
    ai_chat_mod.addImport("native_sdk", desktop_mod);
    ai_chat_mod.addImport("ts_ai_chat_core", ai_chat_core_mod);

    // The service-feed-reader example's core, service child, and shipping
    // markup, tested as one app: a real buffered Cmd.fetch against a
    // loopback fixture, the generated typed client into the real child,
    // and record→replay with neither the service nor the network present.
    const feed_reader_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "examples/service-feed-reader/src/core.ts",
        .src_dir = b.path("examples/service-feed-reader/src"),
        .name = "feed_reader_core",
        .emit_services = true,
    });
    const feed_reader_service = externalServiceFixture(
        b,
        target,
        optimize,
        node,
        corewire_exe,
        b.path("examples/service-feed-reader/src"),
        feed_reader_fixture.services_contract.?,
        "feed_reader_services",
    );
    const feed_reader_stage = b.addWriteFiles();
    const feed_reader_root = feed_reader_stage.addCopyFile(b.path("tests/ts-services/feed_reader_e2e_tests.zig"), "feed_reader_e2e_tests.zig");
    _ = feed_reader_stage.addCopyFile(b.path("examples/service-feed-reader/src/app.native"), "app.native");
    _ = feed_reader_stage.addCopyFile(b.path("examples/service-feed-reader/fixtures/feed.xml"), "fixture_feed.xml");
    const feed_reader_mod = b.createModule(.{
        .root_source_file = feed_reader_root,
        .target = target,
        .optimize = optimize,
    });
    feed_reader_mod.addImport("native_sdk", desktop_mod);
    feed_reader_mod.addImport("ts_feed_reader_core", feed_reader_fixture.module);
    feed_reader_mod.addImport("ts_feed_reader_registry", feed_reader_service.registry);
    const feed_reader_options = b.addOptions();
    feed_reader_options.addOptionPath("service_executable", feed_reader_service.executable);
    feed_reader_mod.addOptions("ts_feed_reader_options", feed_reader_options);

    // Phase-1 TypeScript services, end to end: the frontend emits BOTH
    // sidecars from one checked two-class program; corewire derives the
    // registry/host only from the service sidecar; plain scriptc compiles the
    // child executable; and the Zig battery drives that executable through
    // the production ServiceHost + effects/session boundary.
    const services_fixture = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tests/ts-services/ok/src/core.ts",
        .src_dir = b.path("tests/ts-services/ok/src"),
        .name = "services_fixture_core",
        .emit_services = true,
        .service_packages = &.{"escape-string-regexp|5.0.0|705f4bb4b92fd3469e264a93f2a2e4b24cf7e663d73a5318abaf29ee72674f6d"},
    });
    const service_host_fixture = externalServiceFixture(
        b,
        target,
        optimize,
        node,
        corewire_exe,
        b.path("tests/ts-services/ok/src"),
        services_fixture.services_contract.?,
        "ts_services_fixture_services",
    );
    const services_e2e_mod = module(b, target, optimize, "tests/ts-services/service_e2e_tests.zig");
    services_e2e_mod.addImport("native_sdk", desktop_mod);
    services_e2e_mod.addImport("ts_services_core", services_fixture.module);
    services_e2e_mod.addImport("ts_services_registry", service_host_fixture.registry);
    const service_test_options = b.addOptions();
    service_test_options.addOptionPath("service_executable", service_host_fixture.executable);
    service_test_options.addOption([]const u8, "node_executable", node);
    services_e2e_mod.addOptions("ts_services_options", service_test_options);

    // The same fixture against the in-process carrier: the service archive
    // links into the battery beside the fixture core's archive (distinct
    // symbol prefixes), and ServicePool drives it through the identical
    // TsUiApp/Effects seam.
    const services_pool_mod: ?*std.Build.Module = if (service_host_fixture.archive) |service_archive| pool: {
        const pool_mod = module(b, target, optimize, "tests/ts-services/service_pool_e2e_tests.zig");
        pool_mod.addImport("native_sdk", desktop_mod);
        pool_mod.addImport("ts_services_core", services_fixture.module);
        pool_mod.addImport("ts_services_registry", service_host_fixture.registry);
        pool_mod.link_libc = true;
        pool_mod.addObjectFile(service_archive);
        addScriptcArchiveSystemLibs(pool_mod, target);
        break :pool pool_mod;
    } else null;

    // The mobile execution battery: a static library over the same pool
    // fixture, linked into a runnable harness by the platform toolchain —
    // the same link pattern embedding apps use for the embed library. The
    // Android objects are PIC like the embed library's (the harness there
    // is a bionic executable; a future .so embedding needs it regardless).
    const battery_target_is_mobile = target.result.os.tag == .ios or target.result.abi.isAndroid();
    const mobile_battery: ?std.Build.LazyPath = if (battery_target_is_mobile and service_host_fixture.archive != null) battery: {
        const battery_mod = b.createModule(.{
            .root_source_file = b.path("tests/ts-services/mobile_e2e_battery.zig"),
            .target = target,
            .optimize = optimize,
            .pic = if (target.result.abi.isAndroid()) true else null,
        });
        battery_mod.addImport("native_sdk", desktop_mod);
        battery_mod.addImport("ts_services_core", services_fixture.module);
        battery_mod.addImport("ts_services_registry", service_host_fixture.registry);
        battery_mod.link_libc = true;
        battery_mod.addObjectFile(service_host_fixture.archive.?);
        const battery_lib = b.addLibrary(.{
            .linkage = .static,
            .name = "ts-mobile-e2e",
            .root_module = battery_mod,
            .use_llvm = @import("build/app.zig").useLlvmWorkaround(target),
        });
        if (target.result.abi.isAndroid()) {
            // Flatten the nested TypeScript archives (Zig's ELF static-lib
            // emission stores .a inputs as members) so the NDK link consumes
            // plain objects — the same normalization the app lane applies.
            const merge = b.addSystemCommand(&.{node});
            merge.addFileArg(b.path("packages/core/scripts/merge_static_archives.mjs"));
            merge.addArgs(&.{ "--zig", b.graph.zig_exe, "--format", "gnu" });
            merge.addArg("--out");
            const merged = merge.addOutputFileArg("libts-mobile-e2e.a");
            merge.addArg("--in");
            merge.addFileArg(battery_lib.getEmittedBin());
            break :battery merged;
        }
        break :battery battery_lib.getEmittedBin();
    } else null;

    // Service-host carrier benchmark: the same production service lane
    // (frontend contract -> corewire host/registry -> exact-pinned
    // plain-scriptc executable) over a bytes-echo operation that returns
    // its request unchanged, so tools/bench_service_host.zig measures the
    // carrier — lazy spawn, framing, pipes, worker queueing — and never a
    // workload.
    const service_bench_core = externalCoreFixtureModule(b, target, optimize, node, corewire_exe, .{
        .entry = "tools/service-host-bench/src/core.ts",
        .src_dir = b.path("tools/service-host-bench/src"),
        .name = "service_host_bench_core",
        .emit_services = true,
    });
    const service_bench_fixture = externalServiceFixture(
        b,
        target,
        optimize,
        node,
        corewire_exe,
        b.path("tools/service-host-bench/src"),
        service_bench_core.services_contract.?,
        "service_host_bench_services",
    );
    const service_bench_mod = module(b, target, optimize, "tools/bench_service_host.zig");
    service_bench_mod.addImport("native_sdk", desktop_mod);
    service_bench_mod.addImport("service_registry", service_bench_fixture.registry);
    const service_bench_options = b.addOptions();
    service_bench_options.addOptionPath("service_executable", service_bench_fixture.executable);
    service_bench_options.addOption(bool, "has_archive", service_bench_fixture.archive != null);
    service_bench_mod.addOptions("bench_options", service_bench_options);
    if (service_bench_fixture.archive) |bench_archive| {
        // The in-process carrier's half of the benchmark: the same echo
        // service as a linked archive, driven through ServicePool.
        service_bench_mod.link_libc = true;
        service_bench_mod.addObjectFile(bench_archive);
        addScriptcArchiveSystemLibs(service_bench_mod, target);
    }
    const service_bench_exe = b.addExecutable(.{
        .name = "bench-service-host",
        .root_module = service_bench_mod,
    });

    // Sidecar-shim conformance: a corewire-generated mirror per corpus
    // fixture. The markup fixture's sidecar is the committed
    // hand-written one (independent ground truth for the schema); the
    // rest are the frontend-emitted contracts from the fixture compiles
    // above, so corpus mirrors cannot go stale against their cores.
    const conformance_mod = module(b, target, optimize, "tests/sidecar/conformance_tests.zig");
    conformance_mod.addImport("native_sdk", desktop_mod);
    // The canonical value encoder the envelope and snapshot axes compare
    // against (the same module the generated shims stage).
    conformance_mod.addImport("corewire_rt", module(b, target, optimize, "tools/corewire/shim_rt.zig"));
    conformance_mod.addImport("shim_markup_core", sidecarShimModule(b, target, optimize, corewire_exe, b.path("tests/sidecar/markup_fixture.contract.json")));
    // Compile-cost guard: this generated mirror carries 160 realistically
    // named Msg arms and must need no quota setting in app or test code.
    conformance_mod.addImport("shim_wide_core", sidecarShimModule(b, target, optimize, corewire_exe, b.path("tests/sidecar/wide_msg_fixture.contract.json")));
    // The integer-class fixture: a hand-written sidecar attesting mixed
    // i64/u64 slot classes, so the suite drives boundary and full-range
    // integer values through a generated mirror's decode paths.
    conformance_mod.addImport("shim_integer_core", sidecarShimModule(b, target, optimize, corewire_exe, b.path("tests/sidecar/integer_fixture.contract.json")));
    const conformance_fixtures = [_]struct {
        shim_import: []const u8,
        contract_name: []const u8,
        core: ExternalCoreFixture,
        /// Attested integer slots the compiled projection carries as f64
        /// (values that reach the f64-exact boundary have no honest i64
        /// declaration on that side).
        f64_slots: []const []const u8 = &.{},
    }{
        .{ .shim_import = "shim_host_core", .contract_name = "host-fixture", .core = host_fixture, .f64_slots = &.{"Model.pastBytes"} },
        .{ .shim_import = "shim_kanban_core", .contract_name = "kanban", .core = kanban_fixture },
        .{ .shim_import = "shim_soundboard_core", .contract_name = "soundboard", .core = soundboard_fixture },
        .{ .shim_import = "shim_monitor_core", .contract_name = "system-monitor", .core = monitor_fixture },
        .{ .shim_import = "shim_ai_chat_core", .contract_name = "ai-chat", .core = ai_chat_fixture },
    };
    // The corpus contract artifacts an external core toolchain consumes
    // (stage-core-contracts): the effective sidecar plus its generated
    // entry module and compiler profile, per fixture. Every corewire
    // consumer reads the FRONTEND-emitted contract.
    var core_contracts: std.ArrayList(CoreContract) = .empty;
    {
        const projections = facadeProjections(b, corewire_exe, markup_fixture.contract, &.{});
        core_contracts.append(b.allocator, .{
            .name = "markup-fixture",
            .sidecar = projections.sidecar,
            .facade = projections.facade,
            .profile = projections.profile,
        }) catch @panic("OOM");
    }
    for (conformance_fixtures) |fixture| {
        conformance_mod.addImport(fixture.shim_import, sidecarShimModule(b, target, optimize, corewire_exe, fixture.core.contract));
        const projections = facadeProjections(b, corewire_exe, fixture.core.contract, fixture.f64_slots);
        core_contracts.append(b.allocator, .{
            .name = fixture.contract_name,
            .sidecar = projections.sidecar,
            .facade = projections.facade,
            .profile = projections.profile,
        }) catch @panic("OOM");
    }

    // The ABI-law suite (tests/sidecar/external_core_abi_tests.zig):
    // the executable half of the conformance story — the markup
    // fixture's REAL archive driven directly through the C ABI
    // bindings, beside a FRESH generated mirror (the conformance
    // binary's mirror links the stub core's exports — one process
    // cannot carry both symbol sets). The mirror generates from the
    // archive's OWN co-emitted sidecar, so its boot fence checks the
    // compile's real build_id against the identity getters.
    const abi_laws_mod = module(b, target, optimize, "tests/sidecar/external_core_abi_tests.zig");
    abi_laws_mod.link_libc = true;
    abi_laws_mod.addImport("corewire_rt", module(b, target, optimize, "tools/corewire/shim_rt.zig"));
    abi_laws_mod.addImport("core_abi", module(b, target, optimize, "tools/corewire/core_abi.zig"));
    abi_laws_mod.addImport("shim_core", sidecarShimModule(b, target, optimize, corewire_exe, markup_fixture.sidecar));
    abi_laws_mod.addObjectFile(markup_fixture.archive);
    addScriptcArchiveSystemLibs(abi_laws_mod, target);

    const mixed_return_abi_mod = module(b, target, optimize, "tests/sidecar/mixed_return_abi_tests.zig");
    mixed_return_abi_mod.addImport("mixed_return_core", mixed_return_fixture.module);

    return .{
        .host = filteredTestArtifact(b, e2e_mod, "ts-core-e2e-tests", &.{}),
        .persist = filteredTestArtifact(b, persist_mod, "ts-persist-e2e-tests", &.{}),
        .markup = filteredTestArtifact(b, markup_e2e_mod, "ts-markup-e2e-tests", &.{}),
        .kanban = filteredTestArtifact(b, kanban_mod, "ts-kanban-e2e-tests", &.{}),
        .soundboard = filteredTestArtifact(b, soundboard_mod, "ts-soundboard-e2e-tests", &.{}),
        .system_monitor = filteredTestArtifact(b, monitor_mod, "ts-system-monitor-e2e-tests", &.{}),
        .scaffold_ide = filteredTestArtifact(b, scaffold_ide_mod, "ts-scaffold-ide-e2e-tests", &.{}),
        .ai_chat = filteredTestArtifact(b, ai_chat_mod, "ts-ai-chat-e2e-tests", &.{}),
        .feed_reader = filteredTestArtifact(b, feed_reader_mod, "ts-feed-reader-e2e-tests", &.{}),
        .services = filteredTestArtifact(b, services_e2e_mod, "ts-services-e2e-tests", &.{}),
        .services_pool = if (services_pool_mod) |pool_mod| filteredTestArtifact(b, pool_mod, "ts-services-pool-e2e-tests", &.{}) else null,
        .mobile_battery = mobile_battery,
        .service_host_bench = service_bench_exe,
        .sidecar_conformance = filteredTestArtifact(b, conformance_mod, "sidecar-conformance-tests", &.{}),
        .external_core_abi_laws = filteredTestArtifact(b, abi_laws_mod, "external-core-abi-tests", &.{}),
        .mixed_return_abi_laws = filteredTestArtifact(b, mixed_return_abi_mod, "mixed-return-abi-tests", &.{}),
        .core_contracts = core_contracts.toOwnedSlice(b.allocator) catch @panic("OOM"),
    };
}

/// System import libraries scriptc's compiled-archive runtime reaches on
/// Windows targets — core and service archives alike (Winsock, adapter
/// enumeration, and crypto-backed randomness). No-op elsewhere; the
/// archives' other dependencies are libc's. The app lane's twin is the
/// Windows platform block in build/app.zig.
fn addScriptcArchiveSystemLibs(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .windows) return;
    mod.linkSystemLibrary("ws2_32", .{});
    mod.linkSystemLibrary("iphlpapi", .{});
    mod.linkSystemLibrary("advapi32", .{});
}

/// Attach ScriptC's explicit-Linux-target glibc-floor teaching to an actual
/// compile step. A target can match the host triple and still need the teaching
/// because Zig's explicitly spelled `-gnu` target uses its default glibc floor.
/// The root graph constructs fixture lanes even for unrelated selections such
/// as the release pipeline's cross-compiled `zig build cli`; making the
/// teaching a dependency preserves those CLI-only builds while still refusing
/// the unsupported target before a selected ScriptC compile does any work.
fn addScriptcGlibcFloorTeaching(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step) void {
    const app_build = @import("build/app.zig");
    if (!app_build.linuxGlibcSpellingHitsDefaultFloor(target)) return;
    step.dependOn(&b.addFail(app_build.scriptcLinuxGlibcSpellingTeaching(b, target)).step);
}

const ExternalServiceFixture = struct {
    executable: std.Build.LazyPath,
    /// The in-process carrier's library archive (thread-instanced,
    /// runtime-localized), compiled from the same staged tree. Present
    /// wherever the pinned compiler's localized-archive matrix covers the
    /// pairing (native Linux, cross-Linux x86_64/aarch64, Windows x86_64,
    /// or macOS from a macOS host — see build/app.zig
    /// serviceArchiveSupported); null elsewhere, and for explicitly spelled
    /// linux-gnu targets below the glibc 2.36 runtime floor.
    archive: ?std.Build.LazyPath,
    registry: *std.Build.Module,
};

/// Compile one fixture's service class through the production phase-1 lane:
/// service sidecar -> corewire host/registry -> ordinary source stage (plus
/// the pinned compiler's tagged-throw compatibility lowering) -> exact pinned
/// scriptc outputs (the child executable, plus the in-process library archive
/// wherever the compiler's localized-archive matrix covers the host/target
/// pairing). No author source is re-read for dispatch facts after the sidecar
/// emission.
fn externalServiceFixture(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    node: []const u8,
    corewire_exe: *std.Build.Step.Compile,
    src_dir: std.Build.LazyPath,
    contract: std.Build.LazyPath,
    name: []const u8,
) ExternalServiceFixture {
    const app_build = @import("build/app.zig");
    const emit_archive = app_build.serviceArchiveSupported(b.graph.host.result, target);
    const project = b.addRunArtifact(corewire_exe);
    project.addArg("--services-sidecar");
    project.addFileArg(contract);
    project.addArg("--service-host-main");
    const host_main = project.addOutputFileArg("service_host_main.ts");
    project.addArg("--service-registry");
    const registry_source = project.addOutputFileArg("services.zig");
    project.addArg("--service-inproc-main");
    const inproc_main = project.addOutputFileArg("service_inproc_main.ts");
    project.addArg("--service-inproc-profile");
    const inproc_profile = project.addOutputFileArg("service_profile.json");

    const stage = b.addSystemCommand(&.{node});
    stage.addFileArg(b.path("packages/core/scripts/stage_external_services.mjs"));
    stage.addArg("--src");
    stage.addDirectoryArg(src_dir);
    stage.addArg("--host-main");
    stage.addFileArg(host_main);
    stage.addArg("--inproc-main");
    stage.addFileArg(inproc_main);
    stage.addArg("--inproc-profile");
    stage.addFileArg(inproc_profile);
    stage.addArg("--contract");
    stage.addFileArg(contract);
    stage.addArg("--out");
    const stage_dir = stage.addOutputDirectoryArg("services-stage");
    // A LazyPath directory records only its producer dependency; source-tree
    // content does not otherwise participate in Run's cache key. Service
    // files are discovered recursively by the staging script, so rerun this
    // cheap copy step whenever the lane is requested rather than risk a stale
    // compiled host after an author edits a nested service module.
    stage.has_side_effects = true;

    const compile = b.addSystemCommand(&.{node});
    compile.addFileArg(b.path("packages/core/scripts/run_external_service_compiler.mjs"));
    compile.addFileInput(b.path("packages/core/scripts/compiler_command.mjs"));
    compile.addArg("--stage");
    compile.addDirectoryArg(stage_dir);
    compile.addArg("--manifest");
    compile.addFileArg(b.path("packages/core/package.json"));
    compile.addArg("--contract");
    compile.addFileArg(contract);
    // Mobile targets are archive-only (no child process exists there): the
    // driver refuses --out-exe, so the child-carrier batteries get a stub
    // path they never execute for those targets.
    const mobile_target = target.result.os.tag == .ios or target.result.abi.isAndroid();
    const executable: std.Build.LazyPath = if (mobile_target)
        b.addWriteFiles().add(b.fmt("{s}-unavailable-on-mobile", .{name}), "")
    else exe: {
        compile.addArg("--out-exe");
        const suffix = if (target.result.os.tag == .windows) ".exe" else "";
        break :exe compile.addOutputFileArg(b.fmt("{s}{s}", .{ name, suffix }));
    };
    const archive: ?std.Build.LazyPath = if (emit_archive) archive: {
        compile.addArg("--out-archive");
        break :archive compile.addOutputFileArg(b.fmt("lib{s}.a", .{name}));
    } else null;
    const host_platform = b.fmt("{t}-{t}-{t}", .{ b.graph.host.result.cpu.arch, b.graph.host.result.os.tag, b.graph.host.result.abi });
    compile.addArgs(&.{ "--host-platform", host_platform, "--target-platform", app_build.scriptcPlatformTriple(b, target), "--zig-exe", b.graph.zig_exe });
    app_build.addScriptcAndroidNdk(b, compile, target);
    addScriptcGlibcFloorTeaching(b, target, &compile.step);
    if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER")) |override| {
        compile.addArgs(&.{ "--compiler", override });
    } else {
        compile.addArgs(&.{ "--compiler", repositoryScriptcBin(b) });
    }

    return .{
        .executable = executable,
        .archive = archive,
        .registry = b.createModule(.{
            .root_source_file = registry_source,
            .target = target,
            .optimize = optimize,
        }),
    };
}

const FacadeProjections = struct {
    sidecar: std.Build.LazyPath,
    facade: std.Build.LazyPath,
    profile: std.Build.LazyPath,
};

/// A sidecar's compiled-core projections: the effective contract after
/// caller-stated demotions, the generated entry module (core_facade.ts), and
/// the compiler profile that builds it (core_profile.json), emitted by one
/// corewire invocation so no staged sibling can describe a different layout.
fn facadeProjections(
    b: *std.Build,
    corewire_exe: *std.Build.Step.Compile,
    sidecar_json: std.Build.LazyPath,
    f64_slots: []const []const u8,
) FacadeProjections {
    const generate = b.addRunArtifact(corewire_exe);
    generate.addArg("--sidecar");
    generate.addFileArg(sidecar_json);
    generate.addArg("--facade");
    const facade = generate.addOutputFileArg("core_facade.ts");
    generate.addArg("--profile");
    const profile = generate.addOutputFileArg("core_profile.json");
    generate.addArg("--effective-sidecar");
    const sidecar = generate.addOutputFileArg("core.contract.json");
    for (f64_slots) |slot| {
        generate.addArg("--f64-slot");
        generate.addArg(slot);
    }
    return .{ .sidecar = sidecar, .facade = facade, .profile = profile };
}

/// One fixture's generated-mirror module: run corewire over the
/// sidecar, stage the emitted core_shim.zig as core.zig beside its two
/// staged runtime files (shim_rt.zig, core_abi.zig) — the same staging
/// shape the transpiler lane gives its emitted core and rt.zig.
fn sidecarShimModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    corewire_exe: *std.Build.Step.Compile,
    sidecar_json: std.Build.LazyPath,
) *std.Build.Module {
    const generate = b.addRunArtifact(corewire_exe);
    generate.addArg("--sidecar");
    generate.addFileArg(sidecar_json);
    generate.addArg("--out");
    const generated = generate.addOutputFileArg("core_shim.zig");
    const staged = b.addWriteFiles();
    const shim_root = staged.addCopyFile(generated, "core.zig");
    _ = staged.addCopyFile(b.path("tools/corewire/shim_rt.zig"), "shim_rt.zig");
    _ = staged.addCopyFile(b.path("tools/corewire/core_abi.zig"), "core_abi.zig");
    return b.createModule(.{
        .root_source_file = shim_root,
        .target = target,
        .optimize = optimize,
    });
}

/// One externally compiled TS fixture core: the corewire-generated
/// mirror over the fixture's compiled archive, staged as one module in
/// the app lane's exact shape (core.zig + its shim runtime), with the
/// archive linked behind it — plus the frontend-emitted contract
/// sidecar (the document corewire's projections consume) and the
/// archive's own co-emitted sidecar.
const ExternalCoreFixture = struct {
    module: *std.Build.Module,
    /// The frontend-emitted contract (stage-core-contracts, the
    /// conformance shims).
    contract: std.Build.LazyPath,
    /// The compiled-core archive (already linked into `module`; the
    /// ABI-law suite links it directly).
    archive: std.Build.LazyPath,
    /// The archive's OWN co-emitted contract sidecar — the document its
    /// mirror must generate from (the boot identity fence pairs them).
    sidecar: std.Build.LazyPath,
    /// Present only for a two-class fixture that asks the frontend to emit the
    /// service registry sidecar from the same checked program.
    services_contract: ?std.Build.LazyPath,
};

const ExternalCoreFixtureSpec = struct {
    /// The entry module, build-root-relative (the contract's stated
    /// entry spelling).
    entry: []const u8,
    /// The compile-source directory holding the core's whole import
    /// graph (an example's src/, or a staged single-file fixture dir).
    src_dir: std.Build.LazyPath,
    /// The archive's symbol-safe stem (`lib<name>.a`).
    name: []const u8,
    /// The fixture stands in for an app whose manifest declares Tier 1.
    persist_capability: bool = false,
    /// The fixture stands in for an app whose manifest declares Tier 2.
    store_capability: bool = false,
    /// The fixture stands in for an app whose manifest declares Tier 3.
    relational_capability: bool = false,
    /// The fixture stands in for an app whose manifest declares the Tier-4
    /// build capability and its matching core-effect permission.
    credentials_capability: bool = false,
    /// Attested integer slots the compiled projection carries as f64
    /// (values that reach the f64-exact boundary have no honest i64
    /// declaration on that side) — corewire's --f64-slot demotions,
    /// applied to the compile profile and every downstream projection.
    f64_slots: []const []const u8 = &.{},
    emit_services: bool = false,
    service_packages: []const []const u8 = &.{},
};

/// Compile one TS fixture core through the external core compiler at
/// build time — the same pipeline the app lane runs (build/app.zig
/// tsCoreStage): frontend check + contract, corewire facade/profile
/// projection, compile-tree staging, the exact-pinned compile, and the
/// mirror generated from the co-emitted sidecar.
fn externalCoreFixtureModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    node: []const u8,
    corewire_exe: *std.Build.Step.Compile,
    spec: ExternalCoreFixtureSpec,
) ExternalCoreFixture {
    const app_build = @import("build/app.zig");
    // The frontend, in check-only mode: the subset checker gates the
    // compile, and the contract sidecar states the build-root-relative
    // entry spelling. The frontend reads its own sources, the SDK
    // modules, and the core's WHOLE import graph at run time; declare
    // them all so edits re-check the fixture (every sibling .ts of the
    // entry is a superset of the reachable imports: over-approximation
    // only re-runs the check, never misses a stale input).
    const check = b.addSystemCommand(&.{node});
    check.addFileArg(b.path("packages/core/src/cli.ts"));
    check.addFileArg(b.path(spec.entry));
    check.addArg("--contract");
    const contract_raw = check.addOutputFileArg("core.contract.json");
    const contract = app_build.stabilizeGeneratedFile(b, contract_raw, "core.contract.json", false);
    check.addArg("--contract-entry");
    check.addArg(spec.entry);
    const services_contract: ?std.Build.LazyPath = if (spec.emit_services) services: {
        check.addArg("--services-contract");
        const raw = check.addOutputFileArg("services.contract.json");
        break :services app_build.stabilizeGeneratedFile(b, raw, "services.contract.json", false);
    } else null;
    for (spec.service_packages) |package_entry| check.addArgs(&.{ "--service-package", package_entry });
    const services_client: ?std.Build.LazyPath = if (services_contract) |service_contract| client: {
        const service_project = b.addRunArtifact(corewire_exe);
        service_project.addArg("--services-sidecar");
        service_project.addFileArg(service_contract);
        service_project.addArg("--service-client");
        const client_raw = service_project.addOutputFileArg("services.gen.ts");
        break :client app_build.stabilizeGeneratedFile(b, client_raw, "services.gen.ts", false);
    } else null;
    if (spec.persist_capability) check.addArgs(&.{ "--capability", "persist" });
    if (spec.store_capability) check.addArgs(&.{ "--capability", "store" });
    if (spec.relational_capability) check.addArgs(&.{ "--capability", "sqlite" });
    if (spec.credentials_capability) check.addArgs(&.{ "--capability", "credentials", "--permission", "credentials" });
    if (std.mem.eql(u8, spec.entry, "tests/ts-core/fixture.ts")) check.addArgs(&.{ "--permission", "filesystem" });
    tsCoreAddDirInputs(b, check, "packages/core/sdk");
    tsCoreAddDirInputs(b, check, std.fs.path.dirname(spec.entry) orelse ".");
    const frontend_sources = [_][]const u8{
        "checker.ts", "cli.ts", "contract.ts", "diagnostics.ts", "frontend.ts", "infer.ts", "modules.ts", "service_contract.ts", "sqlite_codegen.ts", "sqlite_cli.ts", "sqlite_runtime_policy.ts", "typed_ast.ts", "types.ts", "wyhash.ts",
    };
    for (frontend_sources) |source| {
        check.addFileInput(b.path(b.fmt("packages/core/src/{s}", .{source})));
    }
    // Service contracts echo the exact scriptc pin read from this manifest.
    // Declare that runtime read explicitly so a compiler bump invalidates a
    // warm build cache before the compile lane checks the echoed version.
    if (spec.emit_services) check.addFileInput(b.path("packages/core/package.json"));

    // corewire projects the generated compile entry and its profile in
    // one invocation, so the profile's entry spelling and the facade
    // file can never skew.
    const project = b.addRunArtifact(corewire_exe);
    project.addArg("--sidecar");
    project.addFileArg(contract);
    project.addArg("--facade");
    const facade = project.addOutputFileArg("core_facade.ts");
    project.addArg("--profile");
    const profile = project.addOutputFileArg("core_profile.json");
    for (spec.f64_slots) |slot| {
        project.addArg("--f64-slot");
        project.addArg(slot);
    }

    // The compile stage: author sources + staged SDK + static surface +
    // generated entry/profile, one scratch tree.
    const stage_run = b.addSystemCommand(&.{node});
    stage_run.addFileArg(b.path("packages/core/scripts/stage_external_core.mjs"));
    stage_run.addArg("--src");
    stage_run.addDirectoryArg(spec.src_dir);
    stage_run.addArg("--sdk");
    stage_run.addDirectoryArg(b.path("packages/core/sdk"));
    stage_run.addArg("--static");
    stage_run.addFileArg(b.path("packages/core/compile-surface/core.ts"));
    stage_run.addArg("--facade");
    stage_run.addFileArg(facade);
    stage_run.addArg("--profile");
    stage_run.addFileArg(profile);
    if (services_client) |client| {
        stage_run.addArg("--services-client");
        stage_run.addFileArg(client);
    }
    tsCoreAddCoreDirInputs(b, stage_run, std.fs.path.dirname(spec.entry) orelse ".");
    app_build.addStagedCoreSdkInputs(b, b, stage_run);
    stage_run.addArg("--out");
    const stage_dir = stage_run.addOutputDirectoryArg("stage");

    // The external compile: driver-verified against the SDK's exact
    // pin, archive normalized, the co-emitted sidecar captured.
    const compile = b.addSystemCommand(&.{node});
    compile.addFileArg(b.path("packages/core/scripts/run_external_core_compiler.mjs"));
    compile.addFileInput(b.path("packages/core/scripts/compiler_command.mjs"));
    compile.addArg("--stage");
    compile.addDirectoryArg(stage_dir);
    compile.addArgs(&.{ "--name", spec.name });
    compile.addArg("--manifest");
    compile.addFileArg(b.path("packages/core/package.json"));
    compile.addArg("--frontend-sidecar");
    compile.addFileArg(contract);
    compile.addArg("--out-archive");
    const archive = compile.addOutputFileArg(b.fmt("lib{s}.a", .{spec.name}));
    compile.addArg("--out-sidecar");
    const compiled_sidecar = compile.addOutputFileArg("core.contract.json");
    compile.addArgs(&.{
        "--host-platform",
        b.fmt("{t}-{t}-{t}", .{ b.graph.host.result.cpu.arch, b.graph.host.result.os.tag, b.graph.host.result.abi }),
        "--target-platform",
        app_build.scriptcPlatformTriple(b, target),
        "--zig-exe",
        b.graph.zig_exe,
    });
    app_build.addScriptcAndroidNdk(b, compile, target);
    addScriptcGlibcFloorTeaching(b, target, &compile.step);
    if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER")) |override| {
        // The development override: point at any toolchain command; the
        // driver still refuses a release other than the SDK's pin.
        compile.addArgs(&.{ "--compiler", override });
    } else {
        compile.addArgs(&.{ "--compiler", repositoryScriptcBin(b) });
    }

    // The mirror, generated from the archive's OWN co-emitted contract,
    // staged in the app lane's module shape with the archive linked
    // behind it (the compiler's runtime needs libc).
    const mirror = b.addRunArtifact(corewire_exe);
    mirror.addArg("--sidecar");
    mirror.addFileArg(compiled_sidecar);
    mirror.addArg("--out");
    const shim = mirror.addOutputFileArg("core_shim.zig");
    const staged = b.addWriteFiles();
    const shim_root = staged.addCopyFile(shim, "core.zig");
    _ = staged.addCopyFile(b.path("tools/corewire/shim_rt.zig"), "shim_rt.zig");
    _ = staged.addCopyFile(b.path("tools/corewire/core_abi.zig"), "core_abi.zig");
    const mod = b.createModule(.{
        .root_source_file = shim_root,
        .target = target,
        .optimize = optimize,
    });
    mod.link_libc = true;
    mod.addObjectFile(archive);
    addScriptcArchiveSystemLibs(mod, target);
    return .{
        .module = mod,
        .contract = contract,
        .archive = archive,
        .sidecar = compiled_sidecar,
        .services_contract = services_contract,
    };
}

/// Declare every .ts file under `dir_path` (relative to the build root) as a
/// file input of the transpile step — the recursive multi-file staleness set.
/// Service modules live below src/services/, so a flat scan would let their
/// generated contract stay stale in a warm fixture build.
fn tsCoreAddDirInputs(b: *std.Build, transpile: *std.Build.Step.Run, dir_path: []const u8) void {
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ts")) continue;
        transpile.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir_path, entry.path })));
    }
}

/// The source set stage_external_core.mjs copies: every ordinary `.ts` file,
/// excluding the independent services compiler class and declaration files.
fn tsCoreAddCoreDirInputs(b: *std.Build, stage: *std.Build.Step.Run, dir_path: []const u8) void {
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".ts") or std.mem.endsWith(u8, entry.basename, ".d.ts")) continue;
        const normalized = b.dupe(entry.path);
        for (normalized) |*char| if (char.* == '\\') {
            char.* = '/';
        };
        if (std.mem.startsWith(u8, normalized, "services/")) continue;
        stage.addFileInput(b.path(b.fmt("{s}/{s}", .{ dir_path, entry.path })));
    }
}

fn filteredTestArtifact(b: *std.Build, mod: *std.Build.Module, name: []const u8, filters: []const []const u8) *std.Build.Step.Compile {
    // use_llvm: Zig 0.16.0's self-hosted x86_64 backend miscompiles the
    // SysV C ABI for f32-heavy signatures (native_sdk_app_viewport); see
    // useLlvmWorkaround in build/app.zig for the full story and repro.
    const use_llvm = if (mod.resolved_target) |target| @import("build/app.zig").useLlvmWorkaround(target) else null;
    return b.addTest(.{ .name = name, .root_module = mod, .filters = filters, .use_llvm = use_llvm });
}

/// One slice of the framework test suite, selected by test-name filters.
/// The framework module compiles into a single test binary whose ~580
/// tests run serially in one process, which made that binary the longest
/// step in `zig build test` by a wide margin — the rest of the suite is
/// dozens of binaries that each finish in well under a second. The
/// aggregate `test` step therefore runs the framework module as one
/// filtered binary per family below, so the build runner executes the
/// families concurrently and the suite finishes with the slowest family
/// instead of the sum of all of them. `zig build test-desktop` still runs
/// the unfiltered binary when a single process is easier to debug, and
/// each family has its own `test-desktop-<name>` step.
const DesktopTestShard = struct {
    /// Suffix for the artifact name and the `test-desktop-<name>` step.
    name: []const u8,
    description: []const u8,
    /// A test file's namespace is routed to the first shard in
    /// `desktop_test_shard_specs` with a matching prefix, so earlier
    /// entries carve their family out of the later, broader ones and
    /// the final empty prefix collects every namespace left over.
    prefixes: []const []const u8,
};

const desktop_test_shard_specs = [_]DesktopTestShard{
    .{
        .name = "canvas-widget",
        .description = "Run framework canvas widget tests",
        .prefixes = &.{"runtime.canvas_widget"},
    },
    .{
        .name = "canvas-frame",
        .description = "Run framework canvas frame, budget, image, and font tests",
        .prefixes = &.{"runtime.canvas"},
    },
    .{
        .name = "ui-shell",
        .description = "Run framework UI app and shell layout tests",
        .prefixes = &.{ "runtime.ui_app", "runtime.shell" },
    },
    .{
        .name = "runtime-core",
        .description = "Run framework runtime core, effects, session, and bridge tests",
        .prefixes = &.{"runtime."},
    },
    .{
        .name = "platform",
        .description = "Run framework platform, automation, embed, and remaining tests",
        .prefixes = &.{""},
    },
};

/// A framework source file that declares top-level tests, described by
/// the dotted namespace the test runner uses in fully-qualified test
/// names: tests in src/runtime/effects_tests.zig are named
/// "runtime.effects_tests.test.<name>".
const DesktopTestFile = struct {
    namespace: []const u8,
    /// Names of the file's `test "<name>"` declarations, in source order.
    /// Unnamed `test { ... }` blocks are not listed: the test runner
    /// exempts them from filtering, so they run in every shard. That is
    /// deliberate — those blocks are the aggregators whose references
    /// make the compiler discover the named tests in the first place,
    /// and their bodies are empty at run time.
    named_tests: []const []const u8,
};

/// Test binaries for the framework module, one per shard spec. Filters
/// are derived from the source tree at configure time: every framework
/// file with a top-level `test` declaration contributes its namespace as
/// a filter ("runtime.effects_tests.test") to exactly one shard, so a
/// new test file is picked up — and routed to a shard by prefix — the
/// moment it exists, and a file can never silently fall out of
/// `zig build test` because a hand-kept list went stale.
fn desktopTestShardArtifacts(b: *std.Build, mod: *std.Build.Module) [desktop_test_shard_specs.len]*std.Build.Step.Compile {
    const files = desktopTestFiles(b);
    var filters: [desktop_test_shard_specs.len]std.ArrayList([]const u8) = @splat(.empty);
    for (files) |file| {
        const shard = desktopTestShardIndex(file.namespace);
        if (std.mem.eql(u8, file.namespace, "root")) {
            // Filters match anywhere in a fully-qualified name, and the
            // module root's namespace ("root") is a dotted suffix of
            // every other root.zig namespace ("runtime.root",
            // "platform.root", ...), so a bare "root.test" filter would
            // pull those files' tests into this shard as well. Filter
            // the module root by exact test name instead.
            for (file.named_tests) |test_name| {
                filters[shard].append(b.allocator, b.fmt("root.test.{s}", .{test_name})) catch @panic("OOM");
            }
            continue;
        }
        filters[shard].append(b.allocator, b.fmt("{s}.test", .{file.namespace})) catch @panic("OOM");
        // The same suffix hazard across two shards would run the longer
        // file's tests twice per `zig build test`. Refuse the layout up
        // front so the collision is resolved when the file is added, not
        // when a duplicated test starts flaking.
        for (files) |other| {
            if (desktopTestShardIndex(other.namespace) == shard) continue;
            if (std.mem.endsWith(u8, other.namespace, b.fmt(".{s}", .{file.namespace}))) {
                std.debug.panic(
                    "framework test shards: namespace {s} is a dotted suffix of {s} in another shard; their name filters would overlap. Adjust desktop_test_shard_specs so both land in one shard.",
                    .{ file.namespace, other.namespace },
                );
            }
        }
    }
    var artifacts: [desktop_test_shard_specs.len]*std.Build.Step.Compile = undefined;
    for (&artifacts, desktop_test_shard_specs, filters) |*artifact, spec, shard_filters| {
        artifact.* = filteredTestArtifact(b, mod, b.fmt("desktop-{s}-tests", .{spec.name}), shard_filters.items);
    }
    return artifacts;
}

fn desktopTestShardIndex(namespace: []const u8) usize {
    for (desktop_test_shard_specs, 0..) |spec, index| {
        for (spec.prefixes) |prefix| {
            if (std.mem.startsWith(u8, namespace, prefix)) return index;
        }
    }
    unreachable; // the final shard's empty prefix matches every namespace
}

/// Scans the framework source tree for files declaring top-level tests,
/// sorted by namespace so the generated filters — and therefore the
/// shard binaries' cache manifests — do not churn with directory
/// iteration order. src/primitives and src/tooling are separate modules
/// with their own test binaries; everything else under src/ belongs to
/// the framework module rooted at src/root.zig.
fn desktopTestFiles(b: *std.Build) []const DesktopTestFile {
    const gpa = b.allocator;
    const io = b.graph.io;
    var files: std.ArrayList(DesktopTestFile) = .empty;
    var src_dir = b.build_root.handle.openDir(io, "src", .{ .iterate = true }) catch |err|
        std.debug.panic("framework test shards: unable to open src/: {s}", .{@errorName(err)});
    defer src_dir.close(io);
    var walker = src_dir.walk(gpa) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch |err|
        std.debug.panic("framework test shards: unable to walk src/: {s}", .{@errorName(err)})) |entry|
    {
        if (entry.kind == .directory) {
            if (entry.depth() == 1 and
                (std.mem.eql(u8, entry.basename, "primitives") or std.mem.eql(u8, entry.basename, "tooling")))
            {
                walker.leave(io);
            }
            continue;
        }
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(16 * 1024 * 1024)) catch |err|
            std.debug.panic("framework test shards: unable to read src/{s}: {s}", .{ entry.path, @errorName(err) });
        var named_tests: std.ArrayList([]const u8) = .empty;
        var has_tests = false;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            // Only column-zero declarations: a test nested inside a
            // container would carry that container's namespace, which
            // these filters would not match.
            if (!std.mem.startsWith(u8, line, "test ")) continue;
            has_tests = true;
            const rest = line["test ".len..];
            if (rest.len > 0 and rest[0] == '"') {
                if (std.mem.indexOfScalar(u8, rest[1..], '"')) |end| {
                    named_tests.append(gpa, rest[1 .. 1 + end]) catch @panic("OOM");
                }
            }
        }
        if (!has_tests) continue;
        const namespace = gpa.dupe(u8, entry.path[0 .. entry.path.len - ".zig".len]) catch @panic("OOM");
        std.mem.replaceScalar(u8, namespace, std.fs.path.sep, '.');
        files.append(gpa, .{ .namespace = namespace, .named_tests = named_tests.items }) catch @panic("OOM");
    }
    const sorted = files.items;
    std.mem.sort(DesktopTestFile, sorted, {}, struct {
        fn lessThan(_: void, lhs: DesktopTestFile, rhs: DesktopTestFile) bool {
            return std.mem.lessThan(u8, lhs.namespace, rhs.namespace);
        }
    }.lessThan);
    return sorted;
}

fn addTestStep(b: *std.Build, name: []const u8, description: []const u8, artifact: *std.Build.Step.Compile) void {
    const step = b.step(name, description);
    step.dependOn(&b.addRunArtifact(artifact).step);
}

/// How an example's build is driven. `managed` examples carry only
/// app.zon + src (+ assets): the `native` CLI synthesizes their build
/// graph, so their suites run through the CLI verbs — exactly what a user
/// gets from `native init`. `owned` examples keep a build.zig of their own
/// (extra steps or flags the generated graph does not provide) and are
/// driven through plain in-dir `zig build`.
const ExampleBuildShape = enum { managed, owned };

fn addExampleTestStep(b: *std.Build, cli_exe: *std.Build.Step.Compile, group: *std.Build.Step, name: []const u8, description: []const u8, example_path: []const u8, shape: ExampleBuildShape) *std.Build.Step {
    const run = switch (shape) {
        .owned => b.addSystemCommand(&.{ "zig", "build", "test", "-Dplatform=null" }),
        .managed => managedExampleRun(b, cli_exe, &.{ "test", "-Dplatform=null" }),
    };
    run.setCwd(b.path(example_path));
    // Every example suite must actually run every time: the child build owns
    // its own caching, and this outer step's argv never changes when example
    // or framework sources do, so letting the step cache would skip real
    // tests. But a side-effect run that also inherits stdio holds the build
    // runner's global stderr lock for the child's entire lifetime, which
    // executes the example suites strictly one at a time. Capturing both
    // streams keeps the always-run semantics while releasing that lock, so
    // independent examples run concurrently (bounded by the runner's job
    // pool, one worker per CPU — cold child builds peak well under 1 GB
    // each, so a machine-wide pool of them fits in memory). On failure the
    // captured stderr is reported under this step's name, so a failing
    // example still names itself.
    run.has_side_effects = true;
    _ = run.captureStdOut(.{});
    _ = run.captureStdErr(.{});
    // Concurrent children all spawn the same binary, so carry the step name
    // into the run: a failure line then reads "test-example-<name> failure"
    // instead of nineteen indistinguishable "run exe native" entries.
    run.setName(name);
    const step = b.step(name, description);
    step.dependOn(&run.step);
    group.dependOn(&run.step);
    return step;
}

/// Run a `native` CLI verb (argv tail) against a managed example. The CLI
/// artifact runs from the build cache, where its executable location does
/// not reveal the framework checkout, so NATIVE_SDK_PATH pins the generated
/// graph's framework dependency to this repository.
fn managedExampleRun(b: *std.Build, cli_exe: *std.Build.Step.Compile, argv_tail: []const []const u8) *std.Build.Step.Run {
    const run = b.addRunArtifact(cli_exe);
    run.addArgs(argv_tail);
    run.setEnvironmentVariable("NATIVE_SDK_PATH", b.pathFromRoot("."));
    return run;
}

fn addLayoutCheckStep(b: *std.Build, group: *std.Build.Step, name: []const u8, description: []const u8, paths: []const []const u8) void {
    const step = b.step(name, description);
    for (paths) |path| {
        const check = b.addSystemCommand(&.{ "test", "-f", path });
        step.dependOn(&check.step);
        group.dependOn(&check.step);
    }
}

const FileContainsCheck = struct {
    path: []const u8,
    pattern: []const u8,
};

fn addFileContainsCheckStep(b: *std.Build, checker: *std.Build.Step.Compile, group: *std.Build.Step, name: []const u8, description: []const u8, checks: []const FileContainsCheck) void {
    const step = b.step(name, description);
    for (checks) |check_value| {
        const check = b.addRunArtifact(checker);
        // The checked paths are relative to this build script. Run steps
        // otherwise inherit the invoking process's cwd, and `zig build test`
        // is also invoked from zero-config app directories that resolve up
        // to this build.zig (scaffolded workspaces, examples) — from there
        // the relative paths would point into the app, not the repo.
        check.setCwd(b.path("."));
        check.addArg(check_value.path);
        check.addArg(check_value.pattern);
        step.dependOn(&check.step);
        group.dependOn(&check.step);
    }
}

fn packageSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux, .ios, .android => "",
    };
}

fn packageVersion(b: *std.Build) []const u8 {
    var file = std.Io.Dir.cwd().openFile(b.graph.io, "build.zig.zon", .{}) catch return "0.1.0";
    defer file.close(b.graph.io);
    var buffer: [4096]u8 = undefined;
    const len = file.readPositionalAll(b.graph.io, &buffer, 0) catch return "0.1.0";
    const bytes = buffer[0..len];
    const marker = ".version = \"";
    const start = std.mem.indexOf(u8, bytes, marker) orelse return "0.1.0";
    const value_start = start + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, bytes, value_start, '"') orelse return "0.1.0";
    return b.allocator.dupe(u8, bytes[value_start..value_end]) catch return "0.1.0";
}

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, web_engine_tool.default_cef_dir)) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

/// CEF dir for a sub-build whose cwd is an example directory (two levels
/// below the repo root). Relative paths are resolved by the example's
/// build against its own root, so the repo-root-relative default must be
/// rebased; absolute overrides pass through, but the example build.zigs
/// reject them (b.path panics), so callers should prefer relative paths.
fn exampleCefDir(b: *std.Build, cef_dir: []const u8) []const u8 {
    if (std.fs.path.isAbsolute(cef_dir)) return cef_dir;
    return b.fmt("../../{s}", .{cef_dir});
}

fn webEngineFromBuildOption(option: WebEngineOption) web_engine_tool.Engine {
    return switch (option) {
        .system => .system,
        .chromium => .chromium,
    };
}

fn buildWebEngineFromResolved(engine: web_engine_tool.Engine) WebEngineOption {
    return switch (engine) {
        .system => .system,
        .chromium => .chromium,
    };
}
