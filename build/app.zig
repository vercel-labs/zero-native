//! Framework build helper: `addApp` gives a markup/builder app a complete
//! build (exe, run, test) from a ~5-line build.zig. The app supplies
//! src/main.zig, app.zon, and assets; the runner and all framework modules
//! come from the native-sdk dependency.

const std = @import("std");
const builtin = @import("builtin");
const json_to_zon = @import("../src/tooling/json_to_zon.zig");

/// Canonicalize a generated file by its CONTENT before another build step
/// consumes it. `std.Build.Step.Run` normally places outputs under a cache
/// directory keyed by every declared input. That is correct for the producer,
/// but it means an unrelated input can change the output PATH even when the
/// file's bytes are identical; downstream Run steps hash that path and miss
/// their own caches. TypeScript's combined frontend is exactly that shape:
/// service implementation edits re-run the checker while often leaving the
/// core ABI contract byte-identical.
///
/// This narrow adapter gives equal bytes one immutable cache path. Consumers
/// still invalidate whenever the bytes change, while producer-only churn
/// stops here. It is public so the repository's fixture graph can exercise
/// the same boundary as app builds.
pub fn stabilizeGeneratedFile(b: *std.Build, source: std.Build.LazyPath, basename: []const u8, trace: bool) std.Build.LazyPath {
    return StableGeneratedFile.create(b, source, basename, trace).lazyPath();
}

const StableGeneratedFile = struct {
    step: std.Build.Step,
    source: std.Build.LazyPath,
    basename: []const u8,
    trace: bool,
    generated: std.Build.GeneratedFile,

    fn create(b: *std.Build, source: std.Build.LazyPath, basename: []const u8, trace: bool) *StableGeneratedFile {
        const stable = b.allocator.create(StableGeneratedFile) catch @panic("OOM");
        stable.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("stabilize generated {s}", .{basename}),
                .owner = b,
                .makeFn = make,
            }),
            .source = source.dupe(b),
            .basename = b.dupePath(basename),
            .trace = trace,
            .generated = undefined,
        };
        stable.generated = .{ .step = &stable.step };
        source.addStepDependencies(&stable.step);
        return stable;
    }

    fn lazyPath(self: *StableGeneratedFile) std.Build.LazyPath {
        return .{ .generated = .{ .file = &self.generated } };
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *StableGeneratedFile = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const arena = b.allocator;
        const source_path = self.source.getPath3(b, step);
        const bytes = source_path.root_dir.handle.readFileAlloc(io, source_path.sub_path, arena, .limited(64 * 1024 * 1024)) catch |err|
            return step.fail("cannot stabilize generated {s}: {t}", .{ self.basename, err });

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const output_dir = b.pathJoin(&.{ "o", "native-stable", &hex });
        const output_path = b.pathJoin(&.{ output_dir, self.basename });
        self.generated.path = try b.cache_root.join(arena, &.{output_path});

        var reused = false;
        if (b.cache_root.handle.readFileAlloc(io, output_path, arena, .limited(64 * 1024 * 1024))) |existing| {
            reused = std.mem.eql(u8, existing, bytes);
        } else |_| {}
        if (!reused) {
            b.cache_root.handle.createDirPath(io, output_dir) catch |err|
                return step.fail("cannot create the stable generated-output directory for {s}: {t}", .{ self.basename, err });
            var atomic = b.cache_root.handle.createFileAtomic(io, output_path, .{ .replace = true }) catch |err|
                return step.fail("cannot stage stable generated {s}: {t}", .{ self.basename, err });
            defer atomic.deinit(io);
            atomic.file.writeStreamingAll(io, bytes) catch |err|
                return step.fail("cannot write stable generated {s}: {t}", .{ self.basename, err });
            atomic.replace(io) catch |err|
                return step.fail("cannot publish stable generated {s}: {t}", .{ self.basename, err });
        }
        step.result_cached = reused;
        if (self.trace) std.debug.print("native build trace: {s} content {s} {s}\n", .{
            self.basename,
            &hex,
            if (reused) "reused" else "changed",
        });
    }
};

/// The shared web-layer inference contract: this build graph is one thin
/// adapter over it (the CLI's manifest tooling and the app runner are the
/// others), feeding it the inputs only this boundary sees — the
/// `-Dweb-engine` and `-Dweb-layer` flags resolved against app.zon.
const web_layer_contract = @import("../src/primitives/app_manifest/web_layer.zig");

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

const WebEngineOption = web_layer_contract.WebEngine;

const WebLayerOption = web_layer_contract.WebViewLayer;

pub const AppOptions = struct {
    name: []const u8,
    /// Explicit manifest path. Null auto-detects app.json first, then app.zon,
    /// so older owned build.zig files can adopt JSON without a build edit.
    manifest: ?[]const u8 = null,
    /// App entry point; defaults to src/main.zig (relative to `app_root`).
    main: []const u8 = "src/main.zig",
    /// Root of the app source tree, relative to the build root. "." for a
    /// build.zig that lives in the app directory (every ejected app). The
    /// CLI's generated build graph under `<app>/.native/build/` passes
    /// "../.." so `src/`, `app.zon`, and `assets/` keep resolving in the
    /// app directory rather than the cache directory.
    app_root: []const u8 = ".",
    /// Live `<terminal>` sessions: set true AND pin ghostty as a LAZY
    /// dependency in the app's OWN build.zig.zon (the examples/workbench
    /// pin) — the framework then resolves `ghostty-vt` with the app
    /// module's target/optimize and the safe flags (simd off, no macOS
    /// app or xcframework artifacts), and the runtime owns the emulator
    /// behind every `<terminal pty={key}>` binding. Default false wires
    /// the stub: `<terminal>` renders the honest empty surface, and the
    /// build never traverses ghostty's dependency graph (whose configure
    /// step walks wuffs/translate_c and whose full build pulls harfbuzz)
    /// — the load-bearing property for scaffolded apps.
    terminal_sessions: bool = false,
};

/// Which core the app tree carries. No flag and no config anywhere: the
/// tree IS the truth — `src/core.ts` is a TypeScript core (compiled to
/// native code at build time, run through generated wiring),
/// `src/main.zig` a Zig one, and both at once is a teaching error
/// naming the two files.
const CoreTree = enum { zig, ts, both, neither };

fn detectCoreTree(b: *std.Build, app_root: []const u8) CoreTree {
    const has_ts = appFileExists(b, app_root, "src/core.ts");
    const has_zig = appFileExists(b, app_root, "src/main.zig");
    if (has_ts and has_zig) return .both;
    if (has_ts) return .ts;
    if (has_zig) return .zig;
    return .neither;
}

fn appFileExists(b: *std.Build, app_root: []const u8, sub_path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, appPath(b, app_root, sub_path), .{}) catch return false;
    return true;
}

fn appManifestName(b: *std.Build, app_root: []const u8, requested: ?[]const u8) []const u8 {
    if (requested) |name| return name;
    if (appFileExists(b, app_root, "app.json")) return "app.json";
    return "app.zon";
}

fn appManifestPath(b: *std.Build, app_root: []const u8, manifest_name: []const u8) []const u8 {
    return appPath(b, app_root, manifest_name);
}

/// Produce the Zig module consumed by the existing comptime manifest wiring.
/// ZON manifests are already modules; JSON manifests are converted losslessly
/// into a generated module, keeping one runtime feature path for both formats.
fn appManifestModule(b: *std.Build, app_root: []const u8, manifest_name: []const u8) *std.Build.Module {
    const path = appManifestPath(b, app_root, manifest_name);
    if (!json_to_zon.isJsonPath(path)) {
        return b.createModule(.{ .root_source_file = b.path(path) });
    }
    const source = b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(1024 * 1024)) catch
        @panic("cannot read app.json");
    const zon = json_to_zon.convertAlloc(b.allocator, source) catch |err| switch (err) {
        error.NullNotAllowed => @panic("app.json cannot contain null values; omit optional fields instead"),
        else => @panic("cannot convert app.json into the build-time manifest module; run `native check` for a precise diagnostic"),
    };
    const generated = b.addWriteFiles().add("app_manifest.zon", zon);
    return b.createModule(.{ .root_source_file = generated });
}

const TsWindowView = struct {
    label: []const u8,
    source_path: []const u8,
    staged_path: []const u8,
};

const TsMarkupSource = struct {
    set_path: []const u8,
    source_path: []const u8,
    staged_path: []const u8,
};

const TsWindowViews = struct {
    views: []const TsWindowView,
    sources: []const TsMarkupSource,
};

const TsAppMarkupSources = struct {
    /// Non-root, non-window files discovered under src/. Window files are
    /// staged by the existing secondary-window registry and must not be
    /// copied a second time.
    files: []const TsMarkupSource,
    /// The root view's embedded resolver set. Its path keys are relative to
    /// src/, matching the root disk watcher; existing window sources are
    /// projected under their staged `windows/...` names.
    sources: []const TsMarkupSource,
};

const max_markup_source_path_len = 200;
const max_markup_source_path_segments = 24;
const root_markup_source_prefix = "src/";

/// Whether a path relative to `src/` fits the markup resolver once the
/// generated desktop watch and `native check` address it as `src/<path>`.
/// The compiled source set drops that prefix, but accepting a path only the
/// compiled resolver can represent would make development and release
/// disagree at the boundary.
pub fn markupSourcePathWithinBudget(path: []const u8) bool {
    var segments: usize = 1; // the disk resolver's leading `src` segment
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next() != null) segments += 1;
    return root_markup_source_prefix.len + path.len <= max_markup_source_path_len and
        segments <= max_markup_source_path_segments;
}

fn validateMarkupSourcePath(path: []const u8) void {
    if (!markupSourcePathWithinBudget(path)) {
        std.debug.panic(
            "\nTypeScript markup source path `src/{s}` exceeds the import resolver budget: the full app-relative path, including `src/`, must be at most {d} bytes and {d} segments\n",
            .{ path, max_markup_source_path_len, max_markup_source_path_segments },
        );
    }
}

pub fn isRootMarkupSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".native") and
        !std.mem.eql(u8, path, "app.native") and
        !std.mem.startsWith(u8, path, "windows/");
}

/// Default TypeScript secondary-window views are statically discovered under
/// `src/windows/`: `settings.native` serves descriptor label `settings`.
/// Direct files form the generated launcher's closed, comptime-compiled view
/// set while nested `.native` files are the shared import source set and
/// `windows(model)` owns dynamic liveness.
fn collectTsWindowViews(b: *std.Build, app_root: []const u8) TsWindowViews {
    const windows_path = appPath(b, app_root, "src/windows");
    var dir = b.build_root.handle.openDir(b.graph.io, windows_path, .{ .iterate = true }) catch return .{ .views = &.{}, .sources = &.{} };
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return .{ .views = &.{}, .sources = &.{} };
    defer walker.deinit();
    var views: std.ArrayList(TsWindowView) = .empty;
    var sources: std.ArrayList(TsMarkupSource) = .empty;
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".native")) continue;
        const normalized_path = b.dupe(entry.path);
        for (normalized_path) |*char| {
            if (char.* == '\\') char.* = '/';
        }
        sources.append(b.allocator, .{
            .set_path = normalized_path,
            .source_path = b.fmt("src/windows/{s}", .{normalized_path}),
            .staged_path = b.fmt("windows/{s}", .{normalized_path}),
        }) catch @panic("OOM");
        // Direct children are label-addressed window roots. Nested files
        // are component sources those roots may import transitively.
        if (std.mem.indexOfScalar(u8, entry.path, '/') != null or std.mem.indexOfScalar(u8, entry.path, '\\') != null) continue;
        const label = entry.path[0 .. entry.path.len - ".native".len];
        if (label.len == 0 or label.len > 64 or std.mem.eql(u8, label, ".") or std.mem.eql(u8, label, "..")) {
            @panic("\ninvalid TypeScript secondary-window view filename: use src/windows/<label>.native with a non-empty label of at most 64 bytes\n");
        }
        for (label) |ch| {
            if (ch == 0 or ch == '/' or ch == '\\') {
                @panic("\ninvalid TypeScript secondary-window view filename: the filename stem must be a valid window label\n");
            }
        }
        views.append(b.allocator, .{
            .label = b.dupe(label),
            .source_path = b.fmt("src/windows/{s}", .{entry.path}),
            .staged_path = b.fmt("windows/{s}", .{entry.path}),
        }) catch @panic("OOM");
    }
    const less = struct {
        fn than(_: void, a: TsWindowView, z: TsWindowView) bool {
            return std.mem.order(u8, a.label, z.label) == .lt;
        }
    }.than;
    std.mem.sort(TsWindowView, views.items, {}, less);
    const source_less = struct {
        fn than(_: void, a: TsMarkupSource, z: TsMarkupSource) bool {
            return std.mem.order(u8, a.set_path, z.set_path) == .lt;
        }
    }.than;
    std.mem.sort(TsMarkupSource, sources.items, {}, source_less);
    return .{ .views = views.items, .sources = sources.items };
}

/// The root TypeScript view resolves imports from every `.native` file under
/// `src/` except itself. Window files already come from collectTsWindowViews;
/// append those under `windows/...` keys so this set matches the root disk
/// resolver without changing the separate window resolver root.
fn collectAppMarkupSources(b: *std.Build, app_root: []const u8, window_views: TsWindowViews) TsAppMarkupSources {
    const src_path = appPath(b, app_root, "src");
    var dir = b.build_root.handle.openDir(b.graph.io, src_path, .{ .iterate = true }) catch
        return .{ .files = &.{}, .sources = &.{} };
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return .{ .files = &.{}, .sources = &.{} };
    defer walker.deinit();

    var files: std.ArrayList(TsMarkupSource) = .empty;
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".native")) continue;
        const normalized_path = b.dupe(entry.path);
        for (normalized_path) |*char| {
            if (char.* == '\\') char.* = '/';
        }
        if (!isRootMarkupSourcePath(normalized_path)) continue;
        validateMarkupSourcePath(normalized_path);
        files.append(b.allocator, .{
            .set_path = normalized_path,
            .source_path = b.fmt("src/{s}", .{normalized_path}),
            .staged_path = normalized_path,
        }) catch @panic("OOM");
    }

    const less = struct {
        fn than(_: void, a: TsMarkupSource, z: TsMarkupSource) bool {
            return std.mem.order(u8, a.set_path, z.set_path) == .lt;
        }
    }.than;
    std.mem.sort(TsMarkupSource, files.items, {}, less);

    var sources: std.ArrayList(TsMarkupSource) = .empty;
    sources.ensureTotalCapacity(b.allocator, files.items.len + window_views.sources.len) catch @panic("OOM");
    sources.appendSliceAssumeCapacity(files.items);
    for (window_views.sources) |source| {
        validateMarkupSourcePath(source.staged_path);
        sources.appendAssumeCapacity(.{
            .set_path = source.staged_path,
            .source_path = source.source_path,
            .staged_path = source.staged_path,
        });
    }
    std.mem.sort(TsMarkupSource, sources.items, {}, less);
    return .{ .files = files.items, .sources = sources.items };
}

fn tsAppMarkupSourcesSource(b: *std.Build, registry: TsAppMarkupSources) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator,
        \\//! Generated by build/app.zig from src/**/*.native.
        \\const native_sdk = @import("native_sdk");
        \\const canvas = native_sdk.canvas;
        \\pub const sources = [_]canvas.ui_markup.SourceFile{
        \\
    ) catch @panic("OOM");
    for (registry.sources) |source| {
        const line = std.fmt.allocPrint(
            b.allocator,
            "    .{{ .path = \"{f}\", .source = @embedFile(\"{f}\") }},\n",
            .{ std.zig.fmtString(source.set_path), std.zig.fmtString(source.staged_path) },
        ) catch @panic("OOM");
        out.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    out.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return out.items;
}

fn tsWindowRegistrySource(b: *std.Build, registry: TsWindowViews) []const u8 {
    const views = registry.views;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(b.allocator,
        \\//! Generated by build/app.zig from src/windows/<label>.native.
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\const core = @import("core.zig");
        \\const canvas = native_sdk.canvas;
        \\const Adapter = native_sdk.TsUiApp(core);
        \\const App = Adapter.App;
        \\
    ) catch @panic("OOM");
    if (registry.sources.len > 0) {
        out.appendSlice(b.allocator,
            \\const window_sources = [_]canvas.ui_markup.SourceFile{
            \\
        ) catch @panic("OOM");
        for (registry.sources) |source| {
            const line = std.fmt.allocPrint(
                b.allocator,
                "    .{{ .path = \"{f}\", .source = @embedFile(\"{f}\") }},\n",
                .{ std.zig.fmtString(source.set_path), std.zig.fmtString(source.staged_path) },
            ) catch @panic("OOM");
            out.appendSlice(b.allocator, line) catch @panic("OOM");
        }
        out.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    }
    for (views, 0..) |view, index| {
        const line = std.fmt.allocPrint(
            b.allocator,
            "const WindowView{d} = canvas.CompiledMarkupImports(core.Model, core.Msg, \"{f}\", &window_sources);\n",
            .{ index, std.zig.fmtString(std.fs.path.basename(view.staged_path)) },
        ) catch @panic("OOM");
        out.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    if (views.len == 0) {
        out.appendSlice(b.allocator,
            \\pub fn build(_: *App.Ui, _: *const core.Model, _: []const u8) App.Ui.Node {
            \\    @compileError("this TypeScript core exports windows(model), but the app has no src/windows/<label>.native views");
            \\}
            \\pub const fragments = [_]canvas.MarkupFragment{};
            \\
        ) catch @panic("OOM");
        return out.items;
    }
    out.appendSlice(b.allocator,
        \\pub fn build(ui: *App.Ui, model: *const core.Model, label: []const u8) App.Ui.Node {
        \\
    ) catch @panic("OOM");
    for (views, 0..) |view, index| {
        const line = std.fmt.allocPrint(
            b.allocator,
            "    if (std.mem.eql(u8, label, \"{f}\")) return WindowView{d}.build(ui, model);\n",
            .{ std.zig.fmtString(view.label), index },
        ) catch @panic("OOM");
        out.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    out.appendSlice(b.allocator,
        \\    @panic("windows(model) declared a label with no src/windows/<label>.native view");
        \\}
        \\pub const fragments = [_]canvas.MarkupFragment{
        \\
    ) catch @panic("OOM");
    for (views, 0..) |view, index| {
        const line = std.fmt.allocPrint(
            b.allocator,
            "    WindowView{d}.fragment(\"{f}\"),\n",
            .{ index, std.zig.fmtString(view.source_path) },
        ) catch @panic("OOM");
        out.appendSlice(b.allocator, line) catch @panic("OOM");
    }
    out.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return out.items;
}

/// How a TypeScript core compiles: through the external core compiler,
/// always. The frontend checks the core and emits its contract sidecar,
/// corewire projects the compile entry and profile, the exact-pinned
/// external toolchain builds the archive, and the app links corewire's
/// generated mirror over it. `.core_compiler` in app.zon (and the
/// `-Dcore-compiler` flag) accept only "external" — the value exists so
/// a stated choice stays stateable; the removed transpiled lane's
/// spelling is refused with a teaching (see resolveCoreCompiler).
const core_compiler_teaching =
    "\ncore_compiler = \"transpiler\" names the removed TS-to-Zig transpiled lane (v0.7.0" ++
    " removed it): a TypeScript core compiles through the external core compiler now, and" ++
    " that is the default.\nDelete the setting (or spell it \"external\").\n";

/// The staged TypeScript-core wiring: one generated directory holding the
/// core module (the generated mirror with its staged shim runtime) and the
/// SDK's generated-wiring entry (ts_core_main.zig as main.zig) — plus the
/// compiled-core archive and isolated markup data object the app module
/// links. Built once per app build and shared by the exe and test modules.
const TsCoreStage = struct {
    main_root: std.Build.LazyPath,
    /// The staged mobile wiring (ts_core_mobile.zig beside the same
    /// mirror/registry files): the embed static library's `app`
    /// module roots here on iOS/Android targets.
    mobile_root: std.Build.LazyPath,
    /// Release/mobile-only module embedding src/app.native. It lives in a
    /// separate generated directory so a Debug app-code module never gains
    /// the root markup as a transitive file input; Debug links markup_c.
    app_markup_root: std.Build.LazyPath,
    /// The compiled-core archive: the app module links it (with libc,
    /// for the toolchain's runtime) beside the staged mirror.
    archive: std.Build.LazyPath,
    /// Plain-scriptc service host compiled from src/services/, when that
    /// class exists and the child carrier is selected. It is installed/
    /// packaged beside the app executable.
    service_exe: ?std.Build.LazyPath = null,
    /// The in-process carrier's service archive (thread-instanced,
    /// runtime-localized), when that class exists and the in-process
    /// carrier is selected. The app module links it beside the core's
    /// archive.
    service_archive: ?std.Build.LazyPath = null,
    /// C source containing the primary markup bytes under stable external
    /// symbols. Compiled as a tiny data object by the final app artifact.
    markup_c: std.Build.LazyPath,
    migrations: std.Build.LazyPath,
};

/// Which carrier runs src/services/ operations. Auto preserves the isolated,
/// single-instance child carrier; apps can explicitly opt into the parallel
/// in-process pool wherever the pinned service compiler can build the
/// runtime-localized service archive for the target (see
/// serviceArchiveSupported). `.service_carrier` in app.zon and the
/// `-Dservice-carrier` flag state the choice.
const ServiceCarrierOption = enum { auto, in_process, child };

const ServiceCarrier = enum { none, child, in_process };

/// Whether the pinned compiler can build TypeScript archives/executables for
/// this host/target pairing. Native desktop targets use their host toolchain,
/// including native Windows/MSVC. Cross-Windows builds use Zig's bundled GNU
/// sysroot; an MSVC cross target has no CRT headers or libraries to compile
/// the ScriptC runtime against. Mobile targets are aarch64 only and
/// archive-only (library mode — the app links the archive; no standalone
/// executable exists there): iOS device/simulator archives build on a macOS
/// host against the selected Apple SDK, Android archives build on any
/// desktop host against a discovered NDK sysroot.
pub fn scriptcCompileSupported(host: std.Target, target: std.Build.ResolvedTarget) bool {
    const desktop_host = switch (host.os.tag) {
        .macos, .linux, .windows => true,
        else => false,
    };
    if (!desktop_host) return false;
    const cross = scriptcTargetIsCross(host, target);
    return switch (target.result.os.tag) {
        .linux => if (target.result.abi.isAndroid()) target.result.cpu.arch == .aarch64 else true,
        .windows => !cross or target.result.abi == .gnu,
        .macos => host.os.tag == .macos,
        .ios => host.os.tag == .macos and target.result.cpu.arch == .aarch64,
        else => false,
    };
}

/// Whether the pinned service compiler can build the in-process carrier's
/// archive (runtime-localized, thread-instanced) on this build host for
/// this target. Its object localizers are deliberately architecture-aware:
/// native Linux uses host binutils, cross-ELF accepts x86_64/aarch64
/// (Android's aarch64 archives ride this lane), COFF accepts x86_64 (GNU
/// when cross-compiled; the host ABI when native), and Mach-O — macOS, iOS
/// device, and iOS simulator — needs a macOS host (Apple linking rides the
/// host toolchain's SDK).
pub fn serviceArchiveSupported(host: std.Target, target: std.Build.ResolvedTarget) bool {
    if (!scriptcCompileSupported(host, target)) return false;
    const cross = scriptcTargetIsCross(host, target);
    return switch (target.result.os.tag) {
        .linux => !cross or target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64,
        .windows => target.result.cpu.arch == .x86_64,
        .macos, .ios => host.os.tag == .macos,
        else => false,
    };
}

/// Whether a Linux target's spelling lands on Zig's default glibc floor,
/// which predates `arc4random_buf` — a symbol the compiled service
/// runtime references, so the link fails late and opaquely without the
/// configure-time teaching. A native target (no `-Dtarget` os) resolves
/// the system's own glibc and is exempt; an explicitly spelled `-gnu`
/// target needs a stated glibc of 2.36 or later (or `-musl`, whose libc
/// always has the symbol).
pub fn linuxGlibcSpellingHitsDefaultFloor(target: std.Build.ResolvedTarget) bool {
    if (target.result.os.tag != .linux or !target.result.abi.isGnu()) return false;
    if (target.query.os_tag == null) return false;
    const glibc = target.query.glibc_version orelse return true;
    return glibc.order(.{ .major = 2, .minor = 36, .patch = 0 }) == .lt;
}

/// Whether ScriptC needs its zig-cc target lane rather than the native host
/// compiler. Keep this identical to the driver scripts' platform-triple
/// comparison: a stated glibc version makes an otherwise same-triple Linux
/// target cross because that floor must reach Zig's `-target` argument.
pub fn scriptcTargetIsCross(host: std.Target, target: std.Build.ResolvedTarget) bool {
    if (target.result.os.tag != host.os.tag or target.result.cpu.arch != host.cpu.arch) return true;
    // Zig's Windows host triple defaults to GNU even when native clang uses
    // the installed Windows toolchain. A same-architecture MSVC target is
    // therefore still native compiler work. Preserve an exact native GNU
    // triple too; every other ABI change needs the zig-cc cross lane.
    if (target.result.os.tag == .windows) {
        return target.result.abi != host.abi and target.result.abi != .msvc;
    }
    return target.result.abi != host.abi or target.query.glibc_version != null;
}

/// The glibc-floor teaching for explicitly targeted ScriptC builds. Both the
/// core archive and either service carrier carry the compiled TypeScript
/// runtime, so all of them hit the same missing symbol. This is independent of
/// whether the target triple happens to match the build host.
pub fn scriptcLinuxGlibcSpellingTeaching(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    return b.fmt(
        "\nTypeScript target {t}-linux-gnu uses Zig's default glibc floor, which" ++
            " predates arc4random_buf — a symbol the compiled runtime needs (glibc" ++
            " 2.36+).\nSpell the target as \"{t}-linux-gnu.2.36\" (or later), or" ++
            " \"{t}-linux-musl\".\n",
        .{ target.result.cpu.arch, target.result.cpu.arch, target.result.cpu.arch },
    );
}

pub fn panicScriptcLinuxGlibcSpelling(b: *std.Build, target: std.Build.ResolvedTarget) noreturn {
    @panic(scriptcLinuxGlibcSpellingTeaching(b, target));
}

pub fn panicUnsupportedScriptcTarget(b: *std.Build, host: std.Target, target: std.Build.ResolvedTarget) noreturn {
    if (target.result.os.tag == .windows and scriptcTargetIsCross(host, target) and target.result.abi != .gnu) {
        @panic(b.fmt(
            "\nTypeScript cross-target Windows builds require the GNU ABI: Zig supplies" ++
                " that target's CRT and system libraries, while an MSVC target needs a native" ++
                " Windows toolchain.\nBuild {t}-windows-msvc on a matching Windows host, or" ++
                " cross-compile as \"{t}-windows-gnu\".\n",
            .{ target.result.cpu.arch, target.result.cpu.arch },
        ));
    }
    if (target.result.os.tag == .ios and host.os.tag != .macos) {
        @panic(
            "\nTypeScript iOS builds run on a macOS build host only: the Apple SDK sysroot" ++
                " and Mach-O symbol localization live there.\nBuild iOS apps on a Mac.\n",
        );
    }
    @panic(
        "\nTypeScript builds support native host targets, Linux and Windows GNU cross" ++
            " targets from macOS/Linux/Windows, macOS targets from macOS, and the mobile" ++
            " targets aarch64 iOS/iOS-simulator (from macOS) and aarch64 Android." ++
            "\nChoose a supported target/host pairing.\n",
    );
}

fn resolveServiceCarrier(
    choice: ServiceCarrierOption,
    has_services: bool,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) ServiceCarrier {
    if (!has_services) return .none;
    const host = b.graph.host.result;
    const supported = serviceArchiveSupported(host, target);
    // Mobile has no child processes, so the in-process pool is the only
    // carrier there: auto resolves to it, and an explicit "child" is a
    // stated impossibility, taught rather than quietly rewritten.
    if (target.result.os.tag == .ios or target.result.abi.isAndroid()) {
        return switch (choice) {
            .auto, .in_process => if (supported) .in_process else panicUnsupportedScriptcTarget(b, host, target),
            .child => @panic(
                "\nservice_carrier = \"child\" is unavailable on mobile targets: iOS and Android" ++
                    " apps cannot spawn a sibling service process, so src/services operations run" ++
                    " on the in-process pool there.\nUse \"auto\" or \"in_process\" (desktop" ++
                    " builds of the same app keep the child carrier under auto).\n",
            ),
        };
    }
    const carrier: ServiceCarrier = switch (choice) {
        .auto, .child => .child,
        .in_process => if (supported) .in_process else @panic(
            "\nservice_carrier = \"in_process\" requires a target the pinned service compiler" ++
                " can produce a runtime-localized archive for: native Linux, cross-Linux" ++
                " x86_64/aarch64, native Windows x86_64, cross-Windows x86_64 GNU," ++
                " macOS from a macOS build host, or a mobile target." ++
                "\nUse \"child\" (or drop the setting — auto selects the child carrier)" ++
                " for this target.\n",
        ),
    };
    return carrier;
}

/// The `arch-os-abi` platform spelling every ScriptC compile lane receives.
/// A stated glibc version rides the abi (`gnu.2.36`) so the compiler's
/// cross lane builds at the spelled floor rather than the default one.
pub fn scriptcPlatformTriple(b: *std.Build, target: std.Build.ResolvedTarget) []const u8 {
    const triple = b.fmt("{t}-{t}-{t}", .{ target.result.cpu.arch, target.result.os.tag, target.result.abi });
    if (target.result.os.tag != .linux or !target.result.abi.isGnu()) return triple;
    const glibc = target.query.glibc_version orelse return triple;
    return if (glibc.patch == 0)
        b.fmt("{s}.{d}.{d}", .{ triple, glibc.major, glibc.minor })
    else
        b.fmt("{s}.{d}.{d}.{d}", .{ triple, glibc.major, glibc.minor, glibc.patch });
}

fn parseServiceCarrierOption(raw: []const u8) ServiceCarrierOption {
    if (std.mem.eql(u8, raw, "auto")) return .auto;
    if (std.mem.eql(u8, raw, "in_process")) return .in_process;
    if (std.mem.eql(u8, raw, "child")) return .child;
    @panic("\n.service_carrier must be \"auto\", \"in_process\", or \"child\"\n");
}

/// The frontend's own sources — the staleness set of every build step
/// that runs it (a frontend edit re-checks every core).
const frontend_sources = [_][]const u8{
    "checker.ts", "cli.ts", "contract.ts", "diagnostics.ts", "frontend.ts", "infer.ts", "modules.ts", "ownership.ts", "service_contract.ts", "sqlite_codegen.ts", "sqlite_cli.ts", "sqlite_runtime_policy.ts", "typed_ast.ts", "types.ts", "wyhash.ts",
};

/// Whether the frontend's TypeScript compiler (@typescript/old, the
/// exactly pinned npm alias of the real `typescript` package) RESOLVES
/// from the SDK's packages/core, by node's ancestor node_modules walk —
/// at the SDK's exactly pinned VERSION. The same semantics the CLI gates
/// on (src/tooling/ts_core.zig
/// transpilerResolution, this predicate's deliberate twin: keep the two
/// in lockstep).
///
/// Validation tracks ONLY what runtime loads, from the same origin
/// runtime resolves from: typed_ast.ts imports "@typescript/old" directly
/// and build/ts_run.mjs's load hook requires it from the target
/// packages/core/src module — src/ never carries a node_modules, so
/// packages/core is the walk origin that mirrors both. Covers every
/// layout: a repo checkout's packages/core/node_modules (nearest wins),
/// and the npm-installed CLI whose own `dependencies` carry the alias
/// (nested under the package on global prefixes, hoisted to the project
/// root on local ones, pnpm's sibling node_modules).
///
/// A stray `@typescript/typescript6` compat wrapper in a consumer tree
/// (a former dependency of this package, or the consumer's own) is
/// deliberately NOT probed: nothing imports it at run time, and holding
/// the alias's version as seen FROM a wrapper's origin against the pin
/// can only FALSE-REJECT healthy trees — a consumer's hoisted conflicting
/// `@typescript/old` wins the walk from there while the copy runtime
/// actually loads sits correctly pinned under packages/core.
///
/// Resolvable means the alias's manifest AND its entrypoint are present
/// (see tsAliasedCompilerVersion for node's error shape and the
/// mid-extraction slivers) and its installed version equals the pin —
/// read from the SDK dependency's own packages/core/package.json (the
/// `npm:typescript@X.Y.Z` alias suffix in devDependencies —
/// tsParseAliasedCompilerPin, mirroring the twin's
/// parseAliasedCompilerPin), never hardcoded, so version bumps stay a
/// one-file change.
const TsToolchainResolution = union(enum) {
    resolved,
    unresolved,
    /// The aliased compiler resolves, but at a version other than the
    /// SDK's exact pin (strings allocated on b.allocator, freed never —
    /// this is configure-time teaching data).
    version_mismatch: struct { resolved: []const u8, pinned: []const u8 },
};

fn tsToolchainResolution(b: *std.Build, dep: *std.Build.Dependency) TsToolchainResolution {
    const sdk_root = tsSdkRoot(b.allocator, b.graph.io, dep);
    // The pin first: an SDK tree whose packages/core/package.json is
    // missing or pinless is not one this gate can vouch for (the file
    // ships in every layout), so it concludes unresolved and the teaching
    // path acts.
    const pinned = tsPinnedCompilerVersion(b, sdk_root) orelse return .unresolved;
    const resolved = tsAliasedCompilerVersion(b, b.pathJoin(&.{ sdk_root, "packages", "core" })) orelse return .unresolved;
    if (std.mem.eql(u8, resolved, pinned)) return .resolved;
    return .{ .version_mismatch = .{ .resolved = resolved, .pinned = pinned } };
}

/// How runtime's `import "@typescript/old"` resolves, by node's walk FROM
/// `origin_dir` upward: the nearest ancestor
/// `node_modules/@typescript/old` wins (skipping ancestors that are
/// themselves a node_modules directory, as node does). Callers pass the
/// SDK's packages/core — the origin typed_ast.ts and ts_run.mjs resolve
/// the alias from. The walk must be a real ancestor walk, not a
/// fixed-sibling probe: npm hoists the alias to the install root on flat
/// layouts and nests it under the CLI on version conflicts. Resolvable
/// means the alias's manifest AND its entrypoint — the alias is the real
/// `typescript` package, whose `"main"` is ./lib/typescript.js (no
/// `"exports"`): a bare directory (an interrupted install, a pruned
/// node_modules) is MODULE_NOT_FOUND at run time, and a manifest without
/// its entrypoint (npm extraction is not atomic; package.json rides
/// first in the tarball) fails just as opaquely. Hardcoding it is safe
/// because the alias is exactly pinned (`npm:typescript@X.Y.Z` in both
/// manifests plus the lockfile) and drift-checked by check-version-sync.
/// A manifest without its entrypoint THROWS in node rather than
/// consulting a deeper ancestor, so it concludes unresolvable here too
/// (this predicate's deliberate twin: src/tooling/ts_core.zig's
/// aliasedCompilerVersion — keep the two in lockstep).
///
/// Returns the resolved alias's installed VERSION so the caller can hold
/// it against the SDK's pin; a resolvable-looking alias whose manifest
/// carries no version field returns null (every real npm install writes
/// one — its absence is a corrupt sliver, not a compiler to vouch for).
fn tsAliasedCompilerVersion(b: *std.Build, origin_dir: []const u8) ?[]const u8 {
    const io = b.graph.io;
    var dir: []const u8 = origin_dir;
    while (true) {
        if (!std.mem.eql(u8, std.fs.path.basename(dir), "node_modules")) {
            found: {
                const manifest_path = b.pathJoin(&.{ dir, "node_modules", "@typescript", "old", "package.json" });
                std.Io.Dir.cwd().access(io, manifest_path, .{}) catch break :found;
                std.Io.Dir.cwd().access(io, b.pathJoin(&.{ dir, "node_modules", "@typescript", "old", "lib", "typescript.js" }), .{}) catch return null;
                const manifest = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, b.allocator, .limited(64 * 1024)) catch return null;
                return tsParseQuotedManifestValue(manifest, "\"version\"", "");
            }
        }
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// The version the SDK pins its aliased compiler to, read from the SDK
/// dependency's own packages/core/package.json — the same manifest the
/// CLI's gate reads, so both surfaces learn a version bump from one file.
fn tsPinnedCompilerVersion(b: *std.Build, sdk_root: []const u8) ?[]const u8 {
    const manifest = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathJoin(&.{ sdk_root, "packages", "core", "package.json" }), b.allocator, .limited(64 * 1024)) catch return null;
    const pin = tsParseQuotedManifestValue(manifest, "\"@typescript/old\"", "npm:typescript@") orelse return null;
    // Exact X.Y.Z only (check-version-sync's pin shape), mirroring the
    // twin's parseAliasedCompilerPin: a range is not a pin.
    if (pin.len == 0) return null;
    for (pin) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return null;
    }
    if (std.mem.count(u8, pin, ".") != 2) return null;
    return pin;
}

/// Targeted scan for a manifest key's string value (the twin of
/// ts_core.zig's parsePackageVersion/parseAliasedCompilerPin scanners):
/// find `key`, expect `: "<required_prefix><value>"`, return `value`.
fn tsParseQuotedManifestValue(manifest_json: []const u8, comptime key: []const u8, comptime required_prefix: []const u8) ?[]const u8 {
    const key_at = std.mem.indexOf(u8, manifest_json, key) orelse return null;
    var rest = manifest_json[key_at + key.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\r\n");
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
    if (rest.len == 0 or rest[0] != '"') return null;
    rest = rest[1..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const value = rest[0..end];
    if (!std.mem.startsWith(u8, value, required_prefix)) return null;
    const suffix = value[required_prefix.len..];
    if (suffix.len == 0) return null;
    return suffix;
}

/// PR 166 adds both the published compile-cache bootstrap and the optional
/// library-profile optimization field. The installed bootstrap is therefore
/// the capability marker: keep older exact pins byte-for-byte compatible;
/// once that release is installed, Debug/native-dev gets `dev` and
/// release/package artifacts get `release` automatically.
fn scriptcProfileOptimization(b: *std.Build, dep: *std.Build.Dependency, optimize: std.builtin.OptimizeMode) ?[]const u8 {
    const sdk_root = tsSdkRoot(b.allocator, b.graph.io, dep);
    var dir: []const u8 = b.pathJoin(&.{ sdk_root, "packages", "core" });
    while (true) {
        if (!std.mem.eql(u8, std.fs.path.basename(dir), "node_modules")) {
            const marker = b.pathJoin(&.{ dir, "node_modules", "scriptc", "dist", "bootstrap.js" });
            std.Io.Dir.cwd().access(b.graph.io, marker, .{}) catch {
                dir = std.fs.path.dirname(dir) orelse return null;
                continue;
            };
            return if (optimize == .Debug) "dev" else "release";
        }
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// The SDK dependency's real root, resolved the way both the toolchain
/// check and its teaching name it.
fn tsSdkRoot(allocator: std.mem.Allocator, io: std.Io, dep: *std.Build.Dependency) []const u8 {
    const raw_root = dep.builder.build_root.path orelse ".";
    return std.Io.Dir.cwd().realPathFileAlloc(io, raw_root, allocator) catch raw_root;
}

const TsToolingConsumer = enum { app_core, sqlite_schema };

/// Resolve the node + pinned TypeScript loader shared by the app-core
/// frontend and relational schema generator. Keep app-shape assertions out
/// of this helper: a Zig core may use SQLite without carrying a markup view.
fn tsToolingPreflight(b: *std.Build, dep: *std.Build.Dependency, consumer: TsToolingConsumer) []const u8 {
    const node = b.findProgram(&.{"node"}, &.{}) catch switch (consumer) {
        .app_core => @panic("\nbuilding a TypeScript app core needs node on PATH (the @native-sdk/core frontend checks the" ++
            " core at build time; the binary you ship carries no JS runtime).\nInstall Node.js 24+" ++
            " — https://nodejs.org or `brew install node` — and re-run.\n"),
        .sqlite_schema => @panic("\nbuilding relational SQLite migrations needs node on PATH (the schema checker and" ++
            " migration generator run at build time; the binary you ship carries no JS runtime).\nInstall Node.js" ++
            " 24+ — https://nodejs.org or `brew install node` — and re-run.\n"),
    };
    switch (tsToolchainResolution(b, dep)) {
        .resolved => {},
        .unresolved => {
            // Safety net for direct `zig build` users: the `native` CLI
            // gates this itself, so reaching here means zig was invoked by
            // hand against an SDK whose toolchain resolves nowhere. Name
            // the SDK dependency's real location as a RESOLVED path and
            // fail the configure phase cleanly — a teaching message, never
            // a panic stack trace.
            const sdk_root = tsSdkRoot(dep.builder.allocator, dep.builder.graph.io, dep);
            switch (consumer) {
                .app_core => std.debug.print(
                    \\
                    \\error: the @native-sdk/core frontend cannot resolve its TypeScript toolchain
                    \\(its compiler, @typescript/old). On a repo checkout, install it once with:
                    \\  cd {s}/packages/core && npm ci --include=dev
                    \\(An npm-installed @native-sdk/cli carries the toolchain automatically; if it
                    \\is missing there, the install is broken - reinstall @native-sdk/cli.)
                    \\
                    \\
                , .{sdk_root}),
                .sqlite_schema => std.debug.print(
                    \\
                    \\error: the relational SQLite schema generator cannot resolve its TypeScript toolchain
                    \\(its compiler, @typescript/old). On a repo checkout, install it once with:
                    \\  cd {s}/packages/core && npm ci --include=dev
                    \\(An npm-installed @native-sdk/cli carries the toolchain automatically; if it
                    \\is missing there, the install is broken - reinstall @native-sdk/cli.)
                    \\
                    \\
                , .{sdk_root}),
            }
            std.process.exit(1);
        },
        .version_mismatch => |mismatch| {
            // The wrong-VERSION shape gets its own teaching (the CLI's
            // gate mirrors it): a conflicting consumer-tree
            // @typescript/old shadows the SDK's exact pin, and no install
            // command fixes what is already installed — the conflict has
            // to move.
            switch (consumer) {
                .app_core => std.debug.print(
                    \\
                    \\error: the @native-sdk/core frontend's TypeScript compiler resolves at the
                    \\wrong version: @typescript/old resolves to typescript {s}, but the SDK pins
                    \\npm:typescript@{s}. Another package in this tree pins a conflicting
                    \\@typescript/old - align it with the SDK's pin (or remove it) and reinstall,
                    \\so the SDK's exact pin is the copy that resolves.
                    \\
                    \\
                , .{ mismatch.resolved, mismatch.pinned }),
                .sqlite_schema => std.debug.print(
                    \\
                    \\error: the relational SQLite schema generator's TypeScript compiler resolves at the
                    \\wrong version: @typescript/old resolves to typescript {s}, but the SDK pins
                    \\npm:typescript@{s}. Another package in this tree pins a conflicting
                    \\@typescript/old - align it with the SDK's pin (or remove it) and reinstall,
                    \\so the SDK's exact pin is the copy that resolves.
                    \\
                    \\
                , .{ mismatch.resolved, mismatch.pinned }),
            }
            std.process.exit(1);
        },
    }
    return node;
}

/// The TS-core-only shape gate plus the shared tooling preflight. The
/// frontend (the subset checker and contract-sidecar emitter) runs under
/// node; the compile itself is the external toolchain's.
fn tsCorePreflight(b: *std.Build, dep: *std.Build.Dependency, app_root: []const u8) []const u8 {
    if (!appFileExists(b, app_root, "src/app.native")) {
        @panic("\nthis app has a TypeScript core (src/core.ts) but no view: TS apps render markup," ++
            " so add src/app.native (the whole view tier binds the core's model)\n");
    }
    return tsToolingPreflight(b, dep, .app_core);
}

/// The TypeScript-core compile lane: the frontend checks the core and
/// emits its contract sidecar, corewire projects the generated compile
/// entry and library-mode profile, the stager assembles the compile
/// tree (author sources with the mechanical staging transforms, the
/// staged SDK modules, the static compile surface), the exact-pinned
/// external toolchain builds the archive AND co-emits the archive's own
/// contract sidecar, and corewire generates the mirror module from THAT
/// document — so the boot identity fence always pairs the mirror with
/// its own compile. The staged module directory carries core.zig (the
/// mirror) + its staged runtime + main.zig, so the
/// generated wiring imports one fixed shape.
fn tsCoreStage(
    b: *std.Build,
    dep: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    app_root: []const u8,
    app_name: []const u8,
    persist_capability: bool,
    store_capability: bool,
    relational_capability: bool,
    credentials_capability: bool,
    credentials_permission: bool,
    persist_version: ?u64,
    service_packages: []const ServicePackageConfig,
    service_carrier_choice: ServiceCarrierOption,
    service_pool_workers: ?u8,
    build_trace: bool,
    scriptc_optimization: ?[]const u8,
) TsCoreStage {
    const node = tsCorePreflight(b, dep, app_root);
    const window_views = collectTsWindowViews(b, app_root);
    const app_markup_sources = collectAppMarkupSources(b, app_root, window_views);
    const has_services = appHasServiceFiles(b, app_root);
    if (!scriptcCompileSupported(b.graph.host.result, target)) {
        panicUnsupportedScriptcTarget(b, b.graph.host.result, target);
    }
    // Every TypeScript app compiles its core archive for the target. Any
    // explicitly spelled Linux GNU target without a sufficient glibc version
    // lands on Zig's too-old default floor, even when its triple matches the
    // build host; reject it before either compile lane reaches the linker.
    if (linuxGlibcSpellingHitsDefaultFloor(target)) {
        panicScriptcLinuxGlibcSpelling(b, target);
    }
    const service_carrier = resolveServiceCarrier(service_carrier_choice, has_services, b, target);

    // Relational schema analysis runs the real SQLite parser in memory before
    // the ordinary core checker. Its generated SDK/static surfaces carry the
    // named Cmd.q/Sub.q members, while the Zig projection embeds the exact
    // append-only migration chain the checker accepted.
    var checked_sdk_core: std.Build.LazyPath = dep.path("packages/core/sdk/core.ts");
    var checked_static_core: std.Build.LazyPath = dep.path("packages/core/compile-surface/core.ts");
    var migrations_zig: std.Build.LazyPath = dep.path("src/app_runner/no_migrations.zig");
    if (relational_capability) {
        const sqlite_check = b.addSystemCommand(&.{node});
        sqlite_check.addFileArg(dep.path("build/ts_run.mjs"));
        sqlite_check.addFileArg(dep.path("packages/core/src/sqlite_cli.ts"));
        sqlite_check.addArg("--src");
        sqlite_check.addDirectoryArg(b.path(appPath(b, app_root, "src")));
        sqlite_check.addArg("--sdk-in");
        sqlite_check.addFileArg(dep.path("packages/core/sdk/core.ts"));
        sqlite_check.addArg("--static-in");
        sqlite_check.addFileArg(dep.path("packages/core/compile-surface/core.ts"));
        sqlite_check.addArg("--sdk-out");
        checked_sdk_core = sqlite_check.addOutputFileArg("core.ts");
        sqlite_check.addArg("--sdk-events-out");
        _ = sqlite_check.addOutputFileArg("events.ts");
        sqlite_check.addArg("--sdk-text-out");
        _ = sqlite_check.addOutputFileArg("text.ts");
        sqlite_check.addArg("--sdk-bytes-text-methods-out");
        _ = sqlite_check.addOutputFileArg("bytes_text_methods.d.ts");
        sqlite_check.addArg("--sdk-events-dts-out");
        _ = sqlite_check.addOutputFileArg("events.d.ts");
        sqlite_check.addArg("--sdk-text-dts-out");
        _ = sqlite_check.addOutputFileArg("text.d.ts");
        sqlite_check.addArg("--static-out");
        checked_static_core = sqlite_check.addOutputFileArg("core_static.ts");
        sqlite_check.addArg("--zig-out");
        migrations_zig = sqlite_check.addOutputFileArg("migrations.zig");
        sqlite_check.addArg("--metadata-out");
        _ = sqlite_check.addOutputFileArg("sqlite.meta.json");
        sqlite_check.addArgs(&.{ "--state", b.pathFromRoot(appPath(b, app_root, "src/schema/migrations.lock.json")) });
        if (appFileExists(b, app_root, "src/schema/migrations.lock.json")) {
            sqlite_check.addFileInput(b.path(appPath(b, app_root, "src/schema/migrations.lock.json")));
        }
        sqlite_check.addFileInput(dep.path("packages/core/src/sqlite_codegen.ts"));
        sqlite_check.addFileInput(dep.path("packages/core/src/sqlite_runtime_policy.ts"));
        for ([_][]const u8{ "events.ts", "text.ts", "bytes_text_methods.d.ts", "events.d.ts", "text.d.ts" }) |source| {
            sqlite_check.addFileInput(dep.path(b.fmt("packages/core/sdk/{s}", .{source})));
        }
        addAppSqlDirInputs(b, sqlite_check, appPath(b, app_root, "src"));
    }

    // The frontend, in check-only mode: the subset checker and the
    // contract sidecar, no emission. Every check-time teaching gates the
    // compile here — the checker's NS diagnostics stream to stderr
    // verbatim; nothing wraps them. The frontend runs through
    // build/ts_run.mjs, not as `node cli.ts`: on the npm-installed
    // layout the frontend's .ts sources live inside node_modules, where
    // node refuses its builtin type stripping — the runner strips those
    // modules with the frontend's own installed TypeScript and is a
    // pass-through on a repo checkout. The frontend reads its own
    // sources, the SDK modules, and the core's WHOLE import graph at
    // run time; declare them all so an edit to ANY module of a
    // multi-file core re-checks it (every .ts under src/ is a superset
    // of the reachable imports: over-approximation only re-runs the
    // check, never misses a stale input).
    const check = b.addSystemCommand(&.{node});
    check.setName("native ts frontend (core + service contracts)");
    check.addFileArg(dep.path("build/ts_run.mjs"));
    check.addFileArg(dep.path("packages/core/src/cli.ts"));
    check.addFileArg(b.path(appPath(b, app_root, "src/core.ts")));
    check.addArg("--contract");
    const contract_raw = check.addOutputFileArg("core.contract.json");
    const contract = stabilizeGeneratedFile(b, contract_raw, "core.contract.json", build_trace);
    // The document's entry spelling is app-relative (the sidecar/facade
    // contract carries no machine paths).
    check.addArgs(&.{ "--contract-entry", "src/core.ts" });
    const services_contract: ?std.Build.LazyPath = if (has_services) services_contract: {
        check.addArg("--services-contract");
        const raw = check.addOutputFileArg("services.contract.json");
        break :services_contract stabilizeGeneratedFile(b, raw, "services.contract.json", build_trace);
    } else null;
    if (persist_capability) check.addArgs(&.{ "--capability", "persist" });
    for (service_packages) |package_entry| {
        check.addArgs(&.{
            "--service-package",
            b.fmt("{s}|{s}|{s}", .{ package_entry.name, package_entry.version, package_entry.content_hash }),
        });
    }
    if (store_capability) check.addArgs(&.{ "--capability", "store" });
    if (relational_capability) check.addArgs(&.{ "--capability", "sqlite" });
    if (credentials_capability) check.addArgs(&.{ "--capability", "credentials" });
    if (credentials_permission) check.addArgs(&.{ "--permission", "credentials" });
    // Activate the cross-tier registry check even when discovery found no
    // roots: the empty set must reject a core that declares a window.
    check.addArg("--window-views");
    for (window_views.views) |view| check.addArgs(&.{ "--window-view", view.label });
    if (relational_capability) {
        check.addArg("--sdk-core");
        check.addFileArg(checked_sdk_core);
    }
    if (persist_version) |version| {
        check.addArgs(&.{ "--persist-version", b.fmt("{d}", .{version}) });
        check.addArgs(&.{ "--persist-state", appPath(b, app_root, ".native/cache/persist-schema.json") });
    }
    addTsDirInputs(b, dep.builder, check, "packages/core/sdk");
    addAppTsDirInputs(b, check, appPath(b, app_root, "src"));
    for (frontend_sources) |source| {
        check.addFileInput(dep.path(b.fmt("packages/core/src/{s}", .{source})));
    }
    // Service contracts echo the exact scriptc pin read from this manifest.
    // Declare that runtime read explicitly so a compiler bump invalidates a
    // warm build cache before the compile lane checks the echoed version.
    if (has_services) check.addFileInput(dep.path("packages/core/package.json"));

    // corewire, compiled from the SDK dependency for the build host: one
    // invocation projects the generated compile entry and its profile,
    // so the profile's entry spelling and the facade file can never skew.
    const corewire_exe = corewireExe(b, dep);
    const project = b.addRunArtifact(corewire_exe);
    project.setName("native corewire (core facade + profile)");
    project.addArg("--sidecar");
    project.addFileArg(contract);
    project.addArg("--facade");
    const facade = project.addOutputFileArg("core_facade.ts");
    project.addArg("--profile");
    const profile = project.addOutputFileArg("core_profile.json");
    if (scriptc_optimization) |value| project.addArgs(&.{ "--optimization", value });

    // The fourth corewire projection is intentionally driven only by the
    // service sidecar: the generated TypeScript dispatch loop and Zig
    // name/index registry never rediscover facts from author source.
    var service_registry: std.Build.LazyPath = dep.path("src/app_runner/no_services.zig");
    var service_exe: ?std.Build.LazyPath = null;
    var service_archive: ?std.Build.LazyPath = null;
    var service_client: ?std.Build.LazyPath = null;
    if (services_contract) |service_contract| {
        const service_project = b.addRunArtifact(corewire_exe);
        service_project.setName("native corewire (service host + ABI projections)");
        service_project.addArg("--services-sidecar");
        service_project.addFileArg(service_contract);
        service_project.addArg("--service-host-main");
        const service_host_main = service_project.addOutputFileArg("service_host_main.ts");
        service_project.addArg("--service-registry");
        const service_registry_raw = service_project.addOutputFileArg("services.zig");
        service_registry = stabilizeGeneratedFile(b, service_registry_raw, "services.zig", build_trace);
        service_project.addArg("--service-client");
        const service_client_raw = service_project.addOutputFileArg("services.gen.ts");
        service_client = stabilizeGeneratedFile(b, service_client_raw, "services.gen.ts", build_trace);
        const service_inproc_main: ?std.Build.LazyPath = if (service_carrier == .in_process) inproc: {
            service_project.addArg("--service-inproc-main");
            break :inproc service_project.addOutputFileArg("service_inproc_main.ts");
        } else null;
        const service_inproc_profile: ?std.Build.LazyPath = if (service_carrier == .in_process) inproc: {
            service_project.addArg("--service-inproc-profile");
            break :inproc service_project.addOutputFileArg("service_profile.json");
        } else null;

        // Ordinary service TypeScript is staged without core-subset rewrites.
        // The one service-boundary lowering turns NS1067's `{ kind, message }`
        // throw into the tagged Error shape the pinned compiler can catch from an
        // imported op; no deterministic profile fences participate here.
        const service_stage_run = b.addSystemCommand(&.{node});
        service_stage_run.setName("native stage TypeScript services");
        service_stage_run.addFileArg(dep.path("packages/core/scripts/stage_external_services.mjs"));
        service_stage_run.addArg("--src");
        service_stage_run.addDirectoryArg(b.path(appPath(b, app_root, "src")));
        service_stage_run.addArg("--host-main");
        service_stage_run.addFileArg(service_host_main);
        if (service_inproc_main) |inproc_main| {
            service_stage_run.addArg("--inproc-main");
            service_stage_run.addFileArg(inproc_main);
        }
        if (service_inproc_profile) |inproc_profile| {
            service_stage_run.addArg("--inproc-profile");
            service_stage_run.addFileArg(inproc_profile);
        }
        if (scriptc_optimization) |value| service_project.addArgs(&.{ "--optimization", value });
        service_stage_run.addArg("--contract");
        service_stage_run.addFileArg(service_contract);
        service_stage_run.addArg("--out");
        const service_stage_dir = service_stage_run.addOutputDirectoryArg("services-stage");
        // The staging script discovers nested service modules recursively;
        // a directory LazyPath alone does not hash those discovered files.
        service_stage_run.has_side_effects = true;

        const service_compile = b.addSystemCommand(&.{node});
        service_compile.setName("native scriptc service compile");
        if (build_trace) service_compile.setEnvironmentVariable("SCRIPTC_TIMING", "1");
        service_compile.addFileArg(dep.path("packages/core/scripts/run_external_service_compiler.mjs"));
        service_compile.addFileInput(dep.path("packages/core/scripts/compiler_command.mjs"));
        service_compile.addArg("--stage");
        service_compile.addDirectoryArg(service_stage_dir);
        service_compile.addArg("--manifest");
        service_compile.addFileArg(dep.path("packages/core/package.json"));
        service_compile.addArg("--contract");
        service_compile.addFileArg(service_contract);
        if (service_carrier == .in_process) {
            // The in-process carrier links the service class into the app
            // binary; no sibling executable is built or packaged.
            service_compile.addArg("--out-archive");
            service_archive = service_compile.addOutputFileArg(b.fmt("lib{s}_services.a", .{externalCoreSymbolName(b, app_name)}));
        } else {
            service_compile.addArg("--out-exe");
            const service_suffix = if (target.result.os.tag == .windows) ".exe" else "";
            service_exe = service_compile.addOutputFileArg(b.fmt("{s}_services{s}", .{ app_name, service_suffix }));
        }
        service_compile.addArgs(&.{
            "--host-platform",
            b.fmt("{t}-{t}-{t}", .{ b.graph.host.result.cpu.arch, b.graph.host.result.os.tag, b.graph.host.result.abi }),
            "--target-platform",
            scriptcPlatformTriple(b, target),
            // Cross service compiles run the pinned compiler's zig-cc
            // lane; hand over this build's own zig so the lane never
            // depends on a PATH zig (native compiles ignore it).
            "--zig-exe",
            b.graph.zig_exe,
        });
        addScriptcAndroidNdk(b, service_compile, target);
        if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER")) |override| {
            service_compile.addArgs(&.{ "--compiler", override });
        } else {
            // Let Node resolve the dependency from the SDK package origin:
            // this is npm's own nested/hoisted/global-sibling walk, and the
            // driver follows scriptc's published `bin` declaration.
            service_compile.addArg("--compiler-package-origin");
            service_compile.addFileArg(dep.path("packages/core/package.json"));
        }
    }

    // The compile stage: author sources + staged SDK + static surface +
    // generated entry/profile, one scratch tree.
    const stage_run = b.addSystemCommand(&.{node});
    stage_run.setName("native stage TypeScript core");
    stage_run.addFileArg(dep.path("packages/core/scripts/stage_external_core.mjs"));
    stage_run.addArg("--src");
    stage_run.addDirectoryArg(b.path(appPath(b, app_root, "src")));
    stage_run.addArg("--sdk");
    stage_run.addDirectoryArg(dep.path("packages/core/sdk"));
    stage_run.addArg("--static");
    stage_run.addFileArg(checked_static_core);
    stage_run.addArg("--facade");
    stage_run.addFileArg(facade);
    stage_run.addArg("--profile");
    stage_run.addFileArg(profile);
    if (service_client) |client| {
        stage_run.addArg("--services-client");
        stage_run.addFileArg(client);
    }
    // `addDirectoryArg` orders the stager after a generated directory but
    // does not hash a source directory's discovered contents. The old graph
    // accidentally got core-source invalidation from changing producer cache
    // paths. Now that generated ABI files are stabilized by content, state
    // every source the stager copies explicitly: authored core files plus the
    // two SDK implementation modules. Services are excluded because they have
    // their own compile lane.
    addAppCoreTsDirInputs(b, stage_run, appPath(b, app_root, "src"));
    addStagedCoreSdkInputs(b, dep.builder, stage_run);
    stage_run.addArg("--out");
    const stage_dir = stage_run.addOutputDirectoryArg("stage");

    // The external compile itself: driver-verified against the SDK's
    // exact pin, archive normalized, the co-emitted sidecar captured.
    const symbol_name = externalCoreSymbolName(b, app_name);
    const compile = b.addSystemCommand(&.{node});
    compile.setName("native scriptc core compile");
    if (build_trace) compile.setEnvironmentVariable("SCRIPTC_TIMING", "1");
    compile.addFileArg(dep.path("packages/core/scripts/run_external_core_compiler.mjs"));
    compile.addFileInput(dep.path("packages/core/scripts/compiler_command.mjs"));
    compile.addArg("--stage");
    compile.addDirectoryArg(stage_dir);
    compile.addArgs(&.{ "--name", symbol_name });
    compile.addArg("--manifest");
    compile.addFileArg(dep.path("packages/core/package.json"));
    compile.addArg("--frontend-sidecar");
    compile.addFileArg(contract);
    compile.addArg("--out-archive");
    const archive = compile.addOutputFileArg(b.fmt("lib{s}.a", .{symbol_name}));
    compile.addArg("--out-sidecar");
    const compiled_sidecar = compile.addOutputFileArg("core.contract.json");
    compile.addArgs(&.{
        "--host-platform",
        b.fmt("{t}-{t}-{t}", .{ b.graph.host.result.cpu.arch, b.graph.host.result.os.tag, b.graph.host.result.abi }),
        "--target-platform",
        scriptcPlatformTriple(b, target),
        // Keep the core and service archives on the same cross compiler and
        // target. Native compiles ignore the supplied Zig path.
        "--zig-exe",
        b.graph.zig_exe,
    });
    addScriptcAndroidNdk(b, compile, target);
    if (b.graph.environ_map.get("NATIVE_SDK_CORE_COMPILER")) |override| {
        // The development override: point at any toolchain command; the
        // driver still refuses a release other than the SDK's pin.
        compile.addArgs(&.{ "--compiler", override });
    } else {
        compile.addArg("--compiler-package-origin");
        compile.addFileArg(dep.path("packages/core/package.json"));
    }

    // The mirror, generated from the archive's OWN co-emitted contract.
    const mirror = b.addRunArtifact(corewire_exe);
    mirror.setName("native corewire (compiled-core mirror)");
    mirror.addArg("--sidecar");
    mirror.addFileArg(compiled_sidecar);
    mirror.addArg("--out");
    const shim = mirror.addOutputFileArg("core_shim.zig");

    // The staged module directory: the mirror is the app's core.zig,
    // and it imports its staged shim runtime relatively.
    const staged = b.addWriteFiles();
    _ = staged.addCopyFile(shim, "core.zig");
    _ = staged.addCopyFile(dep.path("tools/corewire/shim_rt.zig"), "shim_rt.zig");
    _ = staged.addCopyFile(dep.path("tools/corewire/core_abi.zig"), "core_abi.zig");
    _ = staged.addCopyFile(service_registry, "services.zig");
    // The carrier selection, as one staged constant module: the generated
    // wiring comptime-switches its service transport on it.
    _ = staged.add("service_carrier.zig", b.fmt(
        \\//! Generated by the app build: the resolved service-carrier selection.
        \\pub const Kind = enum {{ none, child, in_process }};
        \\pub const kind: Kind = .{t};
        \\/// Pool width for the in-process carrier; null resolves the
        \\/// runtime default (min(4, cores)).
        \\pub const pool_workers: ?usize = {?d};
        \\
    , .{ service_carrier, service_pool_workers }));
    _ = staged.addCopyFile(migrations_zig, "migrations.zig");
    // Every imported file is an input to Debug's embedded source resolver and
    // the release/mobile compiled view, so stage those beside the runner.
    // Keep the ROOT out of this directory: changing any file in one WriteFiles
    // output changes its directory identity, and the runner lives here. Root
    // markup gets a separate release-only module below; Debug keeps the small
    // linked C data object, preserving its link-only edit path.
    for (app_markup_sources.files) |source| {
        _ = staged.addCopyFile(b.path(appPath(b, app_root, source.source_path)), source.staged_path);
    }
    // Primary markup bytes live in their own tiny C translation unit. They
    // drive Debug desktop without participating in Zig source analysis, so a
    // root markup edit there reuses the compiled app/SDK graph and performs
    // only C data compile + relink.
    const markup_embed = b.addSystemCommand(&.{node});
    markup_embed.setName("native embed primary markup data");
    markup_embed.addFileArg(dep.path("packages/core/scripts/embed_markup_c.mjs"));
    markup_embed.addFileArg(b.path(appPath(b, app_root, "src/app.native")));
    const markup_c = markup_embed.addOutputFileArg("app_markup.c");
    for (window_views.sources) |source| {
        _ = staged.addCopyFile(b.path(appPath(b, app_root, source.source_path)), source.staged_path);
    }
    _ = staged.add("app_sources.zig", tsAppMarkupSourcesSource(b, app_markup_sources));
    _ = staged.add("window_views.zig", tsWindowRegistrySource(b, window_views));
    const main_root = staged.addCopyFile(dep.path("src/app_runner/ts_core_main.zig"), "main.zig");
    // The mobile wiring stages beside the desktop entry: same mirror, same
    // registry, same carrier constant — only the shell differs (the embed
    // host's AppDef contract instead of a process `main`).
    const mobile_root = staged.addCopyFile(dep.path("src/app_runner/ts_core_mobile.zig"), "mobile.zig");
    const release_markup = b.addWriteFiles();
    _ = release_markup.addCopyFile(b.path(appPath(b, app_root, "src/app.native")), "app.native");
    const app_markup_root = release_markup.add("app_markup_root.zig",
        \\//! Generated release/mobile embedding for the TypeScript root view.
        \\pub const source = @embedFile("app.native");
        \\
    );
    return .{
        .main_root = main_root,
        .mobile_root = mobile_root,
        .app_markup_root = app_markup_root,
        .archive = archive,
        .service_exe = service_exe,
        .service_archive = service_archive,
        .markup_c = markup_c,
        .migrations = migrations_zig,
    };
}

fn sqliteMigrationsStage(b: *std.Build, dep: *std.Build.Dependency, app_root: []const u8) std.Build.LazyPath {
    const node = tsToolingPreflight(b, dep, .sqlite_schema);
    const generate = b.addSystemCommand(&.{node});
    generate.addFileArg(dep.path("build/ts_run.mjs"));
    generate.addFileArg(dep.path("packages/core/src/sqlite_cli.ts"));
    generate.addArg("--src");
    generate.addDirectoryArg(b.path(appPath(b, app_root, "src")));
    generate.addArg("--zig-out");
    const migrations = generate.addOutputFileArg("migrations.zig");
    generate.addArgs(&.{ "--state", b.pathFromRoot(appPath(b, app_root, "src/schema/migrations.lock.json")) });
    if (appFileExists(b, app_root, "src/schema/migrations.lock.json")) {
        generate.addFileInput(b.path(appPath(b, app_root, "src/schema/migrations.lock.json")));
    }
    generate.addFileInput(dep.path("packages/core/src/sqlite_codegen.ts"));
    generate.addFileInput(dep.path("packages/core/src/sqlite_runtime_policy.ts"));
    addAppSqlDirInputs(b, generate, appPath(b, app_root, "src"));
    return migrations;
}

fn addAppSqlDirInputs(b: *std.Build, run: *std.Build.Step.Run, src_path: []const u8) void {
    var dir = b.build_root.handle.openDir(b.graph.io, src_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sql")) continue;
        run.addFileInput(b.path(b.fmt("{s}/{s}", .{ src_path, entry.path })));
    }
}

/// corewire (the contract-sidecar shim generator), compiled from the SDK
/// dependency's sources for the build host.
fn corewireExe(b: *std.Build, dep: *std.Build.Dependency) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = dep.path("tools/corewire/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    return b.addExecutable(.{
        .name = "corewire",
        .root_module = mod,
        .use_llvm = useLlvmWorkaround(b.graph.host),
    });
}

/// The archive's symbol-safe stem (`<app>_core` with every non-identifier
/// byte folded to '_'), the -o name the external compile builds under.
fn externalCoreSymbolName(b: *std.Build, app_name: []const u8) []const u8 {
    const stem = b.fmt("{s}_core", .{app_name});
    const sanitized = b.dupe(stem);
    for (sanitized) |*char| {
        const ok = (char.* >= 'a' and char.* <= 'z') or (char.* >= 'A' and char.* <= 'Z') or
            (char.* >= '0' and char.* <= '9') or char.* == '_';
        if (!ok) char.* = '_';
    }
    return sanitized;
}

/// Declare every .ts file in an SDK-relative directory as a file input of
/// the transpile step (the SDK library modules an app may import).
fn addTsDirInputs(b: *std.Build, sdk_builder: *std.Build, transpile: *std.Build.Step.Run, dir_path: []const u8) void {
    var dir = sdk_builder.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ts")) continue;
        transpile.addFileInput(sdk_builder.path(b.fmt("{s}/{s}", .{ dir_path, entry.name })));
    }
}

/// Declare every .ts file under the app's src/ (recursively — a core may
/// split into subdirectories) as a file input of the transpile step.
fn addAppTsDirInputs(b: *std.Build, transpile: *std.Build.Step.Run, src_path: []const u8) void {
    var dir = b.build_root.handle.openDir(b.graph.io, src_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ts")) continue;
        transpile.addFileInput(b.path(b.fmt("{s}/{s}", .{ src_path, entry.path })));
    }
}

/// Declare exactly the author TypeScript files copied into the core compiler's
/// scratch tree. `src/services/` is a separate compiler class and `.d.ts`
/// files are declarations for editor/provider use, not scriptc source inputs.
fn addAppCoreTsDirInputs(b: *std.Build, stage: *std.Build.Step.Run, src_path: []const u8) void {
    var dir = b.build_root.handle.openDir(b.graph.io, src_path, .{ .iterate = true }) catch return;
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
        stage.addFileInput(b.path(b.fmt("{s}/{s}", .{ src_path, entry.path })));
    }
}

/// Declare the SDK implementation modules copied by
/// stage_external_core.mjs. A directory LazyPath supplies ordering only for
/// this source tree; these file inputs make implementation-only SDK edits
/// invalidate the staged tree and compiled core archive even when the public
/// contract remains byte-identical. Public for the repository fixture graph,
/// which exercises the same compiler boundary as app builds.
pub fn addStagedCoreSdkInputs(b: *std.Build, sdk_builder: *std.Build, stage: *std.Build.Step.Run) void {
    for ([_][]const u8{ "text.ts", "events.ts" }) |source| {
        stage.addFileInput(sdk_builder.path(b.fmt("packages/core/sdk/{s}", .{source})));
    }
}

fn appHasServiceFiles(b: *std.Build, app_root: []const u8) bool {
    const services_path = appPath(b, app_root, "src/services");
    var dir = b.build_root.handle.openDir(b.graph.io, services_path, .{ .iterate = true }) catch return false;
    defer dir.close(b.graph.io);
    var walker = dir.walk(b.allocator) catch return false;
    defer walker.deinit();
    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".ts") and
            !std.mem.endsWith(u8, entry.basename, ".d.ts")) return true;
    }
    return false;
}

/// The `native_sdk_app_*` C ABI every embed static library exports.
pub const mobile_export_symbol_names = [_][]const u8{
    "native_sdk_app_create",
    "native_sdk_app_destroy",
    "native_sdk_app_destroy_with_status",
    "native_sdk_app_start",
    "native_sdk_app_activate",
    "native_sdk_app_deactivate",
    "native_sdk_app_stop",
    "native_sdk_app_resize",
    "native_sdk_app_viewport",
    "native_sdk_app_viewport_state",
    "native_sdk_app_gpu_frame_state",
    "native_sdk_app_text_input_state",
    "native_sdk_app_set_text_measure",
    "native_sdk_app_set_audio_service",
    "native_sdk_app_set_credential_service",
    "native_sdk_app_audio_event",
    "native_sdk_app_set_image_service",
    "native_sdk_app_set_automation_dir",
    "native_sdk_app_set_data_root",
    "native_sdk_app_touch",
    "native_sdk_app_scroll",
    "native_sdk_app_key",
    "native_sdk_app_text",
    "native_sdk_app_ime",
    "native_sdk_app_command",
    "native_sdk_app_frame",
    "native_sdk_app_chrome_tab_count",
    "native_sdk_app_chrome_tab_at",
    "native_sdk_app_chrome_primary_action",
    "native_sdk_app_chrome_selected_tab",
    "native_sdk_app_chrome_navigation_depth",
    "native_sdk_app_chrome_navigation_back_command",
    "native_sdk_app_chrome_icon_pixels",
    "native_sdk_app_set_form_factor",
    "native_sdk_app_set_chrome_tabs_projected",
    "native_sdk_app_set_asset_root",
    "native_sdk_app_set_asset_entry",
    "native_sdk_app_last_command_count",
    "native_sdk_app_last_command_name",
    "native_sdk_app_last_error_name",
    "native_sdk_app_widget_semantics_count",
    "native_sdk_app_widget_semantics_at",
    "native_sdk_app_widget_semantics_by_id",
    "native_sdk_app_widget_text_geometry",
    "native_sdk_app_widget_action",
    "native_sdk_app_render_pixel_size",
    "native_sdk_app_render_pixels",
    "native_sdk_app_render_pixels_damage",
};

pub const MobileSceneOption = enum {
    /// The user app's UiApp on a gpu_surface view (window 1,
    /// "mobile-surface"), pumped by the host's frame callback.
    canvas,
    /// The fixed WebView shell the ios/android/mobile-shell examples embed
    /// today; the app module is not compiled in.
    webview,
};

pub const MobileLibOptions = struct {
    name: []const u8,
    /// Mobile app entry (the `"app"` module the embed host drives); must
    /// declare `Model`, `Msg`, `initModel`, and `mobileOptions` — see
    /// `src/embed/ui_host.zig`. Ignored for `.scene = .webview`.
    main: []const u8 = "src/main.zig",
    scene: MobileSceneOption = .canvas,
    /// Link and install the engine-owned Tier-2 record store. Standard
    /// `addApp` builds infer this from app.zon; direct `addMobileLib`
    /// callers state it here because that lower-level API has no manifest.
    store_capability: bool = false,
    /// Link and install the engine-owned Tier-3 relational database.
    relational_capability: bool = false,
    /// Generated append-only migration module. Direct low-level callers may
    /// omit it and open an empty version-0 database.
    relational_migrations: ?std.Build.LazyPath = null,
    /// Compile the Tier-4 core credential effects into the mobile host.
    credentials_capability: bool = false,
    /// Grant those effects access to the registered OS credential service.
    credentials_permission: bool = false,
    /// Grant raw file effects access outside the OS-owned app data root.
    filesystem_permission: bool = false,
    /// Stable app identity used as the Keychain/Keystore service namespace.
    credentials_service: []const u8 = "dev.native_sdk.app",
    /// Frozen registered-image pixel budget. Standard app builds infer it
    /// from app.zon; low-level embedders default to the SDK's 1 MiB tier.
    max_image_pixel_bytes: usize = 1024 * 1024,
    /// A TypeScript core's staged mobile wiring: set by `addAppArtifacts`
    /// when the tree carries src/core.ts. The `app` module roots at the
    /// staged mobile entry instead of `main`, and the compiled core (and
    /// in-process service) archives merge into the embed static library —
    /// the host tiers keep linking exactly one archive.
    ts_core: ?MobileTsCore = null,
};

/// The TypeScript pieces a mobile embed library consumes (see
/// `MobileLibOptions.ts_core`).
pub const MobileTsCore = struct {
    /// The staged mobile wiring (mobile.zig beside the generated mirror).
    main_root: std.Build.LazyPath,
    /// Separate root-markup module consumed by the compiled mobile view.
    app_markup_root: std.Build.LazyPath,
    /// The compiled-core archive; merged into the embed library.
    archive: std.Build.LazyPath,
    /// The in-process service archive, when src/services exists.
    service_archive: ?std.Build.LazyPath,
    /// The app.zon module the mobile wiring reads scene chrome, identity,
    /// and theme from (`app_manifest_zon`).
    manifest_mod: *std.Build.Module,
};

/// Mobile counterpart of `addApp`: produce the embed static library
/// (`native_sdk_app_*` C ABI) compiled with the user's UiApp. Call it from
/// a standalone build.zig (it registers the standard `target`/`optimize`
/// options itself).
pub fn addMobileLib(b: *std.Build, dep: *std.Build.Dependency, options: MobileLibOptions) void {
    const target = nativeSdkTarget(b);
    const optimize_request = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize = exampleOptimizeMode(b, optimize_request, .Debug);
    addMobileLibWithTarget(b, dep, target, optimize, options);
}

/// The mobile-lib wiring behind `addMobileLib`, for builds that already
/// resolved `target`/`optimize` (`addAppArtifacts` registers the `lib`
/// step through this for iOS/Android targets, so every standard app —
/// generated graph or ejected `addApp` — can produce the embed library
/// with nothing but `-Dtarget`).
fn addMobileLibWithTarget(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: MobileLibOptions) void {
    const native_sdk_mod = nativeSdkModule(b, dep, target, optimize);
    // Android hosts load the embed lib inside a shared object
    // (System.loadLibrary / NativeActivity), so every object must be PIC —
    // without it Zig emits local-exec TLS relocations (R_AARCH64_TLSLE_*)
    // that the NDK linker rejects when producing the shim .so. Imported
    // modules leave `pic` null and inherit this from the root module.
    const pic: ?bool = if (target.result.abi.isAndroid()) true else null;
    const exports_mod = b.createModule(.{
        .root_source_file = dep.path(switch (options.scene) {
            .canvas => "src/embed/app_exports.zig",
            .webview => "src/embed/c_exports.zig",
        }),
        .target = target,
        .optimize = optimize,
        .pic = pic,
    });
    exports_mod.addImport("native_sdk", native_sdk_mod);
    if (options.scene == .canvas) {
        const mobile_options = b.addOptions();
        mobile_options.addOption(bool, "store_capability", options.store_capability);
        mobile_options.addOption(bool, "relational_capability", options.relational_capability);
        mobile_options.addOption(bool, "credentials_capability", options.credentials_capability);
        mobile_options.addOption(bool, "credentials_permission", options.credentials_permission);
        mobile_options.addOption(bool, "filesystem_permission", options.filesystem_permission);
        mobile_options.addOption([]const u8, "credentials_service", options.credentials_service);
        mobile_options.addOption(usize, "max_image_pixel_bytes", options.max_image_pixel_bytes);
        exports_mod.addImport("mobile_build_options", mobile_options.createModule());
        const migration_path = options.relational_migrations orelse dep.path("src/app_runner/no_migrations.zig");
        const migration_mod = b.createModule(.{ .root_source_file = migration_path, .target = target, .optimize = optimize });
        migration_mod.addImport("native_sdk", native_sdk_mod);
        exports_mod.addImport("relational_migrations", migration_mod);
        // A TypeScript core's app module roots at the staged mobile wiring;
        // a Zig core's at the app's own mobile entry. Either way the embed
        // host sees the same AppDef contract (Model/Msg/initModel/
        // mobileOptions).
        const app_mod = if (options.ts_core) |ts| ts_app: {
            const mod = b.createModule(.{
                .root_source_file = ts.main_root,
                .target = target,
                .optimize = optimize,
            });
            mod.addImport("app_manifest_zon", ts.manifest_mod);
            mod.addImport("app_markup_root", b.createModule(.{
                .root_source_file = ts.app_markup_root,
                .target = target,
                .optimize = optimize,
            }));
            break :ts_app mod;
        } else localModule(b, target, optimize, options.main);
        app_mod.addImport("native_sdk", native_sdk_mod);
        exports_mod.addImport("app", app_mod);
    }
    if (options.ts_core) |ts| {
        // The compiled TypeScript archives merge into the embed static
        // library (Zig's static-lib emission bundles archive inputs), so
        // the iOS/Android host tiers keep linking the one archive they
        // already stage. The toolchain's runtime needs libc; the host
        // link supplies it (plus -lm/-ldl on Android, which the Android
        // host link already passes).
        exports_mod.link_libc = true;
        exports_mod.addObjectFile(ts.archive);
        if (ts.service_archive) |service_archive| exports_mod.addObjectFile(service_archive);
    }
    if (options.store_capability or options.relational_capability) {
        exports_mod.addIncludePath(dep.path("third_party/sqlite"));
        exports_mod.addCSourceFile(.{
            .file = dep.path("third_party/sqlite/sqlite3.c"),
            .flags = sqliteCFlags(b, target),
        });
        exports_mod.link_libc = true;
    }
    exports_mod.export_symbol_names = &mobile_export_symbol_names;

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = options.name,
        .root_module = exports_mod,
        // The embed C ABI (`native_sdk_app_viewport`) is exactly the
        // f32-heavy SysV signature Zig 0.16.0's self-hosted x86_64 backend
        // miscompiles (see useLlvmWorkaround in the framework build.zig):
        // clang-compiled hosts calling a self-hosted Debug lib receive
        // corrupted inset/keyboard floats on x86_64 (Android emulators,
        // Intel simulators). Force LLVM there; Release already uses it.
        .use_llvm = useLlvmWorkaround(target),
    });

    const lib_step = b.step("lib", "Build the mobile embed static library");
    if (options.ts_core != null and target.result.abi.isAndroid()) {
        // Zig's ELF static-library emission stores the compiled TypeScript
        // archives as nested members instead of merging their objects (the
        // Mach-O emission merges), and the NDK's -shared host link would
        // skip those blobs with only a warning. Flatten to one plain
        // object archive so the Android host tier keeps linking exactly
        // the archive it already stages.
        const merged = mergeMobileArchive(b, dep, lib, options.name);
        const lib_name = b.fmt("lib{s}.a", .{options.name});
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(merged, .lib, lib_name).step);
        lib_step.dependOn(&b.addInstallFileWithDir(merged, .lib, lib_name).step);
    } else {
        b.installArtifact(lib);
        lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);
    }
}

/// Flatten an Android embed library whose members include the compiled
/// TypeScript archives (see the call site above). Runs under node like the
/// rest of the TypeScript lane's drivers.
fn mergeMobileArchive(b: *std.Build, dep: *std.Build.Dependency, lib: *std.Build.Step.Compile, name: []const u8) std.Build.LazyPath {
    const node = b.findProgram(&.{"node"}, &.{}) catch
        @panic("\nmerging the mobile TypeScript archives needs node on PATH (the TypeScript core lane already requires it).\n");
    const merge = b.addSystemCommand(&.{node});
    merge.addFileArg(dep.path("packages/core/scripts/merge_static_archives.mjs"));
    merge.addArgs(&.{ "--zig", b.graph.zig_exe, "--format", "gnu" });
    merge.addArg("--out");
    const merged = merge.addOutputFileArg(b.fmt("lib{s}.a", .{name}));
    merge.addArg("--in");
    merge.addFileArg(lib.getEmittedBin());
    return merged;
}

/// The pieces `addApp` wires, for callers that extend the standard app
/// build (extra native sources, frameworks, post-build steps such as
/// entitlement signing). `install` is the artifact-install step behind the
/// default `zig build`; append dependencies to it and to `run` to order
/// work between the emitted binary and its consumers.
pub const AppArtifacts = struct {
    exe: *std.Build.Step.Compile,
    tests: *std.Build.Step.Compile,
    install: *std.Build.Step.InstallArtifact,
    run: *std.Build.Step.Run,
};

pub fn addApp(b: *std.Build, dep: *std.Build.Dependency, app_options: AppOptions) void {
    _ = addAppArtifacts(b, dep, app_options);
}

pub fn addAppArtifacts(b: *std.Build, dep: *std.Build.Dependency, app_options: AppOptions) AppArtifacts {
    const target = nativeSdkTarget(b);
    const optimize_request = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize = exampleOptimizeMode(b, optimize_request, .Debug);
    const app_optimize = exampleOptimizeMode(b, optimize_request, .ReleaseFast);
    const build_trace = b.option(bool, "build-trace", "Trace generated TypeScript ABI artifacts and cache reuse") orelse false;
    const scriptc_optimization = scriptcProfileOptimization(b, dep, app_optimize);

    // The core role is detected from the tree (never a flag or config):
    // builds with a custom `main` entry declared their core explicitly and
    // skip detection.
    const core_tree: CoreTree = if (std.mem.eql(u8, app_options.main, "src/main.zig"))
        detectCoreTree(b, app_options.app_root)
    else
        .zig;
    if (core_tree == .both) {
        @panic("\nthis app declares two cores: src/core.ts (TypeScript) and src/main.zig (Zig)." ++
            "\nAn app has exactly one core - the tree is the truth. Keep src/core.ts and delete" ++
            " src/main.zig,\nor keep src/main.zig and delete src/core.ts. (Other Zig files under" ++
            " src/ are fine either way.)\n");
    }
    const manifest_name = appManifestName(b, app_options.app_root, app_options.manifest);
    const app_config = appManifestBuildConfig(b, app_options.app_root, manifest_name);
    // The core-compiler setting names the one lane there is; the flag
    // overrides app.zon's `.core_compiler` and both exist so a stated
    // choice stays stateable (and so the removed lane's spelling teaches
    // instead of failing opaquely).
    if (b.option([]const u8, "core-compiler", "How a TypeScript core compiles: external (the default and only lane)")) |flag| {
        if (std.mem.eql(u8, flag, "transpiler")) @panic(core_compiler_teaching);
        if (!std.mem.eql(u8, flag, "external")) @panic("\n-Dcore-compiler must be \"external\" (the default and only lane)\n");
        if (core_tree != .ts) {
            @panic("\n-Dcore-compiler applies to TypeScript cores (src/core.ts) only; this app has" ++
                " a Zig core.\nDrop the flag or port the core to TypeScript.\n");
        }
    }
    // The service-carrier selection: `-Dservice-carrier` overrides app.zon's
    // `.service_carrier`; both default to auto (the child carrier).
    const service_carrier_choice: ServiceCarrierOption = choice: {
        if (b.option([]const u8, "service-carrier", "How src/services operations run: auto (default), in_process, child")) |flag| {
            break :choice parseServiceCarrierOption(flag);
        }
        break :choice parseServiceCarrierOption(app_config.service_carrier);
    };
    const service_pool_workers: ?u8 = workers: {
        const configured = b.option(u8, "service-pool-size", "In-process service carrier worker threads (1-16; default min(4, cores))") orelse
            app_config.service_pool_size;
        if (configured) |count| {
            if (count < 1 or count > 16) @panic("\nservice pool size must be between 1 and 16\n");
        }
        break :workers configured;
    };
    const ts_stage: ?TsCoreStage = if (core_tree == .ts)
        tsCoreStage(
            b,
            dep,
            target,
            app_options.app_root,
            app_options.name,
            app_config.persist_capability,
            app_config.store_capability,
            app_config.relational_capability,
            app_config.credentials_capability,
            app_config.credentials_permission,
            app_config.persist_version,
            app_config.service_packages,
            service_carrier_choice,
            service_pool_workers,
            build_trace,
            scriptc_optimization,
        )
    else
        null;
    const relational_migrations = if (ts_stage) |stage|
        stage.migrations
    else if (app_config.relational_capability)
        sqliteMigrationsStage(b, dep, app_options.app_root)
    else
        dep.path("src/app_runner/no_migrations.zig");

    // Mobile targets get the embed static library as a `lib` step: the
    // artifact the toolkit-owned iOS host (and any hand-written shim)
    // links, so `native dev|package --target ios` works against every
    // standard app build — generated graph or ejected — with nothing but
    // `-Dtarget`. Desktop targets keep the step absent. A TypeScript core
    // roots the library's app module at the staged mobile wiring and
    // merges the compiled archives into it.
    if (target.result.os.tag == .ios or target.result.abi.isAndroid()) {
        addMobileLibWithTarget(b, dep, target, optimize, .{
            .name = app_options.name,
            .main = appPath(b, app_options.app_root, app_options.main),
            .store_capability = app_config.store_capability,
            .relational_capability = app_config.relational_capability,
            .relational_migrations = relational_migrations,
            .credentials_capability = app_config.credentials_capability,
            .credentials_permission = app_config.credentials_permission,
            .filesystem_permission = app_config.filesystem_permission,
            .credentials_service = app_config.app_id,
            .max_image_pixel_bytes = app_config.max_image_pixel_bytes,
            .ts_core = if (ts_stage) |stage| .{
                .main_root = stage.mobile_root,
                .app_markup_root = stage.app_markup_root,
                .archive = stage.archive,
                .service_archive = stage.service_archive,
                .manifest_mod = appManifestModule(b, app_options.app_root, manifest_name),
            } else null,
        });
    }
    const platform_option = b.option(PlatformOption, "platform", "Desktop backend: auto, null, macos, linux, windows") orelse .auto;
    const trace_option = b.option(TraceOption, "trace", "Trace output: off, events, runtime, all") orelse .events;
    const debug_overlay = b.option(bool, "debug-overlay", "Enable debug overlay output") orelse false;
    const automation_enabled = b.option(bool, "automation", "Enable Native SDK automation artifacts") orelse false;
    const js_bridge_enabled = b.option(bool, "js-bridge", "Enable optional JavaScript bridge stubs") orelse false;
    const web_engine_override = b.option(WebEngineOption, "web-engine", "Override app.zon web engine: system, chromium");
    const web_layer_override = b.option(WebLayerOption, "web-layer", "Override app.zon webview_layer: auto, include, exclude");
    const cef_dir_override = b.option([]const u8, "cef-dir", "Override CEF root directory for Chromium builds");
    const cef_auto_install_override = b.option(bool, "cef-auto-install", "Override app.zon CEF auto-install setting");
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
    const web_engine = web_engine_override orelse app_config.web_engine;
    if (app_config.updates_enabled and selected_platform == .macos and web_engine == .chromium) {
        @panic("\nnative updates currently require the system macOS host; use web_engine = \"system\" or remove the updates block\n");
    }
    const cef_dir = cef_dir_override orelse defaultCefDir(selected_platform, app_config.cef_dir);
    const cef_auto_install = cef_auto_install_override orelse app_config.cef_auto_install;
    if (web_engine == .chromium and selected_platform != .macos) {
        @panic("-Dweb-engine=chromium currently requires -Dplatform=macos");
    }
    const web_layer = resolveWebLayer(app_config, web_engine, web_layer_override);

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
    options.addOption(bool, "web_layer", web_layer);
    const options_mod = options.createModule();

    const app_mod = appModule(b, dep, target, app_optimize, app_options, manifest_name, options_mod, ts_stage, relational_migrations, app_config);
    // TypeScript app code and platform hosts are expensive Zig/Clang semantic
    // work but do not depend on primary markup bytes. Compile them once into
    // an object, then make the executable a link-only artifact over that
    // cached object plus the tiny generated markup-data object. A markup edit
    // therefore avoids re-analyzing the SDK and app runner entirely.
    const exe_root = if (ts_stage) |stage| root: {
        const app_code = b.addObject(.{
            .name = b.fmt("{s}-app-code", .{app_options.name}),
            .root_module = app_mod,
            .use_llvm = useLlvmWorkaround(target),
        });
        const link_mod = b.createModule(.{ .target = target, .optimize = app_optimize });
        link_mod.addObject(app_code);
        if (app_optimize == .Debug) link_mod.addObject(markupDataObject(b, target, app_optimize, stage.markup_c));
        // Object dependencies propagate framework/system-library NAMES, but
        // Zig does not propagate the search paths or rpaths recorded on the
        // module that produced an object. Restate those path-only facts on
        // the final link module so the cached app-code split remains link-
        // equivalent to compiling the app module directly.
        addPlatformLinkSearchPaths(b, selected_platform, web_engine, cef_dir, link_mod);
        break :root link_mod;
    } else app_mod;
    const exe = b.addExecutable(.{
        .name = app_options.name,
        .root_module = exe_root,
        // The app executable crosses the platform C seam on every host
        // call (the GTK host's `native_sdk_gtk_create_view` is a
        // 22-parameter mix of pointers, sizes, ints, and doubles), and
        // Zig 0.16.0's self-hosted x86_64 backend miscompiles exactly
        // that calling-convention shape (see useLlvmWorkaround below):
        // a Debug `native dev` on x86_64 Linux placed the stack-passed
        // string arguments one slot off, so the host read a garbage
        // `role` pointer and crashed in `native_sdk_strndup` while the
        // register-passed `label` arrived intact. Every other artifact
        // in this graph already forces LLVM on x86_64; the app exe —
        // the one binary users actually run — must too.
        .use_llvm = useLlvmWorkaround(target),
    });
    // Windows subsystem posture: release-shaped exes (`native build`,
    // and therefore everything `native package --target windows` wraps)
    // are GUI-subsystem, so launching the app never flashes a console
    // window behind it. Debug exes keep the console subsystem — the dev
    // loop's logs live there, and a double-clicked Debug binary opening
    // its own log console is a feature. Redirected logging still works
    // on GUI exes (handles inherit; only console AUTO-allocation is
    // gated by the subsystem), so automation harnesses that pipe
    // `app.exe > log 2>&1` keep their logs either way.
    if (target.result.os.tag == .windows and app_optimize != .Debug) {
        exe.subsystem = .windows;
    }
    linkPlatform(b, dep, target, app_mod, exe, selected_platform, web_engine, web_layer, cef_dir, cef_auto_install);
    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);

    const service_install: ?*std.Build.Step.InstallFile = if (ts_stage) |stage| if (stage.service_exe) |service_exe| service_install: {
        const suffix = if (target.result.os.tag == .windows) ".exe" else "";
        const value = b.addInstallFileWithDir(service_exe, .bin, b.fmt("{s}_services{s}", .{ app_options.name, suffix }));
        b.getInstallStep().dependOn(&value.step);
        break :service_install value;
    } else null else null;

    // A service-bearing app runs from the installed layout so the host is
    // a real sibling exactly as it is in a package. Service-free apps keep
    // the direct cached-artifact fast path.
    const run = if (service_install != null) run: {
        const suffix = if (target.result.os.tag == .windows) ".exe" else "";
        const value = b.addSystemCommand(&.{b.getInstallPath(.bin, b.fmt("{s}{s}", .{ app_options.name, suffix }))});
        value.step.dependOn(&install.step);
        value.step.dependOn(&service_install.?.step);
        break :run value;
    } else b.addRunArtifact(exe);
    addCefRuntimeRunFiles(b, target, run, exe, web_engine, cef_dir);
    addWebView2RuntimeRunFiles(dep, target, run, web_engine, web_layer);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run.step);

    // TypeScript tests need their own module even when optimize modes match:
    // the production app module feeds the cached app-code object and must not
    // absorb the separately linked markup data object.
    const test_app_mod = if (ts_stage != null or app_optimize != optimize)
        appModule(b, dep, target, optimize, app_options, manifest_name, options_mod, ts_stage, relational_migrations, app_config)
    else
        app_mod;
    if (ts_stage) |stage| {
        if (optimize == .Debug) test_app_mod.addObject(markupDataObject(b, target, optimize, stage.markup_c));
    }
    const tests = b.addTest(.{ .root_module = test_app_mod, .use_llvm = useLlvmWorkaround(target) });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `native test` must surface the app's compile-time teaching errors,
    // not just its test failures. Test builds never analyze `main` (the
    // test runner replaces the entry point), so rules that fire inside it
    // — UiApp.create's Model-defaults rule above all — used to ambush at
    // `native build`, the LAST step in the loop. Compiling this object
    // forces full semantic analysis of the app module, entry point
    // included; nothing links or runs.
    const analysis_root = b.addWriteFiles().add("app_analysis.zig",
        \\//! Generated by the app build: force semantic analysis of the
        \\//! app's entry point at test time. Exactly `main`, transitively —
        \\//! the same surface `native build` analyzes — so test-time can
        \\//! never be stricter than the build it fronts.
        \\comptime {
        \\    const app = @import("app");
        \\    if (@hasDecl(app, "main")) _ = &app.main;
        \\}
        \\
    );
    const analysis_mod = b.createModule(.{
        .root_source_file = analysis_root,
        .target = target,
        .optimize = optimize,
    });
    analysis_mod.addImport("app", test_app_mod);
    const analysis_obj = b.addObject(.{
        .name = b.fmt("{s}-analysis", .{app_options.name}),
        .root_module = analysis_mod,
        .use_llvm = useLlvmWorkaround(target),
    });
    test_step.dependOn(&analysis_obj.step);

    // `zig build model-contract`: reflect the app's Model/Msg into
    // zig-out/model-contract.zon so `native check` can verify markup
    // bindings against the app's real surface without compiling the app.
    // The artifact carries a hash over the app's Zig sources; the checker
    // degrades to structural checking when it goes stale. Apps without a
    // pub Model/Msg pair make this a silent no-op. The test step refreshes
    // the artifact too, so CI-checked apps always hold a fresh one.
    const contract_root = b.addWriteFiles().add("model_contract_emit.zig",
        \\//! Generated by the app build: emits the model contract artifact
        \\//! (see the toolkit's ui_markup_contract.zig).
        \\const std = @import("std");
        \\const native_sdk = @import("native_sdk");
        \\const app = @import("app");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    try native_sdk.canvas.emitModelContractMain(app, init);
        \\}
        \\
    );
    // The emit root must share the app module's native_sdk instance so
    // the Msg payload types it classifies are the same types the app
    // declares its variants with.
    const contract_mod = b.createModule(.{
        .root_source_file = contract_root,
        .target = target,
        .optimize = optimize,
    });
    contract_mod.addImport("app", test_app_mod);
    if (test_app_mod.import_table.get("native_sdk")) |sdk_mod| {
        contract_mod.addImport("native_sdk", sdk_mod);
    }
    const contract_exe = b.addExecutable(.{
        .name = b.fmt("{s}-model-contract", .{app_options.name}),
        .root_module = contract_mod,
        .use_llvm = useLlvmWorkaround(target),
    });
    const contract_run = b.addRunArtifact(contract_exe);
    contract_run.setCwd(b.path(app_options.app_root));
    contract_run.addArgs(&.{ "--src", "src", "--out", "zig-out/model-contract.zon" });
    contract_run.has_side_effects = true;
    const contract_step = b.step("model-contract", "Emit zig-out/model-contract.zon for `native check`");
    contract_step.dependOn(&contract_run.step);
    test_step.dependOn(&contract_run.step);

    // `zig build package`: bundle the built binary through the `native`
    // CLI (built from the native_sdk dependency), so a scaffolded app can
    // package itself without locating the CLI by hand.
    const host_os = b.graph.host.result.os.tag;
    const package_target: ?[]const u8 = switch (host_os) {
        .macos => "macos",
        .linux => "linux",
        .windows => "windows",
        else => null,
    };
    if (package_target) |package_target_name| {
        const package_run = b.addRunArtifact(dep.artifact("native"));
        // The CLI resolves SDK-owned package inputs (the vendored
        // WebView2 loader) from the framework root; the cached artifact's
        // own location cannot derive it, so hand it over explicitly.
        package_run.setEnvironmentVariable("NATIVE_SDK_PATH", dep.builder.pathFromRoot("."));
        package_run.addArgs(&.{ "package", "--target", package_target_name, "--manifest", manifest_name, "--output" });
        package_run.addArg(if (host_os == .macos)
            b.fmt("zig-out/package/{s}.app", .{app_options.name})
        else
            b.fmt("zig-out/package/{s}", .{package_target_name}));
        package_run.addArg("--binary");
        package_run.addFileArg(exe.getEmittedBin());
        if (ts_stage) |stage| if (stage.service_exe) |service_exe| {
            package_run.addArg("--service-binary");
            package_run.addFileArg(service_exe);
        };
        // The archive and report names carry an optimize label; this
        // build graph knows the packaged binary's REAL mode, so forward
        // it instead of letting the CLI assume one.
        package_run.addArgs(&.{ "--optimize", @tagName(app_optimize) });
        // Forward the RESOLVED web-layer decision, never the raw inputs:
        // this graph already decided web vs native-only for the exe it is
        // packaging (app.zon declarations plus -Dweb-layer/-Dweb-engine),
        // and the CLI re-inferring from app.zon alone would miss a
        // flag-driven override — a WebView2-referencing exe packaged
        // without its loader. Handing over the decision itself makes
        // exe/package agreement structural.
        package_run.addArgs(&.{ "--web-layer", if (web_layer) "include" else "exclude" });
        // Same reasoning for the web engine: the CLI defaults to system, so
        // a Chromium exe packaged without these flags would ship no CEF
        // runtime (the generated build graph already forwards them).
        package_run.addArgs(&.{ "--web-engine", @tagName(web_engine), "--cef-dir", cef_dir });
        if (cef_auto_install) package_run.addArg("--cef-auto-install");
        if (app_config.updates_enabled and host_os == .macos) package_run.addArg("--update-archive");
        package_run.has_side_effects = true;
        const package_step = b.step("package", "Create a distributable package via the native CLI");
        package_step.dependOn(&package_run.step);
    }

    return .{ .exe = exe, .tests = tests, .install = install, .run = run };
}

/// Zig 0.16.0's self-hosted x86_64 backend miscompiles the SysV C calling
/// convention for f32-heavy signatures with interleaved pointer arguments
/// (`native_sdk_app_viewport`: 11 f32s + 2 pointers): both the caller and
/// the callee place/read the wrong registers and stack slots, so safe-area
/// insets arrive as garbage on x86_64 Debug builds while every LLVM-backed
/// build is correct. Minimal repro (fails under `zig test`, passes with
/// `-fllvm` on x86_64-linux):
///
///   fn take(a: ?*anyopaque, w: f32, h: f32, s: f32, p: ?*anyopaque,
///           t: f32, r: f32, bo: f32, l: f32, kt: f32, kr: f32, kb: f32,
///           kl: f32) callconv(.c) void { ... }
///
/// The same backend also mis-places STACK-passed integer/pointer arguments
/// in long mixed signatures with interleaved doubles: calling the GTK
/// host's `native_sdk_gtk_create_view` (22 params: 6 register ints, 4
/// doubles, 12 stack ints/pointers/sizes) from self-hosted Debug code
/// hands the clang-compiled callee arguments shifted by one stack slot
/// from `visible` onward — the callee's `role` pointer reads as the
/// caller's `enabled` value (a 4-byte 1 under 0xAA undefined fill,
/// faulting at 0xaaaaaaaa00000001) and `role_len` reads as the role
/// pointer. Register-passed arguments (`label`) arrive intact, which is
/// why the crash appears only at the first stack-passed string. Verified
/// against zig 0.16.0 on x86_64-linux with a standalone caller/callee
/// pair: self-hosted Debug corrupts, `-fllvm` is correct.
///
/// Force the LLVM backend on x86_64 until the upstream backend is fixed;
/// Release modes already default to LLVM, so this only changes Debug.
pub fn useLlvmWorkaround(target: std.Build.ResolvedTarget) ?bool {
    return if (target.result.cpu.arch == .x86_64) true else null;
}

fn exampleOptimizeMode(b: *std.Build, requested: ?std.builtin.OptimizeMode, default_mode: std.builtin.OptimizeMode) std.builtin.OptimizeMode {
    if (requested) |mode| return mode;
    return switch (b.release_mode) {
        .off => default_mode,
        .any, .fast => .ReleaseFast,
        .safe => .ReleaseSafe,
        .small => .ReleaseSmall,
    };
}

fn appModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, app_options: AppOptions, manifest_name: []const u8, options_mod: *std.Build.Module, ts_stage: ?TsCoreStage, relational_migrations: std.Build.LazyPath, app_config: AppManifestBuildConfig) *std.Build.Module {
    const native_sdk_mod = nativeSdkModuleWithTerminal(b, dep, target, optimize, app_options.terminal_sessions);
    const runner_mod = b.createModule(.{
        .root_source_file = dep.path("src/app_runner/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const manifest_mod = appManifestModule(b, app_options.app_root, manifest_name);
    runner_mod.addImport("native_sdk", native_sdk_mod);
    runner_mod.addImport("build_options", options_mod);
    runner_mod.addImport("app_manifest_zon", manifest_mod);
    const migration_mod = b.createModule(.{ .root_source_file = relational_migrations, .target = target, .optimize = optimize });
    migration_mod.addImport("native_sdk", native_sdk_mod);
    runner_mod.addImport("relational_migrations", migration_mod);

    const app_mod = if (ts_stage) |stage|
        // TypeScript core: the app module roots at the staged generated
        // wiring (ts_core_main.zig beside the mirror core.zig, its shim
        // runtime; primary markup bytes link as a separate data object).
        b.createModule(.{
            .root_source_file = stage.main_root,
            .target = target,
            .optimize = optimize,
        })
    else
        localModule(b, target, optimize, appPath(b, app_options.app_root, app_options.main));
    app_mod.addImport("native_sdk", native_sdk_mod);
    app_mod.addImport("runner", runner_mod);
    if (ts_stage != null) {
        // The wiring derives scene/identity/security from app.zon itself.
        app_mod.addImport("app_manifest_zon", manifest_mod);
    }
    if (ts_stage) |stage| {
        // The compiled-core archive links behind the staged mirror; the
        // toolchain's runtime needs libc.
        app_mod.link_libc = true;
        app_mod.addObjectFile(stage.archive);
        // Debug reads src/app.native only through the separately linked C
        // data object. Supplying this generated module in Debug would put
        // the authored root back into the app-code dependency graph even
        // though the runner's comptime branch never imports it.
        if (optimize != .Debug) {
            app_mod.addImport("app_markup_root", b.createModule(.{
                .root_source_file = stage.app_markup_root,
                .target = target,
                .optimize = optimize,
            }));
        }
        // The in-process service archive links beside it (distinct symbol
        // prefix; its runtime internals are localized).
        if (stage.service_archive) |service_archive| app_mod.addObjectFile(service_archive);
    }
    if (app_config.sqlite_capability) {
        // `store` and the relational `sqlite` tier share this exact object.
        // The source is absent from every artifact declaring neither
        // capability, which keeps capability inference a real binary-size
        // boundary rather than a runtime flag.
        app_mod.addIncludePath(dep.path("third_party/sqlite"));
        app_mod.addCSourceFile(.{
            .file = dep.path("third_party/sqlite/sqlite3.c"),
            .flags = &sqlite_c_defines,
        });
        app_mod.link_libc = true;
    }
    addMacosInfoPlist(b, app_mod, target, app_config);
    return app_mod;
}

/// Compile primary markup bytes independently from the Zig app graph. The
/// final artifact sees this as an object-file input, so a markup edit dirties
/// only this tiny C compile and the final link.
fn markupDataObject(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, source: std.Build.LazyPath) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize });
    mod.addCSourceFile(.{ .file = source, .flags = &.{} });
    return b.addObject(.{ .name = "native-app-markup-data", .root_module = mod });
}

/// Bare Mach-O executables launched by the dev loop do not have an app
/// bundle's external Info.plist. Embed launch policy plus capture usage
/// strings in the conventional section so LaunchServices starts accessory
/// apps without a transient Dock tile and capture consent can be presented.
/// Packaged apps retain their richer external plist generated by package.zig.
fn addMacosInfoPlist(b: *std.Build, app_mod: *std.Build.Module, target: std.Build.ResolvedTarget, config: AppManifestBuildConfig) void {
    if (target.result.os.tag != .macos) return;
    if (config.dock_visible and !config.microphone_permission and !config.system_audio_permission) return;

    const launch_policy = if (!config.dock_visible)
        "  <key>LSUIElement</key>\\n  <true/>\\n"
    else
        "";
    const microphone = if (config.microphone_permission)
        "  <key>NSMicrophoneUsageDescription</key>\\n  <string>This app captures microphone audio when you start recording.</string>\\n"
    else
        "";
    const system_audio = if (config.system_audio_permission)
        "  <key>NSAudioCaptureUsageDescription</key>\\n  <string>This app captures system audio when you start recording.</string>\\n" ++
            "  <key>NSScreenCaptureUsageDescription</key>\\n  <string>This app captures system audio when you start recording.</string>\\n"
    else
        "";
    const source = b.fmt(
        \\#define NATIVE_SDK_INFO_PLIST "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" "<plist version=\"1.0\">\n<dict>\n{s}{s}{s}</dict>\n</plist>\n"
        \\__attribute__((used, section("__TEXT,__info_plist")))
        \\static const unsigned char native_sdk_info_plist[sizeof(NATIVE_SDK_INFO_PLIST) - 1] = NATIVE_SDK_INFO_PLIST;
        \\
    , .{ launch_policy, microphone, system_audio });
    const generated = b.addWriteFiles().add("native_sdk_macos_info_plist.c", source);
    app_mod.addCSourceFile(.{ .file = generated, .flags = &.{} });
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

const sqlite_c_defines = [_][]const u8{
    "-DSQLITE_THREADSAFE=2",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_DQS=0",
    "-DSQLITE_ENABLE_FTS5",
    "-DSQLITE_ENABLE_JSON1",
    "-DSQLITE_ENABLE_UPDATE_HOOK",
    "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
};

/// Zig deliberately supplies no libc headers for Apple/Android cross targets.
/// Store-capable mobile libraries therefore compile the vendored amalgamation
/// against the same platform SDK the host tier will use to link the archive.
/// Desktop targets keep Zig's ordinary libc discovery. Pub because the SDK's
/// own build graph compiles the same amalgamation into modules that also
/// configure under a mobile -Dtarget (the mobile e2e battery).
pub fn sqliteCFlags(b: *std.Build, target: std.Build.ResolvedTarget) []const []const u8 {
    if (target.result.os.tag == .ios) {
        const sysroot = b.sysroot orelse iosSdkPath(b, target.result.abi == .simulator) orelse
            std.debug.panic("a store-capable iOS library needs the Apple SDK; install Xcode or pass --sysroot <iphone SDK path>", .{});
        return b.dupeStrings(&.{
            sqlite_c_defines[0],
            sqlite_c_defines[1],
            sqlite_c_defines[2],
            sqlite_c_defines[3],
            sqlite_c_defines[4],
            sqlite_c_defines[5],
            sqlite_c_defines[6],
            sqlite_c_defines[7],
            "-isysroot",
            sysroot,
            b.fmt("-isystem{s}/usr/include", .{sysroot}),
        });
    }
    if (target.result.abi.isAndroid()) {
        const sysroot = b.sysroot orelse androidNdkSysrootPath(b) orelse
            std.debug.panic("a store-capable Android library needs the NDK; set ANDROID_NDK_ROOT or ANDROID_HOME, or pass --sysroot <NDK sysroot>", .{});
        const triple = target.result.linuxTriple(b.allocator) catch @panic("out of memory");
        return b.dupeStrings(&.{
            sqlite_c_defines[0],
            sqlite_c_defines[1],
            sqlite_c_defines[2],
            sqlite_c_defines[3],
            sqlite_c_defines[4],
            sqlite_c_defines[5],
            sqlite_c_defines[6],
            sqlite_c_defines[7],
            b.fmt("-isystem{s}/usr/include/{s}", .{ sysroot, triple }),
            b.fmt("-isystem{s}/usr/include", .{sysroot}),
        });
    }
    return &sqlite_c_defines;
}

fn iosSdkPath(b: *std.Build, simulator: bool) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ "xcrun", "--sdk", if (simulator) "iphonesimulator" else "iphoneos", "--show-sdk-path" },
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

/// Thread the Android NDK location into a ScriptC driver invocation the
/// way `--zig-exe` threads this build's zig: resolved here, at the one
/// boundary that already knows how to discover it, so the compiler's own
/// discovery never depends on the ambient environment. A missing NDK stays
/// quiet — the driver and compiler own the teaching when an Android
/// compile actually needs one.
pub fn addScriptcAndroidNdk(b: *std.Build, run: *std.Build.Step.Run, target: std.Build.ResolvedTarget) void {
    if (!target.result.abi.isAndroid()) return;
    const ndk_root = androidNdkRootPath(b) orelse return;
    run.addArgs(&.{ "--android-ndk", ndk_root });
}

/// The NDK's root directory (the directory holding toolchains/llvm):
/// ANDROID_NDK_ROOT/ANDROID_NDK_HOME wins, else the newest ndk/<version>
/// under the platform SDK location — the same order the compiler's own
/// discovery uses, so threading it changes nothing but the authority.
fn androidNdkRootPath(b: *std.Build) ?[]const u8 {
    for ([_][]const u8{ "ANDROID_NDK_ROOT", "ANDROID_NDK_HOME", "ANDROID_NDK_LATEST_HOME" }) |name| {
        if (b.graph.environ_map.get(name)) |root| {
            if (root.len > 0 and buildDirExists(b, root)) return root;
        }
    }
    const sdk_root = androidSdkRoot(b) orelse return null;
    return latestVersionSubdir(b, sdk_root, "ndk") orelse blk: {
        const legacy = b.pathJoin(&.{ sdk_root, "ndk-bundle" });
        break :blk if (buildDirExists(b, legacy)) legacy else null;
    };
}

fn androidNdkSysrootPath(b: *std.Build) ?[]const u8 {
    for ([_][]const u8{ "ANDROID_NDK_ROOT", "ANDROID_NDK_HOME", "ANDROID_NDK_LATEST_HOME" }) |name| {
        if (b.graph.environ_map.get(name)) |root| {
            if (root.len > 0) {
                if (ndkSysrootUnder(b, root)) |sysroot| return sysroot;
            }
        }
    }

    const sdk_root = androidSdkRoot(b) orelse return null;
    const ndk_root = latestVersionSubdir(b, sdk_root, "ndk") orelse blk: {
        const legacy = b.pathJoin(&.{ sdk_root, "ndk-bundle" });
        break :blk if (buildDirExists(b, legacy)) legacy else return null;
    };
    return ndkSysrootUnder(b, ndk_root);
}

fn androidSdkRoot(b: *std.Build) ?[]const u8 {
    for ([_][]const u8{ "ANDROID_HOME", "ANDROID_SDK_ROOT" }) |name| {
        if (b.graph.environ_map.get(name)) |root| {
            if (root.len > 0 and buildDirExists(b, root)) return root;
        }
    }
    return switch (builtin.os.tag) {
        .macos => if (b.graph.environ_map.get("HOME")) |home|
            b.pathJoin(&.{ home, "Library", "Android", "sdk" })
        else
            null,
        .windows => if (b.graph.environ_map.get("LOCALAPPDATA")) |local_app_data|
            b.pathJoin(&.{ local_app_data, "Android", "Sdk" })
        else
            null,
        else => if (b.graph.environ_map.get("HOME")) |home|
            b.pathJoin(&.{ home, "Android", "Sdk" })
        else
            null,
    };
}

fn ndkSysrootUnder(b: *std.Build, ndk_root: []const u8) ?[]const u8 {
    const prebuilt_path = b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt" });
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(b.graph.io, prebuilt_path, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var iterator = dir.iterate();
    while (iterator.next(b.graph.io) catch return null) |entry| {
        if (entry.kind != .directory) continue;
        const sysroot = b.pathJoin(&.{ prebuilt_path, entry.name, "sysroot" });
        if (buildDirExists(b, b.pathJoin(&.{ sysroot, "usr", "include" }))) return sysroot;
    }
    return null;
}

fn latestVersionSubdir(b: *std.Build, root: []const u8, parent: []const u8) ?[]const u8 {
    const parent_path = b.pathJoin(&.{ root, parent });
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(b.graph.io, parent_path, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var best: ?[]const u8 = null;
    defer if (best) |name| b.allocator.free(name);
    var iterator = dir.iterate();
    while (iterator.next(b.graph.io) catch return null) |entry| {
        if (entry.kind != .directory) continue;
        if (best) |current| {
            if (!versionLess(current, entry.name)) continue;
            b.allocator.free(current);
            best = null;
        }
        best = b.allocator.dupe(u8, entry.name) catch @panic("out of memory");
    }
    const name = best orelse return null;
    return b.pathJoin(&.{ parent_path, name });
}

fn versionLess(a: []const u8, b: []const u8) bool {
    var a_parts = std.mem.splitScalar(u8, a, '.');
    var b_parts = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const a_part = a_parts.next();
        const b_part = b_parts.next();
        if (a_part == null and b_part == null) return false;
        if (a_part == null) return true;
        if (b_part == null) return false;
        const a_num = std.fmt.parseUnsigned(u64, a_part.?, 10) catch null;
        const b_num = std.fmt.parseUnsigned(u64, b_part.?, 10) catch null;
        if (a_num != null and b_num != null) {
            if (a_num.? != b_num.?) return a_num.? < b_num.?;
        } else switch (std.mem.order(u8, a_part.?, b_part.?)) {
            .lt => return true,
            .gt => return false,
            .eq => {},
        }
    }
}

fn buildDirExists(b: *std.Build, path: []const u8) bool {
    var cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(b.graph.io, path, .{}) catch return false;
    dir.close(b.graph.io);
    return true;
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

fn nativeSdkModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return nativeSdkModuleWithTerminal(b, dep, target, optimize, false);
}

fn nativeSdkModuleWithTerminal(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, terminal_sessions: bool) *std.Build.Module {
    const geometry_mod = externalModule(b, dep, target, optimize, "src/primitives/geometry/root.zig");
    const assets_mod = externalModule(b, dep, target, optimize, "src/primitives/assets/root.zig");
    const app_dirs_mod = externalModule(b, dep, target, optimize, "src/primitives/app_dirs/root.zig");
    const trace_mod = externalModule(b, dep, target, optimize, "src/primitives/trace/root.zig");
    const app_manifest_mod = externalModule(b, dep, target, optimize, "src/primitives/app_manifest/root.zig");
    const diagnostics_mod = externalModule(b, dep, target, optimize, "src/primitives/diagnostics/root.zig");
    const platform_info_mod = externalModule(b, dep, target, optimize, "src/primitives/platform_info/root.zig");
    const json_mod = externalModule(b, dep, target, optimize, "src/primitives/json/root.zig");
    const canvas_mod = externalModule(b, dep, target, optimize, "src/primitives/canvas/root.zig");
    canvas_mod.addImport("geometry", geometry_mod);
    canvas_mod.addImport("json", json_mod);
    const debug_mod = externalModule(b, dep, target, optimize, "src/debug/root.zig");
    debug_mod.addImport("app_dirs", app_dirs_mod);
    debug_mod.addImport("trace", trace_mod);

    const native_sdk_mod = externalModule(b, dep, target, optimize, "src/root.zig");
    // The header makes the internal wrapper parsable even when lazy exports
    // are reflected; the amalgamation itself is attached below only for an
    // opted-in store/sqlite artifact.
    native_sdk_mod.addIncludePath(dep.path("third_party/sqlite"));
    native_sdk_mod.addImport("geometry", geometry_mod);
    native_sdk_mod.addImport("assets", assets_mod);
    native_sdk_mod.addImport("app_dirs", app_dirs_mod);
    native_sdk_mod.addImport("trace", trace_mod);
    native_sdk_mod.addImport("app_manifest", app_manifest_mod);
    native_sdk_mod.addImport("diagnostics", diagnostics_mod);
    native_sdk_mod.addImport("platform_info", platform_info_mod);
    native_sdk_mod.addImport("json", json_mod);
    native_sdk_mod.addImport("canvas", canvas_mod);
    // The terminal-session emulator seam (see
    // `AppOptions.terminal_sessions`): an opted-in app's OWN lazy
    // ghostty pin resolves here with the app module's target/optimize;
    // everything else gets the stub and never traverses ghostty's
    // dependency graph. An opted-in build whose pin is still unfetched
    // takes the stub for THIS configure pass — the build runner fetches
    // the lazy dependency and re-runs, and the second pass wires the
    // real module.
    native_sdk_mod.addImport("terminal_vt", terminal_vt: {
        if (terminal_sessions) {
            if (b.lazyDependency("ghostty", .{
                .target = target,
                .optimize = optimize,
                // Keep the vt module pure Zig: the SIMD paths pull
                // vendored C++ dependencies the session store never uses.
                .simd = false,
                // Only the vt MODULE is consumed: ghostty's macOS app and
                // xcframework artifacts default ON for Darwin hosts and
                // their configure step resolves the iOS libc, which
                // aborts on a machine with only the command-line tools.
                .@"emit-xcframework" = false,
                .@"emit-macos-app" = false,
            })) |ghostty| {
                const wrapper = externalModule(b, dep, target, optimize, "src/runtime/terminal_vt_ghostty.zig");
                wrapper.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
                break :terminal_vt wrapper;
            }
        }
        break :terminal_vt externalModule(b, dep, target, optimize, "src/runtime/terminal_vt_stub.zig");
    });
    return native_sdk_mod;
}

fn externalModule(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = dep.path(path),
        .target = target,
        .optimize = optimize,
    });
}

// -fno-sanitize=builtin on every ObjC compile: Zig 0.16.0's Debug UBSan
// aborts any process whose first dispatch_once runs — the macOS SDK's
// inline `_dispatch_once` ends in `__builtin_assume(*predicate == ~0l)`
// (dispatch/once.h), Zig's bundled clang instruments that builtin, and the
// check fires spuriously at startup; zig's ubsan_rt then cannot even decode
// the report ("invalid enum value" / "passing zero to clz()" panics).
// Reproduced with a 10-line `zig cc` program against both the 14.5 and
// 26.0 SDKs. Release builds never hit it (no UBSan), which is why only
// Debug-built examples (standardOptimizeOption default) crashed.
fn linkPlatform(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, app_mod: *std.Build.Module, exe: *std.Build.Step.Compile, platform: PlatformOption, web_engine: WebEngineOption, web_layer: bool, cef_dir: []const u8, cef_auto_install: bool) void {
    addPlatformLinkSearchPaths(b, platform, web_engine, cef_dir, app_mod);
    if (platform == .macos) {
        switch (web_engine) {
            .system => {
                const sdk_include = if (b.sysroot) |sysroot| b.fmt("-I{s}/usr/include", .{sysroot}) else "";
                const flags: []const []const u8 = if (b.sysroot) |sysroot| &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0", "-isysroot", sysroot, sdk_include } else &.{ "-fobjc-arc", "-fno-sanitize=builtin", "-ObjC", "-mmacosx-version-min=11.0" };
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/macos/appkit_host.m"), .flags = flags });
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
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/macos/cef_host.mm"), .flags = flags });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.linkFramework("Chromium Embedded Framework", .{});
            },
        }
        app_mod.linkFramework("AppKit", .{});
        // The audio playback service (the AppKit host's single AVPlayer).
        app_mod.linkFramework("AVFoundation", .{});
        app_mod.linkFramework("CoreMedia", .{});
        app_mod.linkFramework("ScreenCaptureKit", .{ .weak = true });
        // CVPixelBuffer for the video frame path (the video player's
        // AVPlayerItemVideoOutput frames). CoreMedia's CMTime use stays
        // header-only, but the pixel-buffer calls are real symbols.
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
            .system => if (web_layer) {
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/linux/gtk_host.c"), .flags = &.{} });
                app_mod.linkSystemLibrary("gtk4", .{});
                app_mod.linkSystemLibrary("webkitgtk-6.0", .{});
                app_mod.linkSystemLibrary("dl", .{});
            } else {
                // Native-only app (nothing in app.zon declares web use):
                // compile the GTK host without the embedded web layer.
                // The stub define excludes the layer outright — the host
                // honors it before probing for the WebKitGTK header, so
                // the layer stays out even on machines where the
                // development package is installed — libwebkitgtk is
                // neither linked nor required at runtime, and the
                // executable carries no WebKit reference at all. This
                // is the expected, configured state of every canvas
                // app on Linux, so the stub compile is deliberately
                // silent — no build note, no compiler diagnostic (the
                // host's seam comment explains why even an
                // informational pragma is dangerous); a stubbed host
                // teaches at runtime by reporting WebViewNotFound the
                // moment an app actually uses a WebView.
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/linux/gtk_host.c"), .flags = &.{"-DNATIVE_SDK_ALLOW_WEBKITGTK_STUB"} });
                app_mod.linkSystemLibrary("gtk4", .{});
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
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/linux/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.a", .{cef_dir})));
                app_mod.linkSystemLibrary("cef", .{});
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("stdc++", .{});
    } else if (platform == .windows) {
        // Common-controls v6 side-by-side dependency: without this
        // manifest the loader binds the system-default v5 assembly, which
        // renders classic-styled controls and lacks the v6-only exports.
        // The manifest also declares per-monitor-v2 DPI awareness so the
        // canvas rasterizes at real device scale instead of Windows
        // bitmap-stretching a 96-DPI surface on scaled displays.
        exe.win32_manifest = dep.path("assets/native-sdk.manifest");
        switch (web_engine) {
            .system => if (web_layer) {
                // The vendored WebView2 SDK header (third_party/webview2)
                // turns on the host's embedded-WebView layer; the host
                // fails the compile by design if it cannot be found.
                app_mod.addIncludePath(dep.path("third_party/webview2/include"));
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/webview2_host.cpp"), .flags = &.{"-std=c++17"} });
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/gpu_surface_renderer.cpp"), .flags = &.{"-std=c++17"} });
                // WebView2Loader.dll rides next to the installed app
                // executable: the host loads it at runtime to discover
                // the machine's WebView2 runtime. Canvas apps never
                // touch it.
                const loader = b.addInstallBinFile(dep.path(webView2LoaderSubPath(target)), "WebView2Loader.dll");
                b.getInstallStep().dependOn(&loader.step);
            } else {
                // Native-only app (nothing in app.zon declares web use):
                // compile the host without the embedded-WebView layer.
                // The stub define excludes the layer outright — the host
                // honors it before probing for the WebView2 header, so
                // the layer stays out even on machines where the SDK
                // headers are reachable through the system include paths
                // — no WebView2Loader.dll is installed or path-wired,
                // and the executable carries no reference to it at all.
                // This is the expected, configured state of every
                // canvas app on Windows, so the stub compile is
                // deliberately silent — no build note, no compiler
                // diagnostic (the host's seam comment explains why
                // even an informational pragma is dangerous); a
                // stubbed host teaches at runtime by reporting
                // WebViewNotFound the moment an app actually uses a
                // WebView.
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/webview2_host.cpp"), .flags = &.{ "-std=c++17", "-DNATIVE_SDK_ALLOW_WEBVIEW2_STUB" } });
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/gpu_surface_renderer.cpp"), .flags = &.{"-std=c++17"} });
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
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/cef_host.cpp"), .flags = &.{ "-std=c++17", include_arg, define_arg } });
                app_mod.addCSourceFile(.{ .file = dep.path("src/platform/windows/gpu_surface_renderer.cpp"), .flags = &.{"-std=c++17"} });
                app_mod.addObjectFile(b.path(b.fmt("{s}/libcef_dll_wrapper/libcef_dll_wrapper.lib", .{cef_dir})));
            },
        }
        app_mod.linkSystemLibrary("c", .{});
        app_mod.linkSystemLibrary("c++", .{});
        app_mod.linkSystemLibrary("user32", .{});
        app_mod.linkSystemLibrary("gdi32", .{});
        // Retained gpu_surface packets are composited into a hardware
        // Direct2D target; DirectWrite draws the engine-measured text
        // runs (including registered in-memory fonts) on that target.
        // The D2D device sits on a D3D11 device created with
        // BGRA_SUPPORT, and reaches the compositor through a DXGI 1.2
        // flip-model swap chain -- hence d3d11 and dxgi.
        app_mod.linkSystemLibrary("d2d1", .{});
        app_mod.linkSystemLibrary("d3d11", .{});
        app_mod.linkSystemLibrary("dxgi", .{});
        app_mod.linkSystemLibrary("dwrite", .{});
        app_mod.linkSystemLibrary("imm32", .{});
        app_mod.linkSystemLibrary("comctl32", .{});
        app_mod.linkSystemLibrary("ole32", .{});
        app_mod.linkSystemLibrary("oleacc", .{});
        app_mod.linkSystemLibrary("shell32", .{});
        // TypeScript cores link ScriptC's host runtime, whose network-interface
        // helpers use GetAdaptersAddresses and Winsock address conversion; the
        // in-process service archive shares the same runtime and additionally
        // reaches advapi32 (crypto-backed randomness).
        app_mod.linkSystemLibrary("iphlpapi", .{});
        app_mod.linkSystemLibrary("ws2_32", .{});
        app_mod.linkSystemLibrary("advapi32", .{});
        // The audio backend: Media Foundation (session + source resolver
        // + streaming audio renderer) and WinHTTP (the cache fill).
        app_mod.linkSystemLibrary("mf", .{});
        app_mod.linkSystemLibrary("mfplat", .{});
        app_mod.linkSystemLibrary("winhttp", .{});
        if (web_engine == .chromium) app_mod.linkSystemLibrary("libcef", .{});
    }
}

/// Link-search metadata is not inherited through a compiled object in Zig's
/// build graph. Keep every path-only platform setting in this one helper so a
/// TypeScript app's cached app-code object and its final link receive the same
/// framework/library lookup and runtime-search policy.
fn addPlatformLinkSearchPaths(b: *std.Build, platform: PlatformOption, web_engine: WebEngineOption, cef_dir: []const u8, mod: *std.Build.Module) void {
    if (platform == .macos) {
        if (b.sysroot) |sysroot| {
            mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) });
        }
        if (web_engine == .chromium) {
            mod.addFrameworkPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
            mod.addRPath(.{ .cwd_relative = "@executable_path/Frameworks" });
        }
    } else if (platform == .linux and web_engine == .chromium) {
        mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
        mod.addRPath(.{ .cwd_relative = "$ORIGIN" });
    } else if (platform == .windows and web_engine == .chromium) {
        mod.addLibraryPath(b.path(b.fmt("{s}/Release", .{cef_dir})));
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
fn addWebView2RuntimeRunFiles(dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, run: *std.Build.Step.Run, web_engine: WebEngineOption, web_layer: bool) void {
    if (web_engine != .system) return;
    if (!web_layer) return;
    if (target.result.os.tag != .windows) return;
    const loader_dir = std.fs.path.dirname(webView2LoaderSubPath(target)).?;
    run.addPathDir(dep.builder.pathFromRoot(loader_dir));
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
            \\  echo "Fix with: native cef install --dir {s}" >&2
            \\  exit 1
            \\}}
        , .{ cef_dir, cef_dir, cef_dir, cef_dir }),
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

/// What the build graph reads out of app.zon: the web-engine/CEF knobs
/// and the web-layer inference inputs. An unreadable or unparsable
/// manifest falls back to the system engine WITH the web layer kept —
/// over-inclusion is a size cost, wrong exclusion is a broken app.
const AppManifestBuildConfig = struct {
    app_id: []const u8 = "dev.native_sdk.app",
    web_engine: WebEngineOption = .system,
    cef_dir: []const u8 = "third_party/cef/macos",
    cef_auto_install: bool = false,
    webview_layer: WebLayerOption = .auto,
    dock_visible: bool = true,
    microphone_permission: bool = false,
    system_audio_permission: bool = false,
    persist_capability: bool = false,
    persist_version: ?u64 = null,
    service_packages: []const ServicePackageConfig = &.{},
    service_carrier: []const u8 = "auto",
    service_pool_size: ?u8 = null,
    store_capability: bool = false,
    relational_capability: bool = false,
    credentials_capability: bool = false,
    credentials_permission: bool = false,
    filesystem_permission: bool = false,
    max_image_pixel_bytes: usize = 1024 * 1024,
    updates_enabled: bool = false,
    sqlite_capability: bool = false,
    /// The first web declaration found (for teaching messages), or null
    /// when app.zon declares no web use. `web_engine = "system"` alone is
    /// NOT web intent — it is the default in many canvas manifests.
    web_declaration: ?web_layer_contract.Declaration = null,
};

const ServicePackageConfig = struct {
    name: []const u8,
    version: []const u8,
    content_hash: []const u8,
};

/// The lenient app.zon shape the build graph parses for inference: web
/// inclusion, permissions, and the persistence capability/version handed to
/// the TypeScript checker. Everything else is ignored. Full schema validation
/// stays with `native validate` and the runner's comptime import.
const InferenceManifest = struct {
    id: []const u8 = "dev.native_sdk.app",
    capabilities: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    dock_visible: bool = true,
    web_engine: []const u8 = "system",
    webview_layer: []const u8 = "auto",
    core_compiler: []const u8 = "external",
    cef: struct {
        dir: []const u8 = "third_party/cef/macos",
        auto_install: bool = false,
    } = .{},
    frontend: ?struct {} = null,
    persist: ?struct {
        version: u64,
    } = null,
    images: struct {
        max_image_pixel_bytes: usize = 1024 * 1024,
    } = .{},
    service_packages: []const ServicePackageConfig = &.{},
    service_carrier: []const u8 = "auto",
    service_pool_size: u8 = 0,
    updates: ?struct {} = null,
    shell: struct {
        windows: []const struct {
            views: []const struct {
                kind: []const u8 = "",
            } = &.{},
        } = &.{},
    } = .{},
};

fn defaultCefDir(platform: PlatformOption, configured: []const u8) []const u8 {
    if (!std.mem.eql(u8, configured, "third_party/cef/macos")) return configured;
    return switch (platform) {
        .linux => "third_party/cef/linux",
        .windows => "third_party/cef/windows",
        else => configured,
    };
}

/// Resolve an app-relative path against `app_root` (see AppOptions). Kept
/// lexical: `b.path` rejects absolute paths and the generated build graph
/// hands us "../..", which openat/b.path both resolve fine.
fn appPath(b: *std.Build, app_root: []const u8, sub_path: []const u8) []const u8 {
    if (app_root.len == 0 or std.mem.eql(u8, app_root, ".")) return sub_path;
    return b.pathJoin(&.{ app_root, sub_path });
}

fn appManifestBuildConfig(b: *std.Build, app_root: []const u8, manifest_name: []const u8) AppManifestBuildConfig {
    // The fallback for a manifest this lenient parse cannot read keeps
    // the web layer (see AppManifestBuildConfig): a shape mismatch here
    // is not proof the app declares no web use.
    const fallback: AppManifestBuildConfig = .{ .web_declaration = .unreadable_manifest };
    const source = b.build_root.handle.readFileAlloc(b.graph.io, appPath(b, app_root, manifest_name), b.allocator, .limited(1024 * 1024)) catch return fallback;
    @setEvalBranchQuota(2000);
    const raw = if (std.ascii.eqlIgnoreCase(std.fs.path.extension(manifest_name), ".json"))
        std.json.parseFromSliceLeaky(InferenceManifest, b.allocator, source, .{ .ignore_unknown_fields = true }) catch return fallback
    else zon: {
        const source_z = b.allocator.dupeZ(u8, source) catch return fallback;
        break :zon std.zon.parse.fromSliceAlloc(InferenceManifest, b.allocator, source_z, null, .{ .ignore_unknown_fields = true }) catch return fallback;
    };
    // `.core_compiler` names the one lane there is; validated here so
    // the removed transpiled lane's spelling teaches at configure time.
    if (!std.mem.eql(u8, raw.core_compiler, "external")) {
        if (std.mem.eql(u8, raw.core_compiler, "transpiler")) @panic(core_compiler_teaching);
        @panic("\napp.zon .core_compiler must be \"external\" (the default and only lane)\n");
    }
    return .{
        .app_id = raw.id,
        .web_engine = web_layer_contract.parseWebEngine(raw.web_engine) orelse .system,
        .cef_dir = raw.cef.dir,
        .cef_auto_install = raw.cef.auto_install,
        .webview_layer = web_layer_contract.parseWebViewLayer(raw.webview_layer) orelse @panic("app.zon .webview_layer must be \"auto\", \"include\", or \"exclude\""),
        .dock_visible = raw.dock_visible,
        .microphone_permission = hasManifestPermission(raw.permissions, "microphone"),
        .system_audio_permission = hasManifestPermission(raw.permissions, "system_audio"),
        .persist_capability = hasManifestCapability(raw.capabilities, "persist"),
        .persist_version = if (raw.persist) |persist| persist.version else null,
        .service_packages = raw.service_packages,
        .service_carrier = raw.service_carrier,
        .service_pool_size = if (raw.service_pool_size == 0) null else raw.service_pool_size,
        .store_capability = hasManifestCapability(raw.capabilities, "store"),
        .relational_capability = hasManifestCapability(raw.capabilities, "sqlite"),
        .credentials_capability = hasManifestCapability(raw.capabilities, "credentials"),
        .credentials_permission = hasManifestPermission(raw.permissions, "credentials"),
        .filesystem_permission = hasManifestPermission(raw.permissions, "filesystem"),
        .max_image_pixel_bytes = raw.images.max_image_pixel_bytes,
        .updates_enabled = raw.updates != null,
        .sqlite_capability = hasManifestCapability(raw.capabilities, "store") or hasManifestCapability(raw.capabilities, "sqlite"),
        .web_declaration = web_layer_contract.manifestDeclaration(raw),
    };
}

fn hasManifestPermission(permissions: []const []const u8, expected: []const u8) bool {
    for (permissions) |permission| {
        if (std.mem.eql(u8, permission, expected)) return true;
    }
    return false;
}

fn hasManifestCapability(capabilities: []const []const u8, expected: []const u8) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability, expected)) return true;
    }
    return false;
}

/// The web-layer decision for this build: the shared contract fed this
/// boundary's inputs — the manifest declarations from the lenient parse
/// and the engine RESOLVED from `-Dweb-engine` orelse app.zon. WEB means
/// the embedded-WebView layer compiles in; NATIVE-ONLY compiles the host
/// without it. `.webview_layer` (and `-Dweb-layer`) override the
/// inference — but an exclude that contradicts a web declaration is a
/// hard configure error, never a silently broken app.
fn resolveWebLayer(config: AppManifestBuildConfig, web_engine: WebEngineOption, override: ?WebLayerOption) bool {
    const setting = override orelse config.webview_layer;
    const declaration = web_layer_contract.foldEngine(config.web_declaration, web_engine);
    const decision = web_layer_contract.decide(setting, declaration) catch std.debug.panic(
        "the web layer is excluded ({s}) but the app declares web use ({s}); remove the exclude or drop the web declaration",
        .{ if (override != null) "-Dweb-layer=exclude" else "app.zon .webview_layer = \"exclude\"", declaration.?.text() },
    );
    return decision.enabled;
}
