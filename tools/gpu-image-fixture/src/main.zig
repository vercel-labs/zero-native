//! gpu-image-fixture: the registered-image ceiling on a hardware canvas.
//!
//! This is a MEASUREMENT fixture, not a showcase app. It exists to answer one
//! question the showcase apps cannot: what does a resize step cost when the
//! host's per-surface texture cache is full?
//!
//! On Windows the Direct2D renderer flushes its whole `image_bitmaps_` map
//! whenever the surface's pixel size changes, because D2D bitmaps belong to
//! the render target that created them and `ensureTargets` recreates that
//! target. Every showcase app that runs on Windows draws zero bitmaps, so the
//! flush is free there and the cost is invisible. This app draws the maximum
//! the runtime will hold:
//!
//!   - `canvas_limits.max_registered_canvas_images` = 16 slots, and
//!   - `max_registered_canvas_image_pixel_bytes` = 1 MiB = 512x512 RGBA8,
//!
//! so 16 MiB of texture, all of it on screen, all of it re-uploaded on any
//! resize step that changes the backing size. That is the worst case an app
//! can reach through the registered-image path — a real app cannot exceed it
//! without the media-surface channels, which are a separate id space.
//!
//! Pair it with `NATIVE_SDK_GPU_PROFILE` (see gpu_surface_renderer.cpp) and
//! `tools/windows-truth/gpu-resize-profile.ps1`, which drives a synthetic
//! resize drag and reduces the log.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const canvas_label = "fixture-canvas";
const window_width: f32 = 1024;
const window_height: f32 = 768;

/// The runtime registry's slot ceiling (`canvas_limits.max_registered_canvas_images`).
pub const image_count: u32 = 16;
/// The per-slot pixel ceiling: `max_registered_canvas_image_pixel_bytes` is
/// 1 MiB, which is exactly 512x512 RGBA8. Registering anything larger fails
/// with `error.ImageTooLarge`, so this is the widest texture the path allows.
pub const image_extent: u32 = 512;
pub const grid_columns: u32 = 4;

/// Cells are a FIXED size rather than growing with the window, and that
/// is deliberate. What this fixture isolates is texture re-upload, which
/// tracks texture bytes and is independent of drawn size; letting the
/// cells scale with the sweep would vary `DrawBitmap` cost step by step
/// and put a second signal into the same column. Fixed cells keep the
/// display list identical at every window size, so the only thing the
/// sweep changes is the backing surface.
///
/// Sized in LOGICAL points to fit the harness's smallest window (900x700
/// device pixels) on a 125%-scaled display, where that is only ~704x560
/// points of client area. Overflow here is not cosmetic: a cell pushed
/// past the surface edge drops out of the display list and stops being
/// uploaded, so the fixture would quietly measure fewer than 16 textures.
const cell_width: f32 = 150;
const cell_height: f32 = 105;

const app_permissions = [_][]const u8{native_sdk.security.permission_view};
const shell_views = [_]native_sdk.ShellView{
    .{
        .label = canvas_label,
        .kind = .gpu_surface,
        .fill = true,
        .role = "Image fixture canvas",
        .accessibility_label = "GPU image fixture",
        .gpu_backend = .metal,
        .gpu_pixel_format = .bgra8_unorm,
        .gpu_present_mode = .timer,
        .gpu_alpha_mode = .@"opaque",
        .gpu_color_space = .srgb,
        .gpu_vsync = true,
    },
};
const shell_windows = [_]native_sdk.ShellWindow{.{
    .label = "main",
    .title = "GPU Image Fixture",
    .width = window_width,
    .height = window_height,
    .min_width = 420,
    .min_height = 320,
    .restore_state = false,
    .views = &shell_views,
}};
pub const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

// ------------------------------------------------------------------ model

pub const Model = struct {
    /// How many of the requested registrations the runtime accepted.
    /// Anything below the request means the fixture is measuring less than
    /// it claims, so the status line reports it rather than hiding it.
    registered: u32 = 0,
    /// The requested count and edge, after clamping (see `requestedCount`).
    requested: u32 = image_count,
    extent: u32 = image_extent,
    /// Bumped by the sole message so a repaint can be forced from the
    /// canvas without resizing.
    repaints: u32 = 0,

    pub fn residentKib(model: *const Model) u32 {
        return (model.registered * model.extent * model.extent * 4) / 1024;
    }

    pub fn statusLine(model: *const Model, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "{d}/{d} textures · {d}x{d} RGBA8 · {d} KiB resident · repaint {d}", .{
            model.registered,
            model.requested,
            model.extent,
            model.extent,
            model.residentKib(),
            model.repaints,
        }) catch "";
    }
};

/// Fixture knobs, resolved once in `main` (the environment reaches an app
/// through `std.process.Init`, which `init_fx` never sees) so a measurement
/// sweep can walk the texture-count and texture-size axes without a rebuild:
///
///   NATIVE_SDK_FIXTURE_IMAGES  1..16   (default 16, the registry ceiling)
///   NATIVE_SDK_FIXTURE_EXTENT  8..512  (default 512, the per-slot ceiling)
///
/// Both clamp rather than fail: the status line reports what actually
/// registered, so a typo produces a labelled smaller run, never a silent
/// one that claims the ceiling.
var requested_images: u32 = image_count;
var requested_extent: u32 = image_extent;

fn envCount(map: *std.process.Environ.Map, name: []const u8, fallback: u32, low: u32, high: u32) u32 {
    const raw = map.get(name) orelse return fallback;
    const parsed = std.fmt.parseInt(u32, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return fallback;
    return std.math.clamp(parsed, low, high);
}

pub const Msg = union(enum) { repaint };

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .repaint => model.repaints +%= 1,
    }
}

// --------------------------------------------------------------- textures

/// One texture's staging buffer, reused across every registration:
/// `fx.registerImage` copies the pixels before it returns, so the fixture
/// never holds 16 MiB of its own on top of the registry's copy. Sized for
/// the largest texture the registry accepts.
var texture_scratch: [image_extent * image_extent * 4]u8 = undefined;

/// Paint texture `index` into the shared scratch buffer. Every texture is
/// visibly different (hue, gradient direction, and a per-index cell grid),
/// which keeps a host from collapsing them into one cached upload and makes
/// a stale or misindexed bitmap obvious on screen.
fn paintTexture(index: u32, extent: usize) []const u8 {
    const phase: f32 = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(image_count));
    const cell: usize = @max(2, (extent / 32) + @as(usize, index));
    var y: usize = 0;
    while (y < extent) : (y += 1) {
        const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(extent));
        var x: usize = 0;
        while (x < extent) : (x += 1) {
            const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(extent));
            const checker = ((x / cell) + (y / cell)) % 2 == 0;
            const wave = 0.5 + 0.5 * @sin((u * 6.0 + v * 4.0 + phase * 8.0) * std.math.pi);
            const shade: f32 = if (checker) 1.0 else 0.72;
            const r = channel((0.25 + 0.7 * phase) * shade);
            const g = channel((0.30 + 0.6 * wave) * shade);
            const b = channel((0.85 - 0.5 * phase * v) * shade);
            const offset = (y * extent + x) * 4;
            texture_scratch[offset + 0] = r;
            texture_scratch[offset + 1] = g;
            texture_scratch[offset + 2] = b;
            texture_scratch[offset + 3] = 255;
        }
    }
    return texture_scratch[0 .. extent * extent * 4];
}

fn channel(value: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

pub fn imageId(index: u32) canvas.ImageId {
    return @as(canvas.ImageId, index) + 1;
}

/// TEA's init command: register every texture before the first view build,
/// so the very first presented frame already carries the full cache. A
/// refused registration leaves that slot out of the model's count and the
/// grid draws its remaining cells — the fixture degrades loudly in the
/// status line instead of silently measuring a smaller cache.
pub fn initFx(model: *Model, fx: *FixtureApp.Effects) void {
    model.requested = requested_images;
    model.extent = requested_extent;
    var index: u32 = 0;
    while (index < model.requested) : (index += 1) {
        const pixels = paintTexture(index, model.extent);
        fx.registerImage(imageId(index), model.extent, model.extent, pixels) catch continue;
        model.registered += 1;
    }
}

// ------------------------------------------------------------------- view

pub const Ui = canvas.Ui(Msg);

/// A `grid_columns`-wide grid of every registered texture, each cell growing
/// with the window so a resize changes the drawn size as well as the backing
/// size, plus a status line and the repaint button.
pub fn view(ui: *Ui, model: *const Model) Ui.Node {
    const rows = (model.registered + grid_columns - 1) / grid_columns;
    const row_nodes = ui.arena.alloc(Ui.Node, rows) catch return ui.column(.{ .grow = 1 }, .{});
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        const first = row * grid_columns;
        const count = @min(grid_columns, model.registered - first);
        const cells = ui.arena.alloc(Ui.Node, count) catch return ui.column(.{ .grow = 1 }, .{});
        var column: u32 = 0;
        while (column < count) : (column += 1) {
            const index = first + column;
            var cell = ui.image(.{
                .key = canvas.uiKey(index),
                .width = cell_width,
                .height = cell_height,
                .image = imageId(index),
                .semantics = .{ .label = "Fixture texture" },
            });
            cell.widget.image_fit = .cover;
            cells[column] = cell;
        }
        row_nodes[row] = ui.row(.{ .height = cell_height, .gap = 6 }, cells);
    }
    return ui.column(.{ .grow = 1, .gap = 6, .padding = 8 }, .{
        ui.row(.{ .cross = .center, .gap = 10 }, .{
            ui.text(.{ .semantics = .{ .label = "Fixture status" } }, model.statusLine(ui.arena)),
            ui.spacer(1),
            ui.button(.{ .on_press = .repaint }, "Repaint"),
        }),
        row_nodes,
    });
}

// -------------------------------------------------------------------- app

const FixtureApp = native_sdk.UiAppWithFeatures(Model, Msg, .{ .runtime_markup = false });

pub fn main(init: std.process.Init) !void {
    requested_images = envCount(init.environ_map, "NATIVE_SDK_FIXTURE_IMAGES", image_count, 1, image_count);
    requested_extent = envCount(init.environ_map, "NATIVE_SDK_FIXTURE_EXTENT", image_extent, 8, image_extent);
    const app_state = try std.heap.page_allocator.create(FixtureApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = FixtureApp.init(std.heap.page_allocator, Model{}, .{
        .name = "gpu-image-fixture",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .update = update,
        .init_fx = initFx,
        .view = view,
    });
    defer app_state.deinit();
    try runner.runWithOptions(app_state.app(), .{
        .app_name = "gpu-image-fixture",
        .window_title = "GPU Image Fixture",
        .bundle_id = "dev.native_sdk.gpu-image-fixture",
        .default_frame = geometry.RectF.init(0, 0, window_width, window_height),
        .restore_state = false,
        .js_window_api = false,
        .security = .{ .permissions = &app_permissions },
    }, init);
}

test "the fixture claims the runtime's whole registered-image ceiling" {
    // If either limit moves, this fixture stops measuring the worst case.
    try std.testing.expectEqual(native_sdk.max_registered_canvas_images, @as(usize, image_count));
    try std.testing.expectEqual(
        @as(usize, image_extent) * @as(usize, image_extent) * 4,
        native_sdk.max_registered_canvas_image_pixel_bytes,
    );
}

test "every texture registers under a distinct non-zero id" {
    var seen = std.AutoHashMap(canvas.ImageId, void).init(std.testing.allocator);
    defer seen.deinit();
    var index: u32 = 0;
    while (index < image_count) : (index += 1) {
        const id = imageId(index);
        try std.testing.expect(id != 0);
        try std.testing.expect((id & canvas.media_surface_image_id_bit) == 0);
        try std.testing.expect(!seen.contains(id));
        try seen.put(id, {});
    }
}
