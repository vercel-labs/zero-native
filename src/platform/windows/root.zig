const std = @import("std");
const geometry = @import("geometry");
const platform_mod = @import("../root.zig");
const policy_values = @import("../policy_values.zig");
const security = @import("../../security/root.zig");

const bundled_geist_regular = @embedFile("../../primitives/canvas/fonts/Geist-Regular.ttf");
const bundled_geist_mono = @embedFile("../../primitives/canvas/fonts/GeistMono-Regular.ttf");

pub const Error = error{
    CallbackFailed,
    CreateFailed,
    FocusFailed,
    CloseFailed,
    UnsupportedWindowClosePolicy,
    UnsupportedWindowTransparency,
};

const WindowsHost = opaque {};

const WindowsEventKind = enum(c_int) {
    start = 0,
    frame = 1,
    shutdown = 2,
    resize = 3,
    window_frame = 4,
    shortcut = 5,
    native_command = 6,
    app_activated = 7,
    app_deactivated = 8,
    files_dropped = 9,
    menu_command = 10,
    tray_action = 11,
    gpu_surface_frame = 12,
    gpu_surface_resize = 13,
    gpu_surface_input = 14,
    wake = 15,
    timer = 16,
    appearance = 17,
    audio = 18,
    context_menu_action = 19,
    view_focused = 20,
    tray_command = 21,
    notification_command = 22,
};

const WindowsEvent = extern struct {
    kind: WindowsEventKind,
    window_id: u64,
    width: f64,
    height: f64,
    scale: f64,
    x: f64,
    y: f64,
    open: c_int,
    focused: c_int,
    /// Nonzero while the window is alive but hidden by its close_policy
    /// (`open` stays 1 for the whole hidden stretch).
    hidden: c_int,
    label: [*]const u8,
    label_len: usize,
    title: [*]const u8,
    title_len: usize,
    shortcut_id: [*]const u8,
    shortcut_id_len: usize,
    shortcut_key: [*]const u8,
    shortcut_key_len: usize,
    shortcut_modifiers: u32,
    command_name: [*]const u8,
    command_name_len: usize,
    view_label: [*]const u8,
    view_label_len: usize,
    drop_paths: [*]const u8,
    drop_paths_len: usize,
    tray_item_id: u32,
    frame_index: u64,
    timestamp_ns: u64,
    frame_interval_ns: u64,
    nonblank: c_int,
    sample_color: u32,
    /// Concrete Windows presenter plus the most recent accepted packet's
    /// decode/draw durations. The host clears timings before dispatch so
    /// a synchronous next present cannot be clobbered after the callback.
    gpu_backend: c_int,
    packet_decode_ns: u64,
    packet_draw_ns: u64,
    /// Nonzero when the frame completed logically while the top-level
    /// window was minimized (heartbeat pacing; nothing painted) — its
    /// timestamp is pacing policy, never a latency endpoint.
    occluded: c_int,
    /// Nonzero when the Direct2D presenter lost its retained resources and
    /// this completion must rebuild the canvas from a full packet.
    force_full_repaint: c_int,
    input_kind: c_int,
    button: c_int,
    delta_x: f64,
    delta_y: f64,
    key_text: [*]const u8,
    key_text_len: usize,
    input_text: [*]const u8,
    input_text_len: usize,
    has_composition_cursor: c_int,
    composition_cursor: usize,
    timer_id: u64,
    color_scheme: c_int,
    reduce_motion: c_int,
    high_contrast: c_int,
    /// Audio player report payload (`kind == .audio`): the report kind
    /// ordinal plus the live transport readout. `audio_buffering` is the
    /// honest stream-stall mirror (an un-paused stream waiting for
    /// bytes), distinct from `audio_playing` (the transport intent).
    audio_kind: c_int,
    audio_position_ms: u64,
    audio_duration_ms: u64,
    audio_playing: c_int,
    audio_buffering: c_int,
    /// SPECTRUM report payload: the 32 band magnitude bytes on the
    /// documented scale (log-spaced 50 Hz..16 kHz buckets, linear-in-dB
    /// from -60 dBFS at 0 to full scale at 255). Zeros elsewhere.
    audio_bands: [platform_mod.audio_spectrum_band_count]u8,
    /// CONTEXT_MENU_ACTION payload (same field names as the macOS host):
    /// `widget_id` echoes the request's correlation token and
    /// `menu_item_id` is the selected item's id (0 = dismissed without a
    /// selection).
    widget_id: u64,
    menu_item_id: u32,
};

const WindowsCallback = *const fn (context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void;
const WindowsBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;

const shortcut_modifier_primary: u32 = 1 << 0;
const shortcut_modifier_command: u32 = 1 << 1;
const shortcut_modifier_control: u32 = 1 << 2;
const shortcut_modifier_option: u32 = 1 << 3;
const shortcut_modifier_shift: u32 = 1 << 4;

extern fn native_sdk_windows_create(app_name: [*]const u8, app_name_len: usize, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, initial_placement: c_int, restore_policy: c_int, resizable: c_int, titlebar_style: c_int, min_width: f64, min_height: f64, show_policy: c_int, window_flags: u32) ?*WindowsHost;
extern fn native_sdk_windows_destroy(host: *WindowsHost) void;
extern fn native_sdk_windows_run(host: *WindowsHost, callback: WindowsCallback, context: ?*anyopaque) void;
extern fn native_sdk_windows_stop(host: *WindowsHost) void;
extern fn native_sdk_windows_wake(host: *WindowsHost) void;
extern fn native_sdk_windows_request_frame(host: *WindowsHost) void;
extern fn native_sdk_windows_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, max_pixels: usize, out_width: *usize, out_height: *usize) c_int;
extern fn native_sdk_windows_load_webview(host: *WindowsHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_windows_load_window_webview(host: *WindowsHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) c_int;
extern fn native_sdk_windows_set_bridge_callback(host: *WindowsHost, callback: WindowsBridgeCallback, context: ?*anyopaque) void;
extern fn native_sdk_windows_bridge_respond(host: *WindowsHost, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_bridge_respond_window(host: *WindowsHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_bridge_respond_webview(host: *WindowsHost, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_windows_emit_window_event(host: *WindowsHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn native_sdk_windows_set_security_policy(host: *WindowsHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn native_sdk_windows_set_menus(host: *WindowsHost, menu_titles: [*]const [*]const u8, menu_title_lens: [*]const usize, menu_count: usize, item_menu_indices: [*]const u32, item_labels: [*]const [*]const u8, item_label_lens: [*]const usize, item_commands: [*]const [*]const u8, item_command_lens: [*]const usize, item_keys: [*]const [*]const u8, item_key_lens: [*]const usize, item_modifiers: [*]const u32, item_separators: [*]const c_int, item_enabled: [*]const c_int, item_checked: [*]const c_int, item_count: usize) c_int;
extern fn native_sdk_windows_set_shortcuts(host: *WindowsHost, ids: [*]const [*]const u8, id_lens: [*]const usize, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) void;
extern fn native_sdk_windows_create_window(host: *WindowsHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, initial_placement: c_int, restore_policy: c_int, resizable: c_int, titlebar_style: c_int, min_width: f64, min_height: f64, show_policy: c_int, window_flags: u32) c_int;
extern fn native_sdk_windows_start_window_drag(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_set_window_drag_regions(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, rects: [*]const f64, exclusions: [*]const c_int, count: usize) c_int;
extern fn native_sdk_windows_window_chrome(host: *WindowsHost, window_id: u64, top: *f64, left: *f64, bottom: *f64, right: *f64, buttons_x: *f64, buttons_y: *f64, buttons_width: *f64, buttons_height: *f64) c_int;
extern fn native_sdk_windows_start_timer(host: *WindowsHost, timer_id: u64, interval_ns: u64, repeats: c_int) void;
extern fn native_sdk_windows_cancel_timer(host: *WindowsHost, timer_id: u64) void;
extern fn native_sdk_windows_focus_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_close_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_minimize_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_hide_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_show_window(host: *WindowsHost, window_id: u64) c_int;
extern fn native_sdk_windows_set_window_close_policy(host: *WindowsHost, window_id: u64, close_policy: c_int) c_int;
extern fn native_sdk_windows_create_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, kind: c_int, gpu_backend_request: c_int, parent: [*]const u8, parent_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, visible: c_int, enabled: c_int, role: [*]const u8, role_len: usize, accessibility_label: [*]const u8, accessibility_label_len: usize, text: [*]const u8, text_len: usize, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_windows_update_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, has_frame: c_int, x: f64, y: f64, width: f64, height: f64, has_layer: c_int, layer: c_int, has_visible: c_int, visible: c_int, has_enabled: c_int, enabled: c_int, has_role: c_int, role: [*]const u8, role_len: usize, has_accessibility_label: c_int, accessibility_label: [*]const u8, accessibility_label_len: usize, has_text: c_int, text: [*]const u8, text_len: usize, has_command: c_int, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_windows_set_view_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_windows_set_view_visible(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, visible: c_int) c_int;
extern fn native_sdk_windows_focus_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_close_view(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_request_gpu_surface_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_note_gpu_surface_input(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_present_gpu_surface_pixels(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, width: usize, height: usize, scale: f64, has_dirty_rect: c_int, dirty_x: f64, dirty_y: f64, dirty_width: f64, dirty_height: f64, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_windows_present_gpu_surface_packet_binary(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, surface_width: f64, surface_height: f64, scale: f64, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, requires_render: c_int, command_count: usize, unsupported_command_count: usize, representable: c_int, packet: [*]const u8, packet_len: usize) c_int;
extern fn native_sdk_windows_upload_gpu_surface_image(host: *WindowsHost, id: u64, width: usize, height: usize, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_windows_remove_gpu_surface_image(host: *WindowsHost, id: u64) c_int;
extern fn native_sdk_windows_register_gpu_surface_font(host: *WindowsHost, id: u64, ttf: [*]const u8, ttf_len: usize, token: *u64) c_int;
extern fn native_sdk_windows_unregister_gpu_surface_font(host: *WindowsHost, id: u64, token: u64) c_int;
extern fn native_sdk_windows_create_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, transparent: c_int, bridge_enabled: c_int) c_int;
extern fn native_sdk_windows_set_webview_frame(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_windows_navigate_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_windows_set_webview_zoom(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, zoom: f64) c_int;
extern fn native_sdk_windows_set_webview_layer(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, layer: c_int) c_int;
extern fn native_sdk_windows_close_webview(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_windows_open_external_url(host: *WindowsHost, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_windows_reveal_path(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_show_open_dialog(host: *WindowsHost, opts: *const WindowsOpenDialogOpts, buffer: [*]u8, buffer_len: usize) WindowsOpenDialogResult;
extern fn native_sdk_windows_show_save_dialog(host: *WindowsHost, opts: *const WindowsSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_show_message_dialog(host: *WindowsHost, opts: *const WindowsMessageDialogOpts) c_int;
extern fn native_sdk_windows_show_notification(host: *WindowsHost, title: [*]const u8, title_len: usize, subtitle: [*]const u8, subtitle_len: usize, body: [*]const u8, body_len: usize, notification_id: [*]const u8, notification_id_len: usize, action_label: [*]const u8, action_label_len: usize, action_command: [*]const u8, action_command_len: usize) c_int;
extern fn native_sdk_windows_create_tray(host: *WindowsHost, icon_path: [*]const u8, icon_path_len: usize, tooltip: [*]const u8, tooltip_len: usize, activation_command: [*]const u8, activation_command_len: usize, alternate_activation_command: [*]const u8, alternate_activation_command_len: usize, open_command: [*]const u8, open_command_len: usize) c_int;
extern fn native_sdk_windows_update_tray_menu(host: *WindowsHost, item_ids: [*]const u32, labels: [*]const [*]const u8, label_lens: [*]const usize, separators: [*]const c_int, enabled_flags: [*]const c_int, details: [*]const [*]const u8, detail_lens: [*]const usize, roles: [*]const c_int, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) c_int;
extern fn native_sdk_windows_remove_tray(host: *WindowsHost) void;
extern fn native_sdk_windows_add_recent_document(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_clear_recent_documents(host: *WindowsHost) c_int;
extern fn native_sdk_windows_set_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, secret: [*]const u8, secret_len: usize) c_int;
extern fn native_sdk_windows_get_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_delete_credential(host: *WindowsHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize) c_int;
extern fn native_sdk_windows_format_local_time(host: *WindowsHost, timestamp_ms: i64, style: c_int, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_clipboard_read(host: *WindowsHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_clipboard_write(host: *WindowsHost, text: [*]const u8, text_len: usize) void;
extern fn native_sdk_windows_clipboard_read_data(host: *WindowsHost, mime_type: [*]const u8, mime_type_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_windows_clipboard_write_data(host: *WindowsHost, mime_type: [*]const u8, mime_type_len: usize, bytes: [*]const u8, bytes_len: usize) c_int;
extern fn native_sdk_windows_audio_load(host: *WindowsHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_windows_audio_load_url(host: *WindowsHost, url: [*]const u8, url_len: usize, cache_path: [*]const u8, cache_path_len: usize, expected_bytes: u64) c_int;
extern fn native_sdk_windows_audio_play(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_pause(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_stop(host: *WindowsHost) c_int;
extern fn native_sdk_windows_audio_seek(host: *WindowsHost, position_ms: u64) c_int;
extern fn native_sdk_windows_audio_set_volume(host: *WindowsHost, volume: f64) c_int;
const WindowsAudioCapturePush = *const fn (context: ?*anyopaque, kind: c_int, source: c_int, sample_rate: u32, channels: u8, timestamp_ns: u64, frames: u32, pcm: ?[*]const u8, pcm_len: usize) callconv(.c) c_int;
extern fn native_sdk_windows_audio_capture_start(host: *WindowsHost, source: c_int, sample_rate: u32, channels: u8, push_fn: WindowsAudioCapturePush, push_context: ?*anyopaque) c_int;
extern fn native_sdk_windows_audio_capture_stop(host: *WindowsHost, source: c_int) c_int;
extern fn native_sdk_windows_audio_spectrum_supported(host: *WindowsHost) c_int;
extern fn native_sdk_windows_show_context_menu(host: *WindowsHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, token: u64, items: [*]const WindowsContextMenuItem, count: usize) c_int;

/// One context-menu entry crossing the C ABI (the same shape the macOS
/// host takes): labels ride as pointer+length, flags as ints.
const WindowsContextMenuItem = extern struct {
    item_id: u32,
    label: [*]const u8,
    label_len: usize,
    enabled: c_int,
    separator: c_int,
};

const WindowsOpenDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
    allow_directories: c_int,
    allow_multiple: c_int,
};

const WindowsOpenDialogResult = extern struct {
    count: usize,
    bytes_written: usize,
};

const WindowsSaveDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
};

const WindowsMessageDialogOpts = extern struct {
    style: c_int,
    title: [*]const u8,
    title_len: usize,
    message: [*]const u8,
    message_len: usize,
    informative_text: [*]const u8,
    informative_text_len: usize,
    primary_button: [*]const u8,
    primary_button_len: usize,
    secondary_button: [*]const u8,
    secondary_button_len: usize,
    tertiary_button: [*]const u8,
    tertiary_button_len: usize,
};

/// The startup-window twin of the runtime's create-time `.hide` gate:
/// on windows, hide-on-close is honest only when the app declares a
/// tray (status item) — SW_HIDE removes the taskbar entry and windows
/// has no dock-reopen path, so without a tray a hidden window is a
/// running, invisible, unreachable app. The generated runner refuses
/// the declaration at comptime, the runtime refuses secondary windows
/// at create (through the conditional `window_hide_on_close` answer
/// below), and this refuses the platform-created main window at init.
/// Pure (no Win32 externs), so the refusal is unit-testable on every
/// host.
fn refuseUnsupportedMainWindowClosePolicy(app_info: platform_mod.AppInfo) Error!void {
    if (app_info.resolvedMainWindow().close_policy != .hide) return;
    if (app_info.declares_tray) return;
    std.debug.print("window close_policy \"hide\" on windows requires the \"tray\" capability: hiding removes the taskbar entry and windows has no dock-reopen path, so only a status item (tray) could bring the hidden window back - add \"tray\" to .capabilities and install a status item, or declare \"quit\" (the default)\n", .{});
    return error.UnsupportedWindowClosePolicy;
}

/// A Win32 per-pixel-alpha window is painted as one top-level layered
/// bitmap: child HWNDs and non-client chrome do not participate in that
/// bitmap. Canvas children are redirected explicitly by the host, but
/// standard/hidden titlebars and an HMENU would otherwise be silently
/// erased by the transparent DIB. Keep that limitation explicit at the
/// create/configure seams instead of accepting an unusable combination.
fn refuseUnsupportedTransparentWindow(options: platform_mod.WindowOptions, menus_active: bool) Error!void {
    if (!options.transparent) return;
    if (options.titlebar != .chromeless or menus_active) {
        std.debug.print("transparent windows on windows require titlebar = \"chromeless\" and cannot be combined with application menus because Win32 layered windows cannot composite non-client chrome\n", .{});
        return error.UnsupportedWindowTransparency;
    }
}

pub const WindowsPlatform = struct {
    host: *WindowsHost,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},
    /// Mirrors the successfully installed native menu model so a
    /// later runtime-created alpha window can fail with the precise
    /// transparency error before crossing the C ABI.
    menus_active: bool = false,
    /// Latched when effects teardown abandons an in-flight platform call
    /// (a channel wake or blocking credential operation): the stale
    /// call still holds this platform as its context and may execute
    /// into it at any later time, so `deinit` must skip destruction
    /// and leak the host, process-lived — and the wrapper struct the
    /// context actually points at (the wake thunk casts to
    /// `*WindowsPlatform` before reaching the host) must outlive the
    /// call too, which is why runners allocate it through
    /// `createWithOptions` and retire it through `destroy`, the
    /// latch-gated free.
    channel_wake_abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    audio_capture_sinks: [2]platform_mod.AudioCaptureSink = [_]platform_mod.AudioCaptureSink{.{}} ** 2,

    pub fn init(title: []const u8, size: geometry.SizeF) Error!WindowsPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(title: []const u8, size: geometry.SizeF, web_engine: platform_mod.WebEngine) Error!WindowsPlatform {
        return initWithOptions(size, web_engine, .{ .app_name = title, .window_title = title });
    }

    pub fn initWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!WindowsPlatform {
        const window_options = app_info.resolvedMainWindow();
        // The MAIN window is created right here, before any runtime
        // exists, so the runtime's create-time `.hide` gate (the
        // window_hide_on_close feature check) never sees it — the same
        // seam the GTK host holds for its unconditional refusal. On
        // windows the refusal is conditional: hiding removes the
        // taskbar entry and windows has no dock-reopen path, so a
        // declared tray (status item) is the ONLY re-show affordance.
        try refuseUnsupportedMainWindowClosePolicy(app_info);
        try refuseUnsupportedTransparentWindow(window_options, false);
        const window_title = window_options.resolvedTitle(app_info.app_name);
        const frame = window_options.default_frame;
        const host = native_sdk_windows_create(app_info.app_name.ptr, app_info.app_name.len, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, app_info.icon_path.ptr, app_info.icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0, initialPlacementInt(window_options.initial_placement), restorePolicyInt(window_options.restore_policy), if (window_options.resizable) 1 else 0, titlebarStyleInt(window_options.titlebar), minSizeFloor(window_options.min_width), minSizeFloor(window_options.min_height), showModeInt(window_options.show), windowFlags(window_options)) orelse return error.CreateFailed;
        // Packet text must use the same Geist metrics the engine planned
        // against. Register both built-in faces directly from their
        // compile-time bytes; custom application fonts keep the public
        // side-channel and ids >= 64. If either required face cannot be
        // registered, disable packet rendering as one capability and keep
        // the exact reference-pixel fallback — never draw system faces
        // against Geist-planned layout.
        if (web_engine == .system) {
            var font_token: u64 = 0;
            _ = native_sdk_windows_register_gpu_surface_font(host, 1, bundled_geist_regular.ptr, bundled_geist_regular.len, &font_token);
            _ = native_sdk_windows_register_gpu_surface_font(host, 2, bundled_geist_mono.ptr, bundled_geist_mono.len, &font_token);
        }
        // The manifest's declared close policy rides right after the
        // create, like the min-size floor: close handling is host
        // window state fixed for the window's life.
        applyWindowClosePolicy(host, window_options.id, window_options.close_policy);
        return .{
            .host = host,
            .web_engine = web_engine,
            .app_info = app_info,
            .surface_value = .{
                .id = 1,
                .size = size,
                .scale_factor = 1,
            },
        };
    }

    /// Heap-allocate the wrapper (process allocator) and initialize it
    /// in place. Runners must use this over a stack `initWithOptions`
    /// value: `platform().services.context` is this wrapper's ADDRESS,
    /// worker threads dereference it inside the channel wake path, and
    /// a wake call teardown abandons may do so at any later time —
    /// after a runner's stack frame would have unwound. Pair with
    /// `destroy`, the latch-gated free.
    pub fn createWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!*WindowsPlatform {
        const self = std.heap.page_allocator.create(WindowsPlatform) catch return error.CreateFailed;
        errdefer std.heap.page_allocator.destroy(self);
        self.* = try initWithOptions(size, web_engine, app_info);
        return self;
    }

    /// `deinit` plus the wrapper's own storage, gated by the same
    /// latch: an abandoned channel wake call dereferences this wrapper
    /// (its context) BEFORE it reaches the native host, so on abandon
    /// both are leaked, process-lived — deinit-gating extended to
    /// lifetime-gating, the honest completion of the abandoned-worker
    /// idiom. No cross-thread race on the gate: the latch is set
    /// synchronously on the loop thread during effects teardown, which
    /// runs before the runner's deferred destroy.
    pub fn destroy(self: *WindowsPlatform) void {
        self.deinit();
        if (self.channel_wake_abandoned.load(.seq_cst)) return;
        std.heap.page_allocator.destroy(self);
    }

    pub fn deinit(self: *WindowsPlatform) void {
        // An abandoned platform call may still enter this host at
        // any later time (see `channel_wake_abandoned`): destroying it
        // would turn that stale call into a use-after-free, so the
        // host is deliberately leaked, process-lived — the
        // abandoned-worker idiom, applied to the platform itself.
        if (self.channel_wake_abandoned.load(.seq_cst)) {
            std.debug.print("windows platform teardown: an abandoned platform call may still enter this host; skipping destruction and leaking it (and the wrapper it enters through), process-lived, so the stale call stays safe\n", .{});
            return;
        }
        native_sdk_windows_destroy(self.host);
    }

    pub fn platform(self: *WindowsPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "windows",
            .surface_value = self.surface_value,
            .run_fn = run,
            .supports_fn = supportsFeature,
            .services = .{
                .context = self,
                .read_clipboard_fn = readClipboard,
                .write_clipboard_fn = writeClipboard,
                .read_clipboard_data_fn = readClipboardData,
                .write_clipboard_data_fn = writeClipboardData,
                .load_webview_fn = loadWebView,
                .load_window_webview_fn = loadWindowWebView,
                .complete_bridge_fn = completeBridge,
                .complete_window_bridge_fn = completeWindowBridge,
                .complete_webview_bridge_fn = completeWebViewBridge,
                .create_window_fn = createWindow,
                .focus_window_fn = focusWindow,
                .close_window_fn = closeWindow,
                .minimize_window_fn = minimizeWindow,
                .hide_window_fn = hideWindow,
                .show_window_fn = showWindow,
                .quit_app_fn = quitApp,
                .start_window_drag_fn = startWindowDrag,
                .set_window_drag_regions_fn = setWindowDragRegions,
                .window_chrome_fn = windowChrome,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .note_gpu_surface_input_fn = noteGpuSurfaceInput,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .present_gpu_surface_packet_binary_fn = presentGpuSurfacePacketBinary,
                .upload_gpu_surface_image_fn = uploadGpuSurfaceImage,
                .remove_gpu_surface_image_fn = removeGpuSurfaceImage,
                .register_gpu_surface_font_fn = registerGpuSurfaceFont,
                .unregister_gpu_surface_font_fn = unregisterGpuSurfaceFont,
                .show_context_menu_fn = showContextMenu,
                .create_webview_fn = createWebView,
                .set_webview_frame_fn = setWebViewFrame,
                .navigate_webview_fn = navigateWebView,
                .set_webview_zoom_fn = setWebViewZoom,
                .set_webview_layer_fn = setWebViewLayer,
                .close_webview_fn = closeWebView,
                .show_open_dialog_fn = showOpenDialog,
                .show_save_dialog_fn = showSaveDialog,
                .show_message_dialog_fn = showMessageDialog,
                .show_notification_fn = showNotification,
                .create_tray_fn = createTray,
                .update_tray_menu_fn = updateTrayMenu,
                .remove_tray_fn = removeTray,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .set_credential_fn = setCredential,
                .get_credential_fn = getCredential,
                .delete_credential_fn = deleteCredential,
                .note_blocking_call_abandoned_fn = noteChannelWakeAbandoned,
                .format_local_time_fn = formatLocalTime,
                .audio_load_fn = audioLoad,
                .audio_load_url_fn = audioLoadUrl,
                .audio_play_fn = audioPlay,
                .audio_pause_fn = audioPause,
                .audio_stop_fn = audioStop,
                .audio_seek_fn = audioSeek,
                .audio_set_volume_fn = audioSetVolume,
                .audio_capture_start_fn = if (self.web_engine == .system) audioCaptureStart else null,
                .audio_capture_stop_fn = if (self.web_engine == .system) audioCaptureStop else null,
                // The video load verbs are teaching refusals (see
                // `videoLoad`); the transport verbs stay null — the
                // channel never activates without a successful load.
                .video_load_fn = videoLoad,
                .video_load_url_fn = videoLoadUrl,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .start_timer_fn = startTimer,
                .cancel_timer_fn = cancelTimer,
                .wake_fn = wake,
                .note_channel_wake_abandoned_fn = noteChannelWakeAbandoned,
                .request_frame_fn = requestFrame,
                .decode_image_fn = decodeImage,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: platform_mod.PlatformFeature) bool {
        const self: *WindowsPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
            .native_views,
            .native_control_commands,
            .menus,
            .tray,
            .shortcuts,
            .dialogs,
            .clipboard_text,
            .clipboard_rich_data,
            .open_url,
            .reveal_path,
            .notifications,
            .recent_documents,
            .file_drops,
            .app_activation_events,
            .gpu_surfaces,
            .audio_playback,
            .audio_streaming,
            .microphone_capture,
            .system_audio_capture,
            => self.web_engine == .system,
            // Credential Manager backs both core effects and the builtin
            // bridge and does not depend on WebView2 being selected.
            .credentials => true,
            // close_policy .hide: WM_CLOSE hides (ShowWindow SW_HIDE),
            // the window stays in the host map, and the tray is the
            // ONLY re-show affordance — SW_HIDE removes the taskbar
            // entry and windows has no dock-reopen path. An app that
            // declares no tray gets an honest false, so the runtime's
            // create-time gates refuse a `.hide` declaration instead of
            // stranding a hidden window nothing could re-show.
            .window_hide_on_close => self.web_engine == .system and self.app_info.declares_tray,
            // Spectrum analysis captures the app's OWN audio session
            // through process-scoped WASAPI loopback, which the OS grew
            // in Windows 10 2004 — the host probes the activation
            // support live instead of assuming the build.
            .audio_spectrum => self.web_engine == .system and audioSpectrumAvailable(self.host),
            // Native context menus present through TrackPopupMenu (the
            // same popup path the tray menu uses), so the answer rides
            // the same system-engine gate as the tray.
            .context_menus => self.web_engine == .system,
            // Native scroll drivers and app-owned view-surface adoption
            // are macOS-only today; Win32 keeps the engine's wheel
            // physics.
            .gpu_surface_scroll_drivers, .view_surface_adoption => false,
            // Video decode (a Media Foundation session feeding the
            // media-surface texture channel) is not implemented yet:
            // an honest false rather than a half-implemented player.
            // The load verbs teach and refuse (see `videoLoad`), so an
            // app that skips the capability check still learns exactly
            // what is missing.
            .video_playback => false,
        };
    }

    /// Live probe for process-scoped loopback capture (the host asks
    /// the audio activation API rather than trusting a version check).
    /// Test builds link no Win32 host, so they answer the honest floor.
    fn audioSpectrumAvailable(host: *WindowsHost) bool {
        if (comptime @import("builtin").is_test) return false;
        if (@import("builtin").target.os.tag != .windows) return false;
        return native_sdk_windows_audio_spectrum_supported(host) != 0;
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *WindowsPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        native_sdk_windows_set_bridge_callback(self.host, windowsBridgeCallback, &self.state);
        native_sdk_windows_run(self.host, windowsCallback, &self.state);
        if (self.state.failed) return error.CallbackFailed;
    }

    fn windowById(self: *const WindowsPlatform, window_id: platform_mod.WindowId) platform_mod.WindowOptions {
        var index: usize = 0;
        while (index < self.app_info.startupWindowCount()) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            if (window.id == window_id) return window;
        }
        return .{ .id = window_id, .label = "", .title = self.app_info.resolvedWindowTitle() };
    }
};

const RunState = struct {
    self: ?*WindowsPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,

    fn emit(self: *RunState, event: platform_mod.Event) void {
        const handler = self.handler orelse return;
        const context = self.handler_context orelse return;
        handler(context, event) catch {
            self.failed = true;
            if (self.self) |windows| native_sdk_windows_stop(windows.host);
        };
    }
};

fn windowsCallback(context: ?*anyopaque, event: *const WindowsEvent) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .start => state.emit(.app_start),
        .frame => state.emit(.frame_requested),
        .shutdown => state.emit(.app_shutdown),
        .app_activated => state.emit(.app_activated),
        .app_deactivated => state.emit(.app_deactivated),
        .files_dropped => {
            var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
            const paths = platform_mod.splitDropPaths(event.drop_paths[0..event.drop_paths_len], paths_buffer[0..]);
            state.emit(.{ .files_dropped = .{
                .window_id = event.window_id,
                .paths = paths,
            } });
        },
        .resize => {
            const surface: platform_mod.Surface = .{
                .id = event.window_id,
                .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
            };
            if (state.self) |windows| windows.surface_value = surface;
            state.emit(.{ .surface_resized = surface });
        },
        .window_frame => if (state.self) |windows| {
            const event_label = event.label[0..event.label_len];
            const event_title = event.title[0..event.title_len];
            const window = if (event_label.len > 0)
                platform_mod.WindowOptions{ .id = event.window_id, .label = event_label, .title = event_title }
            else
                windows.windowById(event.window_id);
            state.emit(.{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(windows.app_info.app_name),
                .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
                .open = event.open != 0,
                .focused = event.focused != 0,
                .hidden = event.hidden != 0,
            } });
        },
        .view_focused => state.emit(.{ .view_focused = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
        } }),
        .shortcut => state.emit(.{ .shortcut = .{
            .id = event.shortcut_id[0..event.shortcut_id_len],
            .key = event.shortcut_key[0..event.shortcut_key_len],
            .modifiers = shortcutModifiersFromFlags(event.shortcut_modifiers),
            .window_id = event.window_id,
        } }),
        .native_command => state.emit(.{ .native_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
            .view_label = event.view_label[0..event.view_label_len],
        } }),
        .menu_command => state.emit(.{ .menu_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
        } }),
        .tray_action => state.emit(.{ .tray_action = .{ .item_id = event.tray_item_id } }),
        .tray_command => state.emit(.{ .tray_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
        } }),
        .notification_command => state.emit(.{ .notification_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
        } }),
        .gpu_surface_frame => state.emit(.{ .gpu_surface_frame = gpuSurfaceFrameEventFromWindowsEvent(event) }),
        .gpu_surface_resize => state.emit(.{ .gpu_surface_resized = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
            .scale_factor = @floatCast(event.scale),
        } }),
        .gpu_surface_input => state.emit(.{ .gpu_surface_input = gpuSurfaceInputEventFromWindowsEvent(event) }),
        .wake => state.emit(.wake),
        .timer => state.emit(.{ .timer = .{
            .id = event.timer_id,
            .timestamp_ns = event.timestamp_ns,
        } }),
        .appearance => state.emit(.{ .appearance_changed = .{
            .color_scheme = if (event.color_scheme == 1) .dark else .light,
            .reduce_motion = event.reduce_motion != 0,
            .high_contrast = event.high_contrast != 0,
        } }),
        .audio => state.emit(.{ .audio = .{
            .kind = audioEventKindFromInt(event.audio_kind),
            .position_ms = event.audio_position_ms,
            .duration_ms = event.audio_duration_ms,
            .playing = event.audio_playing != 0,
            .buffering = event.audio_buffering != 0,
            .bands = event.audio_bands,
        } }),
        .context_menu_action => state.emit(.{ .context_menu_action = contextMenuActionEventFromWindowsEvent(event) }),
    }
}

fn gpuSurfaceFrameEventFromWindowsEvent(event: *const WindowsEvent) platform_mod.GpuSurfaceFrameEvent {
    return .{
        .window_id = event.window_id,
        .label = event.view_label[0..event.view_label_len],
        .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
        .scale_factor = @floatCast(event.scale),
        .frame_index = event.frame_index,
        .timestamp_ns = event.timestamp_ns,
        .frame_interval_ns = event.frame_interval_ns,
        .nonblank = event.nonblank != 0,
        .sample_color = event.sample_color,
        .packet_decode_ns = event.packet_decode_ns,
        .packet_draw_ns = event.packet_draw_ns,
        .occluded = event.occluded != 0,
        .backend = if (event.gpu_backend == 1) .direct2d else .software,
        .pixel_format = .bgra8_unorm,
        .present_mode = .timer,
        .alpha_mode = .@"opaque",
        .color_space = .srgb,
        .vsync = true,
        .status = .ready,
        .canvas_frame_full_repaint = event.force_full_repaint != 0,
    };
}

/// Pure event mapping (no host calls), unit-testable on every build
/// host: the C event's `widget_id` is the request's correlation token
/// and `menu_item_id` the selected item (0 = dismissed) — the same
/// payload contract as the macOS host, so replay is shape-identical.
fn contextMenuActionEventFromWindowsEvent(event: *const WindowsEvent) platform_mod.ContextMenuActionEvent {
    return .{
        .window_id = event.window_id,
        .view_label = event.view_label[0..event.view_label_len],
        .token = event.widget_id,
        .item_id = event.menu_item_id,
    };
}

/// Ordinals match the audio report kinds in webview2_host.cpp (the same
/// set the macOS host uses); anything unknown degrades to `.failed` so a
/// host/SDK skew is loud in the app instead of undefined behavior here.
fn audioEventKindFromInt(value: c_int) platform_mod.AudioEventKind {
    return switch (value) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        4 => .spectrum,
        else => .failed,
    };
}

fn gpuSurfaceInputEventFromWindowsEvent(event: *const WindowsEvent) platform_mod.GpuSurfaceInputEvent {
    return .{
        .window_id = event.window_id,
        .label = event.view_label[0..event.view_label_len],
        .kind = gpuSurfaceInputKindFromInt(event.input_kind),
        .timestamp_ns = event.timestamp_ns,
        .x = @floatCast(event.x),
        .y = @floatCast(event.y),
        .button = event.button,
        .delta_x = @floatCast(event.delta_x),
        .delta_y = @floatCast(event.delta_y),
        .key = event.key_text[0..event.key_text_len],
        .text = event.input_text[0..event.input_text_len],
        .composition_cursor = if (event.has_composition_cursor != 0) event.composition_cursor else null,
        .modifiers = shortcutModifiersFromFlags(event.shortcut_modifiers),
    };
}

fn gpuSurfaceInputKindFromInt(value: c_int) platform_mod.GpuSurfaceInputKind {
    return switch (value) {
        0 => .pointer_down,
        1 => .pointer_up,
        2 => .pointer_move,
        3 => .pointer_drag,
        4 => .scroll,
        5 => .key_down,
        6 => .key_up,
        7 => .text_input,
        8 => .ime_set_composition,
        9 => .ime_commit_composition,
        10 => .ime_cancel_composition,
        11 => .pointer_cancel,
        else => .pointer_move,
    };
}

fn windowsBridgeCallback(context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
        .webview_label = webview_label[0..webview_label_len],
    } });
}

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_clipboard_read(self.host, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_clipboard_write(self.host, text.ptr, text.len);
}

fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_clipboard_read_data(self.host, mime_type.ptr, mime_type.len, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboardData(context: ?*anyopaque, data: platform_mod.ClipboardData) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_clipboard_write_data(self.host, data.mime_type.ptr, data.mime_type.len, data.bytes.ptr, data.bytes.len) == 0) return error.UnsupportedService;
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    const result = native_sdk_windows_load_window_webview(
        self.host,
        window_id,
        source.bytes.ptr,
        source.bytes.len,
        switch (source.kind) {
            .html => 0,
            .url => 1,
            .assets => 2,
        },
        assets.root_path.ptr,
        assets.root_path.len,
        assets.entry.ptr,
        assets.entry.len,
        assets.origin.ptr,
        assets.origin.len,
        if (assets.spa_fallback) 1 else 0,
    );
    if (result < 0) return error.UnsupportedWindowTransparency;
    if (result == 0) return error.CreateFailed;
}

fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn completeWebViewBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
    if (std.mem.eql(u8, webview_label, "main")) return completeWindowBridge(context, window_id, response);
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_bridge_respond_webview(self.host, window_id, webview_label.ptr, webview_label.len, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
}

/// Thread-safe: `PostMessageW` into the existing message loop (the
/// enqueue-only shape the wake contract requires — never the
/// synchronous `SendMessage`), whose window procedure emits `.wake` on
/// the loop thread.
fn wake(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_wake(self.host);
}

/// Teardown abandoned an in-flight channel wake call: latch the flag
/// `deinit` consults so this host is leaked rather than destroyed (see
/// `WindowsPlatform.channel_wake_abandoned`).
fn noteChannelWakeAbandoned(context: ?*anyopaque) void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    self.channel_wake_abandoned.store(true, .seq_cst);
}

/// Thread-safe like `wake`: `PostMessage` into the message loop, whose
/// window procedure emits one `.frame` event on the loop thread. The
/// automation arrival watcher calls this when a command lands so
/// consumption never depends on the host's own frame pump.
fn requestFrame(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_request_frame(self.host);
}

/// Headless image codec for session replay: the SAME WIC decode a live
/// host serves (see `decodeImage` below — a context-free bytes-to-pixels
/// call, no window, no message loop), so journaled image bytes
/// re-register the identical pixels under a headless replay on the same
/// platform.
pub fn installHeadlessImageCodec(services: *platform_mod.PlatformServices) void {
    services.decode_image_fn = decodeImage;
}

/// WIC-backed image decoding (PNG, JPEG, ... — every codec the OS
/// ships) into straight-alpha RGBA8.
fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8, max_pixels: usize) anyerror!platform_mod.DecodedImage {
    _ = context;
    var width: usize = 0;
    var height: usize = 0;
    return switch (native_sdk_windows_decode_image(bytes.ptr, bytes.len, buffer.ptr, buffer.len, max_pixels, &width, &height)) {
        1 => .{ .width = width, .height = height, .rgba8 = buffer[0 .. width * height * 4] },
        -1 => error.ImageTooLarge,
        else => error.ImageDecodeFailed,
    };
}

fn titlebarStyleInt(style: platform_mod.WindowTitlebarStyle) c_int {
    return switch (style) {
        .standard => 0,
        .hidden_inset => 1,
        .hidden_inset_tall => 2,
        .chromeless => 3,
    };
}

fn initialPlacementInt(placement: platform_mod.WindowInitialPlacement) c_int {
    return switch (placement) {
        .restored => 0,
        .explicit => 1,
        .default => 2,
    };
}

fn restorePolicyInt(policy: platform_mod.WindowRestorePolicy) c_int {
    return switch (policy) {
        .clamp_to_visible_screen => 0,
        .center_on_primary => 1,
    };
}

fn showModeInt(mode: platform_mod.WindowShowMode) c_int {
    return switch (mode) {
        .immediate => 0,
        .on_first_present => 1,
        .hidden => 2,
    };
}

fn windowFlags(options: platform_mod.WindowOptions) u32 {
    var flags: u32 = 0;
    if (options.transparent) flags |= 1 << 0;
    if (options.always_on_top) flags |= 1 << 1;
    if (options.click_through) flags |= 1 << 2;
    if (!options.activate_on_show) flags |= 1 << 3;
    if (!options.allows_fullscreen) flags |= 1 << 4;
    return flags;
}

/// Zero/negative/non-finite floors are the "no floor" sentinel (the
/// host leaves that axis at its natural minimum).
fn closePolicyInt(policy: platform_mod.WindowClosePolicy) c_int {
    return switch (policy) {
        .quit => 0,
        .hide => 1,
    };
}

/// Register a window's declared close policy with the host right after
/// create. `.quit` skips the call — it IS the host default.
fn applyWindowClosePolicy(host: *WindowsHost, window_id: u64, policy: platform_mod.WindowClosePolicy) void {
    if (policy == .quit) return;
    _ = native_sdk_windows_set_window_close_policy(host, window_id, closePolicyInt(policy));
}

fn minSizeFloor(value: f32) f64 {
    return if (std.math.isFinite(value) and value > 0) value else 0;
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    try refuseUnsupportedTransparentWindow(options, self.menus_active);
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (native_sdk_windows_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0, initialPlacementInt(options.initial_placement), restorePolicyInt(options.restore_policy), if (options.resizable) 1 else 0, titlebarStyleInt(options.titlebar), minSizeFloor(options.min_width), minSizeFloor(options.min_height), showModeInt(options.show), windowFlags(options)) == 0) return error.CreateFailed;
    applyWindowClosePolicy(self.host, options.id, options.close_policy);
    return .{
        .id = options.id,
        .label = options.label,
        .title = title,
        .frame = frame,
        .scale_factor = 1,
        .open = true,
        .focused = options.activate_on_show and options.show == .immediate,
        .hidden = options.show == .hidden,
    };
}

fn focusWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn minimizeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_minimize_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn hideWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_hide_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn showWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_show_window(self.host, window_id) == 0) return error.WindowNotFound;
}

/// The graceful quit: stop the message loop the same way the last
/// window's WM_DESTROY does (PostQuitMessage); the run loop's exit
/// emits the same shutdown event.
fn quitApp(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_stop(self.host);
}

fn startWindowDrag(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_start_window_drag(self.host, window_id) == 0) return error.WindowNotFound;
}

/// Drag-region mirror capacity per push: the runtime's own per-view cap
/// (`max_canvas_widget_window_drag_regions_per_view` = 32) bounds it in
/// practice; the flat buffers below are sized for that with headroom.
const max_drag_region_push: usize = 64;

/// Push the canvas view's window-drag region mirror to the host, which
/// answers `WM_NCHITTEST` with `HTCAPTION` inside a region (minus its
/// exclusions) so drag, double-click-maximize, and the right-click
/// system menu are the OS's own caption behavior on hidden-titlebar
/// windows.
fn setWindowDragRegions(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, regions: []const platform_mod.WindowDragRegion) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (regions.len > max_drag_region_push) return error.WindowLimitReached;
    var rects: [max_drag_region_push * 4]f64 = undefined;
    var exclusions: [max_drag_region_push]c_int = undefined;
    for (regions, 0..) |region, index| {
        rects[index * 4 + 0] = region.frame.x;
        rects[index * 4 + 1] = region.frame.y;
        rects[index * 4 + 2] = region.frame.width;
        rects[index * 4 + 3] = region.frame.height;
        exclusions[index] = if (region.exclusion) 1 else 0;
    }
    if (native_sdk_windows_set_window_drag_regions(self.host, window_id, label.ptr, label.len, &rects, &exclusions, regions.len) == 0) return error.ViewNotFound;
}

/// Chrome overlay geometry for hidden-titlebar windows: how far the
/// DWM-drawn caption-button band (top) and the min/max/close cluster
/// (trailing edge) overlay the content, plus the cluster's frame in
/// content coordinates — all in logical points. Standard-chrome windows
/// report zero.
fn windowChrome(context: ?*anyopaque, window_id: platform_mod.WindowId) platform_mod.WindowChrome {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var top: f64 = 0;
    var left: f64 = 0;
    var bottom: f64 = 0;
    var right: f64 = 0;
    var buttons_x: f64 = 0;
    var buttons_y: f64 = 0;
    var buttons_width: f64 = 0;
    var buttons_height: f64 = 0;
    if (native_sdk_windows_window_chrome(self.host, window_id, &top, &left, &bottom, &right, &buttons_x, &buttons_y, &buttons_width, &buttons_height) == 0) return .{};
    return .{
        .insets = .{
            .top = @floatCast(top),
            .left = @floatCast(left),
            .bottom = @floatCast(bottom),
            .right = @floatCast(right),
        },
        .buttons = geometry.RectF.init(@floatCast(buttons_x), @floatCast(buttons_y), @floatCast(buttons_width), @floatCast(buttons_height)),
    };
}

fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_start_timer(self.host, id, interval_ns, if (repeats) 1 else 0);
}

fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_windows_cancel_timer(self.host, id);
}

fn createView(context: ?*anyopaque, options: platform_mod.ViewOptions) anyerror!void {
    if (options.kind == .webview) return createWebView(context, options.webViewOptions());
    if (!isSupportedNativeViewKind(options.kind)) return error.UnsupportedViewKind;
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = options.frame;
    const parent = options.parent orelse "";
    if (native_sdk_windows_create_view(
        self.host,
        options.window_id,
        options.label.ptr,
        options.label.len,
        viewKindInt(options.kind),
        if (options.kind == .gpu_surface) gpuSurfaceBackendRequestInt(options.gpu_surface.backend) else 0,
        parent.ptr,
        parent.len,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
        options.layer,
        if (options.visible) 1 else 0,
        if (options.enabled) 1 else 0,
        options.role.ptr,
        options.role.len,
        options.accessibility_label.ptr,
        options.accessibility_label.len,
        options.text.ptr,
        options.text.len,
        options.command.ptr,
        options.command.len,
    ) == 0) return error.CreateFailed;
}

fn updateView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, patch: platform_mod.ViewPatch) anyerror!void {
    if (patch.url != null) return error.InvalidViewOptions;
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = patch.frame orelse geometry.RectF.init(0, 0, 0, 0);
    const role = patch.role orelse "";
    const accessibility_label = patch.accessibility_label orelse "";
    const text = patch.text orelse "";
    const command = patch.command orelse "";
    if (native_sdk_windows_update_view(
        self.host,
        window_id,
        label.ptr,
        label.len,
        if (patch.frame != null) 1 else 0,
        frame.x,
        frame.y,
        frame.width,
        frame.height,
        if (patch.layer != null) 1 else 0,
        patch.layer orelse 0,
        if (patch.visible != null) 1 else 0,
        if (patch.visible orelse false) 1 else 0,
        if (patch.enabled != null) 1 else 0,
        if (patch.enabled orelse false) 1 else 0,
        if (patch.role != null) 1 else 0,
        role.ptr,
        role.len,
        if (patch.accessibility_label != null) 1 else 0,
        accessibility_label.ptr,
        accessibility_label.len,
        if (patch.text != null) 1 else 0,
        text.ptr,
        text.len,
        if (patch.command != null) 1 else 0,
        command.ptr,
        command.len,
    ) == 0) return error.ViewNotFound;
}

fn setViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_set_view_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.ViewNotFound;
}

fn setViewVisible(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, visible: bool) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_set_view_visible(self.host, window_id, label.ptr, label.len, if (visible) 1 else 0) == 0) return error.ViewNotFound;
}

fn focusView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewFocus;
    if (native_sdk_windows_focus_view(self.host, window_id, label.ptr, label.len) == 0) return error.UnsupportedViewFocus;
}

fn closeView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_windows_close_view(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_request_gpu_surface_frame(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn noteGpuSurfaceInput(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return;
    _ = native_sdk_windows_note_gpu_surface_input(self.host, window_id, label.ptr, label.len);
}

fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: platform_mod.GpuSurfacePixels) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const dirty_bounds = if (pixels.dirty_bounds) |bounds| bounds.normalized() else geometry.RectF{};
    if (native_sdk_windows_present_gpu_surface_pixels(
        self.host,
        pixels.window_id,
        pixels.label.ptr,
        pixels.label.len,
        pixels.width,
        pixels.height,
        pixels.scale_factor,
        if (pixels.dirty_bounds != null) 1 else 0,
        dirty_bounds.x,
        dirty_bounds.y,
        dirty_bounds.width,
        dirty_bounds.height,
        pixels.rgba8.ptr,
        pixels.rgba8.len,
    ) == 0) return error.ViewNotFound;
}

fn presentGpuSurfacePacketBinary(context: ?*anyopaque, packet: platform_mod.GpuSurfacePacket) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const result = native_sdk_windows_present_gpu_surface_packet_binary(
        self.host,
        packet.window_id,
        packet.label.ptr,
        packet.label.len,
        packet.surface_size.width,
        packet.surface_size.height,
        packet.scale_factor,
        packet.clear_color_rgba8[0],
        packet.clear_color_rgba8[1],
        packet.clear_color_rgba8[2],
        packet.clear_color_rgba8[3],
        if (packet.requires_render) 1 else 0,
        packet.command_count,
        packet.unsupported_command_count,
        if (packet.representable) 1 else 0,
        packet.binary.ptr,
        packet.binary.len,
    );
    switch (result) {
        1 => return,
        0 => return error.UnsupportedService,
        -1 => return error.ViewNotFound,
        else => return error.InvalidGpuSurfacePacket,
    }
}

fn uploadGpuSurfaceImage(context: ?*anyopaque, image: platform_mod.GpuSurfaceImagePixels) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return gpuSurfaceImageUploadResult(native_sdk_windows_upload_gpu_surface_image(
        self.host,
        image.id,
        image.width,
        image.height,
        image.rgba8.ptr,
        image.rgba8.len,
    ));
}

fn gpuSurfaceImageUploadResult(result: c_int) anyerror!void {
    switch (result) {
        1 => return,
        0 => return error.UnsupportedService,
        else => return error.InvalidGpuSurfaceImage,
    }
}

fn removeGpuSurfaceImage(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_remove_gpu_surface_image(self.host, id) == 0) return error.InvalidGpuSurfaceImage;
}

fn registerGpuSurfaceFont(context: ?*anyopaque, font: platform_mod.GpuSurfaceFontData) anyerror!u64 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var token: u64 = 0;
    return gpuSurfaceFontRegistrationResult(
        native_sdk_windows_register_gpu_surface_font(self.host, font.id, font.ttf.ptr, font.ttf.len, &token),
        token,
    );
}

fn gpuSurfaceFontRegistrationResult(result: c_int, token: u64) anyerror!u64 {
    return switch (result) {
        1 => token,
        0 => error.UnsupportedService,
        else => error.InvalidGpuSurfaceFont,
    };
}

fn unregisterGpuSurfaceFont(context: ?*anyopaque, id: u64, token: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    switch (native_sdk_windows_unregister_gpu_surface_font(self.host, id, token)) {
        1 => return,
        0 => return error.UnsupportedService,
        else => return error.InvalidGpuSurfaceFont,
    }
}

/// Win32 menus treat `&` in an item label as a mnemonic marker —
/// AppendMenuW eats the ampersand and underlines the next character —
/// so an app-authored label like "R&D" must cross the ABI with the
/// ampersand doubled ("R&&D") to render literally. Labels without an
/// ampersand pass through uncopied; a label whose escaped form does
/// not fit the remaining pool also passes through raw, because an
/// accidental mnemonic on a pathological label beats dropping bytes.
fn escapeMenuLabelAmpersands(label: []const u8, pool: []u8, used: *usize) []const u8 {
    const ampersands = std.mem.count(u8, label, "&");
    if (ampersands == 0) return label;
    if (label.len + ampersands > pool.len - used.*) return label;
    const start = used.*;
    var out = start;
    for (label) |byte| {
        pool[out] = byte;
        out += 1;
        if (byte == '&') {
            pool[out] = '&';
            out += 1;
        }
    }
    used.* = out;
    return pool[start..out];
}

/// Translate the request's items to the C ABI shape, escaping mnemonic
/// ampersands into `label_pool` (the host copies every label before
/// returning, so a caller stack pool is safe). Pure (no host calls), so
/// the separator/disabled/label mapping is unit-testable on every build
/// host.
fn contextMenuItemsToWindows(items: []const platform_mod.ContextMenuItem, buffer: []WindowsContextMenuItem, label_pool: []u8) []const WindowsContextMenuItem {
    const count = @min(items.len, buffer.len);
    var pool_used: usize = 0;
    for (items[0..count], 0..) |item, index| {
        const label = escapeMenuLabelAmpersands(item.label, label_pool, &pool_used);
        buffer[index] = .{
            .item_id = item.id,
            .label = label.ptr,
            .label_len = label.len,
            .enabled = if (item.enabled) 1 else 0,
            .separator = if (item.separator) 1 else 0,
        };
    }
    return buffer[0..count];
}

fn showContextMenu(context: ?*anyopaque, request: platform_mod.ContextMenuRequest) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var items: [platform_mod.max_context_menu_items]WindowsContextMenuItem = undefined;
    var label_pool: [platform_mod.max_context_menu_items * 64]u8 = undefined;
    const translated = contextMenuItemsToWindows(request.items, &items, &label_pool);
    if (native_sdk_windows_show_context_menu(
        self.host,
        request.window_id,
        request.view_label.ptr,
        request.view_label.len,
        request.point.x,
        request.point.y,
        request.token,
        translated.ptr,
        translated.len,
    ) == 0) return error.WindowNotFound;
}

fn createWebView(context: ?*anyopaque, options: platform_mod.WebViewOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const frame = options.frame;
    if (native_sdk_windows_create_webview(self.host, options.window_id, options.label.ptr, options.label.len, options.url.ptr, options.url.len, frame.x, frame.y, frame.width, frame.height, options.layer, if (options.transparent) 1 else 0, if (options.bridge_enabled) 1 else 0) == 0) return error.CreateFailed;
}

fn setWebViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_set_webview_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.WebViewNotFound;
}

fn navigateWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, url: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.InvalidWebViewOptions;
    if (native_sdk_windows_navigate_webview(self.host, window_id, label.ptr, label.len, url.ptr, url.len) == 0) return error.WebViewNotFound;
}

fn setWebViewZoom(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, zoom: f64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.UnsupportedMainWebViewZoom;
    if (native_sdk_windows_set_webview_zoom(self.host, window_id, label.ptr, label.len, zoom) == 0) return error.WebViewNotFound;
}

fn setWebViewLayer(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, layer: i32) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) {
        if (std.mem.eql(u8, label, "main")) return error.UnsupportedMainWebViewLayer;
        return error.UnsupportedChildWebViews;
    }
    if (native_sdk_windows_set_webview_layer(self.host, window_id, label.ptr, label.len, layer) == 0) return error.WebViewNotFound;
}

fn closeWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (std.mem.eql(u8, label, "main")) return error.InvalidWebViewOptions;
    if (native_sdk_windows_close_webview(self.host, window_id, label.ptr, label.len) == 0) return error.WebViewNotFound;
}

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = WindowsOpenDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
        .allow_directories = if (options.allow_directories) 1 else 0,
        .allow_multiple = if (options.allow_multiple) 1 else 0,
    };
    const result = native_sdk_windows_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (result.bytes_written > buffer.len) return error.NoSpaceLeft;
    return .{ .count = result.count, .paths = buffer[0..result.bytes_written] };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = WindowsSaveDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .default_name = options.default_name.ptr,
        .default_name_len = options.default_name.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
    };
    const written = native_sdk_windows_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written > buffer.len) return error.NoSpaceLeft;
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const opts = WindowsMessageDialogOpts{
        .style = @intFromEnum(options.style),
        .title = options.title.ptr,
        .title_len = options.title.len,
        .message = options.message.ptr,
        .message_len = options.message.len,
        .informative_text = options.informative_text.ptr,
        .informative_text_len = options.informative_text.len,
        .primary_button = options.primary_button.ptr,
        .primary_button_len = options.primary_button.len,
        .secondary_button = options.secondary_button.ptr,
        .secondary_button_len = options.secondary_button.len,
        .tertiary_button = options.tertiary_button.ptr,
        .tertiary_button_len = options.tertiary_button.len,
    };
    return @enumFromInt(native_sdk_windows_show_message_dialog(self.host, &opts));
}

fn showNotification(context: ?*anyopaque, options: platform_mod.NotificationOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_show_notification(
        self.host,
        options.title.ptr,
        options.title.len,
        options.subtitle.ptr,
        options.subtitle.len,
        options.body.ptr,
        options.body.len,
        options.id.ptr,
        options.id.len,
        options.action_label.ptr,
        options.action_label.len,
        options.action_command.ptr,
        options.action_command.len,
    ) == 0) return error.UnsupportedService;
}

const max_tray_items: usize = 32;

const TrayFallbackText = struct {
    label: []const u8,
    detail: []const u8,
};

/// Project a rich row onto Win32's plain label/detail menu surface. Chart
/// captions are optional, but the accessibility label is required, so a
/// captionless chart must still remain visible instead of becoming a blank
/// disabled row.
fn trayFallbackText(item: platform_mod.TrayMenuItem) TrayFallbackText {
    if (item.metric) |metric| return .{
        .label = metric.primary_text,
        .detail = metric.secondary_text,
    };
    if (item.chart) |chart| {
        if (chart.leading_caption.len > 0) return .{
            .label = chart.leading_caption,
            .detail = chart.trailing_summary,
        };
        if (chart.trailing_summary.len > 0) return .{
            .label = chart.trailing_summary,
            .detail = "",
        };
        return .{ .label = chart.accessibility_label, .detail = "" };
    }
    return .{ .label = item.label, .detail = item.detail };
}

fn createTray(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, options: platform_mod.TrayOptions) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (status_item_id != platform_mod.primary_status_item_id) return error.UnsupportedService;
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_create_tray(
        self.host,
        options.icon_path.ptr,
        options.icon_path.len,
        options.tooltip.ptr,
        options.tooltip.len,
        options.activation_command.ptr,
        options.activation_command.len,
        options.alternate_activation_command.ptr,
        options.alternate_activation_command.len,
        options.open_command.ptr,
        options.open_command.len,
    ) == 0) return error.UnsupportedService;
    if (options.items.len > 0) {
        try updateTrayMenu(context, status_item_id, options.items);
    }
}

fn updateTrayMenu(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, items: []const platform_mod.TrayMenuItem) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (status_item_id != platform_mod.primary_status_item_id) return error.UnsupportedService;
    if (self.web_engine != .system) return error.UnsupportedService;
    var count: usize = 0;
    var ids: [max_tray_items]u32 = undefined;
    var labels: [max_tray_items][*]const u8 = undefined;
    var label_lens: [max_tray_items]usize = undefined;
    var separators: [max_tray_items]c_int = undefined;
    var enabled_flags: [max_tray_items]c_int = undefined;
    var details: [max_tray_items][*]const u8 = undefined;
    var detail_lens: [max_tray_items]usize = undefined;
    var roles: [max_tray_items]c_int = undefined;
    var keys: [max_tray_items][*]const u8 = undefined;
    var key_lens: [max_tray_items]usize = undefined;
    var modifiers: [max_tray_items]u32 = undefined;
    // Tray labels are app-supplied too, so they get the same mnemonic
    // escape as context-menu items. Detail is appended to the visible
    // Windows fallback label, so escape it too (the host copies both before
    // returning). Doubling covers the all-ampersands worst case.
    var label_pool: [max_tray_items * (platform_mod.max_tray_item_label_bytes + platform_mod.max_tray_item_detail_bytes) * 2]u8 = undefined;
    var pool_used: usize = 0;
    for (items) |item| {
        if (item.segmented) |segmented| {
            for (segmented.options) |option| {
                const label = escapeMenuLabelAmpersands(option.label, &label_pool, &pool_used);
                ids[count] = option.id;
                labels[count] = label.ptr;
                label_lens[count] = label.len;
                separators[count] = 0;
                enabled_flags[count] = if (option.enabled) 1 else 0;
                const selected_detail = if (option.selected) "Selected" else "";
                details[count] = selected_detail.ptr;
                detail_lens[count] = selected_detail.len;
                roles[count] = @intFromEnum(platform_mod.TrayItemRole.command);
                keys[count] = "".ptr;
                key_lens[count] = 0;
                modifiers[count] = 0;
                count += 1;
            }
            continue;
        }
        const fallback = trayFallbackText(item);
        const label = escapeMenuLabelAmpersands(fallback.label, &label_pool, &pool_used);
        const detail = escapeMenuLabelAmpersands(fallback.detail, &label_pool, &pool_used);
        ids[count] = item.id;
        labels[count] = label.ptr;
        label_lens[count] = label.len;
        separators[count] = if (item.separator) 1 else 0;
        // Windows has no custom status-menu row seam. Preserve semantic
        // readouts as visible detail text, while only command/agent rows can
        // become actions.
        enabled_flags[count] = if (item.enabled and (item.role == .command or item.role == .agent)) 1 else 0;
        details[count] = detail.ptr;
        detail_lens[count] = detail.len;
        roles[count] = @intFromEnum(item.role);
        keys[count] = item.key.ptr;
        key_lens[count] = item.key.len;
        modifiers[count] = shortcutModifierFlags(item.modifiers);
        count += 1;
    }
    if (native_sdk_windows_update_tray_menu(self.host, &ids, &labels, &label_lens, &separators, &enabled_flags, &details, &detail_lens, &roles, &keys, &key_lens, &modifiers, count) == 0) return error.UnsupportedService;
}

fn removeTray(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (status_item_id != platform_mod.primary_status_item_id) return error.UnsupportedService;
    if (self.web_engine != .system) return error.UnsupportedService;
    native_sdk_windows_remove_tray(self.host);
}

fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_open_external_url(self.host, url.ptr, url.len) == 0) return error.UnsupportedService;
}

fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_reveal_path(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_add_recent_document(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_windows_clear_recent_documents(self.host) == 0) return error.UnsupportedService;
}

fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const result = native_sdk_windows_set_credential(
        self.host,
        credential.service.ptr,
        credential.service.len,
        credential.account.ptr,
        credential.account.len,
        credential.secret.ptr,
        credential.secret.len,
    );
    if (result == -3) return error.AccessDenied;
    if (result == -4) return error.CredentialFieldTooLarge;
    if (result <= 0) return error.CredentialStoreFailed;
}

fn getCredential(context: ?*anyopaque, key: platform_mod.CredentialKey, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_get_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
        buffer.ptr,
        buffer.len,
    );
    if (len == std.math.maxInt(usize)) return error.CredentialNotFound;
    if (len == std.math.maxInt(usize) - 3) return error.AccessDenied;
    if (len == std.math.maxInt(usize) - 1) return error.CredentialStoreFailed;
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn deleteCredential(context: ?*anyopaque, key: platform_mod.CredentialKey) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const result = native_sdk_windows_delete_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
    );
    if (result == -3) return error.AccessDenied;
    if (result < 0) return error.CredentialStoreFailed;
    if (result == 0) return error.CredentialNotFound;
}

fn formatLocalTime(context: ?*anyopaque, timestamp_ms: i64, style: platform_mod.LocalTimeStyle, buffer: []u8) anyerror![]const u8 {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_windows_format_local_time(self.host, timestamp_ms, @intFromEnum(style), buffer.ptr, buffer.len);
    if (len == 0 or len > buffer.len) return error.LocalTimeFormatFailed;
    return buffer[0..len];
}

/// Map the audio host's synchronous load result: 0 loaded, 1 the file is
/// missing/unreadable, anything else a decode failure. The asynchronous
/// `.loaded` acknowledgment (with the decoded duration) follows as an
/// `.audio` event on the message loop.
fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_windows_audio_load(self.host, path.ptr, path.len)) {
        0 => {},
        1 => error.AudioSourceNotFound,
        else => error.AudioDecodeFailed,
    };
}

/// Map the streaming host's synchronous result: 1 a verified cache entry
/// is playing locally, 0 a progressive stream started (the `.loaded`
/// acknowledgment follows when the topology is ready), anything else the
/// URL itself was unusable. Network failures after this point are
/// asynchronous and arrive as `.audio`/`.failed` events.
fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!platform_mod.AudioLoadResolution {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_windows_audio_load_url(self.host, url.ptr, url.len, cache_path.ptr, cache_path.len, expected_bytes)) {
        0 => .stream,
        1 => .cache,
        else => error.InvalidAudioOptions,
    };
}

fn audioPlay(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_audio_play(self.host) == 0) return error.InvalidAudioOptions;
}

fn audioPause(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_pause(self.host);
}

fn audioStop(context: ?*anyopaque) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_stop(self.host);
}

fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_windows_audio_seek(self.host, position_ms) == 0) return error.InvalidAudioOptions;
}

fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_set_volume(self.host, volume);
}

fn nativeSdkAudioCapturePush(context: ?*anyopaque, kind: c_int, source_value: c_int, sample_rate: u32, channels: u8, timestamp_ns: u64, frames: u32, pcm: ?[*]const u8, pcm_len: usize) callconv(.c) c_int {
    const sink: *platform_mod.AudioCaptureSink = @ptrCast(@alignCast(context orelse return 1));
    const source: platform_mod.AudioCaptureSource = switch (source_value) {
        1 => .system,
        else => .microphone,
    };
    const event_kind: platform_mod.AudioCaptureEventKind = switch (kind) {
        0 => .started,
        1 => .data,
        else => .failed,
    };
    const bytes = if (pcm) |ptr| ptr[0..pcm_len] else "";
    return switch (sink.push(.{
        .kind = event_kind,
        .source = source,
        .format = .{ .sample_rate = sample_rate, .channels = channels },
        .timestamp_ns = timestamp_ns,
        .frames = frames,
        .pcm_s16le = bytes,
    })) {
        .accepted => 0,
        .closed => 1,
        .dropped_full => 2,
        .dropped_oversized => 3,
    };
}

fn audioCaptureStart(context: ?*anyopaque, source: platform_mod.AudioCaptureSource, format: platform_mod.AudioCaptureFormat, sink: platform_mod.AudioCaptureSink) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const stored = &self.audio_capture_sinks[@intFromEnum(source)];
    // The native stop is a synchronous callback fence. Quiesce the old
    // producer before replacing the memory its callback context points at;
    // otherwise a final old-source callback can be delivered to the new sink.
    _ = native_sdk_windows_audio_capture_stop(self.host, @intFromEnum(source));
    stored.* = sink;
    if (native_sdk_windows_audio_capture_start(self.host, @intFromEnum(source), format.sample_rate, format.channels, nativeSdkAudioCapturePush, stored) == 0) {
        stored.* = .{};
        return error.AudioCaptureStartFailed;
    }
}

fn audioCaptureStop(context: ?*anyopaque, source: platform_mod.AudioCaptureSource) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_windows_audio_capture_stop(self.host, @intFromEnum(source));
    self.audio_capture_sinks[@intFromEnum(source)] = .{};
}

/// The video tier's teaching refusal: the load verbs exist so a video
/// source fails with a NAMED explanation instead of a bare
/// unsupported-service, while the transport verbs stay null — the
/// channel never activates without a successful load. Pure (no Win32
/// externs), so the teaching is unit-testable on every host.
fn videoLoad(context: ?*anyopaque, path: []const u8, token: u64, sink: platform_mod.VideoFrameSink) anyerror!void {
    _ = context;
    _ = path;
    _ = token;
    _ = sink;
    std.debug.print("video playback is not implemented on windows yet: the Win32 host has no Media Foundation decode path into the media-surface texture channel - the app receives one failed video event (scope video sources to macos builds, or compose a media-surface with your own producer)\n", .{});
    return error.UnsupportedService;
}

/// The URL twin rides the same teaching — a stream would need the same
/// missing decode path a file does.
fn videoLoadUrl(context: ?*anyopaque, url: []const u8, token: u64, sink: platform_mod.VideoFrameSink) anyerror!void {
    return videoLoad(context, url, token, sink);
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    native_sdk_windows_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

fn configureMenus(context: ?*anyopaque, menus: []const platform_mod.Menu) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    try platform_mod.validateMenus(menus);
    if (menus.len > 0 and self.web_engine != .system) return error.UnsupportedService;

    var menu_titles: [platform_mod.max_menus][*]const u8 = undefined;
    var menu_title_lens: [platform_mod.max_menus]usize = undefined;
    var item_menu_indices: [platform_mod.max_menu_items]u32 = undefined;
    var item_labels: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_label_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_commands: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_command_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_keys: [platform_mod.max_menu_items][*]const u8 = undefined;
    var item_key_lens: [platform_mod.max_menu_items]usize = undefined;
    var item_modifiers: [platform_mod.max_menu_items]u32 = undefined;
    var item_separators: [platform_mod.max_menu_items]c_int = undefined;
    var item_enabled: [platform_mod.max_menu_items]c_int = undefined;
    var item_checked: [platform_mod.max_menu_items]c_int = undefined;

    var item_count: usize = 0;
    for (menus, 0..) |menu, menu_index| {
        menu_titles[menu_index] = menu.title.ptr;
        menu_title_lens[menu_index] = menu.title.len;
        for (menu.items) |item| {
            item_menu_indices[item_count] = @intCast(menu_index);
            item_labels[item_count] = item.label.ptr;
            item_label_lens[item_count] = item.label.len;
            item_commands[item_count] = item.command.ptr;
            item_command_lens[item_count] = item.command.len;
            item_keys[item_count] = item.key.ptr;
            item_key_lens[item_count] = item.key.len;
            item_modifiers[item_count] = shortcutModifierFlags(item.modifiers);
            item_separators[item_count] = if (item.separator) 1 else 0;
            item_enabled[item_count] = if (item.enabled) 1 else 0;
            item_checked[item_count] = if (item.checked) 1 else 0;
            item_count += 1;
        }
    }

    if (native_sdk_windows_set_menus(
        self.host,
        menu_titles[0..menus.len].ptr,
        menu_title_lens[0..menus.len].ptr,
        menus.len,
        item_menu_indices[0..item_count].ptr,
        item_labels[0..item_count].ptr,
        item_label_lens[0..item_count].ptr,
        item_commands[0..item_count].ptr,
        item_command_lens[0..item_count].ptr,
        item_keys[0..item_count].ptr,
        item_key_lens[0..item_count].ptr,
        item_modifiers[0..item_count].ptr,
        item_separators[0..item_count].ptr,
        item_enabled[0..item_count].ptr,
        item_checked[0..item_count].ptr,
        item_count,
    ) == 0) return error.UnsupportedWindowTransparency;
    self.menus_active = menus.len > 0;
}

fn configureShortcuts(context: ?*anyopaque, shortcuts: []const platform_mod.Shortcut) anyerror!void {
    const self: *WindowsPlatform = @ptrCast(@alignCast(context.?));
    if (shortcuts.len > platform_mod.max_shortcuts) return error.InvalidShortcut;
    var ids: [platform_mod.max_shortcuts][*]const u8 = undefined;
    var id_lens: [platform_mod.max_shortcuts]usize = undefined;
    var keys: [platform_mod.max_shortcuts][*]const u8 = undefined;
    var key_lens: [platform_mod.max_shortcuts]usize = undefined;
    var modifiers: [platform_mod.max_shortcuts]u32 = undefined;
    for (shortcuts, 0..) |shortcut, index| {
        try platform_mod.validateShortcut(shortcut);
        ids[index] = shortcut.id.ptr;
        id_lens[index] = shortcut.id.len;
        keys[index] = shortcut.key.ptr;
        key_lens[index] = shortcut.key.len;
        modifiers[index] = shortcutModifierFlags(shortcut.modifiers);
    }
    native_sdk_windows_set_shortcuts(self.host, ids[0..shortcuts.len].ptr, id_lens[0..shortcuts.len].ptr, keys[0..shortcuts.len].ptr, key_lens[0..shortcuts.len].ptr, modifiers[0..shortcuts.len].ptr, shortcuts.len);
}

fn shortcutModifierFlags(modifiers: platform_mod.ShortcutModifiers) u32 {
    var flags: u32 = 0;
    if (modifiers.primary) flags |= shortcut_modifier_primary;
    if (modifiers.command) flags |= shortcut_modifier_command;
    if (modifiers.control) flags |= shortcut_modifier_control;
    if (modifiers.option) flags |= shortcut_modifier_option;
    if (modifiers.shift) flags |= shortcut_modifier_shift;
    return flags;
}

fn shortcutModifiersFromFlags(flags: u32) platform_mod.ShortcutModifiers {
    return .{
        .primary = (flags & shortcut_modifier_primary) != 0,
        .command = (flags & shortcut_modifier_command) != 0,
        .control = (flags & shortcut_modifier_control) != 0,
        .option = (flags & shortcut_modifier_option) != 0,
        .shift = (flags & shortcut_modifier_shift) != 0,
    };
}

fn isSupportedNativeViewKind(kind: platform_mod.ViewKind) bool {
    return switch (kind) {
        .toolbar,
        .titlebar_accessory,
        .sidebar,
        .statusbar,
        .split,
        .stack,
        .button,
        .icon_button,
        .list_item,
        .checkbox,
        .toggle,
        .segmented_control,
        .text_field,
        .search_field,
        .label,
        .spacer,
        .progress_indicator,
        .gpu_surface,
        => true,
        .webview,
        => false,
    };
}

test "windows supports native container and control kinds" {
    try std.testing.expect(isSupportedNativeViewKind(.split));
    try std.testing.expect(isSupportedNativeViewKind(.stack));
    try std.testing.expect(isSupportedNativeViewKind(.icon_button));
    try std.testing.expect(isSupportedNativeViewKind(.list_item));
    try std.testing.expect(isSupportedNativeViewKind(.gpu_surface));
}

test "windows GPU frame maps Direct2D recovery to a full repaint" {
    const label = "canvas";
    var event = std.mem.zeroes(WindowsEvent);
    event.window_id = 7;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.width = 640;
    event.height = 360;
    event.scale = 2;
    event.gpu_backend = 1;
    event.force_full_repaint = 1;

    const frame = gpuSurfaceFrameEventFromWindowsEvent(&event);
    try std.testing.expectEqual(@as(platform_mod.WindowId, 7), frame.window_id);
    try std.testing.expectEqualStrings(label, frame.label);
    try std.testing.expectEqual(platform_mod.GpuSurfaceBackend.direct2d, frame.backend);
    try std.testing.expect(frame.canvas_frame_full_repaint);
}

test "windows gpu surface input preserves key and text" {
    const label = "canvas";
    const key = "enter";
    const text = "\n";
    var event = std.mem.zeroes(WindowsEvent);
    event.window_id = 7;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.input_kind = 5;
    event.timestamp_ns = 123_000_000;
    event.x = 12;
    event.y = 18;
    event.button = 1;
    event.delta_x = -2;
    event.delta_y = 4;
    event.key_text = key.ptr;
    event.key_text_len = key.len;
    event.input_text = text.ptr;
    event.input_text_len = text.len;
    event.shortcut_modifiers = shortcut_modifier_primary | shortcut_modifier_shift;

    const input = gpuSurfaceInputEventFromWindowsEvent(&event);
    try std.testing.expectEqual(@as(platform_mod.WindowId, 7), input.window_id);
    try std.testing.expectEqualStrings("canvas", input.label);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.key_down, input.kind);
    try std.testing.expectEqual(@as(u64, 123_000_000), input.timestamp_ns);
    try std.testing.expectEqual(@as(f32, 12), input.x);
    try std.testing.expectEqual(@as(f32, 18), input.y);
    try std.testing.expectEqual(@as(i32, 1), input.button);
    try std.testing.expectEqual(@as(f32, -2), input.delta_x);
    try std.testing.expectEqual(@as(f32, 4), input.delta_y);
    try std.testing.expectEqualStrings("enter", input.key);
    try std.testing.expectEqualStrings("\n", input.text);
    try std.testing.expect(input.modifiers.primary);
    try std.testing.expect(input.modifiers.shift);
}

test "windows context menu items translate separators, disabled flags, and labels" {
    const items = [_]platform_mod.ContextMenuItem{
        .{ .id = 1, .label = "Complete" },
        .{ .separator = true },
        .{ .id = 3, .label = "Delete", .enabled = false },
        .{ .id = 4, .label = "Move to R&D" },
    };
    var buffer: [platform_mod.max_context_menu_items]WindowsContextMenuItem = undefined;
    var label_pool: [platform_mod.max_context_menu_items * 64]u8 = undefined;
    const translated = contextMenuItemsToWindows(&items, &buffer, &label_pool);
    try std.testing.expectEqual(@as(usize, 4), translated.len);
    try std.testing.expectEqual(@as(u32, 1), translated[0].item_id);
    try std.testing.expectEqualStrings("Complete", translated[0].label[0..translated[0].label_len]);
    try std.testing.expectEqual(@as(c_int, 1), translated[0].enabled);
    try std.testing.expectEqual(@as(c_int, 0), translated[0].separator);
    try std.testing.expectEqual(@as(c_int, 1), translated[1].separator);
    try std.testing.expectEqual(@as(u32, 3), translated[2].item_id);
    try std.testing.expectEqual(@as(c_int, 0), translated[2].enabled);
    // A literal `&` doubles on the way to AppendMenuW so Win32 renders
    // it instead of eating it as a mnemonic marker; ampersand-free
    // labels pass through pointing at the caller's bytes.
    try std.testing.expectEqualStrings("Move to R&&D", translated[3].label[0..translated[3].label_len]);
    try std.testing.expectEqual(items[0].label.ptr, translated[0].label);
}

test "windows menu label escape passes a label through raw when the pool cannot hold it" {
    var pool: [4]u8 = undefined;
    var used: usize = 0;
    const label = "R&D";
    // Escaped form needs 4 bytes and fits exactly.
    try std.testing.expectEqualStrings("R&&D", escapeMenuLabelAmpersands(label, &pool, &used));
    // The pool is spent: the next ampersand label rides unescaped
    // (accidental mnemonic) rather than truncated.
    const passed_through = escapeMenuLabelAmpersands(label, &pool, &used);
    try std.testing.expectEqualStrings("R&D", passed_through);
    try std.testing.expectEqual(label.ptr, passed_through.ptr);
}

test "windows context menu action event maps token and item id" {
    const label = "canvas";
    var event = std.mem.zeroes(WindowsEvent);
    event.kind = .context_menu_action;
    event.window_id = 7;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.widget_id = 42;
    event.menu_item_id = 3;

    const action = contextMenuActionEventFromWindowsEvent(&event);
    try std.testing.expectEqual(@as(platform_mod.WindowId, 7), action.window_id);
    try std.testing.expectEqualStrings("canvas", action.view_label);
    try std.testing.expectEqual(@as(u64, 42), action.token);
    try std.testing.expectEqual(@as(u32, 3), action.item_id);
}

test "windows gpu surface input maps pointer cancel" {
    var event = std.mem.zeroes(WindowsEvent);
    event.input_kind = 11;
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pointer_cancel, gpuSurfaceInputEventFromWindowsEvent(&event).kind);
}

test "windows gpu surface input maps ime text and composition events" {
    // A GCS_COMPSTR preedit update: kind 8 carries the full preedit text
    // plus a UTF-8 byte cursor (the host converts GCS_CURSORPOS UTF-16
    // units into bytes before emitting).
    const preedit = "\xe3\x81\x8b\xe3\x82\x99"; // "か" + combining voiced mark
    var set_event = std.mem.zeroes(WindowsEvent);
    set_event.input_kind = 8;
    set_event.input_text = preedit.ptr;
    set_event.input_text_len = preedit.len;
    set_event.has_composition_cursor = 1;
    set_event.composition_cursor = 3;
    const set_input = gpuSurfaceInputEventFromWindowsEvent(&set_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_set_composition, set_input.kind);
    try std.testing.expectEqualStrings(preedit, set_input.text);
    try std.testing.expectEqual(@as(?usize, 3), set_input.composition_cursor);

    // A GCS_RESULTSTR commit that differs from the preedit arrives as a
    // plain text_input with no cursor (the cancel travelled separately).
    var text_event = std.mem.zeroes(WindowsEvent);
    text_event.input_kind = 7;
    const committed = "が";
    text_event.input_text = committed.ptr;
    text_event.input_text_len = committed.len;
    const text_input = gpuSurfaceInputEventFromWindowsEvent(&text_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.text_input, text_input.kind);
    try std.testing.expectEqualStrings(committed, text_input.text);
    try std.testing.expectEqual(@as(?usize, null), text_input.composition_cursor);

    // Commit-of-preedit and cancel are empty-text notifications: the
    // runtime already buffers the composition text.
    var commit_event = std.mem.zeroes(WindowsEvent);
    commit_event.input_kind = 9;
    const commit_input = gpuSurfaceInputEventFromWindowsEvent(&commit_event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_commit_composition, commit_input.kind);
    try std.testing.expectEqual(@as(usize, 0), commit_input.text.len);
    try std.testing.expectEqual(@as(?usize, null), commit_input.composition_cursor);

    var cancel_event = std.mem.zeroes(WindowsEvent);
    cancel_event.input_kind = 10;
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_cancel_composition, gpuSurfaceInputEventFromWindowsEvent(&cancel_event).kind);
}

test "windows chromium reports unsupported native surfaces" {
    var system = testPlatformWithEngine(.system);
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .main_webview));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .child_webviews));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .native_views));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .native_control_commands));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .menus));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .gpu_surfaces));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .audio_playback));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .audio_streaming));
    try std.testing.expect(WindowsPlatform.supportsFeature(&system, .context_menus));

    var chromium = testPlatformWithEngine(.chromium);
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .main_webview));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .child_webviews));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .native_views));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .native_control_commands));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .menus));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .shortcuts));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .gpu_surfaces));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .audio_playback));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .audio_streaming));
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .context_menus));
}

test "windows hide-on-close support requires the declared tray (the only re-show affordance)" {
    // A system-engine host with a declared tray keeps hide-on-close.
    var with_tray = testPlatformWithEngine(.system);
    with_tray.app_info.declares_tray = true;
    try std.testing.expect(WindowsPlatform.supportsFeature(&with_tray, .window_hide_on_close));
    // Without the declaration the answer is an honest false: SW_HIDE
    // removes the taskbar entry and windows has no dock-reopen path, so
    // the runtime's create-time gates must refuse a `.hide` declaration
    // instead of stranding a hidden window nothing could re-show.
    var without_tray = testPlatformWithEngine(.system);
    try std.testing.expect(!WindowsPlatform.supportsFeature(&without_tray, .window_hide_on_close));
    // The chromium engine answers false regardless, tray or not.
    var chromium = testPlatformWithEngine(.chromium);
    chromium.app_info.declares_tray = true;
    try std.testing.expect(!WindowsPlatform.supportsFeature(&chromium, .window_hide_on_close));
}

test "windows local time conversion applies the timestamp's dynamic daylight rules" {
    // The Win32 host cannot execute in this portable suite, so pin the API
    // sequence Microsoft requires: first expose the UTC SYSTEMTIME, then let
    // the active dynamic time zone select the offset for that instant. Using
    // FileTimeToLocalFileTime here would instead apply the current DST bias.
    const host_source = @embedFile("webview2_host.cpp");
    const format_at = std.mem.indexOf(u8, host_source, "size_t native_sdk_windows_format_local_time(") orelse return error.TestExpectedEqual;
    const format_tail = host_source[format_at..];
    const format_end = std.mem.indexOf(u8, format_tail, "size_t native_sdk_windows_clipboard_read(") orelse return error.TestExpectedEqual;
    const format_source = format_tail[0..format_end];
    const utc_at = std.mem.indexOf(u8, format_source, "FileTimeToSystemTime(&utc, &utc_system_time)") orelse return error.TestExpectedEqual;
    const local_at = std.mem.indexOf(u8, format_source, "SystemTimeToTzSpecificLocalTimeEx(nullptr, &utc_system_time, &system_time)") orelse return error.TestExpectedEqual;
    try std.testing.expect(utc_at < local_at);
    try std.testing.expect(std.mem.indexOf(u8, format_source, "FileTimeToLocalFileTime") == null);
}

test "windows tray carries lifecycle commands rich rows and key equivalents into the host" {
    // These are native Win32 behaviors, so the portable suite pins the
    // compiled host seam. Windows packaging builds cross-compile the same
    // source and catch signature/type drift.
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "host->tray_activation_command = slice(activation_command, activation_command_len);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "emitStatusCommand(host, hwnd, host->tray_alternate_activation_command);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "emitStatusCommand(host, hwnd, host->tray_activation_command);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "emitStatusCommand(host, hwnd, host->tray_open_command);") != null);
    const emit_at = std.mem.indexOf(u8, host_source, "static bool emitStatusCommand(") orelse return error.TestExpectedEqual;
    const emit_tail = host_source[emit_at..];
    const emit_end = std.mem.indexOf(u8, emit_tail, "static void showTrayMenu(") orelse return error.TestExpectedEqual;
    const emit_source = emit_tail[0..emit_end];
    try std.testing.expect(std.mem.indexOf(u8, emit_source, "event.kind = kTrayCommand;") != null);
    try std.testing.expect(std.mem.indexOf(u8, emit_source, "event.kind = kMenuCommand;") == null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "item.detail = slice(details[index], detail_lens[index]);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "item.key = lowerAscii(slice(keys[index], key_lens[index]));") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "item.modifiers = modifiers[index];") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "display_label += shortcutSuffix(item.key, item.modifiers);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "const std::vector<TrayItem> displayed_items = host->tray_items;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "emitTrayActionForCommandId(host, displayed_items, command_id);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "return emitTrayActionForCommandId(host, host->tray_items, item.command_id);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "tray_event == NIN_SELECT || tray_event == NIN_KEYSELECT || tray_event == WM_LBUTTONUP") != null);
}

test "windows chart fallback uses accessibility text when captions are absent" {
    const values = [_]f32{0.5};
    const fallback = trayFallbackText(.{
        .role = .chart,
        .chart = .{
            .values = &values,
            .accessibility_label = "CPU history, 50 percent",
        },
    });
    try std.testing.expectEqualStrings("CPU history, 50 percent", fallback.label);
    try std.testing.expectEqualStrings("", fallback.detail);

    const summarized = trayFallbackText(.{
        .role = .chart,
        .chart = .{
            .values = &values,
            .trailing_summary = "50%",
            .accessibility_label = "CPU history, 50 percent",
        },
    });
    try std.testing.expectEqualStrings("50%", summarized.label);
    try std.testing.expectEqualStrings("", summarized.detail);
}

test "windows refuses a tray-less .hide main window at platform init instead of stranding it hidden" {
    // The pre-created MAIN window never passes through the runtime's
    // create gate, so the platform's init gate must hold the same line
    // (the GTK host's init refusal is the unconditional twin).
    const hide_no_tray: platform_mod.AppInfo = .{ .app_name = "player", .main_window = .{ .close_policy = .hide } };
    try std.testing.expectError(error.UnsupportedWindowClosePolicy, refuseUnsupportedMainWindowClosePolicy(hide_no_tray));
    // The declared tray is the re-show affordance: with it, the same
    // declaration passes.
    const hide_with_tray: platform_mod.AppInfo = .{ .app_name = "player", .declares_tray = true, .main_window = .{ .close_policy = .hide } };
    try refuseUnsupportedMainWindowClosePolicy(hide_with_tray);
    // The default (.quit) never consults the tray.
    const quit_app: platform_mod.AppInfo = .{ .app_name = "player" };
    try refuseUnsupportedMainWindowClosePolicy(quit_app);
}

test "windows WM_CLOSE hide consults the live tray state and downgrades to a real close without it" {
    // The downgrade branch is C++ this test suite cannot execute, so
    // this pins the tray-alive consult and the loud downgrade line
    // textually: a refactor that drops either fails here. Compilation
    // is covered by the cross-target syntax checks the packaging path
    // runs; live close behavior stays windows-host territory.
    const host_source = @embedFile("webview2_host.cpp");
    const close_at = std.mem.indexOf(u8, host_source, "case WM_CLOSE:");
    try std.testing.expect(close_at != null);
    const close_hook = host_source[close_at.?..];
    const consult_at = std.mem.indexOf(u8, close_hook, "if (!host->tray_active)");
    const hide_at = std.mem.indexOf(u8, close_hook, "ShowWindow(hwnd, SW_HIDE);");
    try std.testing.expect(consult_at != null);
    try std.testing.expect(hide_at != null);
    // The consult sits INSIDE the close hook, BEFORE the hide.
    try std.testing.expect(consult_at.? < hide_at.?);
    try std.testing.expect(std.mem.indexOf(u8, close_hook, "downgraded to a real close") != null);
}

test "windows passive show never foregrounds or focuses the window" {
    const host_source = @embedFile("webview2_host.cpp");
    const show_at = std.mem.indexOf(u8, host_source, "int native_sdk_windows_show_window(") orelse return error.TestExpectedEqual;
    const tail = host_source[show_at..];
    const next_at = std.mem.indexOf(u8, tail, "int native_sdk_windows_set_window_close_policy(") orelse return error.TestExpectedEqual;
    const show_fn = tail[0..next_at];
    const passive_at = std.mem.indexOf(u8, show_fn, "ShowWindow(found->second.hwnd, SW_SHOWNOACTIVATE);") orelse return error.TestExpectedEqual;
    const focused_at = std.mem.indexOf(u8, show_fn, "SetFocus(found->second.hwnd);") orelse return error.TestExpectedEqual;
    const active_branch_end = std.mem.indexOfPos(u8, show_fn, focused_at, "} else {") orelse return error.TestExpectedEqual;
    try std.testing.expect(focused_at < active_branch_end);
    try std.testing.expect(std.mem.indexOfPos(u8, show_fn, passive_at, "SetForegroundWindow(") == null);
    try std.testing.expect(std.mem.indexOfPos(u8, show_fn, passive_at, "SetFocus(") == null);

    // Passive is a SHOW policy, not a permanent interaction policy:
    // WS_EX_NOACTIVATE would also suppress activation on a later user
    // click, making an interactive passive overlay impossible to focus.
    const style_at = std.mem.indexOf(u8, host_source, "static DWORD windowExtendedStyle(") orelse return error.TestExpectedEqual;
    const style_tail = host_source[style_at..];
    const style_end = std.mem.indexOf(u8, style_tail, "static bool createNativeWindow(") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOf(u8, style_tail[0..style_end], "WS_EX_NOACTIVATE") == null);
}

test "windows passive canvas creation does not focus its child hwnd" {
    const host_source = @embedFile("webview2_host.cpp");
    const create_at = std.mem.indexOf(u8, host_source, "int native_sdk_windows_create_view(") orelse return error.TestExpectedEqual;
    const tail = host_source[create_at..];
    const next_at = std.mem.indexOf(u8, tail, "int native_sdk_windows_request_gpu_surface_frame(") orelse return error.TestExpectedEqual;
    const create_fn = tail[0..next_at];
    try std.testing.expect(std.mem.indexOf(
        u8,
        create_fn,
        "if (window->second.activate_on_show) SetFocus(hwnd);",
    ) != null);
}

test "windows software GPU backend request stays on the pixel presenter" {
    try std.testing.expectEqual(@as(c_int, 0), gpuSurfaceBackendRequestInt(.metal));
    try std.testing.expectEqual(@as(c_int, 1), gpuSurfaceBackendRequestInt(.software));

    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "view.gpu_backend_request != kGpuBackendRequestSoftware",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (view.gpu_backend_request == kGpuBackendRequestSoftware) return 0;",
    ) != null);
}

test "windows unavailable image uploader negotiates pixel fallback" {
    try gpuSurfaceImageUploadResult(1);
    try std.testing.expectError(error.UnsupportedService, gpuSurfaceImageUploadResult(0));
    try std.testing.expectError(error.InvalidGpuSurfaceImage, gpuSurfaceImageUploadResult(-1));

    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (!host->gpu_renderer) return 0;",
    ) != null);
}

test "windows packet renderer requires deterministic font and caption seams" {
    try std.testing.expectEqual(@as(u64, 37), try gpuSurfaceFontRegistrationResult(1, 37));
    try std.testing.expectError(error.UnsupportedService, gpuSurfaceFontRegistrationResult(0, 0));
    try std.testing.expectError(error.InvalidGpuSurfaceFont, gpuSurfaceFontRegistrationResult(-1, 0));

    const renderer_source = @embedFile("gpu_surface_renderer.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "fallback_builder->CreateFontFallback(&font_fallback_)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "layout2->SetFontFallback(renderer_->fontFallback())",
    ) != null);
    // The caption sample reads one real backing pixel. It used to do that
    // through GDI interop, which forced the whole backing surface to be
    // D2D1_COMPATIBLE_RENDER_TARGET_OPTIONS_GDI_COMPATIBLE; a device-context
    // target cannot carry that flag, so the read is a CPU-readable staging
    // bitmap now. What this pins is the property that mattered — an actual
    // pixel read, not the retained-command estimate.
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "D2D1_BITMAP_OPTIONS_CPU_READ | D2D1_BITMAP_OPTIONS_CANNOT_DRAW",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "readback_bitmap_->Map(D2D1_MAP_OPTIONS_READ, &mapped)",
    ) != null);

    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (id == 1 || id == 2) host->gpu_renderer.reset();",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "view.gpu_surface->readColorAt(sample_x, sample_y, &packed)",
    ) != null);
}

test "windows packet renderer preserves text baselines and disjoint dirty regions" {
    const renderer_source = @embedFile("gpu_surface_renderer.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "draw_line(text.text, text.origin.x, text.origin.y)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "ctx()->DrawGlyphRun(\n                    D2D1::Point2F(glyph.x, glyph.baseline)",
    ) != null);

    const draw_list_at = std.mem.indexOf(
        u8,
        renderer_source,
        "bool drawCommandList(const std::vector<const Command *> &commands",
    ) orelse return error.TestExpectedEqual;
    const draw_list = renderer_source[draw_list_at..];
    const blur_target_at = std.mem.indexOf(
        u8,
        draw_list,
        "const Rect target = blurTarget(*command, outer_clip);",
    ) orelse return error.TestExpectedEqual;
    const segment_end_at = std.mem.indexOf(
        u8,
        draw_list,
        "const HRESULT segment = ctx()->EndDraw();",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expect(blur_target_at < segment_end_at);

    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "gpuSurfaceUpdateRegionRects(\n                hwnd, paint_rects, kGpuPaintRegionRectCap)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "view->gpu_surface->paint(paint_rects, paint_rect_count)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "InvalidateRect(view.hwnd, &info.dirty_rects[index], FALSE)",
    ) != null);
}

test "windows flip-model presentation keeps its two correctness rules" {
    const renderer_source = @embedFile("gpu_surface_renderer.cpp");

    // Rule 1: FLIP_SEQUENTIAL, never FLIP_DISCARD. The renderer's
    // incremental path repaints only damaged regions and copies the rest
    // forward, so a back buffer whose undamaged content DXGI is free to
    // discard would corrupt every patch frame — intermittently, and only
    // on real hardware, which is the worst way to find out.
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;",
    ) != null);
    // The full constant, not the bare word: prose explaining why DISCARD is
    // wrong is exactly what a comment should say, and matching on "FLIP_DISCARD"
    // would fail on it. (The GDI pin this replaced had the mirror-image bug —
    // it kept passing on a comment after the code was gone.)
    try std.testing.expect(std.mem.indexOf(u8, renderer_source, "DXGI_SWAP_EFFECT_FLIP_DISCARD") == null);

    // Rule 2: a partial copy refreshes THIS paint's damage plus the
    // PREVIOUS paint's. With BufferCount = 2 the buffer being drawn was
    // presented two frames ago, so copying only the current damage leaves
    // a stale alternating image outside it. Both loops must be there.
    const copy_at = std.mem.indexOf(
        u8,
        renderer_source,
        "for (const RECT &region : damage) copy_region(region);",
    ) orelse return error.TestExpectedEqual;
    const carry_at = std.mem.indexOf(
        u8,
        renderer_source,
        "for (const RECT &region : swap_last_damage_) copy_region(region);",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expect(copy_at < carry_at);

    // ...and the dirty rects handed to Present1 are this paint's damage
    // alone, because they describe the delta against the previously
    // PRESENTED frame, which is a different set from the copied union.
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "parameters.pDirtyRects = damage.data();",
    ) != null);
}

test "windows swap buffers are allocated on a grid and cropped, never source-sized" {
    const renderer_source = @embedFile("gpu_surface_renderer.cpp");

    // The allocation is rounded up; the CLIENT size is what reaches the
    // screen. Creating at the client size instead would put a
    // ResizeBuffers back into every step of a resize drag, which is the
    // whole cost this removes.
    try std.testing.expect(std.mem.indexOf(u8, renderer_source, "desc.Width = swapAllocExtent(width);") != null);

    // What makes the over-allocation legal is SCALING_NONE's CLIP, and
    // nothing else. `IDXGISwapChain2::SetSourceSize` is the interface DXGI
    // documents for this exact job and it must stay out: paired with
    // SCALING_NONE it renders a surface whose buffer is much taller than
    // its window — a 38 px header rounded up to a 128 px buffer — as a
    // fragment at the top-left on a field of background colour, and it
    // measured as worth nothing (0.428 ms against 0.426 ms per resize
    // step). Match the call, not the type name, so the paragraph above
    // explaining why it is absent does not satisfy its own pin.
    try std.testing.expect(std.mem.indexOf(u8, renderer_source, "SetSourceSize(") == null);

    // Damage is measured against the presented region, never the
    // allocation: an over-allocated buffer is larger than the window, and
    // a dirty rect outside the source region is not a valid dirty rect.
    // A clamp against the bitmap's own pixel size would look right and be
    // wrong by exactly the rounding.
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "clamped.right = std::min<LONG>(static_cast<LONG>(source_width_), clamped.right);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "backing_pixels.width == source_width_ && backing_pixels.height == source_height_",
    ) != null);

    // SetBackgroundColor is documented to apply only to DXGI_SCALING_NONE
    // in windowed mode, so the fill that keeps a growing drag from
    // flashing depends on that scaling mode staying put.
    try std.testing.expect(std.mem.indexOf(u8, renderer_source, "desc.Scaling = DXGI_SCALING_NONE;") != null);
    try std.testing.expect(std.mem.indexOf(u8, renderer_source, "swap_chain_->SetBackgroundColor(&background)") != null);
}

test "windows packet renderer keeps square rectangle stroke joins" {
    const renderer_source = @embedFile("gpu_surface_renderer.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "style.lineJoin = D2D1_LINE_JOIN_MITER;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        renderer_source,
        "command.shape.kind == Shape::Kind::stroke_rect\n                ? rect_stroke_",
    ) != null);
}

test "windows click-through uses a layered surface even when visually opaque" {
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window.transparent || window.click_through) style |= WS_EX_LAYERED;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window.click_through && !window.transparent &&\n        !SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA))",
    ) != null);
}

test "windows transparent windows compose canvas siblings and reject unredirectable children" {
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "static bool presentTransparentWindow(Host *host, Window &window)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "std::sort(surfaces.begin(), surfaces.end()",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "compositePremultipliedChannel(128, 128, 64) == 160",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window->second.transparent && kind != kViewGpuSurface) return 0;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window->second.transparent) return 0;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window->second.transparent) return -1;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (window.transparent && (!windowIsChromeless(window) || !host->menus.empty())) return false;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (menu_count > 0) {\n        for (const auto &entry : host->windows) {\n            if (entry.second.transparent) return 0;",
    ) != null);
}

test "windows transparent resize frame remains hit-testable without filling the client" {
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "static constexpr uint8_t kTransparentResizeHitAlpha = 1;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "outsideTransparentClientBounds(6, 100, 7, 7, 713, 513)",
    ) != null);
    const present_at = std.mem.indexOf(
        u8,
        host_source,
        "static bool presentTransparentWindow(Host *host, Window &window)",
    ) orelse return error.TestExpectedEqual;
    const present = host_source[present_at..];
    const seed_at = std.mem.indexOf(
        u8,
        present,
        "if (window.resizable) {\n        seedTransparentResizeHitFrame(",
    ) orelse return error.TestExpectedEqual;
    const surfaces_at = std.mem.indexOf(
        u8,
        present,
        "std::vector<NativeView *> surfaces;",
    ) orelse return error.TestExpectedEqual;
    try std.testing.expect(seed_at < surfaces_at);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present,
        "if (input_window && input_window->click_through && message == WM_NCHITTEST) return HTTRANSPARENT;",
    ) != null);
}

test "windows transparent windows require chromeless chrome and no menus" {
    try refuseUnsupportedTransparentWindow(.{
        .titlebar = .chromeless,
        .transparent = true,
    }, false);
    try std.testing.expectError(error.UnsupportedWindowTransparency, refuseUnsupportedTransparentWindow(.{
        .titlebar = .standard,
        .transparent = true,
    }, false));
    try std.testing.expectError(error.UnsupportedWindowTransparency, refuseUnsupportedTransparentWindow(.{
        .titlebar = .hidden_inset,
        .transparent = true,
    }, false));
    try std.testing.expectError(error.UnsupportedWindowTransparency, refuseUnsupportedTransparentWindow(.{
        .titlebar = .chromeless,
        .transparent = true,
    }, true));
    // The constraint is only about per-pixel alpha: ordinary menu
    // windows keep every titlebar style.
    try refuseUnsupportedTransparentWindow(.{}, true);
}

test "windows first-present windows have a fallback reveal deadline" {
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "constexpr ULONGLONG kDeferredShowDeadlineMs = 1000;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "showDeferredWindowIfDeadlinePassed(entry.second);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "window.deferred_show_started_ms = window.show_on_first_present ? GetTickCount64() : 0;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (!window.hwnd || window.shown || window.policy_hidden) return;",
    ) != null);
}

test "windows busy message loop drains due gpu frames outside input callbacks" {
    // The waitable timer is the precise idle wake source, but queued input
    // may win the message-loop race. Pin the complementary post-dispatch
    // drain: it must run only after DispatchMessage returns (outside the
    // runtime callback that requested the frame) while the host is still
    // running. The helper must retire the one-shot before emitting so
    // synchronous presentation can re-arm it, and abort if that callback
    // stops the host so no later due surface receives a post-shutdown event.
    const host_source = @embedFile("webview2_host.cpp");
    const run_at = std.mem.indexOf(u8, host_source, "void native_sdk_windows_run(") orelse return error.TestExpectedEqual;
    const run_tail = host_source[run_at..];
    const dispatch_at = std.mem.indexOf(u8, run_tail, "DispatchMessageW(&message);") orelse return error.TestExpectedEqual;
    const post_dispatch = run_tail[dispatch_at..];
    try std.testing.expect(std.mem.indexOf(u8, post_dispatch, "if (host->running) gpuSurfaceDrainDueFrameEmissions(host);") != null);

    const helper_at = std.mem.indexOf(u8, host_source, "static void gpuSurfaceDrainDueFrameEmissions(Host *host)") orelse return error.TestExpectedEqual;
    const helper_tail = host_source[helper_at..];
    const helper_end = std.mem.indexOf(u8, helper_tail, "static void paintGpuSurface(") orelse return error.TestExpectedEqual;
    const helper = helper_tail[0..helper_end];
    try std.testing.expect(std.mem.indexOf(u8, helper, "if (!host || !host->running) return;") != null);
    const loop_at = std.mem.indexOf(u8, helper, "for (const std::string &key : due_keys)") orelse return error.TestExpectedEqual;
    const loop = helper[loop_at..];
    const before_emit_guard_at = std.mem.indexOf(u8, loop, "if (!host->running) return;") orelse return error.TestExpectedEqual;
    const kill_at = std.mem.indexOf(u8, helper, "KillTimer(hwnd, kGpuEmitTimerId);") orelse return error.TestExpectedEqual;
    const clear_at = std.mem.indexOf(u8, helper, "view.gpu_emission_scheduled = false;") orelse return error.TestExpectedEqual;
    const emit_at = std.mem.indexOf(u8, helper, "gpuSurfaceEmitFrame(host, view, hwnd);") orelse return error.TestExpectedEqual;
    const after_emit = helper[emit_at + "gpuSurfaceEmitFrame(host, view, hwnd);".len ..];
    try std.testing.expect(std.mem.indexOf(u8, after_emit, "if (!host->running) return;") != null);
    try std.testing.expect(loop_at + before_emit_guard_at < emit_at);
    try std.testing.expect(kill_at < clear_at);
    try std.testing.expect(clear_at < emit_at);
}

test "windows gpu frame deadlines use a high resolution waitable timer" {
    // A nominal 16.67 ms SetTimer is commonly rounded to the legacy timer
    // grid. Pin the host's precise path: one process-owned high-resolution
    // waitable timer follows the earliest scheduled surface, participates in
    // the message loop, refreshes after an emission, and closes at teardown.
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "CREATE_WAITABLE_TIMER_HIGH_RESOLUTION") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "SetWaitableTimer(host->gpu_frame_wake_timer") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "MsgWaitForMultipleObjectsEx(") != null);

    const schedule_at = std.mem.indexOf(u8, host_source, "static void gpuSurfaceScheduleFrameEmission(Host *host, NativeView &view)") orelse return error.TestExpectedEqual;
    const schedule_tail = host_source[schedule_at..];
    const schedule_end = std.mem.indexOf(u8, schedule_tail, "static void gpuSurfaceDrainDueFrameEmissions(") orelse return error.TestExpectedEqual;
    const schedule = schedule_tail[0..schedule_end];
    const scheduled_at = std.mem.indexOf(u8, schedule, "view.gpu_emission_scheduled = true;") orelse return error.TestExpectedEqual;
    const wake_at = std.mem.indexOf(u8, schedule, "gpuSurfaceRefreshFrameWakeTimer(host);") orelse return error.TestExpectedEqual;
    try std.testing.expect(scheduled_at < wake_at);

    const timer_at = std.mem.indexOf(u8, host_source, "if (wparam == kGpuEmitTimerId)") orelse return error.TestExpectedEqual;
    const timer_tail = host_source[timer_at..];
    const emit_at = std.mem.indexOf(u8, timer_tail, "gpuSurfaceEmitFrame(host, *view, hwnd);") orelse return error.TestExpectedEqual;
    const refresh_at = std.mem.indexOf(u8, timer_tail, "gpuSurfaceRefreshFrameWakeTimer(host);") orelse return error.TestExpectedEqual;
    try std.testing.expect(emit_at < refresh_at);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "gpuSurfaceDestroyFrameWakeTimer(host);") != null);
}

test "windows window focus includes focused native child views" {
    // This predicate lives in the C++ host, where the real HWND tree is
    // available. Pin the two parts of its contract textually: focus is
    // resolved through GA_ROOT, and every emitted window frame uses
    // that shared answer. Cross-target host builds compile the code;
    // the Windows canvas smoke supplies the live child-focus exercise.
    const host_source = @embedFile("webview2_host.cpp");
    const predicate_at = std.mem.indexOf(u8, host_source, "static bool windowOwnsKeyboardFocus(const Window &window)");
    try std.testing.expect(predicate_at != null);
    const predicate = host_source[predicate_at.?..];
    try std.testing.expect(std.mem.indexOf(u8, predicate, "GetAncestor(focused, GA_ROOT) == window.hwnd") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "event.focused = windowOwnsKeyboardFocus(window);") != null);
    const focus_edge_at = std.mem.indexOf(u8, host_source, "case WM_SETFOCUS:");
    try std.testing.expect(focus_edge_at != null);
    const focus_edge = host_source[focus_edge_at.?..];
    try std.testing.expect(std.mem.indexOf(u8, focus_edge, "HWND root = GetAncestor(hwnd, GA_ROOT);") != null);
    try std.testing.expect(std.mem.indexOf(u8, focus_edge, "entry.second.hwnd == root") != null);
}

test "windows webview focus reports the focused child label" {
    // WebView2 owns the page HWND and its input; GotFocus is the
    // controller-level edge that mirrors keyboard ownership back into
    // the runtime's per-view register.
    const host_source = @embedFile("webview2_host.cpp");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "add_GotFocus(Callback<ICoreWebView2FocusChangedEventHandler>") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "event.kind = kViewFocused;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "event.view_label = focused->second.label.c_str();") != null);
}

test "windows audio event maps kinds and payload" {
    var event = std.mem.zeroes(WindowsEvent);
    event.audio_kind = 1;
    event.audio_position_ms = 1_500;
    event.audio_duration_ms = 120_000;
    event.audio_playing = 1;
    event.audio_buffering = 1;
    try std.testing.expectEqual(platform_mod.AudioEventKind.position, audioEventKindFromInt(event.audio_kind));
    try std.testing.expectEqual(platform_mod.AudioEventKind.loaded, audioEventKindFromInt(0));
    try std.testing.expectEqual(platform_mod.AudioEventKind.completed, audioEventKindFromInt(2));
    // Unknown ordinals degrade loudly to failed, never to silence.
    try std.testing.expectEqual(platform_mod.AudioEventKind.failed, audioEventKindFromInt(3));
    try std.testing.expectEqual(platform_mod.AudioEventKind.failed, audioEventKindFromInt(99));
}

fn testPlatformWithEngine(web_engine: platform_mod.WebEngine) WindowsPlatform {
    return .{
        .host = undefined,
        .web_engine = web_engine,
        .app_info = .{},
        .surface_value = .{},
    };
}

fn viewKindInt(kind: platform_mod.ViewKind) c_int {
    return switch (kind) {
        .webview => 0,
        .toolbar => 1,
        .titlebar_accessory => 2,
        .sidebar => 3,
        .statusbar => 4,
        .split => 5,
        .stack => 6,
        .button => 7,
        .icon_button => 17,
        .list_item => 18,
        .text_field => 8,
        .search_field => 9,
        .label => 10,
        .spacer => 11,
        .gpu_surface => 12,
        .checkbox => 13,
        .toggle => 14,
        .progress_indicator => 15,
        .segmented_control => 16,
    };
}

fn gpuSurfaceBackendRequestInt(backend: platform_mod.GpuSurfaceBackend) c_int {
    return if (backend == .software) 1 else 0;
}

fn flattenFilters(filters: []const platform_mod.FileFilter, buffer: []u8) []const u8 {
    var offset: usize = 0;
    for (filters) |filter| {
        for (filter.extensions) |ext| {
            if (offset > 0 and offset < buffer.len) {
                buffer[offset] = ';';
                offset += 1;
            }
            const end = @min(offset + ext.len, buffer.len);
            if (end > offset) {
                @memcpy(buffer[offset..end], ext[0..(end - offset)]);
                offset = end;
            }
        }
    }
    return buffer[0..offset];
}

test "windows platform module exports type" {
    _ = WindowsPlatform;
}
