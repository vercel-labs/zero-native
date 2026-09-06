// This example owns its build: it adds the frontend install/build/dev-server steps and the hand-wired WebView shell that the generated app graph does not provide.
const std = @import("std");

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
};

const default_native_sdk_path = "../..";
const app_exe_name = "next";

pub fn build(b: *std.Build) void {
    const target = nativeSdkTarget(b);
    const optimize = b.standardOptimizeOption(.{});
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    const automation_enabled = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
    const package_target = b.option(PackageTarget, "package-target", "Package target: macos, windows, linux") orelse .macos;
    const native_sdk_path = b.option([]const u8, "native-sdk-path", "Path to the Native SDK framework checkout") orelse default_native_sdk_path;
    const optimize_name = @tagName(optimize);
    const selected_platform: PlatformOption = switch (platform_option) {
        .auto => if (target.result.os.tag == .macos) .macos else if (target.result.os.tag == .linux) .linux else if (target.result.os.tag == .windows) .windows else .null,
        else => platform_option,
    };
    if (selected_platform == .macos and target.result.os.tag != .macos) {
        @panic("-Dplatform=macos requires a macOS target");
    }
    if (selected_platform == .linux and target.result.os.tag != .linux) {
        @panic("-Dplatform=linux requires a Linux target");
    }
    if (selected_platform == .windows and target.result.os.tag != .windows) {
        @panic("-Dplatform=windows requires a Windows target");
    }
    const app_web_engine = appWebEngineConfig();
    const web_engine = web_engine_override orelse app_web_engine.web_engine;
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_web_engine.cef_dir);
    const cef_auto_install = cef_auto_install_override orelse app_web_engine.cef_auto_install;
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }

    const native_sdk_mod = nativeSdkModule(b, target, optimize, native_sdk_path);
    const options = b.addOptions();
    options.addOption([]const u8, "platform", switch (selected_platform) {
        .auto => unreachable,
        .null => "null",
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
    });
    options.addOption([]const u8, "trace", @tagName(trace_option));
    options.addOption([]const u8, "web_engine", @tagName(web_engine));
    options.addOption(bool, "debug_overlay", debug_overlay);
    options.addOption(bool, "automation", automation_enabled);
    options.addOption(bool, "js_bridge", js_bridge_enabled);
    const options_mod = options.createModule();

    const runner_mod = localModule(b, target, optimize, "src/runner.zig");
    runner_mod.addImport("native_sdk", native_sdk_mod);
    runner_mod.addImport("build_options", options_mod);
    runner_mod.addImport("app_manifest_zon", b.createModule(.{ .root_source_file = b.path("app.zon") }));

    const app_mod = localModule(b, target, optimize, "src/main.zig");
    app_mod.addImport("native_sdk", native_sdk_mod);
    app_mod.addImport("runner", runner_mod);
    const exe = b.addExecutable(.{
        .name = app_exe_name,
        .root_module = app_mod,
        // Zig 0.16.0's self-hosted x86_64 backend (the Debug default)
        // miscompiles the SysV C calling convention for the long
        // mixed-argument signatures the platform hosts use, shifting
        // stack-passed pointers by one slot (a Debug run on x86_64 Linux
        // crashes creating its first shell view). Force LLVM there,
        // mirroring the Native SDK build graph; Release modes already
        // use LLVM, so only Debug changes.
        .use_llvm = useLlvmWorkaround(target),
    });
    linkPlatform(b, target, app_mod, exe, selected_platform, web_engine, native_sdk_path, cef_dir, cef_auto_install);
    b.installArtifact(exe);

    const frontend_install = b.addSystemCommand(&.{ "npm", "install", "--prefix", "frontend" });
    const frontend_install_step = b.step("frontend-install", "Install frontend dependencies");
    frontend_install_step.dependOn(&frontend_install.step);

    const frontend_build = b.addSystemCommand(&.{ "npm", "--prefix", "frontend", "run", "build" });
    frontend_build.step.dependOn(&frontend_install.step);
    const frontend_step = b.step("frontend-build", "Build the frontend");
    frontend_step.dependOn(&frontend_build.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(&frontend_build.step);
    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
    addWebView2RuntimeRunFiles(b, target, run, web_engine, native_sdk_path);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    const dev = b.addSystemCommand(&.{ "native", "dev", "--manifest", "app.zon", "--binary" });
    dev.addFileArg(exe.getEmittedBin());
    dev.step.dependOn(&exe.step);
    dev.step.dependOn(&frontend_install.step);
    const dev_step = b.step("dev", "Run the frontend dev server and native shell");
    dev_step.dependOn(&dev.step);

    const package = b.addSystemCommand(&.{
        "native",
        "package",
        "--target",
        @tagName(package_target),
        "--manifest",
        "app.zon",
        "--assets",
        "frontend/out",
        "--optimize",
        optimize_name,
        "--output",
        b.fmt("zig-out/package/{s}-0.1.0-{s}-{s}{s}", .{ app_exe_name, @tagName(package_target), optimize_name, packageSuffix(package_target) }),
        "--binary",
    });
    package.addFileArg(exe.getEmittedBin());
    package.addArgs(&.{ "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
    if (cef_auto_install) package.addArg("--cef-auto-install");
    package.step.dependOn(&exe.step);
    package.step.dependOn(&frontend_build.step);
    const package_step = b.step("package", "Create a local package artifact");
    package_step.dependOn(&package.step);

    const tests = b.addTest(.{ .root_module = app_mod });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn nativeSdkTarget(b: *std.Build) std.Build.ResolvedTarget {
    const target = b.standardTargetOptions(.{});
    if (target.result.os.tag != .macos) return target;

    if (b.sysroot == null) {
        b.sysroot = macosSdkPath(b) orelse b.sysroot;
    }

    var query = target.query;
    query.os_tag = .macos;
    query.os_version_min = .{ .semver = .{ .major = 11, .minor = 0, .patch = 0 } };
    return b.resolveTargetQuery(query);
}

fn macosSdkPath(b: *std.Build) ?[]const u8 {
    if (b.graph.environ_map.get("SDKROOT")) |sdkroot| {
        if (sdkroot.len > 0) return sdkroot;
    }

    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return null;
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        b.allocator.free(result.stdout);
        return null;
    }
    return std.mem.trimEnd(u8, result.stdout, "\r\n");
}

fn localModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
    });
}

fn nativeSdkPath(b: *std.Build, native_sdk_path: []const u8, sub_path: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = b.pathJoin(&.{ native_sdk_path, sub_path }) };
}

fn nativeSdkModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8) *std.Build.Module {
    const geometry_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/geometry/root.zig");
    const assets_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/assets/root.zig");
    const app_dirs_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_dirs/root.zig");
    const trace_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/trace/root.zig");
    const app_manifest_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/platform_info/root.zig");
    const json_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/json/root.zig");
    const canvas_mod = externalModule(b, target, optimize, native_sdk_path, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    const debug_mod = externalModule(b, target, optimize, native_sdk_path, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const native_sdk_mod = externalModule(b, target, optimize, native_sdk_path, "src/root.zig");
    native_sdk_mod.addImport("geometry", geometry_mod);
    native_sdk_mod.addImport("assets", assets_mod);
    native_sdk_mod.addImport("app_dirs", app_dirs_mod);
    native_sdk_mod.addImport("trace", trace_mod);
    native_sdk_mod.addImport("app_manifest", app_manifest_mod);
    native_sdk_mod.addImport("diagnostics", diagnostics_mod);
    native_sdk_mod.addImport("platform_info", platform_info_mod);
    native_sdk_mod.addImport("json", json_mod);
    native_sdk_mod.addImport("canvas", canvas_mod);
    return native_sdk_mod;
}

fn externalModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_sdk_path: []const u8, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = nativeSdkPath(b, native_sdk_path, path),
        .target = target,
        .optimize = optimize,
    });
}

fn linkPlatform(b: *std.Build, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, native_sdk_path: []const u8, cef_dir: []const u8, cef_auto_install: bool) void {
    if (platform == .macos) {
        switch (web_engine) {
            .system => {
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/appkit_host.m"), .flags = flags });
                app_mod.linkFramework("WebKit", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                // The SDK's usr/include must stay a system include dir (searched after zig's
                // bundled libc++/libc headers). A plain -I shadows libc++'s <string.h>/<math.h>
                // wrappers in ObjC++ and surfaces SDK nullability gaps as a diagnostic flood.
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-isystem{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include, include_arg, define_arg } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC++", "-std=c++17", "-stdlib=libc++", "-mmacosx-version-min=11.0", include_arg, define_arg };
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/cef_host.mm"), .flags = flags });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkFramework("Chromium Embedded Framework", .{});
                app_mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
            },
        }
        if (b.sysroot) |sysroot| {
            app_mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/macos/capture_info_plist.c"), .flags = &.{} });
        app_mod.linkFramework("AppKit", .{});
        // The audio playback service (the AppKit host's single AVPlayer).
        app_mod.linkFramework("AVFoundation", .{});
        app_mod.linkFramework("CoreMedia", .{});
        app_mod.linkFramework("ScreenCaptureKit", .{ .weak = true });
        // CVPixelBuffer for the video frame path (the AppKit host's
        // AVPlayerItemVideoOutput frames are real CoreVideo symbols).
        app_mod.linkFramework("CoreVideo", .{});
        // Spectrum analysis of the app's own playback: the MediaToolbox
        // audio tap hands the player's PCM to the host, and Accelerate
        // (vDSP) turns it into band magnitudes.
        app_mod.linkFramework("MediaToolbox", .{});
        app_mod.linkFramework("Accelerate", .{});
        app_mod.linkFramework("Foundation", .{});
        app_mod.linkFramework("CoreText", .{});
        app_mod.linkFramework("UniformTypeIdentifiers", .{});
        app_mod.linkFramework("Security", .{});
        app_mod.linkFramework("Metal", .{});
        app_mod.linkFramework("QuartzCore", .{});
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("c++", .{});
    } else if (platform == .linux) {
        switch (web_engine) {
            .system => {
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/gtk_host.c"), .flags = &.{} });
                app_mod.linkSystemLibrary("gtk4", .{});
                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
                app_mod.linkSystemLibrary("dl", .{});
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
                app_mod.linkSystemLibrary("cef", .{});
                app_mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
    } else if (platform == .windows) {
        switch (web_engine) {
            .system => {
                // The vendored WebView2 SDK header (third_party/webview2)
                // turns on the host's embedded-WebView layer; the host
                // fails the compile by design if it cannot be found.
                app_mod.addIncludePath(nativeSdkPath(b, native_sdk_path, "third_party/webview2/include"));
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/webview2_host.cpp"), .flags = &.{"-std=c++17"} });
                // WebView2Loader.dll rides next to the installed app
                // executable: the host loads it at runtime to discover
                // the machine's WebView2 runtime. Canvas apps never
                // touch it.
                const loader = b.addInstallBinFile(nativeSdkPath(b, native_sdk_path, webView2LoaderSubPath(target)), "WebView2Loader.dll");
                b.getInstallStep().dependOn(&loader.step);
            },
            .chromium => {
                const cef_check = addCefCheck(b, target, cef_dir);
                if (cef_auto_install) {
                    const cef_auto = b.addSystemCommand(&.{ "native", "cef", "install", "--dir", cef_dir });
                    cef_check.step.dependOn(&cef_auto.step);
                }
                exe.step.dependOn(&cef_check.step);
                const include_arg = b.fmt("-I{s}", .{cef_dir});
                const define_arg = b.fmt("-DNATIVE_SDK_CEF_DIR=\"{s}\"", .{cef_dir});
                app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
                app_mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
            },
        }
        app_mod.addCSourceFile(.{ .file = nativeSdkPath(b, native_sdk_path, "src/platform/windows/gpu_surface_renderer.cpp"), .flags = &.{"-std=c++17"} });
        app_mod.linkSystemLibrary("c", .{});
        app_mod.linkSystemLibrary("c++", .{});
        app_mod.linkSystemLibrary("user32", .{});
        app_mod.linkSystemLibrary("gdi32", .{});
        app_mod.linkSystemLibrary("d2d1", .{});
        app_mod.linkSystemLibrary("d3d11", .{});
        app_mod.linkSystemLibrary("dxgi", .{});
        app_mod.linkSystemLibrary("dwrite", .{});
        app_mod.linkSystemLibrary("imm32", .{});
        app_mod.linkSystemLibrary("comctl32", .{});
        app_mod.linkSystemLibrary("ole32", .{});
        app_mod.linkSystemLibrary("oleacc", .{});
        app_mod.linkSystemLibrary("shell32", .{});
        // The audio backend: Media Foundation (session + source resolver
        // + streaming audio renderer) and WinHTTP (the cache fill).
        app_mod.linkSystemLibrary("mf", .{});
        app_mod.linkSystemLibrary("mfplat", .{});
        app_mod.linkSystemLibrary("winhttp", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
    }
}

/// The vendored WebView2Loader.dll for the target architecture, relative
/// to the framework root.
fn webView2LoaderSubPath(target: std.Build.ResolvedTarget) []const u8 {
    return if (target.result.cpu.arch == .aarch64)
        "third_party/webview2/arm64/WebView2Loader.dll"
    else
        "third_party/webview2/x64/WebView2Loader.dll";
}

/// `zig build run` executes the cached artifact, which has no installed
/// WebView2Loader.dll beside it; the vendored loader's directory goes on
/// the run step's PATH so the host's LoadLibrary resolves it in dev runs.
fn addWebView2RuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, web_engine: WebEngineOption, native_sdk_path: []const u8) void {
    if (web_engine != .system) return;
    if (target.result.os.tag != .windows) return;
    const loader_dir = std.fs.path.dirname(webView2LoaderSubPath(target)).?;
    run.addPathDir(b.pathFromRoot(b.pathJoin(&.{ native_sdk_path, loader_dir })));
}

fn addCefRuntimeRunFiles(b: *std.Build, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, exe: *std.Build.Step.Compile, web_engine: WebEngineOption, cef_dir: []const u8) void {
    if (web_engine != .chromium) return;
    if (target.result.os.tag != .macos) return;
    const copy = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\set -e
            \\exe="$0"
            \\exe_dir="$(dirname "$exe")"
            \\rm -rf "zig-out/Frameworks/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/Chromium Embedded Framework.framework" &&
            \\mkdir -p "zig-out/Frameworks" "zig-out/bin/Frameworks" ".zig-cache/o/Frameworks" "$exe_dir" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/Frameworks/" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" "zig-out/bin/Frameworks/" &&
            \\cp -R "{s}/Release/Chromium Embedded Framework.framework" ".zig-cache/o/Frameworks/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libEGL.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libGLESv2.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/libvk_swiftshader.dylib" "$exe_dir/" &&
            \\cp "{s}/Release/Chromium Embedded Framework.framework/Libraries/vk_swiftshader_icd.json" "$exe_dir/"
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
    });
    copy.addFileArg(exe.getEmittedBin());
    run.step.dependOn(&copy.step);
}

fn addCefCheck(b: *std.Build, target: std.Build.ResolvedTarget, cef_dir: []const u8) *std.Build.Step.Run {
    const script = switch (target.result.os.tag) {
        .macos => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -d "{s}/Release/Chromium Embedded Framework.framework" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Expected:" >&2
            \\  echo "  {s}/include/cef_app.h" >&2
            \\  echo "  {s}/Release/Chromium Embedded Framework.framework" >&2
            \\  echo "  {s}/libcef_dll_wrapper/libcef_dll_wrapper.a" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  echo "Or rerun with: -Dcef-auto-install=true" >&2
            \\  echo "Pass -Dcef-dir=/path/to/cef if your bundle lives elsewhere." >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir, cef_dir }),
        .linux => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.so" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.a" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        .windows => b.fmt(
            \\test -f "{s}/include/cef_app.h" &&
            \\test -f "{s}/Release/libcef.dll" &&
            \\test -f "{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib" || {{
            \\  echo "missing CEF dependency for -Dweb-engine=chromium" >&2
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
        else => "echo unsupported CEF target >&2; exit 1",
    };
    return b.addSystemCommand(&.{ "sh", "-c", script });
}

fn packageSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux => "",
    };
}

const AppWebEngineConfig = struct {
    web_engine: WebEngineOption = .system,
    cef_dir: []const u8 = "third_party/cef/macos",
    cef_auto_install: bool = false,
};

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

fn appWebEngineConfig() AppWebEngineConfig {
    const source = @embedFile("app.zon");
    var config: AppWebEngineConfig = .{};
    if (stringField(source, ".web_engine")) |value| {
        config.web_engine = parseWebEngine(value) orelse .system;
    }
    if (objectSection(source, ".cef")) |cef| {
        if (stringField(cef, ".dir")) |value| config.cef_dir = value;
        if (boolField(cef, ".auto_install")) |value| config.cef_auto_install = value;
    }
    return config;
}

fn parseWebEngine(value: []const u8) ?WebEngineOption {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return null;
}

fn stringField(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    const start_quote = std.mem.indexOfScalarPos(u8, source, equals, '"') orelse return null;
    const end_quote = std.mem.indexOfScalarPos(u8, source, start_quote + 1, '"') orelse return null;
    return source[start_quote + 1 .. end_quote];
}

fn objectSection(source: []const u8, field: []const u8) ?[]const u8 {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, source, field_index, '{') orelse return null;
    var depth: usize = 0;
    var index = open;
    while (index < source.len) : (index += 1) {
        switch (source[index]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return source[open + 1 .. index];
            },
            else => {},
        }
    }
    return null;
}

fn boolField(source: []const u8, field: []const u8) ?bool {
    const field_index = std.mem.indexOf(u8, source, field) orelse return null;
    const equals = std.mem.indexOfScalarPos(u8, source, field_index, '=') orelse return null;
    var index = equals + 1;
    while (index < source.len and std.ascii.isWhitespace(source[index])) : (index += 1) {}
    if (std.mem.startsWith(u8, source[index..], "true")) return true;
    if (std.mem.startsWith(u8, source[index..], "false")) return false;
    return null;
}

// Zig 0.16.0's self-hosted x86_64 backend miscompiles the SysV C calling
// convention for long mixed int/pointer/double signatures (the platform
// hosts' view-create calls) and f32-heavy ones (the embed viewport ABI):
// stack-passed arguments arrive shifted, so a Debug x86_64 build crashes
// at the first platform call that passes strings on the stack. Force the
// LLVM backend on x86_64 until the upstream backend is fixed; Release
// modes already default to LLVM, so this only changes Debug builds.
fn useLlvmWorkaround(target: std.Build.ResolvedTarget) ?bool {
    return if (target.result.cpu.arch == .x86_64) true else null;
}
