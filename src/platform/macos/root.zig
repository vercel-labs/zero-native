const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("geometry");
const platform_mod = @import("../root.zig");
const policy_values = @import("../policy_values.zig");
const security = @import("../../security/root.zig");
const canvas = @import("canvas");
// The packaging pipeline's one-image icon machinery: dev runs borrow its
// macOS mask/inset render so the Dock tile matches `native package`.
const app_icon = canvas.app_icon;
const updater_c_api = @import("../../updater/c_api.zig");

comptime {
    _ = updater_c_api.native_sdk_update_verify_feed;
    _ = updater_c_api.native_sdk_update_verify_archive;
}

pub const Error = error{
    CallbackFailed,
    CreateFailed,
    FocusFailed,
    CloseFailed,
    UnsupportedWindowTransparency,
};

const AppKitHost = opaque {};

const AppKitEventKind = enum(c_int) {
    start = 0,
    frame = 1,
    shutdown = 2,
    resize = 3,
    window_frame = 4,
    shortcut = 5,
    native_command = 6,
    menu_command = 7,
    app_activated = 8,
    app_deactivated = 9,
    files_dropped = 10,
    gpu_surface_frame = 11,
    gpu_surface_resize = 12,
    gpu_surface_input = 13,
    widget_accessibility_action = 14,
    appearance_changed = 15,
    timer = 16,
    wake = 17,
    gpu_surface_scroll_driver = 18,
    context_menu_action = 19,
    audio = 20,
    video = 21,
    view_focused = 22,
    tray_command = 23,
    notification_command = 24,
};

const AppKitEvent = extern struct {
    kind: AppKitEventKind,
    window_id: u64,
    width: f64,
    height: f64,
    scale: f64,
    x: f64,
    y: f64,
    open: c_int,
    focused: c_int,
    /// WINDOW_FRAME: nonzero while the window is alive but hidden by
    /// its close_policy (`open` stays 1 for the whole hidden stretch).
    hidden: c_int,
    label: [*]const u8,
    label_len: usize,
    shortcut_id: [*]const u8,
    shortcut_id_len: usize,
    shortcut_key: [*]const u8,
    shortcut_key_len: usize,
    shortcut_modifiers: u32,
    command_name: [*]const u8,
    command_name_len: usize,
    status_item_id: u32,
    view_label: [*]const u8,
    view_label_len: usize,
    key_text: [*]const u8,
    key_text_len: usize,
    input_text: [*]const u8,
    input_text_len: usize,
    drop_paths: [*]const u8,
    drop_paths_len: usize,
    frame_index: u64,
    timestamp_ns: u64,
    frame_interval_ns: u64,
    nonblank: c_int,
    sample_color: u32,
    input_kind: c_int,
    button: c_int,
    delta_x: f64,
    delta_y: f64,
    widget_id: u64,
    widget_action: c_int,
    widget_text: [*]const u8,
    widget_text_len: usize,
    has_widget_text_selection: c_int,
    widget_text_selection_start: usize,
    widget_text_selection_end: usize,
    has_composition_cursor: c_int,
    composition_cursor: usize,
    color_scheme: c_int,
    reduce_motion: c_int,
    high_contrast: c_int,
    timer_id: u64,
    scroll_driver_offset_x: f64,
    scroll_driver_offset_y: f64,
    menu_item_id: u32,
    /// Host-stamped packet decode/draw durations riding the frame
    /// event (0 when no packet present happened since the last one).
    packet_decode_ns: u64,
    packet_draw_ns: u64,
    /// Nonzero when the frame completed logically while the window was
    /// occluded (no glass flip; heartbeat pacing) — its timestamp is
    /// pacing policy, never a latency measurement endpoint.
    occluded: c_int,
    /// Audio player report payload (`kind == .audio`): the
    /// `AudioEventKind` ordinal plus the player's position/duration
    /// readout at emit time.
    audio_kind: c_int,
    audio_position_ms: u64,
    audio_duration_ms: u64,
    audio_playing: c_int,
    /// Nonzero while a streamed source is stalled waiting for network
    /// bytes (distinct from `audio_playing`, the transport intent).
    audio_buffering: c_int,
    /// SPECTRUM report payload: the 32 band magnitude bytes on the
    /// documented scale (log-spaced 50 Hz..16 kHz buckets, linear-in-dB
    /// from -60 dBFS at 0 to full scale at 255). Zeros elsewhere.
    audio_bands: [platform_mod.audio_spectrum_band_count]u8,
    /// Video player report payload (`kind == .video`): the
    /// `VideoEventKind` ordinal plus the player's position/duration
    /// readout at emit time. `video_buffering` is stream-only, distinct
    /// from `video_playing` (the transport intent) — the audio pair's
    /// exact semantics.
    video_kind: c_int,
    /// The engine-minted load token this event's playback echoes (see
    /// `platform.VideoEvent.token`).
    video_token: u64,
    video_position_ms: u64,
    video_duration_ms: u64,
    video_playing: c_int,
    video_buffering: c_int,
    /// `.loaded` payload: the STREAM's decoded pixel dimensions — the
    /// honest source geometry even when the host fits frames to the
    /// sink's pixel budget. Zeros on every other kind.
    video_width: u64,
    video_height: u64,
};

const AppKitCallback = *const fn (context: ?*anyopaque, event: *const AppKitEvent) callconv(.c) void;
const AppKitBridgeCallback = *const fn (context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void;
/// Where the AppKit host's video frame pump delivers decoded frames
/// (`native_sdk_appkit_video_sink_push_t`): one tightly packed
/// straight-alpha RGBA8 frame per call, answered 0 accepted, 1 the
/// receiving claim was released (the host stops its frame timer),
/// anything else one dropped frame.
const AppKitVideoSinkPush = *const fn (context: ?*anyopaque, width: usize, height: usize, pixels: [*c]const u8, len: usize) callconv(.c) c_int;

extern fn native_sdk_test_imageio_thumbnail_dimensions(
    bytes: [*]const u8,
    bytes_len: usize,
    source_width: usize,
    source_height: usize,
    max_pixels: usize,
    out_width: *usize,
    out_height: *usize,
) c_int;

extern fn native_sdk_test_appkit_text_baselines(
    regular_bytes: [*]const u8,
    regular_len: usize,
    mono_bytes: [*]const u8,
    mono_len: usize,
    size: f64,
    baseline: f64,
    out_regular_offset: *f64,
    out_mono_offset: *f64,
    out_compact_regular_offset: *f64,
    out_compact_mono_offset: *f64,
    out_old_regular_first: *c_int,
    out_old_mono_first: *c_int,
    out_fixed_regular_first: *c_int,
    out_fixed_mono_first: *c_int,
    out_wrapped_regular_first: *c_int,
    out_wrapped_mono_first: *c_int,
    out_compact_regular_first: *c_int,
    out_compact_mono_first: *c_int,
    out_fallback_first: *c_int,
) c_int;

const shortcut_modifier_primary: u32 = 1 << 0;
const shortcut_modifier_command: u32 = 1 << 1;
const shortcut_modifier_control: u32 = 1 << 2;
const shortcut_modifier_option: u32 = 1 << 3;
const shortcut_modifier_shift: u32 = 1 << 4;

extern fn native_sdk_appkit_create(app_name: [*]const u8, app_name_len: usize, display_name: [*]const u8, display_name_len: usize, version: [*]const u8, version_len: usize, about_description: [*]const u8, about_description_len: usize, has_web_content: c_int, dock_visible: c_int, window_title: [*]const u8, window_title_len: usize, bundle_id: [*]const u8, bundle_id_len: usize, icon_path: [*]const u8, icon_path_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, initial_placement: c_int, restore_policy: c_int, resizable: c_int, titlebar_style: c_int, show_policy: c_int, window_flags: u32) ?*AppKitHost;
extern fn native_sdk_appkit_destroy(host: *AppKitHost) void;
extern fn native_sdk_appkit_set_dock_icon_rgba(host: *AppKitHost, pixels: [*]const u8, width: usize, height: usize) void;
extern fn native_sdk_appkit_set_dock_icon_file(host: *AppKitHost, path: [*]const u8, path_len: usize) void;
extern fn native_sdk_appkit_configure_updates(host: *AppKitHost, feed_url: [*]const u8, feed_url_len: usize, public_key: [*]const u8, public_key_len: usize, check_on_start: c_int, target: [*]const u8, target_len: usize) void;
extern fn native_sdk_appkit_check_for_updates(host: *AppKitHost, user_initiated: c_int) c_int;
extern fn native_sdk_appkit_run(host: *AppKitHost, callback: AppKitCallback, context: ?*anyopaque) void;
extern fn native_sdk_appkit_stop(host: *AppKitHost) void;
extern fn native_sdk_appkit_request_stop(host: *AppKitHost) void;
extern fn native_sdk_appkit_load_webview(host: *AppKitHost, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_appkit_load_window_webview(host: *AppKitHost, window_id: u64, source: [*]const u8, source_len: usize, source_kind: c_int, asset_root: [*]const u8, asset_root_len: usize, asset_entry: [*]const u8, asset_entry_len: usize, asset_origin: [*]const u8, asset_origin_len: usize, spa_fallback: c_int) void;
extern fn native_sdk_appkit_set_bridge_callback(host: *AppKitHost, callback: AppKitBridgeCallback, context: ?*anyopaque) void;
extern fn native_sdk_appkit_bridge_respond(host: *AppKitHost, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_bridge_respond_window(host: *AppKitHost, window_id: u64, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_bridge_respond_webview(host: *AppKitHost, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, response: [*]const u8, response_len: usize) void;
extern fn native_sdk_appkit_emit_window_event(host: *AppKitHost, window_id: u64, name: [*]const u8, name_len: usize, detail_json: [*]const u8, detail_json_len: usize) void;
extern fn native_sdk_appkit_set_security_policy(host: *AppKitHost, allowed_origins: [*]const u8, allowed_origins_len: usize, external_urls: [*]const u8, external_urls_len: usize, external_action: c_int) void;
extern fn native_sdk_appkit_set_menus(host: *AppKitHost, menu_titles: [*]const [*]const u8, menu_title_lens: [*]const usize, menu_count: usize, item_menu_indices: [*]const u32, item_labels: [*]const [*]const u8, item_label_lens: [*]const usize, item_commands: [*]const [*]const u8, item_command_lens: [*]const usize, item_keys: [*]const [*]const u8, item_key_lens: [*]const usize, item_modifiers: [*]const u32, item_separators: [*]const c_int, item_enabled: [*]const c_int, item_checked: [*]const c_int, item_count: usize) void;
extern fn native_sdk_appkit_set_shortcuts(host: *AppKitHost, ids: [*]const [*]const u8, id_lens: [*]const usize, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) void;
extern fn native_sdk_appkit_request_frame(host: *AppKitHost) void;
extern fn native_sdk_appkit_create_window(host: *AppKitHost, window_id: u64, window_title: [*]const u8, window_title_len: usize, window_label: [*]const u8, window_label_len: usize, x: f64, y: f64, width: f64, height: f64, restore_frame: c_int, initial_placement: c_int, restore_policy: c_int, resizable: c_int, titlebar_style: c_int, show_policy: c_int, window_flags: u32) c_int;
extern fn native_sdk_appkit_set_window_content_min_size(host: *AppKitHost, window_id: u64, min_width: f64, min_height: f64) c_int;
extern fn native_sdk_appkit_focus_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_close_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_minimize_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_hide_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_show_window(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_set_dock_presence(host: *AppKitHost, visible: c_int) c_int;
extern fn native_sdk_appkit_launch_at_login_status(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_set_launch_at_login(host: *AppKitHost, enabled: c_int) c_int;
extern fn native_sdk_appkit_set_window_close_policy(host: *AppKitHost, window_id: u64, close_policy: c_int) c_int;
extern fn native_sdk_appkit_start_window_drag(host: *AppKitHost, window_id: u64) c_int;
extern fn native_sdk_appkit_window_chrome_insets(host: *AppKitHost, window_id: u64, top: *f64, left: *f64, bottom: *f64, right: *f64, buttons_x: *f64, buttons_y: *f64, buttons_width: *f64, buttons_height: *f64) c_int;
extern fn native_sdk_appkit_create_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, kind: c_int, parent: [*]const u8, parent_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, visible: c_int, enabled: c_int, role: [*]const u8, role_len: usize, accessibility_label: [*]const u8, accessibility_label_len: usize, text: [*]const u8, text_len: usize, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_appkit_update_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, has_frame: c_int, x: f64, y: f64, width: f64, height: f64, has_layer: c_int, layer: c_int, has_visible: c_int, visible: c_int, has_enabled: c_int, enabled: c_int, has_role: c_int, role: [*]const u8, role_len: usize, has_accessibility_label: c_int, accessibility_label: [*]const u8, accessibility_label_len: usize, has_text: c_int, text: [*]const u8, text_len: usize, has_command: c_int, command: [*]const u8, command_len: usize) c_int;
extern fn native_sdk_appkit_set_view_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_appkit_set_view_visible(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, visible: c_int) c_int;
extern fn native_sdk_appkit_set_view_cursor(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, cursor: c_int) c_int;
extern fn native_sdk_appkit_focus_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_close_view(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_adopt_view_surface(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, ns_view: *anyopaque) c_int;
extern fn native_sdk_appkit_release_view_surface(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_request_gpu_surface_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_note_gpu_surface_input(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_set_gpu_surface_scroll_drivers(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, drivers: [*]const AppKitScrollDriver, count: usize, occluders: [*]const AppKitScrollOccluder, occluder_count: usize) c_int;
extern fn native_sdk_appkit_show_context_menu(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, token: u64, items: [*]const AppKitContextMenuItem, count: usize) c_int;
extern fn native_sdk_appkit_start_timer(host: *AppKitHost, timer_id: u64, interval_ns: u64, repeats: c_int) void;
extern fn native_sdk_appkit_cancel_timer(host: *AppKitHost, timer_id: u64) void;
extern fn native_sdk_appkit_audio_load(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_audio_load_url(host: *AppKitHost, url: [*]const u8, url_len: usize, cache_path: [*]const u8, cache_path_len: usize, expected_bytes: u64) c_int;
extern fn native_sdk_appkit_audio_play(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_pause(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_stop(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_audio_seek(host: *AppKitHost, position_ms: u64) c_int;
extern fn native_sdk_appkit_audio_set_volume(host: *AppKitHost, volume: f64) c_int;
const AppKitAudioCapturePush = *const fn (context: ?*anyopaque, kind: c_int, source: c_int, sample_rate: u32, channels: u8, timestamp_ns: u64, frames: u32, pcm: ?[*]const u8, pcm_len: usize) callconv(.c) c_int;
extern fn native_sdk_appkit_audio_capture_start(host: *AppKitHost, source: c_int, sample_rate: u32, channels: u8, push_fn: AppKitAudioCapturePush, push_context: ?*anyopaque) c_int;
extern fn native_sdk_appkit_audio_capture_stop(host: *AppKitHost, source: c_int) c_int;
extern fn native_sdk_appkit_audio_capture_supported(host: *AppKitHost, source: c_int) c_int;
extern fn native_sdk_appkit_video_load(host: *AppKitHost, path: [*]const u8, path_len: usize, token: u64, push_fn: AppKitVideoSinkPush, push_context: ?*anyopaque) c_int;
extern fn native_sdk_appkit_video_load_url(host: *AppKitHost, url: [*]const u8, url_len: usize, token: u64, push_fn: AppKitVideoSinkPush, push_context: ?*anyopaque) c_int;
extern fn native_sdk_appkit_video_play(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_video_pause(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_video_stop(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_video_seek(host: *AppKitHost, position_ms: u64) c_int;
extern fn native_sdk_appkit_video_set_volume(host: *AppKitHost, volume: f64) c_int;
extern fn native_sdk_appkit_video_set_muted(host: *AppKitHost, muted: c_int) c_int;
extern fn native_sdk_appkit_video_set_loop(host: *AppKitHost, loop: c_int) c_int;
extern fn native_sdk_appkit_wake(host: *AppKitHost) void;
extern fn native_sdk_appkit_present_gpu_surface_pixels(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, width: usize, height: usize, scale: f64, has_dirty_rect: c_int, dirty_x: f64, dirty_y: f64, dirty_width: f64, dirty_height: f64, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_appkit_present_gpu_surface_packet(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, surface_width: f64, surface_height: f64, scale: f64, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, requires_render: c_int, command_count: usize, unsupported_command_count: usize, representable: c_int, json: [*]const u8, json_len: usize) c_int;
extern fn native_sdk_appkit_present_gpu_surface_packet_binary(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, surface_width: f64, surface_height: f64, scale: f64, clear_r: u8, clear_g: u8, clear_b: u8, clear_a: u8, requires_render: c_int, command_count: usize, unsupported_command_count: usize, representable: c_int, packet: [*]const u8, packet_len: usize) c_int;
extern fn native_sdk_appkit_upload_gpu_surface_image(host: *AppKitHost, image_id: u64, width: usize, height: usize, rgba8: [*]const u8, rgba8_len: usize) c_int;
extern fn native_sdk_appkit_remove_gpu_surface_image(host: *AppKitHost, image_id: u64) c_int;
extern fn native_sdk_appkit_update_widget_accessibility(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, nodes: [*]const AppKitWidgetAccessibilityNode, node_count: usize) c_int;
extern fn native_sdk_appkit_create_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize, x: f64, y: f64, width: f64, height: f64, layer: c_int, transparent: c_int, bridge_enabled: c_int) c_int;
extern fn native_sdk_appkit_set_webview_frame(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, x: f64, y: f64, width: f64, height: f64) c_int;
extern fn native_sdk_appkit_navigate_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_appkit_set_webview_zoom(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, zoom: f64) c_int;
extern fn native_sdk_appkit_set_webview_layer(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize, layer: c_int) c_int;
extern fn native_sdk_appkit_close_webview(host: *AppKitHost, window_id: u64, label: [*]const u8, label_len: usize) c_int;
extern fn native_sdk_appkit_clipboard_read(host: *AppKitHost, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_measure_text(font_id: u64, size: f64, text: [*]const u8, text_len: usize) f64;
extern fn native_sdk_appkit_measure_text_advances(font_id: u64, size: f64, text: [*]const u8, text_len: usize, advances: [*]f32) c_int;
extern fn native_sdk_appkit_measure_text_ink(font_id: u64, size: f64, text: [*]const u8, text_len: usize, min_x: *f64, max_x: *f64, min_y: *f64, max_y: *f64) c_int;
extern fn native_sdk_appkit_register_font(font_id: u64, bytes: [*]const u8, bytes_len: usize, out_token: *u64) c_int;
extern fn native_sdk_appkit_unregister_font(font_id: u64, token: u64) c_int;
extern fn native_sdk_appkit_register_bundled_fonts() void;
extern fn native_sdk_appkit_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, max_pixels: usize, out_width: *usize, out_height: *usize) c_int;
extern fn native_sdk_appkit_clipboard_write(host: *AppKitHost, text: [*]const u8, text_len: usize) void;
extern fn native_sdk_appkit_clipboard_read_data(host: *AppKitHost, mime_type: [*]const u8, mime_type_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_clipboard_write_data(host: *AppKitHost, mime_type: [*]const u8, mime_type_len: usize, bytes: [*]const u8, bytes_len: usize) c_int;
extern fn native_sdk_appkit_show_notification(host: *AppKitHost, title: [*]const u8, title_len: usize, subtitle: [*]const u8, subtitle_len: usize, body: [*]const u8, body_len: usize, notification_id: [*]const u8, notification_id_len: usize, action_label: [*]const u8, action_label_len: usize, action_command: [*]const u8, action_command_len: usize) c_int;
extern fn native_sdk_appkit_open_external_url(host: *AppKitHost, url: [*]const u8, url_len: usize) c_int;
extern fn native_sdk_appkit_reveal_path(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_add_recent_document(host: *AppKitHost, path: [*]const u8, path_len: usize) c_int;
extern fn native_sdk_appkit_clear_recent_documents(host: *AppKitHost) c_int;
extern fn native_sdk_appkit_set_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, secret: [*]const u8, secret_len: usize) c_int;
extern fn native_sdk_appkit_get_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_delete_credential(host: *AppKitHost, service: [*]const u8, service_len: usize, account: [*]const u8, account_len: usize) c_int;
extern fn native_sdk_appkit_format_local_time(host: *AppKitHost, timestamp_ms: i64, style: c_int, buffer: [*]u8, buffer_len: usize) usize;

const AppKitScrollOccluder = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
};

const AppKitScrollDriver = extern struct {
    driver_id: u64,
    parent_driver_id: u64,
    occluder_mask: u32,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    content_width: f64,
    content_height: f64,
    offset_x: f64,
    offset_y: f64,
    set_offset_x: c_int,
    set_offset_y: c_int,
    rubber_band: c_int,
    scrolls_x: c_int,
    scrolls_y: c_int,
};

const AppKitContextMenuItem = extern struct {
    item_id: u32,
    label: [*]const u8,
    label_len: usize,
    enabled: c_int,
    separator: c_int,
};

const AppKitOpenDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
    allow_directories: c_int,
    allow_multiple: c_int,
};

const AppKitOpenDialogResult = extern struct {
    count: usize,
    bytes_written: usize,
};

const AppKitSaveDialogOpts = extern struct {
    title: [*]const u8,
    title_len: usize,
    default_path: [*]const u8,
    default_path_len: usize,
    default_name: [*]const u8,
    default_name_len: usize,
    extensions: [*]const u8,
    extensions_len: usize,
};

const AppKitMessageDialogOpts = extern struct {
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

const AppKitWidgetAccessibilityNode = extern struct {
    id: u64,
    parent_id: u64,
    role: c_int,
    label: [*]const u8,
    label_len: usize,
    text_value: [*]const u8,
    text_value_len: usize,
    placeholder: [*]const u8,
    placeholder_len: usize,
    has_text_selection: c_int,
    text_selection_start: usize,
    text_selection_end: usize,
    has_text_composition: c_int,
    text_composition_start: usize,
    text_composition_end: usize,
    has_value: c_int,
    value: f64,
    has_grid_row_index: c_int,
    grid_row_index: usize,
    has_grid_column_index: c_int,
    grid_column_index: usize,
    has_grid_row_count: c_int,
    grid_row_count: usize,
    has_grid_column_count: c_int,
    grid_column_count: usize,
    has_list_item_index: c_int,
    list_item_index: u32,
    has_list_item_count: c_int,
    list_item_count: u32,
    has_scroll_offset: c_int,
    scroll_offset: f64,
    has_scroll_viewport_extent: c_int,
    scroll_viewport_extent: f64,
    has_scroll_content_extent: c_int,
    scroll_content_extent: f64,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    state_flags: u32,
    action_flags: u32,
};

const widget_state_enabled: u32 = 1 << 0;
const widget_state_focused: u32 = 1 << 1;
const widget_state_selected: u32 = 1 << 2;
const widget_state_pressed: u32 = 1 << 3;
const widget_state_expanded: u32 = 1 << 4;
const widget_state_collapsed: u32 = 1 << 5;
const widget_state_required: u32 = 1 << 6;
const widget_state_read_only: u32 = 1 << 7;
const widget_state_invalid: u32 = 1 << 8;
const widget_state_can_undo: u32 = 1 << 9;
const widget_state_can_redo: u32 = 1 << 10;
const widget_action_focus: u32 = 1 << 0;
const widget_action_press: u32 = 1 << 1;
const widget_action_toggle: u32 = 1 << 2;
const widget_action_increment: u32 = 1 << 3;
const widget_action_decrement: u32 = 1 << 4;
const widget_action_set_text: u32 = 1 << 5;
const widget_action_set_selection: u32 = 1 << 6;
const widget_action_select: u32 = 1 << 7;
const widget_action_drag: u32 = 1 << 8;
const widget_action_drop_files: u32 = 1 << 9;
const widget_action_dismiss: u32 = 1 << 10;

const AppKitTrayCallback = *const fn (context: ?*anyopaque, status_item_id: u32, item_id: u32) callconv(.c) void;
const AppKitTraySegmentOption = extern struct {
    item_id: u32,
    label: [*]const u8,
    label_len: usize,
    selected: c_int,
    enabled: c_int,
};
const AppKitTraySegmentedRow = extern struct {
    row_index: usize,
    options: [*]const AppKitTraySegmentOption,
    option_count: usize,
};
const AppKitTrayMetricRow = extern struct {
    row_index: usize,
    primary_text: [*]const u8,
    primary_text_len: usize,
    secondary_text: [*]const u8,
    secondary_text_len: usize,
    accessibility_label: [*]const u8,
    accessibility_label_len: usize,
};
const AppKitTrayChartRow = extern struct {
    row_index: usize,
    values: [*]const f32,
    value_count: usize,
    min_value: f64,
    max_value: f64,
    leading_caption: [*]const u8,
    leading_caption_len: usize,
    trailing_summary: [*]const u8,
    trailing_summary_len: usize,
    accessibility_label: [*]const u8,
    accessibility_label_len: usize,
};

extern fn native_sdk_appkit_show_open_dialog(host: *AppKitHost, opts: *const AppKitOpenDialogOpts, buffer: [*]u8, buffer_len: usize) AppKitOpenDialogResult;
extern fn native_sdk_appkit_show_save_dialog(host: *AppKitHost, opts: *const AppKitSaveDialogOpts, buffer: [*]u8, buffer_len: usize) usize;
extern fn native_sdk_appkit_show_message_dialog(host: *AppKitHost, opts: *const AppKitMessageDialogOpts) c_int;
extern fn native_sdk_appkit_create_tray(host: *AppKitHost, status_item_id: u32, icon_path: [*]const u8, icon_path_len: usize, title: [*]const u8, title_len: usize, tooltip: [*]const u8, tooltip_len: usize, visible: c_int, width: f64, tone: c_int, icon_opacity: f64, monospaced: c_int, font_size: f64, font_weight: c_int, activation_command: [*]const u8, activation_command_len: usize, alternate_activation_command: [*]const u8, alternate_activation_command_len: usize, open_command: [*]const u8, open_command_len: usize) void;
extern fn native_sdk_appkit_update_tray_shell(host: *AppKitHost, status_item_id: u32, icon_path: [*]const u8, icon_path_len: usize, tooltip: [*]const u8, tooltip_len: usize, visible: c_int, activation_command: [*]const u8, activation_command_len: usize, alternate_activation_command: [*]const u8, alternate_activation_command_len: usize, open_command: [*]const u8, open_command_len: usize) void;
extern fn native_sdk_appkit_update_tray_menu(host: *AppKitHost, status_item_id: u32, item_ids: [*]const u32, labels: [*]const [*]const u8, label_lens: [*]const usize, separators: [*]const c_int, enabled_flags: [*]const c_int, details: [*]const [*]const u8, detail_lens: [*]const usize, roles: [*]const c_int, keys: [*]const [*]const u8, key_lens: [*]const usize, modifiers: [*]const u32, count: usize) void;
extern fn native_sdk_appkit_update_tray_rich_rows(host: *AppKitHost, status_item_id: u32, segmented_rows: [*]const AppKitTraySegmentedRow, segmented_count: usize, metric_rows: [*]const AppKitTrayMetricRow, metric_count: usize, chart_rows: [*]const AppKitTrayChartRow, chart_count: usize) void;
extern fn native_sdk_appkit_update_tray_title(host: *AppKitHost, status_item_id: u32, title: [*]const u8, title_len: usize) void;
extern fn native_sdk_appkit_update_tray_presentation(host: *AppKitHost, status_item_id: u32, title: [*]const u8, title_len: usize, width: f64, tone: c_int, icon_opacity: f64, monospaced: c_int, font_size: f64, font_weight: c_int) void;
extern fn native_sdk_appkit_remove_tray(host: *AppKitHost, status_item_id: u32) void;
extern fn native_sdk_appkit_set_tray_callback(host: *AppKitHost, callback: AppKitTrayCallback, context: ?*anyopaque) void;

/// Whether a Dock icon path names a raw image source (.png/.svg) that
/// `native package` would inset and mask onto the macOS icon grid.
/// Debug builds only: dev runs are unbundled, so the Dock shows exactly
/// the file the host is handed — a full-bleed square source would sit
/// sharp-cornered next to every masked tile. Release apps read their
/// icon from the bundle's .icns (already masked at package time), and
/// prebuilt .icns paths ship untouched in every mode.
fn devDockIconNeedsMask(path: []const u8) bool {
    if (builtin.mode != .Debug) return false;
    return app_icon.sourceKindForPath(path) != null;
}

/// The toolkit's default app icon, the same bytes `native package`
/// embeds as its fallback: unbundled runs whose configured icon file is
/// absent render this instead of showing the generic executable tile,
/// so a dev run and the packaged app fall back to the same picture from
/// ONE committed source (src/tooling/default_icon.png) — apps that ship
/// no icon of their own never carry a copy that can drift stale.
const default_icon_png = @embedFile("../../tooling/default_icon.png");

/// How the startup Dock icon resolves for this process.
const DockIconPlan = enum {
    /// The host loads the configured icon file itself (the classic
    /// path; also every bundled run, where the .app's own icon must
    /// never be overridden).
    host_file,
    /// Debug dev run with a raw square source: background-render the
    /// packaging mask/inset and hand the host pixels.
    masked_render,
    /// Unbundled run with no icon file on disk: background-render the
    /// embedded toolkit default.
    embedded_default,
};

fn planDockIcon(path: []const u8) DockIconPlan {
    if (iconFileExists(path)) {
        return if (devDockIconNeedsMask(path)) .masked_render else .host_file;
    }
    // No icon file. Inside a packaged .app the bundle's .icns already
    // owns the tile — hands off. Anywhere else (dev runs from the build
    // cache, plain zig-out binaries) macOS would show the generic
    // executable tile, so the embedded default steps in.
    if (processIsBundled()) return .host_file;
    return .embedded_default;
}

/// Existence probe for the configured Dock icon file. `access(2)`
/// directly: this sits on the launch path, where a stat is noise but an
/// event-loop `std.Io` instance is not; the host re-reads the file
/// asynchronously anyway, so a race here only re-selects the fallback.
fn iconFileExists(path: []const u8) bool {
    // Hermetic guard: this file compiles into every desktop target's
    // test build, and non-macOS builds must never reference the libc
    // symbol below, so the probe answers false at comptime there.
    if (comptime builtin.os.tag != .macos) return false;
    var buffer: [1024:0]u8 = undefined;
    if (path.len == 0 or path.len >= buffer.len) return false;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return std.c.access(buffer[0..path.len :0].ptr, std.c.F_OK) == 0;
}

/// Whether this process runs from inside a packaged .app bundle (the
/// executable lives under Contents/MacOS). Unbundled processes get the
/// dev-run icon fallbacks; bundled ones keep their Info.plist identity.
fn processIsBundled() bool {
    // Same hermetic guard as `iconFileExists`: the executable-path
    // lookup below exists only on macOS, and non-macOS test builds of
    // this file must never reference it.
    if (comptime builtin.os.tag != .macos) return false;
    var buffer: [4096]u8 = undefined;
    var size: u32 = buffer.len;
    if (std.c._NSGetExecutablePath(&buffer, &size) != 0) return false;
    const path = std.mem.sliceTo(buffer[0..], 0);
    return std.mem.indexOf(u8, path, ".app/Contents/MacOS/") != null;
}

/// Ceiling for a dev Dock icon source read. The pipeline caps sources at
/// 16384px on a side; any honest PNG/SVG source sits far below this.
const max_dev_dock_icon_source_bytes: usize = 32 * 1024 * 1024;

/// Start the background masked render for a raw dev icon source. Kept
/// off the launch path on purpose (the same reason the host decodes
/// .icns files off it): the Debug-mode render costs real milliseconds,
/// and the Dock tile updating a few frames after launch is
/// imperceptible. Every failure falls back to the host's plain file
/// load — the pre-parity behavior — so a broken source still shows
/// whatever the file holds and packaging stays the surface that reports
/// icon problems with teaching messages.
fn spawnDevDockIconRender(host: *AppKitHost, path: []const u8) void {
    const gpa = std.heap.c_allocator;
    const path_copy = gpa.dupe(u8, path) catch {
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
        return;
    };
    const thread = std.Thread.spawn(.{}, devDockIconRenderMain, .{ host, path_copy }) catch {
        gpa.free(path_copy);
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
        return;
    };
    thread.detach();
}

fn devDockIconRenderMain(host: *AppKitHost, path: []u8) void {
    const gpa = std.heap.c_allocator;
    defer gpa.free(path);
    renderDevDockIcon(gpa, host, path) catch {
        native_sdk_appkit_set_dock_icon_file(host, path.ptr, path.len);
    };
}

/// Start the background render of the embedded default icon (see
/// `default_icon_png`). Same off-the-launch-path policy as the masked
/// dev render; failure means no Dock icon, exactly the pre-fallback
/// behavior for a missing file.
fn spawnDefaultDockIconRender(host: *AppKitHost) void {
    const thread = std.Thread.spawn(.{}, defaultDockIconRenderMain, .{host}) catch return;
    thread.detach();
}

fn defaultDockIconRenderMain(host: *AppKitHost) void {
    const gpa = std.heap.c_allocator;
    var source = switch (app_icon.loadSource(gpa, default_icon_png, .png) catch return) {
        .ok => |value| value,
        .issue => return,
    };
    defer source.deinit(gpa);
    // The exact packaging render: the default is pre-shaped (transparent
    // corners), so it ships through untouched at the master size and the
    // dev tile equals the packaged fallback tile.
    const rgba = app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size) catch return;
    defer gpa.free(rgba);
    native_sdk_appkit_set_dock_icon_rgba(host, rgba.ptr, app_icon.master_size, app_icon.master_size);
}

/// Render the masked macOS canvas for a raw icon source and hand the
/// pixels to the AppKit host. `renderMacosCanvas` is the exact packaging
/// render: full-bleed art is inset to the icon-grid artwork square and
/// masked by the standard rounded rectangle, while pre-shaped art (all
/// four corners already transparent) ships untouched, never
/// double-inset. Rendered at the pipeline's 1024 master size — the same
/// canvas the packaged .icns tops out at — so the dev tile and the
/// packaged tile are the same picture.
fn renderDevDockIcon(gpa: std.mem.Allocator, host: *AppKitHost, path: []const u8) !void {
    const kind = app_icon.sourceKindForPath(path) orelse return error.UnsupportedImage;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_dev_dock_icon_source_bytes));
    defer gpa.free(bytes);
    var source = switch (try app_icon.loadSource(gpa, bytes, kind)) {
        .ok => |value| value,
        // Undecodable or non-square: fall back to the raw file load
        // (the caller's catch) instead of guessing at a crop here.
        .issue => return error.UnsupportedImage,
    };
    defer source.deinit(gpa);
    const rgba = try app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size);
    defer gpa.free(rgba);
    native_sdk_appkit_set_dock_icon_rgba(host, rgba.ptr, app_icon.master_size, app_icon.master_size);
}

pub const MacPlatform = struct {
    host: *AppKitHost,
    web_engine: platform_mod.WebEngine,
    app_info: platform_mod.AppInfo,
    surface_value: platform_mod.Surface,
    state: RunState = .{},
    /// Latched when effects teardown abandons an in-flight platform call
    /// (a channel wake or blocking credential operation): the stale
    /// call still holds this platform as its context and may execute
    /// into it at any later time, so `deinit` must skip destruction
    /// and leak the host, process-lived — and the wrapper struct the
    /// context actually points at (the wake thunk casts to
    /// `*MacPlatform` before reaching the host) must outlive the call
    /// too, which is why runners allocate it through
    /// `createWithOptions` and retire it through `destroy`, the
    /// latch-gated free.
    channel_wake_abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The CURRENT video frame sink — the host's C push trampoline
    /// cannot carry a Zig error-union fn pointer, so the sink lives
    /// here and `nativeSdkVideoSinkPush` forwards through it. Single
    /// player, single slot: loads replace it on the main thread, and
    /// every push happens on the main thread (the host's frame pump is
    /// a run-loop timer), so a plain field is race-free.
    video_sink: platform_mod.VideoFrameSink = .{},
    audio_capture_sinks: [2]platform_mod.AudioCaptureSink = [_]platform_mod.AudioCaptureSink{.{}} ** 2,

    pub fn init(title: []const u8, size: geometry.SizeF) Error!MacPlatform {
        return initWithEngine(title, size, .system);
    }

    pub fn initWithEngine(title: []const u8, size: geometry.SizeF, web_engine: platform_mod.WebEngine) Error!MacPlatform {
        return initWithOptions(size, web_engine, .{ .app_name = title, .window_title = title });
    }

    pub fn initWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!MacPlatform {
        const window_options = app_info.resolvedMainWindow();
        try refuseUnsupportedTransparentWindow(web_engine, window_options);
        const window_title = window_options.resolvedTitle(app_info.app_name);
        const frame = window_options.default_frame;
        const display_name = app_info.resolvedDisplayName();
        // Dev-run Dock icon parity: a raw square icon source (.png/.svg)
        // gets the packaging pipeline's macOS mask/inset before it
        // reaches the Dock, so the dev tile matches the packaged one —
        // and an unbundled run with NO icon file gets the embedded
        // toolkit default, the same fallback `native package` ships.
        // For both render plans the host's own file load is suppressed
        // (an empty path at create) and a background render delivers
        // the pixels instead. Prebuilt .icns paths that exist — and
        // every bundled run, whose icon comes from the bundle — keep
        // the classic load byte-for-byte.
        const dock_icon = planDockIcon(app_info.icon_path);
        const icon_path = if (dock_icon == .host_file) app_info.icon_path else "";
        const host = native_sdk_appkit_create(app_info.app_name.ptr, app_info.app_name.len, display_name.ptr, display_name.len, app_info.version.ptr, app_info.version.len, app_info.description.ptr, app_info.description.len, if (app_info.has_web_content) 1 else 0, if (app_info.dock_visible) 1 else 0, window_title.ptr, window_title.len, app_info.bundle_id.ptr, app_info.bundle_id.len, icon_path.ptr, icon_path.len, window_options.label.ptr, window_options.label.len, frame.x, frame.y, frame.width, frame.height, if (window_options.restore_state) 1 else 0, initialPlacementInt(window_options.initial_placement), restorePolicyInt(window_options.restore_policy), if (window_options.resizable) 1 else 0, titlebarStyleInt(window_options.titlebar), showModeInt(window_options.show), windowFlags(window_options)) orelse return error.CreateFailed;
        const update_target = comptime switch (builtin.cpu.arch) {
            .aarch64 => "macos-aarch64",
            .x86_64 => "macos-x86_64",
            else => "macos-unsupported",
        };
        native_sdk_appkit_configure_updates(host, app_info.update_feed_url.ptr, app_info.update_feed_url.len, app_info.update_public_key.ptr, app_info.update_public_key.len, if (app_info.update_check_on_start) 1 else 0, update_target.ptr, update_target.len);
        switch (dock_icon) {
            .host_file => {},
            .masked_render => spawnDevDockIconRender(host, app_info.icon_path),
            .embedded_default => spawnDefaultDockIconRender(host),
        }
        // The startup window's declared content min-size floor
        // (AppKit `contentMinSize`); the create call above registers
        // the window under its id, so the floor applies right after.
        applyWindowContentMinSize(host, window_options.id, window_options.min_width, window_options.min_height);
        // Same timing for the declared close policy: the manifest's
        // .hide threads through here so the STARTUP window's red
        // button hides from the first frame on.
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
    pub fn createWithOptions(size: geometry.SizeF, web_engine: platform_mod.WebEngine, app_info: platform_mod.AppInfo) Error!*MacPlatform {
        const self = std.heap.page_allocator.create(MacPlatform) catch return error.CreateFailed;
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
    pub fn destroy(self: *MacPlatform) void {
        self.deinit();
        if (self.channel_wake_abandoned.load(.seq_cst)) return;
        std.heap.page_allocator.destroy(self);
    }

    pub fn deinit(self: *MacPlatform) void {
        // An abandoned platform call may still enter this host at
        // any later time (see `channel_wake_abandoned`): destroying it
        // would turn that stale call into a use-after-free, so the
        // host is deliberately leaked, process-lived — the
        // abandoned-worker idiom, applied to the platform itself.
        if (self.channel_wake_abandoned.load(.seq_cst)) {
            std.debug.print("macos platform teardown: an abandoned platform call may still enter this host; skipping destruction and leaking it (and the wrapper it enters through), process-lived, so the stale call stays safe\n", .{});
            return;
        }
        native_sdk_appkit_destroy(self.host);
    }

    pub fn platform(self: *MacPlatform) platform_mod.Platform {
        return .{
            .context = self,
            .name = "macos",
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
                .set_dock_presence_fn = setDockPresence,
                .launch_at_login_status_fn = launchAtLoginStatus,
                .set_launch_at_login_fn = setLaunchAtLogin,
                .quit_app_fn = quitApp,
                .start_window_drag_fn = startWindowDrag,
                .window_chrome_fn = windowChrome,
                .create_view_fn = createView,
                .update_view_fn = updateView,
                .set_view_frame_fn = setViewFrame,
                .set_view_visible_fn = setViewVisible,
                .set_view_cursor_fn = setViewCursor,
                .focus_view_fn = focusView,
                .close_view_fn = closeView,
                .adopt_view_surface_fn = adoptViewSurface,
                .release_view_surface_fn = releaseViewSurface,
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
                .set_credential_fn = setCredential,
                .get_credential_fn = getCredential,
                .delete_credential_fn = deleteCredential,
                .note_blocking_call_abandoned_fn = noteChannelWakeAbandoned,
                .format_local_time_fn = formatLocalTime,
                .open_external_url_fn = openExternalUrl,
                .reveal_path_fn = revealPath,
                .add_recent_document_fn = addRecentDocument,
                .clear_recent_documents_fn = clearRecentDocuments,
                .check_for_updates_fn = checkForUpdates,
                .create_tray_fn = createTray,
                .update_tray_shell_fn = updateTrayShell,
                .update_tray_menu_fn = updateTrayMenu,
                .update_tray_title_fn = updateTrayTitle,
                .update_tray_presentation_fn = updateTrayPresentation,
                .remove_tray_fn = removeTray,
                .configure_security_policy_fn = configureSecurityPolicy,
                .configure_menus_fn = configureMenus,
                .configure_shortcuts_fn = configureShortcuts,
                .emit_window_event_fn = emitWindowEvent,
                .start_timer_fn = startTimer,
                .cancel_timer_fn = cancelTimer,
                .audio_load_fn = audioLoad,
                .audio_load_url_fn = audioLoadUrl,
                .audio_play_fn = audioPlay,
                .audio_pause_fn = audioPause,
                .audio_stop_fn = audioStop,
                .audio_seek_fn = audioSeek,
                .audio_set_volume_fn = audioSetVolume,
                .audio_capture_start_fn = if (self.web_engine == .system) audioCaptureStart else null,
                .audio_capture_stop_fn = if (self.web_engine == .system) audioCaptureStop else null,
                .video_load_fn = videoLoad,
                .video_load_url_fn = videoLoadUrl,
                .video_play_fn = videoPlay,
                .video_pause_fn = videoPause,
                .video_stop_fn = videoStop,
                .video_seek_fn = videoSeek,
                .video_set_volume_fn = videoSetVolume,
                .video_set_muted_fn = videoSetMuted,
                .video_set_loop_fn = videoSetLoop,
                .wake_fn = wake,
                .note_channel_wake_abandoned_fn = noteChannelWakeAbandoned,
                .request_frame_fn = requestFrame,
                .request_gpu_surface_frame_fn = requestGpuSurfaceFrame,
                .note_gpu_surface_input_fn = noteGpuSurfaceInput,
                .set_gpu_surface_scroll_drivers_fn = setGpuSurfaceScrollDrivers,
                .show_context_menu_fn = showContextMenu,
                .present_gpu_surface_pixels_fn = presentGpuSurfacePixels,
                .present_gpu_surface_packet_fn = presentGpuSurfacePacket,
                .present_gpu_surface_packet_binary_fn = presentGpuSurfacePacketBinary,
                .upload_gpu_surface_image_fn = uploadGpuSurfaceImage,
                .remove_gpu_surface_image_fn = removeGpuSurfaceImage,
                .register_gpu_surface_font_fn = registerGpuSurfaceFont,
                .unregister_gpu_surface_font_fn = unregisterGpuSurfaceFont,
                .update_widget_accessibility_fn = updateWidgetAccessibility,
                .measure_text_fn = measureText,
                .measure_text_advances_fn = measureTextAdvances,
                .measure_text_ink_fn = measureTextInk,
                .decode_image_fn = decodeImage,
            },
            .app_info = self.app_info,
        };
    }

    fn supportsFeature(context: *anyopaque, feature: platform_mod.PlatformFeature) bool {
        const self: *MacPlatform = @ptrCast(@alignCast(context));
        return switch (feature) {
            .main_webview,
            .child_webviews,
            .tray,
            .shortcuts,
            .dialogs,
            .clipboard_text,
            .clipboard_rich_data,
            .open_url,
            .reveal_path,
            .notifications,
            .recent_documents,
            .credentials,
            .app_activation_events,
            // close_policy .hide: windowShouldClose orders the window
            // out instead of closing, the Dock reopen re-shows it —
            // both hosts (AppKit and the CEF variant) implement it.
            .window_hide_on_close,
            => true,
            .context_menus => true,
            .native_views,
            .native_control_commands,
            .menus,
            .file_drops,
            .gpu_surfaces,
            .gpu_surface_scroll_drivers,
            .view_surface_adoption,
            // Audio lives in the AppKit host (one AVPlayer for local
            // files and streamed URL sources); the Chromium host stubs
            // the C ABI and reports honestly unsupported rather than
            // half-implementing a second player. Spectrum analysis
            // ships with the player (an MTAudioProcessingTap feeding
            // vDSP — both in-box on every macOS this toolkit runs on),
            // so its report rides the same engine gate.
            .audio_playback,
            .audio_streaming,
            .audio_spectrum,
            => self.web_engine == .system,
            .microphone_capture => self.web_engine == .system and audioCaptureSupported(self.host, .microphone),
            .system_audio_capture => self.web_engine == .system and audioCaptureSupported(self.host, .system),
            // AVFoundation video ships in the AppKit host only (one
            // AVPlayer whose AVPlayerItemVideoOutput frames feed the
            // media-surface sink); the CEF host stubs the C ABI and
            // reports honestly unsupported rather than half-implementing
            // a second player.
            .video_playback => self.web_engine == .system,
        };
    }

    /// The host performs the availability probe because system capture is
    /// version-gated at runtime (the deployment target predates
    /// ScreenCaptureKit audio). Hermetic Zig tests do not link an AppKit
    /// host, so keep the probe behind the same test/target seam as Linux's
    /// runtime-loaded service probes.
    fn audioCaptureSupported(host: *AppKitHost, source: platform_mod.AudioCaptureSource) bool {
        if (comptime @import("builtin").is_test) return false;
        if (@import("builtin").target.os.tag != .macos) return false;
        return native_sdk_appkit_audio_capture_supported(host, @intFromEnum(source)) != 0;
    }

    fn run(context: *anyopaque, handler: platform_mod.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *MacPlatform = @ptrCast(@alignCast(context));
        self.state = .{
            .self = self,
            .handler = handler,
            .handler_context = handler_context,
        };
        native_sdk_appkit_set_bridge_callback(self.host, appkitBridgeCallback, &self.state);
        native_sdk_appkit_set_tray_callback(self.host, appkitTrayCallback, &self.state);
        native_sdk_appkit_run(self.host, appkitCallback, &self.state);
        if (self.state.failed) return error.CallbackFailed;
    }

    fn windowById(self: *const MacPlatform, window_id: platform_mod.WindowId) platform_mod.WindowOptions {
        var index: usize = 0;
        while (index < self.app_info.startupWindowCount()) : (index += 1) {
            const window = self.app_info.resolvedStartupWindow(index);
            if (window.id == window_id) return window;
        }
        return .{ .id = window_id, .label = "", .title = self.app_info.resolvedWindowTitle() };
    }
};

const RunState = struct {
    self: ?*MacPlatform = null,
    handler: ?platform_mod.EventHandler = null,
    handler_context: ?*anyopaque = null,
    failed: bool = false,

    fn emit(self: *RunState, event: platform_mod.Event) void {
        const handler = self.handler orelse return;
        const context = self.handler_context orelse return;
        handler(context, event) catch |err| {
            // The app is about to terminate through `CallbackFailed`;
            // name the error that latched the failure (and, in builds
            // that carry one, its return trace) so the exit is
            // attributable instead of a bare CallbackFailed.
            std.debug.print("platform callback failed: {s} (event {s})\n", .{ @errorName(err), @tagName(event) });
            if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
            self.failed = true;
            if (self.self) |mac| native_sdk_appkit_stop(mac.host);
        };
    }
};

fn appkitCallback(context: ?*anyopaque, event: *const AppKitEvent) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    switch (event.kind) {
        .start => state.emit(.app_start),
        .frame => state.emit(.frame_requested),
        .shutdown => state.emit(.app_shutdown),
        .app_activated => state.emit(.app_activated),
        .app_deactivated => state.emit(.app_deactivated),
        .appearance_changed => state.emit(.{ .appearance_changed = .{
            .color_scheme = appKitColorScheme(event.color_scheme),
            .reduce_motion = event.reduce_motion != 0,
            .high_contrast = event.high_contrast != 0,
        } }),
        .resize => {
            const surface: platform_mod.Surface = .{
                .id = event.window_id,
                .size = geometry.SizeF.init(@floatCast(event.width), @floatCast(event.height)),
                .scale_factor = @floatCast(event.scale),
            };
            if (state.self) |mac| mac.surface_value = surface;
            state.emit(.{ .surface_resized = surface });
        },
        .window_frame => if (state.self) |mac| {
            const event_label = event.label[0..event.label_len];
            const window = if (event_label.len > 0)
                platform_mod.WindowOptions{ .id = event.window_id, .label = event_label, .title = mac.app_info.resolvedWindowTitle() }
            else
                mac.windowById(event.window_id);
            state.emit(.{ .window_frame_changed = .{
                .id = window.id,
                .label = window.label,
                .title = window.resolvedTitle(mac.app_info.app_name),
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
        .tray_command => state.emit(.{ .tray_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
            .status_item_id = event.status_item_id,
        } }),
        .notification_command => state.emit(.{ .notification_command = .{
            .name = event.command_name[0..event.command_name_len],
            .window_id = event.window_id,
        } }),
        .timer => state.emit(.{ .timer = .{
            .id = event.timer_id,
            .timestamp_ns = event.timestamp_ns,
        } }),
        .wake => state.emit(.wake),
        .files_dropped => {
            var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
            state.emit(.{ .files_dropped = fileDropEventFromAppKitEvent(event, paths_buffer[0..]) });
        },
        .gpu_surface_frame => state.emit(.{ .gpu_surface_frame = .{
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
            .backend = .metal,
            .pixel_format = .bgra8_unorm,
            .present_mode = .timer,
            .alpha_mode = .@"opaque",
            .color_space = .srgb,
            .vsync = true,
            .status = .ready,
        } }),
        .gpu_surface_resize => state.emit(.{ .gpu_surface_resized = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .frame = geometry.RectF.init(@floatCast(event.x), @floatCast(event.y), @floatCast(event.width), @floatCast(event.height)),
            .scale_factor = @floatCast(event.scale),
        } }),
        .gpu_surface_input => state.emit(.{ .gpu_surface_input = gpuSurfaceInputEventFromAppKitEvent(event) }),
        .gpu_surface_scroll_driver => state.emit(.{ .gpu_surface_scroll_driver = .{
            .window_id = event.window_id,
            .label = event.view_label[0..event.view_label_len],
            .driver_id = event.widget_id,
            .offset_x = @floatCast(event.scroll_driver_offset_x),
            .offset_y = @floatCast(event.scroll_driver_offset_y),
            .timestamp_ns = event.timestamp_ns,
        } }),
        .context_menu_action => state.emit(.{ .context_menu_action = .{
            .window_id = event.window_id,
            .view_label = event.view_label[0..event.view_label_len],
            .token = event.widget_id,
            .item_id = event.menu_item_id,
        } }),
        .audio => state.emit(.{ .audio = .{
            .kind = audioEventKindFromInt(event.audio_kind),
            .position_ms = event.audio_position_ms,
            .duration_ms = event.audio_duration_ms,
            .playing = event.audio_playing != 0,
            .buffering = event.audio_buffering != 0,
            .bands = event.audio_bands,
        } }),
        .video => state.emit(.{ .video = .{
            .kind = videoEventKindFromInt(event.video_kind),
            .token = event.video_token,
            .position_ms = event.video_position_ms,
            .duration_ms = event.video_duration_ms,
            .playing = event.video_playing != 0,
            .buffering = event.video_buffering != 0,
            .width = event.video_width,
            .height = event.video_height,
        } }),
        .widget_accessibility_action => if (widgetAccessibilityActionFromInt(event.widget_action)) |action| {
            state.emit(.{ .widget_accessibility_action = .{
                .window_id = event.window_id,
                .label = event.view_label[0..event.view_label_len],
                .id = event.widget_id,
                .action = action,
                .text = appKitEventBytes(event.widget_text, event.widget_text_len),
                .selection = widgetAccessibilitySelectionFromAppKitEvent(event),
            } });
        },
    }
}

fn appKitColorScheme(value: c_int) platform_mod.ColorScheme {
    return switch (value) {
        1 => .dark,
        else => .light,
    };
}

fn appkitBridgeCallback(context: ?*anyopaque, window_id: u64, webview_label: [*]const u8, webview_label_len: usize, message: [*]const u8, message_len: usize, origin: [*]const u8, origin_len: usize) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .bridge_message = .{
        .bytes = message[0..message_len],
        .origin = origin[0..origin_len],
        .window_id = window_id,
        .webview_label = webview_label[0..webview_label_len],
    } });
}

/// Ordinals match `native_sdk_appkit_audio_event_kind_t` in
/// appkit_host.h; anything unknown degrades to `.failed` so a host/SDK
/// skew is loud in the app instead of undefined behavior here.
fn audioEventKindFromInt(value: c_int) platform_mod.AudioEventKind {
    return switch (value) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        4 => .spectrum,
        else => .failed,
    };
}

/// Ordinals match `native_sdk_appkit_video_event_kind_t` in
/// appkit_host.h; anything unknown degrades to `.failed` so a host/SDK
/// skew is loud in the app instead of undefined behavior here.
fn videoEventKindFromInt(value: c_int) platform_mod.VideoEventKind {
    return switch (value) {
        0 => .loaded,
        1 => .position,
        2 => .completed,
        else => .failed,
    };
}

fn gpuSurfaceInputEventFromAppKitEvent(event: *const AppKitEvent) platform_mod.GpuSurfaceInputEvent {
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
        // The pinch magnification delta rides the ABI event's `scale`
        // field (zero on every non-pinch input emission).
        .scale = @floatCast(event.scale),
    };
}

fn fileDropEventFromAppKitEvent(event: *const AppKitEvent, paths_buffer: [][]const u8) platform_mod.FileDropEvent {
    return .{
        .window_id = event.window_id,
        .view_label = appKitEventBytes(event.view_label, event.view_label_len),
        // AppKit's system host converts every accepted drop to the same
        // top-left-origin view space as gpu-surface input before emitting.
        .point = geometry.PointF.init(@floatCast(event.x), @floatCast(event.y)),
        .paths = platform_mod.splitDropPaths(appKitEventBytes(event.drop_paths, event.drop_paths_len), paths_buffer),
    };
}

fn readClipboard(context: ?*anyopaque, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_clipboard_read(self.host, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

/// CoreText-backed text measurement matching `NativeSdkPacketDrawText`'s
/// font resolution. Negative host results (invalid UTF-8) are surfaced as
/// negative so the canvas provider falls back to its estimator.
/// Headless text services for session replay: the SAME CoreText
/// measurement, canvas-font registration, and bundled-font activation a
/// live host performs, with no window and no run loop — so a journal
/// recorded against this host measures (and therefore lays out and
/// renders) identically under a headless replay on the same platform.
pub fn installHeadlessTextServices(services: *platform_mod.PlatformServices) void {
    native_sdk_appkit_register_bundled_fonts();
    services.measure_text_fn = measureText;
    services.measure_text_advances_fn = measureTextAdvances;
    services.measure_text_ink_fn = measureTextInk;
    services.register_gpu_surface_font_fn = registerGpuSurfaceFont;
    services.unregister_gpu_surface_font_fn = unregisterGpuSurfaceFont;
}

/// Headless image codec for session replay: the SAME CGImageSource
/// decode a live host serves (see `decodeImage` below — a context-free
/// bytes-to-pixels call, no window, no run loop), so journaled image
/// bytes re-register the identical pixels under a headless replay on
/// the same platform.
pub fn installHeadlessImageCodec(services: *platform_mod.PlatformServices) void {
    services.decode_image_fn = decodeImage;
}

fn measureText(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8) f32 {
    _ = context;
    return @floatCast(native_sdk_appkit_measure_text(font_id, size, text.ptr, text.len));
}

/// Batched CoreText measurement: per-cluster advances for the whole run
/// in one host call (see the layout contract on the platform service).
/// A zero host answer (invalid UTF-8, unresolvable font) surfaces as
/// false so the canvas seam keeps its per-prefix path for that run.
fn measureTextAdvances(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, advances: []f32) bool {
    _ = context;
    if (text.len == 0) return true;
    if (advances.len < text.len) return false;
    return native_sdk_appkit_measure_text_advances(font_id, size, text.ptr, text.len, advances.ptr) == 1;
}

fn measureTextInk(context: ?*anyopaque, font_id: u64, size: f32, text: []const u8, metrics: *canvas.TextInkMetrics) bool {
    _ = context;
    if (text.len == 0) return false;
    var min_x: f64 = 0;
    var max_x: f64 = 0;
    var min_y: f64 = 0;
    var max_y: f64 = 0;
    if (native_sdk_appkit_measure_text_ink(font_id, size, text.ptr, text.len, &min_x, &max_x, &min_y, &max_y) != 1) return false;
    metrics.* = .{
        .min_x = @floatCast(min_x),
        .max_x = @floatCast(max_x),
        .min_y = @floatCast(min_y),
        .max_y = @floatCast(max_y),
    };
    return true;
}

/// System image decoding (ImageIO raster codecs plus NSImage's SVG
/// rasterizer) into straight-alpha RGBA8.
fn decodeImage(context: ?*anyopaque, bytes: []const u8, buffer: []u8, max_pixels: usize) anyerror!platform_mod.DecodedImage {
    _ = context;
    var width: usize = 0;
    var height: usize = 0;
    return switch (native_sdk_appkit_decode_image(bytes.ptr, bytes.len, buffer.ptr, buffer.len, max_pixels, &width, &height)) {
        1 => .{ .width = width, .height = height, .rgba8 = buffer[0 .. width * height * 4] },
        -1 => error.ImageTooLarge,
        else => error.ImageDecodeFailed,
    };
}

test "mac packet text keeps mixed-face runs on the engine baseline" {
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    var regular_offset: f64 = 0;
    var mono_offset: f64 = 0;
    var compact_regular_offset: f64 = 0;
    var compact_mono_offset: f64 = 0;
    var old_regular_first: c_int = -1;
    var old_mono_first: c_int = -1;
    var fixed_regular_first: c_int = -1;
    var fixed_mono_first: c_int = -1;
    var wrapped_regular_first: c_int = -1;
    var wrapped_mono_first: c_int = -1;
    var compact_regular_first: c_int = -1;
    var compact_mono_first: c_int = -1;
    var fallback_first: c_int = -1;
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_test_appkit_text_baselines(
        canvas.font_ttf.geist_regular_bytes.ptr,
        canvas.font_ttf.geist_regular_bytes.len,
        canvas.font_ttf.geist_mono_bytes.ptr,
        canvas.font_ttf.geist_mono_bytes.len,
        14.5,
        40,
        &regular_offset,
        &mono_offset,
        &compact_regular_offset,
        &compact_mono_offset,
        &old_regular_first,
        &old_mono_first,
        &fixed_regular_first,
        &fixed_mono_first,
        &wrapped_regular_first,
        &wrapped_mono_first,
        &compact_regular_first,
        &compact_mono_first,
        &fallback_first,
    ));

    // The fixtures genuinely exercise different line-fragment metrics,
    // and the former point-size conversion visibly split their ink rows.
    try std.testing.expectEqual(@as(f64, 13), regular_offset);
    try std.testing.expectEqual(@as(f64, 15), mono_offset);
    try std.testing.expect(old_regular_first != old_mono_first);

    // Explicit line heights smaller than the font box validly place the
    // first baseline above TextKit's container origin. Those negative
    // offsets must not be replaced by the face-dependent ascent fallback.
    try std.testing.expect(compact_regular_offset < 0);
    try std.testing.expect(compact_mono_offset < 0);

    // Both the engine-measured-line path and the rare host-wrapping fallback
    // now place the identical cap outline on one shared engine baseline.
    try std.testing.expectEqual(fixed_regular_first, fixed_mono_first);
    try std.testing.expectEqual(fixed_regular_first, wrapped_regular_first);
    try std.testing.expectEqual(fixed_regular_first, wrapped_mono_first);
    try std.testing.expectEqual(fixed_regular_first, compact_regular_first);
    try std.testing.expectEqual(fixed_regular_first, compact_mono_first);
    try std.testing.expectEqual(fixed_regular_first, fallback_first);
}

test "mac image decoder keeps ImageIO thumbnail rounding inside the pixel cap" {
    // The Objective-C probe is compiled and linked only for macOS test
    // artifacts (build.zig's target-gated image_fit_test.m source). Keep
    // every other host from referencing its symbol at link time.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    // ImageIO derives the minor dimension from ThumbnailMaxPixelSize and
    // rounds it. 537x503 at the default 262,144-pixel target used to ask
    // for a 529px major side and return 529x496 = 262,384 pixels, which
    // the runtime correctly rejected as ImageTooLarge. The host must leave
    // enough headroom for that platform rounding before it asks ImageIO.
    const source_width: usize = 537;
    const source_height: usize = 503;
    const source_pixels = try std.testing.allocator.alloc(u8, source_width * source_height * 4);
    defer std.testing.allocator.free(source_pixels);
    var offset: usize = 0;
    while (offset < source_pixels.len) : (offset += 4) {
        source_pixels[offset..][0..4].* = .{ 23, 91, 177, 255 };
    }

    const encoded_len = try canvas.png.encodedRgba8ByteLen(source_width, source_height);
    const encoded = try std.testing.allocator.alloc(u8, encoded_len);
    defer std.testing.allocator.free(encoded);
    var writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&writer, source_width, source_height, source_pixels);

    const max_pixels: usize = 512 * 512;
    var decoded_width: usize = 0;
    var decoded_height: usize = 0;
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_test_imageio_thumbnail_dimensions(
        writer.buffered().ptr,
        writer.buffered().len,
        source_width,
        source_height,
        max_pixels,
        &decoded_width,
        &decoded_height,
    ));
    try std.testing.expect(decoded_width > 0 and decoded_height > 0);
    try std.testing.expect(decoded_width * decoded_height <= max_pixels);

    // A source panorama may exceed the decoded-axis ceiling. The host must
    // request a bounded thumbnail instead of rejecting the source metadata.
    const panorama_width = platform_mod.max_decoded_image_dimension + 1;
    const panorama_pixels = try std.testing.allocator.alloc(u8, panorama_width * 4);
    defer std.testing.allocator.free(panorama_pixels);
    offset = 0;
    while (offset < panorama_pixels.len) : (offset += 4) {
        panorama_pixels[offset..][0..4].* = .{ 47, 113, 191, 255 };
    }
    const panorama_encoded_len = try canvas.png.encodedRgba8ByteLen(panorama_width, 1);
    const panorama_encoded = try std.testing.allocator.alloc(u8, panorama_encoded_len);
    defer std.testing.allocator.free(panorama_encoded);
    var panorama_writer = std.Io.Writer.fixed(panorama_encoded);
    try canvas.png.writeRgba8(&panorama_writer, panorama_width, 1, panorama_pixels);

    decoded_width = 0;
    decoded_height = 0;
    try std.testing.expectEqual(@as(c_int, 1), native_sdk_test_imageio_thumbnail_dimensions(
        panorama_writer.buffered().ptr,
        panorama_writer.buffered().len,
        panorama_width,
        1,
        max_pixels,
        &decoded_width,
        &decoded_height,
    ));
    try std.testing.expect(decoded_width <= platform_mod.max_decoded_image_dimension);
    try std.testing.expect(decoded_height > 0);
    try std.testing.expect(decoded_width * decoded_height <= max_pixels);
}

fn writeClipboard(context: ?*anyopaque, text: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_clipboard_write(self.host, text.ptr, text.len);
}

fn readClipboardData(context: ?*anyopaque, mime_type: []const u8, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_clipboard_read_data(self.host, mime_type.ptr, mime_type.len, buffer.ptr, buffer.len);
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn writeClipboardData(context: ?*anyopaque, data: platform_mod.ClipboardData) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_clipboard_write_data(self.host, data.mime_type.ptr, data.mime_type.len, data.bytes.ptr, data.bytes.len) == 0) return error.UnsupportedService;
}

fn loadWebView(context: ?*anyopaque, source: platform_mod.WebViewSource) anyerror!void {
    try loadWindowWebView(context, 1, source);
}

fn loadWindowWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, source: platform_mod.WebViewSource) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const assets: platform_mod.WebViewAssetSource = source.asset_options orelse .{ .root_path = "", .entry = "", .origin = "", .spa_fallback = false };
    native_sdk_appkit_load_window_webview(
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
}

fn completeBridge(context: ?*anyopaque, response: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond(self.host, response.ptr, response.len);
}

fn completeWindowBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, response: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond_window(self.host, window_id, response.ptr, response.len);
}

fn completeWebViewBridge(context: ?*anyopaque, window_id: platform_mod.WindowId, webview_label: []const u8, response: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_bridge_respond_webview(self.host, window_id, webview_label.ptr, webview_label.len, response.ptr, response.len);
}

fn emitWindowEvent(context: ?*anyopaque, window_id: platform_mod.WindowId, name: []const u8, detail_json: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_emit_window_event(self.host, window_id, name.ptr, name.len, detail_json.ptr, detail_json.len);
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

fn refuseUnsupportedTransparentWindow(web_engine: platform_mod.WebEngine, options: platform_mod.WindowOptions) Error!void {
    if (web_engine == .chromium and options.transparent) return error.UnsupportedWindowTransparency;
}

fn closePolicyInt(policy: platform_mod.WindowClosePolicy) c_int {
    return switch (policy) {
        .quit => 0,
        .hide => 1,
    };
}

/// Register a window's declared close policy with the host, right
/// after create (the min-size-floor pattern: close handling is host
/// window state fixed for the window's life). `.quit` skips the call —
/// it IS the host default.
fn applyWindowClosePolicy(host: *AppKitHost, window_id: u64, policy: platform_mod.WindowClosePolicy) void {
    if (policy == .quit) return;
    _ = native_sdk_appkit_set_window_close_policy(host, window_id, closePolicyInt(policy));
}

/// Apply a declared content min-size floor to a created window
/// (AppKit `contentMinSize`). Zero/negative/non-finite floors are the
/// "no floor" sentinel and skip the call — the window keeps AppKit's
/// default minimum.
fn applyWindowContentMinSize(host: *AppKitHost, window_id: u64, min_width: f32, min_height: f32) void {
    const width: f64 = if (std.math.isFinite(min_width) and min_width > 0) min_width else 0;
    const height: f64 = if (std.math.isFinite(min_height) and min_height > 0) min_height else 0;
    if (width <= 0 and height <= 0) return;
    _ = native_sdk_appkit_set_window_content_min_size(host, window_id, width, height);
}

fn createWindow(context: ?*anyopaque, options: platform_mod.WindowOptions) anyerror!platform_mod.WindowInfo {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    try refuseUnsupportedTransparentWindow(self.web_engine, options);
    const title = options.resolvedTitle(self.app_info.app_name);
    const frame = options.default_frame;
    if (native_sdk_appkit_create_window(self.host, options.id, title.ptr, title.len, options.label.ptr, options.label.len, frame.x, frame.y, frame.width, frame.height, if (options.restore_state) 1 else 0, initialPlacementInt(options.initial_placement), restorePolicyInt(options.restore_policy), if (options.resizable) 1 else 0, titlebarStyleInt(options.titlebar), showModeInt(options.show), windowFlags(options)) == 0) return error.CreateFailed;
    applyWindowContentMinSize(self.host, options.id, options.min_width, options.min_height);
    applyWindowClosePolicy(self.host, options.id, options.close_policy);
    return .{
        .id = options.id,
        .label = options.label,
        .title = title,
        // Placement can alter the origin synchronously in AppKit; the host's
        // window_frame_changed event reports that actual frame immediately
        // after startup/create and replaces this requested-frame placeholder.
        .frame = frame,
        .scale_factor = 1,
        .open = true,
        .focused = options.activate_on_show and options.show == .immediate,
        .hidden = options.show == .hidden,
    };
}

fn focusWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_focus_window(self.host, window_id) == 0) return error.FocusFailed;
}

fn closeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_close_window(self.host, window_id) == 0) return error.CloseFailed;
}

fn minimizeWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_minimize_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn hideWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_hide_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn showWindow(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_show_window(self.host, window_id) == 0) return error.WindowNotFound;
}

fn setDockPresence(context: ?*anyopaque, visible: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_dock_presence(self.host, if (visible) 1 else 0) == 0) return error.UnsupportedService;
}

fn launchAtLoginStatus(context: ?*anyopaque) anyerror!platform_mod.LaunchAtLoginStatus {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    return launchAtLoginStatusFromInt(native_sdk_appkit_launch_at_login_status(self.host));
}

fn setLaunchAtLogin(context: ?*anyopaque, enabled: bool) anyerror!platform_mod.LaunchAtLoginStatus {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    return launchAtLoginStatusFromInt(native_sdk_appkit_set_launch_at_login(self.host, if (enabled) 1 else 0));
}

fn launchAtLoginStatusFromInt(value: c_int) anyerror!platform_mod.LaunchAtLoginStatus {
    return switch (value) {
        0 => .disabled,
        1 => .enabled,
        2 => .requires_approval,
        3 => .not_found,
        -1 => error.UnsupportedService,
        else => error.LaunchAtLoginFailed,
    };
}

/// The graceful quit: the same emitShutdown + stop the last-window
/// close runs, ALWAYS deferred past the dispatch that requested it —
/// this verb arrives mid dispatch (the command whose update returned
/// it is still being dispatched), and `app_shutdown` must emit only
/// after that dispatch returns, or a recording session seals its
/// journal before the requesting command commits (the command record
/// is lost and replay diverges). While the run loop is live the host
/// queues one loop turn; before [NSApp run] (a quit from App.start's
/// update, or from a boot command during the synchronous first canvas
/// frame) it parks the request and drains it at top level — never the
/// inline emit `native_sdk_appkit_stop` keeps for the host-side
/// failed-START request.
fn quitApp(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_request_stop(self.host);
}

fn startWindowDrag(context: ?*anyopaque, window_id: platform_mod.WindowId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_start_window_drag(self.host, window_id) == 0) return error.WindowNotFound;
}

fn windowChrome(context: ?*anyopaque, window_id: platform_mod.WindowId) platform_mod.WindowChrome {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var top: f64 = 0;
    var left: f64 = 0;
    var bottom: f64 = 0;
    var right: f64 = 0;
    var buttons_x: f64 = 0;
    var buttons_y: f64 = 0;
    var buttons_width: f64 = 0;
    var buttons_height: f64 = 0;
    if (native_sdk_appkit_window_chrome_insets(self.host, window_id, &top, &left, &bottom, &right, &buttons_x, &buttons_y, &buttons_width, &buttons_height) == 0) return .{};
    return .{
        .insets = .{
            .top = @floatCast(top),
            .left = @floatCast(left),
            .bottom = @floatCast(bottom),
            .right = @floatCast(right),
        },
        .buttons = geometry.RectF.init(
            @floatCast(buttons_x),
            @floatCast(buttons_y),
            @floatCast(buttons_width),
            @floatCast(buttons_height),
        ),
    };
}

fn createView(context: ?*anyopaque, options: platform_mod.ViewOptions) anyerror!void {
    if (options.kind == .webview) return createWebView(context, options.webViewOptions());
    if (!isSupportedNativeViewKind(options.kind)) return error.UnsupportedViewKind;
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = options.frame;
    const parent = options.parent orelse "";
    if (native_sdk_appkit_create_view(
        self.host,
        options.window_id,
        options.label.ptr,
        options.label.len,
        viewKindInt(options.kind),
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const frame = patch.frame orelse geometry.RectF.init(0, 0, 0, 0);
    const role = patch.role orelse "";
    const accessibility_label = patch.accessibility_label orelse "";
    const text = patch.text orelse "";
    const command = patch.command orelse "";
    if (native_sdk_appkit_update_view(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.ViewNotFound;
}

fn setViewVisible(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, visible: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_visible(self.host, window_id, label.ptr, label.len, if (visible) 1 else 0) == 0) return error.ViewNotFound;
}

fn setViewCursor(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, cursor: platform_mod.Cursor) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_set_view_cursor(self.host, window_id, label.ptr, label.len, appKitCursor(cursor)) == 0) return error.ViewNotFound;
}

fn focusView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewFocus;
    if (native_sdk_appkit_focus_view(self.host, window_id, label.ptr, label.len) == 0) return error.UnsupportedViewFocus;
}

fn closeView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (native_sdk_appkit_close_view(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn adoptViewSurface(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, surface_handle: *anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_adopt_view_surface(self.host, window_id, label.ptr, label.len, surface_handle) == 0) return error.ViewNotFound;
}

fn releaseViewSurface(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_release_view_surface(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn startTimer(context: ?*anyopaque, id: u64, interval_ns: u64, repeats: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_start_timer(self.host, id, interval_ns, if (repeats) 1 else 0);
}

fn cancelTimer(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_cancel_timer(self.host, id);
}

/// Map the audio host's synchronous load result: 0 loaded, 1 the file is
/// missing/unreadable, anything else a decode failure. The asynchronous
/// `.loaded` acknowledgment (with the decoded duration) follows as an
/// `.audio` event on the run loop.
fn audioLoad(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_appkit_audio_load(self.host, path.ptr, path.len)) {
        0 => {},
        1 => error.AudioSourceNotFound,
        else => error.AudioDecodeFailed,
    };
}

/// Map the streaming host's synchronous result: 1 a verified cache
/// entry is playing locally, 0 a progressive stream started (the
/// `.loaded` acknowledgment follows when the item is ready), anything
/// else the URL itself was unusable. Network failures after this point
/// are asynchronous and arrive as `.audio`/`.failed` events.
fn audioLoadUrl(context: ?*anyopaque, url: []const u8, cache_path: []const u8, expected_bytes: u64) anyerror!platform_mod.AudioLoadResolution {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    return switch (native_sdk_appkit_audio_load_url(self.host, url.ptr, url.len, cache_path.ptr, cache_path.len, expected_bytes)) {
        0 => .stream,
        1 => .cache,
        else => error.InvalidAudioOptions,
    };
}

fn audioPlay(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_audio_play(self.host) == 0) return error.InvalidAudioOptions;
}

fn audioPause(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_pause(self.host);
}

fn audioStop(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_stop(self.host);
}

fn audioSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_audio_seek(self.host, position_ms) == 0) return error.InvalidAudioOptions;
}

fn audioSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_set_volume(self.host, volume);
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const stored = &self.audio_capture_sinks[@intFromEnum(source)];
    // The native stop is a synchronous callback fence. Quiesce the old
    // producer before replacing the memory its callback context points at;
    // otherwise a final old-source callback can be delivered to the new sink.
    _ = native_sdk_appkit_audio_capture_stop(self.host, @intFromEnum(source));
    stored.* = sink;
    if (native_sdk_appkit_audio_capture_start(self.host, @intFromEnum(source), format.sample_rate, format.channels, nativeSdkAudioCapturePush, stored) == 0) {
        stored.* = .{};
        return error.AudioCaptureStartFailed;
    }
}

fn audioCaptureStop(context: ?*anyopaque, source: platform_mod.AudioCaptureSource) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_audio_capture_stop(self.host, @intFromEnum(source));
    self.audio_capture_sinks[@intFromEnum(source)] = .{};
}

/// The C-callable bridge for `VideoFrameSink.push`: the sink's `push_fn`
/// is a Zig-calling-convention error-union fn the host cannot invoke, so
/// the host is handed this trampoline (context = the `MacPlatform`) and
/// it forwards through the platform's current sink. Answers 0 accepted,
/// 1 when the claim reports `error.MediaSurfaceReleased` (the host stops
/// its frame timer — a released claim just means stop pushing), 2 for
/// any other refusal (one dropped frame; latest-wins).
fn nativeSdkVideoSinkPush(context: ?*anyopaque, width: usize, height: usize, pixels: [*c]const u8, len: usize) callconv(.c) c_int {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    self.video_sink.push(width, height, pixels[0..len]) catch |err| {
        return if (err == error.MediaSurfaceReleased) 1 else 2;
    };
    return 0;
}

/// Map the video host's synchronous load result: 0 loaded, 1 the file is
/// missing/unreadable, anything else a decode failure. The asynchronous
/// `.loaded` acknowledgment (with the stream's dimensions and duration)
/// follows as a `.video` event on the run loop; decoded frames flow
/// through the sink stored on the platform (see `nativeSdkVideoSinkPush`).
fn videoLoad(context: ?*anyopaque, path: []const u8, token: u64, sink: platform_mod.VideoFrameSink) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    self.video_sink = sink;
    return switch (native_sdk_appkit_video_load(self.host, path.ptr, path.len, token, nativeSdkVideoSinkPush, self)) {
        0 => {},
        1 => error.VideoSourceNotFound,
        else => error.VideoDecodeFailed,
    };
}

/// Map the streaming host's synchronous result: 0 a progressive stream
/// started (the `.loaded` acknowledgment follows when the item is
/// ready), anything else the URL itself was unusable. Network failures
/// after this point are asynchronous and arrive as `.video`/`.failed`
/// events.
fn videoLoadUrl(context: ?*anyopaque, url: []const u8, token: u64, sink: platform_mod.VideoFrameSink) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    self.video_sink = sink;
    return switch (native_sdk_appkit_video_load_url(self.host, url.ptr, url.len, token, nativeSdkVideoSinkPush, self)) {
        0 => {},
        else => error.InvalidVideoOptions,
    };
}

fn videoPlay(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_video_play(self.host) == 0) return error.InvalidVideoOptions;
}

fn videoPause(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_video_pause(self.host);
}

fn videoStop(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_video_stop(self.host);
    self.video_sink = .{};
}

fn videoSeek(context: ?*anyopaque, position_ms: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_video_seek(self.host, position_ms) == 0) return error.InvalidVideoOptions;
}

fn videoSetVolume(context: ?*anyopaque, volume: f32) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_video_set_volume(self.host, volume);
}

fn videoSetMuted(context: ?*anyopaque, muted: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_video_set_muted(self.host, if (muted) 1 else 0);
}

fn videoSetLoop(context: ?*anyopaque, loop: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    _ = native_sdk_appkit_video_set_loop(self.host, if (loop) 1 else 0);
}

/// Thread-safe: dispatches onto the main queue (`dispatch_async` — the
/// enqueue-only shape the wake contract requires), which emits `.wake`
/// on the AppKit run loop. One of the two services worker threads may
/// call.
fn wake(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_wake(self.host);
}

/// Teardown abandoned an in-flight channel wake call: latch the flag
/// `deinit` consults so this host is leaked rather than destroyed (see
/// `MacPlatform.channel_wake_abandoned`).
fn noteChannelWakeAbandoned(context: ?*anyopaque) void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    self.channel_wake_abandoned.store(true, .seq_cst);
}

/// Thread-safe like `wake`: dispatches onto the main queue, which emits
/// one coalesced `frame` event on the AppKit run loop. The automation
/// arrival watcher calls this when a command lands so an idle app runs
/// the frame that drains it — no timers involved, so the wake works even
/// when the app is backgrounded and its timers are being coalesced.
fn requestFrame(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_request_frame(self.host);
}

fn requestGpuSurfaceFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_request_gpu_surface_frame(self.host, window_id, label.ptr, label.len) == 0) return error.ViewNotFound;
}

fn noteGpuSurfaceInput(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return;
    _ = native_sdk_appkit_note_gpu_surface_input(self.host, window_id, label.ptr, label.len);
}

fn setGpuSurfaceScrollDrivers(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, drivers: []const platform_mod.GpuSurfaceScrollDriver, occluders: []const platform_mod.GpuSurfaceScrollOccluder) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    var specs: [platform_mod.max_gpu_surface_scroll_drivers]AppKitScrollDriver = undefined;
    const count = @min(drivers.len, specs.len);
    for (drivers[0..count], 0..) |driver, index| {
        specs[index] = .{
            .driver_id = driver.id,
            .parent_driver_id = driver.parent_id,
            .occluder_mask = driver.occluder_mask,
            .x = driver.frame.x,
            .y = driver.frame.y,
            .width = driver.frame.width,
            .height = driver.frame.height,
            .content_width = driver.content_size.width,
            .content_height = driver.content_size.height,
            .offset_x = driver.offset_x,
            .offset_y = driver.offset_y,
            .set_offset_x = if (driver.set_offset_x) 1 else 0,
            .set_offset_y = if (driver.set_offset_y) 1 else 0,
            .rubber_band = if (driver.rubber_band) 1 else 0,
            .scrolls_x = if (driver.scrolls_x) 1 else 0,
            .scrolls_y = if (driver.scrolls_y) 1 else 0,
        };
    }
    var occluder_specs: [platform_mod.max_gpu_surface_scroll_occluders]AppKitScrollOccluder = undefined;
    const occluder_count = @min(occluders.len, occluder_specs.len);
    for (occluders[0..occluder_count], 0..) |occluder, index| {
        occluder_specs[index] = .{
            .x = occluder.frame.x,
            .y = occluder.frame.y,
            .width = occluder.frame.width,
            .height = occluder.frame.height,
        };
    }
    if (native_sdk_appkit_set_gpu_surface_scroll_drivers(self.host, window_id, label.ptr, label.len, &specs, count, &occluder_specs, occluder_count) == 0) return error.ViewNotFound;
}

fn showContextMenu(context: ?*anyopaque, request: platform_mod.ContextMenuRequest) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var items: [platform_mod.max_context_menu_items]AppKitContextMenuItem = undefined;
    const count = @min(request.items.len, items.len);
    for (request.items[0..count], 0..) |item, index| {
        items[index] = .{
            .item_id = item.id,
            .label = item.label.ptr,
            .label_len = item.label.len,
            .enabled = if (item.enabled) 1 else 0,
            .separator = if (item.separator) 1 else 0,
        };
    }
    if (native_sdk_appkit_show_context_menu(
        self.host,
        request.window_id,
        request.view_label.ptr,
        request.view_label.len,
        request.point.x,
        request.point.y,
        request.token,
        &items,
        count,
    ) == 0) return error.WindowNotFound;
}

fn presentGpuSurfacePixels(context: ?*anyopaque, pixels: platform_mod.GpuSurfacePixels) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    const dirty_bounds = if (pixels.dirty_bounds) |bounds| bounds.normalized() else geometry.RectF{};
    if (native_sdk_appkit_present_gpu_surface_pixels(
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

fn presentGpuSurfacePacket(context: ?*anyopaque, packet: platform_mod.GpuSurfacePacket) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const result = native_sdk_appkit_present_gpu_surface_packet(
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
        packet.json.ptr,
        packet.json.len,
    );
    switch (result) {
        1 => return,
        0 => return error.UnsupportedService,
        -1 => return error.ViewNotFound,
        else => return error.InvalidGpuSurfacePacket,
    }
}

/// Compact binary twin of `presentGpuSurfacePacket`: identical result
/// contract (0 = refused, which the runtime answers by retrying the
/// JSON encoding in the same frame before its pixel fallback).
fn presentGpuSurfacePacketBinary(context: ?*anyopaque, packet: platform_mod.GpuSurfacePacket) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    const result = native_sdk_appkit_present_gpu_surface_packet_binary(
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
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_upload_gpu_surface_image(
        self.host,
        image.id,
        image.width,
        image.height,
        image.rgba8.ptr,
        image.rgba8.len,
    ) == 0) return error.InvalidGpuSurfaceImage;
}

fn removeGpuSurfaceImage(context: ?*anyopaque, id: u64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedService;
    if (native_sdk_appkit_remove_gpu_surface_image(self.host, id) == 0) return error.InvalidGpuSurfaceImage;
}

/// Registered canvas fonts feed the host's single font-resolution seam
/// (measurement AND packet text drawing), which exists on both web
/// engines, so this is deliberately not gated on `web_engine`. Returns
/// the registration's ownership token: the AppKit host mints one per
/// registration (font state there is per-process, so the token is what
/// lets teardown remove exactly this registration under a shared id);
/// the Chromium host retains no font state and reports 0 — nothing to
/// own, nothing for an unregister to remove.
fn registerGpuSurfaceFont(context: ?*anyopaque, font: platform_mod.GpuSurfaceFontData) anyerror!u64 {
    _ = context;
    var token: u64 = 0;
    if (native_sdk_appkit_register_font(font.id, font.ttf.ptr, font.ttf.len, &token) == 0) return error.InvalidGpuSurfaceFont;
    return token;
}

/// Teardown twin of the registration above: drop the host's per-id font
/// state (the CoreText descriptor and its caches) when the runtime that
/// registered the id deinits — but only while the id's current
/// registration still carries `token`, so an older runtime's deinit
/// never removes a face a newer runtime re-registered under the same
/// id. Same seam as registration, so deliberately not gated on
/// `web_engine` either; unregistering an id the host never saw, or with
/// a stale token, is a no-op accept.
fn unregisterGpuSurfaceFont(context: ?*anyopaque, id: u64, token: u64) anyerror!void {
    _ = context;
    if (native_sdk_appkit_unregister_font(id, token) == 0) return error.InvalidGpuSurfaceFont;
}

fn updateWidgetAccessibility(context: ?*anyopaque, snapshot: platform_mod.WidgetAccessibilitySnapshot) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (self.web_engine != .system) return error.UnsupportedViewKind;
    if (snapshot.nodes.len > platform_mod.max_widget_accessibility_nodes) return error.InvalidViewOptions;
    var nodes: [platform_mod.max_widget_accessibility_nodes]AppKitWidgetAccessibilityNode = undefined;
    for (snapshot.nodes, 0..) |node, index| {
        nodes[index] = .{
            .id = node.id,
            .parent_id = node.parent_id orelse 0,
            .role = @intFromEnum(node.role),
            .label = node.label.ptr,
            .label_len = node.label.len,
            .text_value = node.text_value.ptr,
            .text_value_len = node.text_value.len,
            .placeholder = node.placeholder.ptr,
            .placeholder_len = node.placeholder.len,
            .has_text_selection = if (node.text_selection != null) 1 else 0,
            .text_selection_start = if (node.text_selection) |range| range.start else 0,
            .text_selection_end = if (node.text_selection) |range| range.end else 0,
            .has_text_composition = if (node.text_composition != null) 1 else 0,
            .text_composition_start = if (node.text_composition) |range| range.start else 0,
            .text_composition_end = if (node.text_composition) |range| range.end else 0,
            .has_value = if (node.value != null) 1 else 0,
            .value = node.value orelse 0,
            .has_grid_row_index = if (node.grid_row_index != null) 1 else 0,
            .grid_row_index = node.grid_row_index orelse 0,
            .has_grid_column_index = if (node.grid_column_index != null) 1 else 0,
            .grid_column_index = node.grid_column_index orelse 0,
            .has_grid_row_count = if (node.grid_row_count != null) 1 else 0,
            .grid_row_count = node.grid_row_count orelse 0,
            .has_grid_column_count = if (node.grid_column_count != null) 1 else 0,
            .grid_column_count = node.grid_column_count orelse 0,
            .has_list_item_index = if (node.list_item_index != null) 1 else 0,
            .list_item_index = node.list_item_index orelse 0,
            .has_list_item_count = if (node.list_item_count != null) 1 else 0,
            .list_item_count = node.list_item_count orelse 0,
            .has_scroll_offset = if (node.scroll_offset != null) 1 else 0,
            .scroll_offset = node.scroll_offset orelse 0,
            .has_scroll_viewport_extent = if (node.scroll_viewport_extent != null) 1 else 0,
            .scroll_viewport_extent = node.scroll_viewport_extent orelse 0,
            .has_scroll_content_extent = if (node.scroll_content_extent != null) 1 else 0,
            .scroll_content_extent = node.scroll_content_extent orelse 0,
            .x = node.bounds.x,
            .y = node.bounds.y,
            .width = node.bounds.width,
            .height = node.bounds.height,
            .state_flags = widgetStateFlags(node),
            .action_flags = widgetActionFlags(node.actions),
        };
    }
    if (native_sdk_appkit_update_widget_accessibility(
        self.host,
        snapshot.window_id,
        snapshot.view_label.ptr,
        snapshot.view_label.len,
        nodes[0..snapshot.nodes.len].ptr,
        snapshot.nodes.len,
    ) == 0) return error.ViewNotFound;
}

fn widgetStateFlags(node: platform_mod.WidgetAccessibilityNode) u32 {
    var flags: u32 = 0;
    if (node.enabled) flags |= widget_state_enabled;
    if (node.focused) flags |= widget_state_focused;
    if (node.selected) flags |= widget_state_selected;
    if (node.pressed) flags |= widget_state_pressed;
    if (node.expanded) |expanded| {
        flags |= if (expanded) widget_state_expanded else widget_state_collapsed;
    }
    if (node.required) flags |= widget_state_required;
    if (node.read_only) flags |= widget_state_read_only;
    if (node.invalid) flags |= widget_state_invalid;
    if (node.can_undo) flags |= widget_state_can_undo;
    if (node.can_redo) flags |= widget_state_can_redo;
    return flags;
}

fn widgetActionFlags(actions: platform_mod.WidgetAccessibilityActions) u32 {
    var flags: u32 = 0;
    if (actions.focus) flags |= widget_action_focus;
    if (actions.press) flags |= widget_action_press;
    if (actions.toggle) flags |= widget_action_toggle;
    if (actions.increment) flags |= widget_action_increment;
    if (actions.decrement) flags |= widget_action_decrement;
    if (actions.set_text) flags |= widget_action_set_text;
    if (actions.set_selection) flags |= widget_action_set_selection;
    if (actions.select) flags |= widget_action_select;
    if (actions.drag) flags |= widget_action_drag;
    if (actions.drop_files) flags |= widget_action_drop_files;
    if (actions.dismiss) flags |= widget_action_dismiss;
    return flags;
}

fn appKitCursor(cursor: platform_mod.Cursor) c_int {
    return switch (cursor) {
        .arrow => 0,
        .pointing_hand => 1,
        .text => 2,
        .resize_horizontal => 3,
    };
}

fn createWebView(context: ?*anyopaque, options: platform_mod.WebViewOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const frame = options.frame;
    if (native_sdk_appkit_create_webview(self.host, options.window_id, options.label.ptr, options.label.len, options.url.ptr, options.url.len, frame.x, frame.y, frame.width, frame.height, options.layer, if (options.transparent) 1 else 0, if (options.bridge_enabled) 1 else 0) == 0) return error.CreateFailed;
}

fn setWebViewFrame(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, frame: geometry.RectF) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_frame(self.host, window_id, label.ptr, label.len, frame.x, frame.y, frame.width, frame.height) == 0) return error.WebViewNotFound;
}

fn navigateWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, url: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_navigate_webview(self.host, window_id, label.ptr, label.len, url.ptr, url.len) == 0) return error.WebViewNotFound;
}

fn setWebViewZoom(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, zoom: f64) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_zoom(self.host, window_id, label.ptr, label.len, zoom) == 0) return error.WebViewNotFound;
}

fn setWebViewLayer(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8, layer: i32) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_set_webview_layer(self.host, window_id, label.ptr, label.len, layer) == 0) return error.WebViewNotFound;
}

fn closeWebView(context: ?*anyopaque, window_id: platform_mod.WindowId, label: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_close_webview(self.host, window_id, label.ptr, label.len) == 0) return error.WebViewNotFound;
}

fn showNotification(context: ?*anyopaque, options: platform_mod.NotificationOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_show_notification(
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

fn setCredential(context: ?*anyopaque, credential: platform_mod.Credential) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const result = native_sdk_appkit_set_credential(
        self.host,
        credential.service.ptr,
        credential.service.len,
        credential.account.ptr,
        credential.account.len,
        credential.secret.ptr,
        credential.secret.len,
    );
    if (result == -2) return error.CredentialStoreLocked;
    if (result == -3) return error.AccessDenied;
    if (result <= 0) return error.CredentialStoreFailed;
}

fn getCredential(context: ?*anyopaque, key: platform_mod.CredentialKey, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_get_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
        buffer.ptr,
        buffer.len,
    );
    if (len == std.math.maxInt(usize)) return error.CredentialNotFound;
    if (len == std.math.maxInt(usize) - 2) return error.CredentialStoreLocked;
    if (len == std.math.maxInt(usize) - 3) return error.AccessDenied;
    if (len == std.math.maxInt(usize) - 1) return error.CredentialStoreFailed;
    if (len > buffer.len) return error.NoSpaceLeft;
    return buffer[0..len];
}

fn deleteCredential(context: ?*anyopaque, key: platform_mod.CredentialKey) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const result = native_sdk_appkit_delete_credential(
        self.host,
        key.service.ptr,
        key.service.len,
        key.account.ptr,
        key.account.len,
    );
    if (result == -2) return error.CredentialStoreLocked;
    if (result == -3) return error.AccessDenied;
    if (result < 0) return error.CredentialStoreFailed;
    if (result == 0) return error.CredentialNotFound;
}

fn formatLocalTime(context: ?*anyopaque, timestamp_ms: i64, style: platform_mod.LocalTimeStyle, buffer: []u8) anyerror![]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const len = native_sdk_appkit_format_local_time(self.host, timestamp_ms, @intFromEnum(style), buffer.ptr, buffer.len);
    if (len == 0 or len > buffer.len) return error.LocalTimeFormatFailed;
    return buffer[0..len];
}

fn openExternalUrl(context: ?*anyopaque, url: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_open_external_url(self.host, url.ptr, url.len) == 0) return error.UnsupportedService;
}

fn revealPath(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_reveal_path(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn addRecentDocument(context: ?*anyopaque, path: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_add_recent_document(self.host, path.ptr, path.len) == 0) return error.UnsupportedService;
}

fn clearRecentDocuments(context: ?*anyopaque) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_clear_recent_documents(self.host) == 0) return error.UnsupportedService;
}

fn checkForUpdates(context: ?*anyopaque, user_initiated: bool) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    if (native_sdk_appkit_check_for_updates(self.host, if (user_initiated) 1 else 0) == 0) return error.UnsupportedService;
}

fn configureSecurityPolicy(context: ?*anyopaque, policy: security.Policy) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var origins_buffer: [4096]u8 = undefined;
    var external_buffer: [4096]u8 = undefined;
    const origins = try policy_values.join(policy.navigation.allowed_origins, &origins_buffer);
    const external_urls = try policy_values.join(policy.navigation.external_links.allowed_urls, &external_buffer);
    native_sdk_appkit_set_security_policy(
        self.host,
        origins.ptr,
        origins.len,
        external_urls.ptr,
        external_urls.len,
        @intFromEnum(policy.navigation.external_links.action),
    );
}

fn configureMenus(context: ?*anyopaque, menus: []const platform_mod.Menu) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
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

    native_sdk_appkit_set_menus(
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
    );
}

fn configureShortcuts(context: ?*anyopaque, shortcuts: []const platform_mod.Shortcut) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
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
    native_sdk_appkit_set_shortcuts(self.host, ids[0..shortcuts.len].ptr, id_lens[0..shortcuts.len].ptr, keys[0..shortcuts.len].ptr, key_lens[0..shortcuts.len].ptr, modifiers[0..shortcuts.len].ptr, shortcuts.len);
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
        12 => .pinch_begin,
        13 => .pinch_change,
        14 => .pinch_end,
        else => .pointer_move,
    };
}

fn widgetAccessibilityActionFromInt(value: c_int) ?platform_mod.WidgetAccessibilityActionKind {
    return switch (value) {
        0 => .focus,
        1 => .press,
        2 => .toggle,
        3 => .increment,
        4 => .decrement,
        5 => .set_text,
        6 => .set_selection,
        7 => .select,
        8 => .drag,
        9 => .drop_files,
        10 => .dismiss,
        else => null,
    };
}

fn appKitEventBytes(bytes: [*]const u8, len: usize) []const u8 {
    if (len == 0 or @intFromPtr(bytes) == 0) return "";
    return bytes[0..len];
}

fn widgetAccessibilitySelectionFromAppKitEvent(event: *const AppKitEvent) ?platform_mod.WidgetAccessibilityTextRange {
    if (event.has_widget_text_selection == 0) return null;
    return .{
        .start = event.widget_text_selection_start,
        .end = event.widget_text_selection_end,
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

test "macos notification actions use process-scoped opaque tokens" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(
            u8,
            host_source,
            "NSString *actionToken = [NSUUID UUID].UUIDString;",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            host_source,
            "notification.userInfo = @{ @\"native-sdk-action-token\": actionToken };",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            host_source,
            "self.notificationActionCommands[token]",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            host_source,
            "@\"native-sdk-action-command\"",
        ) == null);
    }
}

test "macos supports native container and control kinds" {
    try std.testing.expect(isSupportedNativeViewKind(.split));
    try std.testing.expect(isSupportedNativeViewKind(.stack));
    try std.testing.expect(isSupportedNativeViewKind(.icon_button));
    try std.testing.expect(isSupportedNativeViewKind(.list_item));
    try std.testing.expect(isSupportedNativeViewKind(.gpu_surface));
}

test "macos chromium reports unsupported native surfaces" {
    var system = testPlatformWithEngine(.system);
    try std.testing.expect(MacPlatform.supportsFeature(&system, .native_views));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .native_control_commands));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .menus));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .gpu_surfaces));
    try std.testing.expect(MacPlatform.supportsFeature(&system, .view_surface_adoption));

    var chromium = testPlatformWithEngine(.chromium);
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .main_webview));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .child_webviews));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .tray));
    try std.testing.expect(MacPlatform.supportsFeature(&chromium, .shortcuts));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .native_views));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .native_control_commands));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .menus));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .file_drops));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .gpu_surfaces));
    try std.testing.expect(!MacPlatform.supportsFeature(&chromium, .view_surface_adoption));
}

test "macos chromium refuses transparent windows" {
    try refuseUnsupportedTransparentWindow(.system, .{ .transparent = true });
    try refuseUnsupportedTransparentWindow(.chromium, .{});
    try std.testing.expectError(
        error.UnsupportedWindowTransparency,
        refuseUnsupportedTransparentWindow(.chromium, .{ .transparent = true }),
    );

    const host_source = @embedFile("cef_host.mm");
    try std.testing.expect(std.mem.count(
        u8,
        host_source,
        "if ((window_flags & (1u << 0)) != 0) return",
    ) >= 2);
}

fn testPlatformWithEngine(web_engine: platform_mod.WebEngine) MacPlatform {
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

fn showOpenDialog(context: ?*anyopaque, options: platform_mod.OpenDialogOptions, buffer: []u8) anyerror!platform_mod.OpenDialogResult {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = AppKitOpenDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
        .allow_directories = if (options.allow_directories) 1 else 0,
        .allow_multiple = if (options.allow_multiple) 1 else 0,
    };
    const result = native_sdk_appkit_show_open_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (result.bytes_written > buffer.len) return error.NoSpaceLeft;
    return .{
        .count = result.count,
        .paths = buffer[0..result.bytes_written],
    };
}

fn showSaveDialog(context: ?*anyopaque, options: platform_mod.SaveDialogOptions, buffer: []u8) anyerror!?[]const u8 {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var ext_buf: [1024]u8 = undefined;
    const ext_str = flattenFilters(options.filters, &ext_buf);
    const opts = AppKitSaveDialogOpts{
        .title = options.title.ptr,
        .title_len = options.title.len,
        .default_path = options.default_path.ptr,
        .default_path_len = options.default_path.len,
        .default_name = options.default_name.ptr,
        .default_name_len = options.default_name.len,
        .extensions = ext_str.ptr,
        .extensions_len = ext_str.len,
    };
    const written = native_sdk_appkit_show_save_dialog(self.host, &opts, buffer.ptr, buffer.len);
    if (written > buffer.len) return error.NoSpaceLeft;
    if (written == 0) return null;
    return buffer[0..written];
}

fn showMessageDialog(context: ?*anyopaque, options: platform_mod.MessageDialogOptions) anyerror!platform_mod.MessageDialogResult {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const opts = AppKitMessageDialogOpts{
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
    const result = native_sdk_appkit_show_message_dialog(self.host, &opts);
    return @enumFromInt(result);
}

const max_tray_items: usize = 32;

fn createTray(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, options: platform_mod.TrayOptions) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    var presentation = options.presentation;
    if (presentation.title.len == 0) presentation.title = options.title;
    native_sdk_appkit_create_tray(
        self.host,
        status_item_id,
        options.icon_path.ptr,
        options.icon_path.len,
        presentation.title.ptr,
        presentation.title.len,
        options.tooltip.ptr,
        options.tooltip.len,
        if (options.visible) 1 else 0,
        presentation.width,
        @intFromEnum(presentation.tone),
        presentation.icon_opacity,
        if (presentation.monospaced) 1 else 0,
        presentation.font_size,
        @intFromEnum(presentation.font_weight),
        options.activation_command.ptr,
        options.activation_command.len,
        options.alternate_activation_command.ptr,
        options.alternate_activation_command.len,
        options.open_command.ptr,
        options.open_command.len,
    );
    if (options.items.len > 0) {
        try updateTrayMenu(context, status_item_id, options.items);
    }
}

fn updateTrayShell(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, shell: platform_mod.TrayShell) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_update_tray_shell(self.host, status_item_id, shell.icon_path.ptr, shell.icon_path.len, shell.tooltip.ptr, shell.tooltip.len, if (shell.visible) 1 else 0, shell.activation_command.ptr, shell.activation_command.len, shell.alternate_activation_command.ptr, shell.alternate_activation_command.len, shell.open_command.ptr, shell.open_command.len);
}

fn updateTrayMenu(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, items: []const platform_mod.TrayMenuItem) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    const count = @min(items.len, max_tray_items);
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
    for (items[0..count], 0..) |item, i| {
        ids[i] = item.id;
        labels[i] = item.label.ptr;
        label_lens[i] = item.label.len;
        separators[i] = if (item.separator) 1 else 0;
        enabled_flags[i] = if (item.enabled) 1 else 0;
        details[i] = item.detail.ptr;
        detail_lens[i] = item.detail.len;
        roles[i] = @intFromEnum(item.role);
        keys[i] = item.key.ptr;
        key_lens[i] = item.key.len;
        modifiers[i] = @as(u32, @intFromBool(item.modifiers.primary)) |
            (@as(u32, @intFromBool(item.modifiers.command)) << 1) |
            (@as(u32, @intFromBool(item.modifiers.control)) << 2) |
            (@as(u32, @intFromBool(item.modifiers.option)) << 3) |
            (@as(u32, @intFromBool(item.modifiers.shift)) << 4);
    }
    native_sdk_appkit_update_tray_menu(self.host, status_item_id, &ids, &labels, &label_lens, &separators, &enabled_flags, &details, &detail_lens, &roles, &keys, &key_lens, &modifiers, count);

    var segment_options: [max_tray_items * platform_mod.max_tray_segment_options]AppKitTraySegmentOption = undefined;
    var segmented_rows: [max_tray_items]AppKitTraySegmentedRow = undefined;
    var metric_rows: [max_tray_items]AppKitTrayMetricRow = undefined;
    var chart_rows: [max_tray_items]AppKitTrayChartRow = undefined;
    var option_count: usize = 0;
    var segmented_count: usize = 0;
    var metric_count: usize = 0;
    var chart_count: usize = 0;
    for (items[0..count], 0..) |item, row_index| {
        if (item.segmented) |segmented| {
            const start = option_count;
            for (segmented.options) |option| {
                segment_options[option_count] = .{
                    .item_id = option.id,
                    .label = option.label.ptr,
                    .label_len = option.label.len,
                    .selected = if (option.selected) 1 else 0,
                    .enabled = if (option.enabled) 1 else 0,
                };
                option_count += 1;
            }
            segmented_rows[segmented_count] = .{
                .row_index = row_index,
                .options = segment_options[start..option_count].ptr,
                .option_count = option_count - start,
            };
            segmented_count += 1;
        }
        if (item.metric) |metric| {
            metric_rows[metric_count] = .{
                .row_index = row_index,
                .primary_text = metric.primary_text.ptr,
                .primary_text_len = metric.primary_text.len,
                .secondary_text = metric.secondary_text.ptr,
                .secondary_text_len = metric.secondary_text.len,
                .accessibility_label = metric.accessibility_label.ptr,
                .accessibility_label_len = metric.accessibility_label.len,
            };
            metric_count += 1;
        }
        if (item.chart) |chart| {
            chart_rows[chart_count] = .{
                .row_index = row_index,
                .values = chart.values.ptr,
                .value_count = chart.values.len,
                .min_value = chart.min_value,
                .max_value = chart.max_value,
                .leading_caption = chart.leading_caption.ptr,
                .leading_caption_len = chart.leading_caption.len,
                .trailing_summary = chart.trailing_summary.ptr,
                .trailing_summary_len = chart.trailing_summary.len,
                .accessibility_label = chart.accessibility_label.ptr,
                .accessibility_label_len = chart.accessibility_label.len,
            };
            chart_count += 1;
        }
    }
    native_sdk_appkit_update_tray_rich_rows(self.host, status_item_id, &segmented_rows, segmented_count, &metric_rows, metric_count, &chart_rows, chart_count);
}

fn updateTrayTitle(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, title: []const u8) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_update_tray_title(self.host, status_item_id, title.ptr, title.len);
}

fn updateTrayPresentation(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId, presentation: platform_mod.TrayPresentation) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_update_tray_presentation(self.host, status_item_id, presentation.title.ptr, presentation.title.len, presentation.width, @intFromEnum(presentation.tone), presentation.icon_opacity, if (presentation.monospaced) 1 else 0, presentation.font_size, @intFromEnum(presentation.font_weight));
}

fn removeTray(context: ?*anyopaque, status_item_id: platform_mod.StatusItemId) anyerror!void {
    const self: *MacPlatform = @ptrCast(@alignCast(context.?));
    native_sdk_appkit_remove_tray(self.host, status_item_id);
}

fn appkitTrayCallback(context: ?*anyopaque, status_item_id: u32, item_id: u32) callconv(.c) void {
    const state: *RunState = @ptrCast(@alignCast(context.?));
    state.emit(.{ .tray_action = .{ .status_item_id = status_item_id, .item_id = item_id } });
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

test "mac platform module exports type" {
    _ = MacPlatform;
}

test "mac AppKit packet text anchors use the resolved font ascent" {
    const host_source = @embedFile("appkit_host.m");
    const baseline_source = @embedFile("appkit_text_baseline.h");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "static BOOL NativeSdkPacketDrawAttributedText(") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "return NativeSdkAppKitDrawAttributedText(value, attributes, x, baseline, width, height, NULL)") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_source, "drawGlyphsForGlyphRange:glyphRange atPoint:") != null);
    try std.testing.expect(std.mem.indexOf(u8, baseline_source, "glyphRangeForTextContainer:container") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_appkit_measure_text_ink(") != null);
}

test "mac status agent rows recognize decorated states and stay actionable" {
    const host_source = @embedFile("appkit_host.m");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "[state hasPrefix:@\"configured \"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "[state hasPrefix:@\"warning \"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "label.textColor = configured ? successColor : warning ? warningColor : NSColor.secondaryLabelColor;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "button.tag = (NSInteger)(((uint64_t)statusItemId << 32) | itemIds[index]);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "button.enabled = enabled[index].boolValue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "button.keyEquivalent = NativeSdkMenuKeyEquivalent(key);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "button.keyEquivalentModifierMask = NativeSdkMenuModifierFlags(modifiers[index].unsignedIntValue);") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "item.keyEquivalent = @\"\";") != null);
}

test "mac title-only tray updates preserve the applied presentation" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "entry.presentationWidth = width;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "entry.presentationTone = tone;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "entry.presentationIconOpacity = iconOpacity;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "entry.presentationMonospaced = monospaced;") != null);
        const update_at = std.mem.indexOf(u8, host_source, "void native_sdk_appkit_update_tray_title(") orelse return error.TestExpectedEqual;
        const update_tail = host_source[update_at..];
        try std.testing.expect(std.mem.indexOf(u8, update_tail, "entry.presentationWidth,") != null);
        try std.testing.expect(std.mem.indexOf(u8, update_tail, "entry.presentationTone,") != null);
        try std.testing.expect(std.mem.indexOf(u8, update_tail, "entry.presentationIconOpacity,") != null);
        try std.testing.expect(std.mem.indexOf(u8, update_tail, "entry.presentationMonospaced") != null);
    }
}

test "mac status lifecycle hooks emit tray commands" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        const emit_at = std.mem.indexOf(u8, host_source, "- (void)emitStatusCommand:(NSString *)command statusItemId:(uint32_t)statusItemId {") orelse return error.TestExpectedEqual;
        const emit_tail = host_source[emit_at..];
        const emit_end = std.mem.indexOf(u8, emit_tail, "- (void)statusItemActivated:") orelse return error.TestExpectedEqual;
        const emit_source = emit_tail[0..emit_end];
        try std.testing.expect(std.mem.indexOf(u8, emit_source, "NATIVE_SDK_APPKIT_EVENT_TRAY_COMMAND") != null);
        try std.testing.expect(std.mem.indexOf(u8, emit_source, "NATIVE_SDK_APPKIT_EVENT_MENU_COMMAND") == null);
    }
}

test "mac typed tray rows cross the AppKit ABI without text conventions" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |source| {
        try std.testing.expect(std.mem.indexOf(u8, source, "TraySegmentedView") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "NSSegmentedControl") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "TrayChartView") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "native_sdk_appkit_update_tray_rich_rows") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "range_selected") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "chart|") == null);
    }
}

test "mac status menu updates preserve the menu being opened" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSMenu *menu = entry.menu;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "[menu removeAllItems];") != null);
    }
}

test "mac webview presses report the focused child label" {
    // WKWebView owns the page's pointer stream, so the AppKit host
    // observes the down before dispatch and emits the explicit inverse
    // edge that blurs a sibling canvas view.
    const host_source = @embedFile("appkit_host.m");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, ".kind = NATIVE_SDK_APPKIT_EVENT_VIEW_FOCUSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, ".view_label = label") != null);
}

test "mac active implicit show activates before making the window key" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        const show_at = std.mem.indexOf(u8, host_source, "- (void)orderWindowForImplicitShow:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
        const show_tail = host_source[show_at..];
        const show_end = std.mem.indexOf(u8, show_tail, "- (void)focusWindowWithId:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
        const show_body = show_tail[0..show_end];
        const activate_at = std.mem.indexOf(u8, show_body, "[NSApp activateIgnoringOtherApps:YES];") orelse return error.TestExpectedEqual;
        const make_key_at = std.mem.indexOf(u8, show_body, "[window makeKeyAndOrderFront:nil];") orelse return error.TestExpectedEqual;
        try std.testing.expect(activate_at < make_key_at);
    }
}

test "mac unrestored secondary windows cascade within the active screen" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSWindow *referenceWindow = NSApp.keyWindow ?: self.window;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSMinX(referenceFrame) + 24.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSMaxY(referenceFrame) - 24.0") != null);
        // Only fresh/default windows under the default clamp policy cascade.
        // center_on_primary deliberately keeps the preceding center placement.
        try std.testing.expect(std.mem.indexOf(u8, host_source, "if (initialPlacement == 2 && restorePolicy == 0 && !makeMain && referenceWindow)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSRect visibleFrame = referenceScreen.visibleFrame;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSMaxX(visibleFrame) - NSWidth(cascadedFrame)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSMaxY(visibleFrame) - NSHeight(cascadedFrame)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "[window setFrame:cascadedFrame display:NO]") != null);
    }
}

test "both mac hosts distinguish restored explicit and default placement" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "const BOOL restoredPlacement = initialPlacement == 0") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "initialPlacement == 2 || (restoredPlacement && restorePolicy == 1)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NativeSdkConstrainFrameToScreen(NSMakeRect(0, 0, width, height), primaryScreen)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NativeSdkConstrainFrame(NSMakeRect(x, y, width, height))") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "return [NSScreen screens].firstObject ?: [NSScreen mainScreen]") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "[window frameRectForContentRect:restoredContentFrame]") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "[window setFrame:restoredWindowFrame display:NO]") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "[window setFrame:NativeSdkCenterFrameOnScreen(window.frame, primaryScreen) display:NO]") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "initialPlacement == 2 && restorePolicy == 0 && !makeMain && referenceWindow") != null);
    }
}

test "both mac hosts preserve valid secondary-display frames" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "static NSScreen *NativeSdkScreenForFrame(NSRect frame)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSArray<NSScreen *> *screens = [NSScreen screens]") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSIntersectionRect(frame, screen.visibleFrame)") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NativeSdkConstrainFrameToScreen(frame, NativeSdkScreenForFrame(frame))") != null);
    }
}

test "mac explicit focus activates before making the window key" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        const focus_at = std.mem.indexOf(u8, host_source, "- (void)focusWindowWithId:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
        const focus_tail = host_source[focus_at..];
        const focus_end = std.mem.indexOf(u8, focus_tail, "- (void)closeWindowWithId:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
        const focus_body = focus_tail[0..focus_end];
        const activate_at = std.mem.indexOf(u8, focus_body, "[NSApp activateIgnoringOtherApps:YES];") orelse return error.TestExpectedEqual;
        const make_key_at = std.mem.indexOf(u8, focus_body, "[window makeKeyAndOrderFront:nil];") orelse return error.TestExpectedEqual;
        try std.testing.expect(activate_at < make_key_at);
    }
}

test "mac dock presence changes policy without activating the app" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        const dock_at = std.mem.indexOf(u8, host_source, "int native_sdk_appkit_set_dock_presence(") orelse return error.TestExpectedEqual;
        const dock_tail = host_source[dock_at..];
        const dock_end = std.mem.indexOf(u8, dock_tail, "int native_sdk_appkit_launch_at_login_status(") orelse return error.TestExpectedEqual;
        const dock_body = dock_tail[0..dock_end];
        try std.testing.expect(std.mem.indexOf(u8, dock_body, "[NSApp setActivationPolicy:policy]") != null);
        try std.testing.expect(std.mem.indexOf(u8, dock_body, "[NSApp activate") == null);
    }
}

test "both mac hosts apply launch dock presence before configuring the app" {
    for ([_][]const u8{ @embedFile("appkit_host.m"), @embedFile("cef_host.mm") }) |host_source| {
        const init_at = std.mem.indexOf(u8, host_source, "dockVisible:(BOOL)dockVisible") orelse return error.TestExpectedEqual;
        const init_tail = host_source[init_at..];
        const policy_at = std.mem.indexOf(u8, init_tail, "dockVisible ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory") orelse return error.TestExpectedEqual;
        const configure_at = std.mem.indexOf(u8, init_tail, "[self configureApplication]") orelse return error.TestExpectedEqual;
        const create_at = std.mem.indexOf(u8, init_tail, "[self createWindowWithId:1") orelse return error.TestExpectedEqual;
        try std.testing.expect(policy_at < configure_at);
        try std.testing.expect(policy_at < create_at);
        if (std.mem.indexOf(u8, init_tail, "ensureCefInitialized();")) |cef_init_at| {
            try std.testing.expect(policy_at < cef_init_at);
        }
        try std.testing.expect(std.mem.indexOf(u8, host_source, "int has_web_content, int dock_visible") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "dockVisible:(dock_visible != 0)") != null);
    }
}

test "mac updater hashes archives off the main thread and treats user cancellation silently" {
    const host_source = @embedFile("appkit_host.m");
    const install_at = std.mem.indexOf(u8, host_source, "- (void)installDownloadedUpdate:(NSURL *)downloadURL version:(NSString *)version archiveBytes:(uint64_t)archiveBytes sha256:(NSString *)sha256 {") orelse return error.TestExpectedEqual;
    const install_tail = host_source[install_at..];
    const install_end = std.mem.indexOf(u8, install_tail, "- (NSMenuItem *)menuItem:") orelse return error.TestExpectedEqual;
    const install_body = install_tail[0..install_end];
    const background_at = std.mem.indexOf(u8, install_body, "dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)") orelse return error.TestExpectedEqual;
    const verify_at = std.mem.indexOf(u8, install_body, "native_sdk_update_verify_archive(") orelse return error.TestExpectedEqual;
    try std.testing.expect(background_at < verify_at);

    const download_at = std.mem.indexOf(u8, host_source, "- (void)downloadUpdateVersion:(NSString *)version archiveURL:(NSString *)archiveURL archiveBytes:(uint64_t)archiveBytes sha256:(NSString *)sha256 releaseNotes:(NSString *)releaseNotes {") orelse return error.TestExpectedEqual;
    const download_tail = host_source[download_at..];
    const download_end = std.mem.indexOf(u8, download_tail, "- (void)updateDownloadLimitTimerFired:") orelse return error.TestExpectedEqual;
    const download_body = download_tail[0..download_end];
    try std.testing.expect(std.mem.indexOf(u8, download_body, "strongSelf.updateDownloadCancelledByUser = YES;") != null);
    try std.testing.expect(std.mem.indexOf(u8, download_body, "if (cancelledByUser)") != null);
    try std.testing.expect(std.mem.indexOf(u8, download_body, "strongSelf.updateCheckRunning = NO;") != null);
}

test "mac updater binds packaged releases to the installed bundle identity" {
    const host_source = @embedFile("appkit_host.m");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "static NSString *NativeSdkPackagedBundleIdentifier(void)") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "self.bundleIdentifier = NativeSdkPackagedBundleIdentifier() ?: configuredBundleIdentifier;") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "strongSelf.bundleIdentifier.UTF8String") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "[candidateBundle.bundleIdentifier isEqualToString:strongSelf.bundleIdentifier]") != null);
}

test "mac updater presents without relying on the startup window and cleans failed staging" {
    const host_source = @embedFile("appkit_host.m");
    const helper_at = std.mem.lastIndexOf(u8, host_source, "- (void)presentUpdateAlert:(NSAlert *)alert completionHandler:") orelse return error.TestExpectedEqual;
    const helper_tail = host_source[helper_at..];
    const helper_end = std.mem.indexOf(u8, helper_tail, "- (void)showUpdateError:") orelse return error.TestExpectedEqual;
    const helper_body = helper_tail[0..helper_end];
    try std.testing.expect(std.mem.indexOf(u8, helper_body, "[self updatePresentationWindow]") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_body, "[alert runModal]") != null);
    try std.testing.expect(std.mem.indexOf(u8, helper_body, "self.window") == null);

    const install_at = std.mem.indexOf(u8, host_source, "- (void)installDownloadedUpdate:(NSURL *)downloadURL version:") orelse return error.TestExpectedEqual;
    const install_tail = host_source[install_at..];
    const create_failure = std.mem.indexOf(u8, install_tail, "if (![manager createDirectoryAtPath:extractPath") orelse return error.TestExpectedEqual;
    const failure_tail = install_tail[create_failure..];
    const failure_end = std.mem.indexOf(u8, failure_tail, "NSString *taskOutput") orelse return error.TestExpectedEqual;
    const failure_body = failure_tail[0..failure_end];
    try std.testing.expect(std.mem.indexOf(u8, failure_body, "removeItemAtPath:stagePath") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_body, "removeItemAtURL:downloadURL") != null);
}

test "mac transparent raw frames are premultiplied exactly once before Metal upload" {
    const host_source = @embedFile("appkit_host.m");
    const helper_at = std.mem.indexOf(
        u8,
        host_source,
        "static void NativeSdkPremultiplyStraightRgba8",
    ) orelse return error.TestExpectedEqual;
    const present_at = std.mem.indexOfPos(
        u8,
        host_source,
        helper_at,
        "- (BOOL)presentPixelsWithWidth:",
    ) orelse return error.TestExpectedEqual;
    const present_tail = host_source[present_at..];

    try std.testing.expect(helper_at < present_at);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "if (self.window && !self.window.opaque && !sourceIsPremultiplied)",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "NativeSdkPremultiplyStraightRgba8(",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "sourceIsPremultiplied:YES rgba8:(const uint8_t *)pixels.bytes",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "sourceIsPremultiplied:NO rgba8:rgba8",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "const uint8_t *uploadBytes = presentBytes +",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        present_tail,
        "memcpy(backingBytes, presentBytes, byteLength);",
    ) != null);
}

test "mac transparent gpu surfaces clear missing canvas content to transparent" {
    const host_source = @embedFile("appkit_host.m");
    const render_at = std.mem.indexOf(
        u8,
        host_source,
        "- (void)renderFrame {",
    ) orelse return error.TestExpectedEqual;
    const render_end = std.mem.indexOfPos(
        u8,
        host_source,
        render_at,
        "- (BOOL)acceptsFirstResponder",
    ) orelse return error.TestExpectedEqual;
    const render_source = host_source[render_at..render_end];

    try std.testing.expect(std.mem.indexOf(
        u8,
        render_source,
        "const BOOL transparentWindow = window != nil && !window.opaque;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, render_source,
        \\descriptor.colorAttachments[0].clearColor = transparentWindow
        \\        ? MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
        \\        : MTLClearColorMake(red, green, blue, 1.0);
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        render_source,
        "if (self.hasCanvasTexture && canvasTextureMatchesDrawable",
    ) != null);
}

test "mac Chromium webview focus reports the focused child label" {
    // CEF's focus handler is the engine-level ownership edge: it covers
    // pointer, keyboard, and programmatic focus without predicting from
    // a press. A generation guard keeps a closing/replaced child from
    // publishing its old label after runtime storage has moved on.
    const host_source = @embedFile("cef_host.mm");
    try std.testing.expect(std.mem.indexOf(u8, host_source, "public CefFocusHandler") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "CefRefPtr<CefFocusHandler> GetFocusHandler() override") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "void NativeSdkCefClient::OnGotFocus") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "webViewGeneration:webview_generation_ matchesKey:") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, ".kind = NATIVE_SDK_APPKIT_EVENT_VIEW_FOCUSED") != null);
    try std.testing.expect(std.mem.indexOf(u8, host_source, "emitViewFocusedForWindowId:window_id_ label:") != null);
}

test "mac dock icon fallback renders the embedded toolkit default" {
    // The exact pipeline `defaultDockIconRenderMain` hands the host:
    // decode the embedded default and render the packaging canvas. This
    // proves the runtime Dock path can consume the embedded bytes — no
    // per-app icon file needed for the default tile.
    const gpa = std.testing.allocator;
    var source = switch (try app_icon.loadSource(gpa, default_icon_png, .png)) {
        .ok => |value| value,
        .issue => return error.TestUnexpectedResult,
    };
    defer source.deinit(gpa);
    const rgba = try app_icon.renderMacosCanvas(gpa, &source, app_icon.master_size);
    defer gpa.free(rgba);
    const size = app_icon.master_size;
    try std.testing.expectEqual(size * size * 4, rgba.len);
    // Pre-shaped icon: the canvas corner stays transparent (the rounded
    // plate never reaches it) …
    try std.testing.expectEqual(@as(u8, 0), rgba[(2 * size + 2) * 4 + 3]);
    // … and the plate is the dark-NEUTRAL gradient: an opaque gray
    // (r == g == b, well below mid-tone) below the layered-sheet mark.
    const plate_index = ((size * 850 / 1024) * size + size / 2) * 4;
    const r = rgba[plate_index];
    try std.testing.expectEqual(@as(u8, 255), rgba[plate_index + 3]);
    try std.testing.expectEqual(r, rgba[plate_index + 1]);
    try std.testing.expectEqual(r, rgba[plate_index + 2]);
    try std.testing.expect(r >= 15 and r <= 60);
}

test "mac dock icon plan uses the embedded default only without a file" {
    // The file-existence and bundle probes are comptime-stubbed to
    // false off macOS, where this plan never runs — only the macOS test
    // build exercises the real probes.
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;
    // Missing file, unbundled test binary: the embedded default.
    try std.testing.expectEqual(DockIconPlan.embedded_default, planDockIcon("assets/does-not-exist.icns"));
    try std.testing.expectEqual(DockIconPlan.embedded_default, planDockIcon(""));
    // A real file keeps the classic host load (or the Debug masked
    // render for raw sources) — an app's own icon always wins.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "icon.icns", .data = "stub" });
    var path_buffer: [256]u8 = undefined;
    // tmpDir lives under .zig-cache/tmp/ relative to the test cwd.
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/icon.icns", .{tmp.sub_path[0..]});
    try std.testing.expectEqual(DockIconPlan.host_file, planDockIcon(path));
}

test "mac widget accessibility maps retained action flags" {
    try std.testing.expectEqual(@as(u32, 0), widgetActionFlags(.{}));
    const flags = widgetActionFlags(.{
        .focus = true,
        .press = true,
        .toggle = true,
        .increment = true,
        .decrement = true,
        .set_text = true,
        .set_selection = true,
        .select = true,
        .drag = true,
        .drop_files = true,
        .dismiss = true,
    });
    try std.testing.expect(flags & widget_action_focus != 0);
    try std.testing.expect(flags & widget_action_press != 0);
    try std.testing.expect(flags & widget_action_toggle != 0);
    try std.testing.expect(flags & widget_action_increment != 0);
    try std.testing.expect(flags & widget_action_decrement != 0);
    try std.testing.expect(flags & widget_action_set_text != 0);
    try std.testing.expect(flags & widget_action_set_selection != 0);
    try std.testing.expect(flags & widget_action_select != 0);
    try std.testing.expect(flags & widget_action_drag != 0);
    try std.testing.expect(flags & widget_action_drop_files != 0);
    try std.testing.expect(flags & widget_action_dismiss != 0);
}

test "mac widget accessibility maps widget state flags" {
    const expanded = widgetStateFlags(.{ .enabled = true, .expanded = true, .required = true, .read_only = true, .invalid = true, .can_undo = true, .can_redo = true });
    try std.testing.expect(expanded & widget_state_enabled != 0);
    try std.testing.expect(expanded & widget_state_expanded != 0);
    try std.testing.expect(expanded & widget_state_collapsed == 0);
    try std.testing.expect(expanded & widget_state_required != 0);
    try std.testing.expect(expanded & widget_state_read_only != 0);
    try std.testing.expect(expanded & widget_state_invalid != 0);
    try std.testing.expect(expanded & widget_state_can_undo != 0);
    try std.testing.expect(expanded & widget_state_can_redo != 0);

    const collapsed = widgetStateFlags(.{ .enabled = true, .expanded = false });
    try std.testing.expect(collapsed & widget_state_enabled != 0);
    try std.testing.expect(collapsed & widget_state_collapsed != 0);
    try std.testing.expect(collapsed & widget_state_expanded == 0);
}

test "mac widget accessibility maps retained action events" {
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.drag, widgetAccessibilityActionFromInt(8).?);
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.drop_files, widgetAccessibilityActionFromInt(9).?);
    try std.testing.expectEqual(platform_mod.WidgetAccessibilityActionKind.dismiss, widgetAccessibilityActionFromInt(10).?);
    try std.testing.expect(widgetAccessibilityActionFromInt(11) == null);
}

test "mac widget accessibility action preserves text payload" {
    const text = "Search customers";
    var event = std.mem.zeroes(AppKitEvent);
    event.widget_text = text.ptr;
    event.widget_text_len = text.len;
    event.has_widget_text_selection = 1;
    event.widget_text_selection_start = 2;
    event.widget_text_selection_end = 8;

    try std.testing.expectEqualStrings("Search customers", appKitEventBytes(event.widget_text, event.widget_text_len));
    try std.testing.expectEqualDeep(platform_mod.WidgetAccessibilityTextRange{ .start = 2, .end = 8 }, widgetAccessibilitySelectionFromAppKitEvent(&event).?);

    event.widget_text_len = 0;
    event.has_widget_text_selection = 0;
    try std.testing.expectEqualStrings("", appKitEventBytes(event.widget_text, event.widget_text_len));
    try std.testing.expect(widgetAccessibilitySelectionFromAppKitEvent(&event) == null);
}

test "mac gpu surface input preserves key and text" {
    const label = "canvas";
    const key = "enter";
    const text = "\n";
    var event = std.mem.zeroes(AppKitEvent);
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

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
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

test "mac file drop bridge preserves view label point and paths" {
    const label = "kanban-canvas";
    const paths = "/tmp/spec.txt\x00/tmp/design.pdf";
    var event = std.mem.zeroes(AppKitEvent);
    event.kind = .files_dropped;
    event.window_id = 7;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.x = 42.5;
    event.y = 91.25;
    event.drop_paths = paths.ptr;
    event.drop_paths_len = paths.len;

    var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
    const drop = fileDropEventFromAppKitEvent(&event, paths_buffer[0..]);
    try std.testing.expectEqual(@as(platform_mod.WindowId, 7), drop.window_id);
    try std.testing.expectEqualStrings("kanban-canvas", drop.view_label);
    try std.testing.expectEqualDeep(geometry.PointF.init(42.5, 91.25), drop.point.?);
    try std.testing.expectEqual(@as(usize, 2), drop.paths.len);
    try std.testing.expectEqualStrings("/tmp/spec.txt", drop.paths[0]);
    try std.testing.expectEqualStrings("/tmp/design.pdf", drop.paths[1]);
}

test "mac file drops and pointer input share the host y-down conversion" {
    const host_source = @embedFile("appkit_host.m");
    try std.testing.expectEqual(@as(usize, 5), std.mem.count(u8, host_source, "NativeSdkViewLocalYDownPoint("));
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "if (!view.isFlipped) point.y = view.bounds.size.height - point.y;",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "const NSPoint yDownPoint = NativeSdkViewLocalYDownPoint(self, point);",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        host_source,
        "NativeSdkViewLocalYDownPoint(self, [self convertPoint:sender.draggingLocation fromView:nil])",
    ) != null);

    const label = "canvas";
    var event = std.mem.zeroes(AppKitEvent);
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.x = 128.5;
    event.y = 73.25;

    var paths_buffer: [platform_mod.max_drop_paths][]const u8 = undefined;
    const drop = fileDropEventFromAppKitEvent(&event, paths_buffer[0..]);
    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(input.x, drop.point.?.x);
    try std.testing.expectEqual(input.y, drop.point.?.y);
}

test "mac gpu surface input preserves ime composition cursor" {
    const label = "canvas";
    const text = "compose";
    var event = std.mem.zeroes(AppKitEvent);
    event.window_id = 9;
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.input_kind = 8;
    event.input_text = text.ptr;
    event.input_text_len = text.len;
    event.has_composition_cursor = 1;
    event.composition_cursor = 4;

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.ime_set_composition, input.kind);
    try std.testing.expectEqualStrings("compose", input.text);
    try std.testing.expectEqual(@as(?usize, 4), input.composition_cursor);
}

test "mac gpu surface input maps pointer cancel" {
    var event = std.mem.zeroes(AppKitEvent);
    event.input_kind = 11;

    const input = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pointer_cancel, input.kind);
}

test "mac gpu surface input maps pinch phases and carries the magnification delta" {
    const label = "timeline-canvas";
    var event = std.mem.zeroes(AppKitEvent);
    event.view_label = label.ptr;
    event.view_label_len = label.len;
    event.input_kind = 12;
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pinch_begin, gpuSurfaceInputEventFromAppKitEvent(&event).kind);

    // The magnification delta rides the ABI event's `scale` field with
    // the pointer anchor on x/y (the host's converted, top-left-origin
    // pointer location).
    event.input_kind = 13;
    event.x = 160;
    event.y = 120;
    event.scale = 0.25;
    const change = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pinch_change, change.kind);
    try std.testing.expectEqual(@as(f32, 0.25), change.scale);
    try std.testing.expectEqual(@as(f32, 160), change.x);
    try std.testing.expectEqual(@as(f32, 120), change.y);

    event.input_kind = 14;
    event.scale = 0;
    const end = gpuSurfaceInputEventFromAppKitEvent(&event);
    try std.testing.expectEqual(platform_mod.GpuSurfaceInputKind.pinch_end, end.kind);
    try std.testing.expectEqual(@as(f32, 0), end.scale);
}

test "mac appearance event maps color scheme" {
    try std.testing.expectEqual(platform_mod.ColorScheme.light, appKitColorScheme(0));
    try std.testing.expectEqual(platform_mod.ColorScheme.dark, appKitColorScheme(1));
    try std.testing.expectEqual(platform_mod.ColorScheme.light, appKitColorScheme(42));
}

test "mac appearance event carries accessibility preferences" {
    var event = std.mem.zeroes(AppKitEvent);
    event.color_scheme = 1;
    event.reduce_motion = 1;
    event.high_contrast = 1;

    try std.testing.expectEqual(platform_mod.ColorScheme.dark, appKitColorScheme(event.color_scheme));
    try std.testing.expect(event.reduce_motion != 0);
    try std.testing.expect(event.high_contrast != 0);
}

test "mac launch-at-login result keeps unsupported separate from operation failure" {
    try std.testing.expectEqual(platform_mod.LaunchAtLoginStatus.disabled, try launchAtLoginStatusFromInt(0));
    try std.testing.expectEqual(platform_mod.LaunchAtLoginStatus.enabled, try launchAtLoginStatusFromInt(1));
    try std.testing.expectEqual(platform_mod.LaunchAtLoginStatus.requires_approval, try launchAtLoginStatusFromInt(2));
    try std.testing.expectEqual(platform_mod.LaunchAtLoginStatus.not_found, try launchAtLoginStatusFromInt(3));
    try std.testing.expectError(error.UnsupportedService, launchAtLoginStatusFromInt(-1));
    try std.testing.expectError(error.LaunchAtLoginFailed, launchAtLoginStatusFromInt(-2));
    try std.testing.expectError(error.LaunchAtLoginFailed, launchAtLoginStatusFromInt(99));
}

test "both mac hosts carry the menu-bar lifecycle and fullscreen hooks" {
    const hosts = [_][]const u8{
        @embedFile("appkit_host.m"),
        @embedFile("cef_host.mm"),
    };
    for (hosts) |host_source| {
        try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_appkit_hide_window") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_appkit_set_dock_presence") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_appkit_launch_at_login_status") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "native_sdk_appkit_set_launch_at_login") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "registerAndReturnError:") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "unregisterAndReturnError:") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "before == 1 || before == 2") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "return succeeded ? NativeSdkLaunchAtLoginStatus() : -2;") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "dlopen(") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "ServiceManagement.framework/ServiceManagement") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "NSWindowCollectionBehaviorFullScreenNone") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "standardWindowButton:NSWindowZoomButton") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "1u << 4") != null);
        try std.testing.expect(std.mem.indexOf(u8, host_source, "policyHiddenWindows") != null);
    }

    // AppKit canvas windows also carry a pending first-present/fallback
    // reveal. An explicit hide must retire that pending reveal before it
    // records the policy-hidden state.
    const appkit_source = hosts[0];
    try std.testing.expect(std.mem.indexOf(u8, appkit_source, "[NSApp activate]") == null);
    try std.testing.expect(std.mem.indexOf(u8, appkit_source, "[NSApp activateIgnoringOtherApps:YES]") != null);
    const hide_at = std.mem.indexOf(u8, appkit_source, "- (void)hideWindowWithId:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
    const hide_tail = appkit_source[hide_at..];
    const show_at = std.mem.indexOf(u8, hide_tail, "- (void)showWindowWithId:(uint64_t)windowId {") orelse return error.TestExpectedEqual;
    const hide_body = hide_tail[0..show_at];
    const cancel_at = std.mem.indexOf(u8, hide_body, "[self.deferredShowWindows removeObjectForKey:@(windowId)];") orelse return error.TestExpectedEqual;
    const policy_at = std.mem.indexOf(u8, hide_body, "[self.policyHiddenWindows addObject:@(windowId)];") orelse return error.TestExpectedEqual;
    try std.testing.expect(cancel_at < policy_at);
}
