//! Comptime reflection helpers over an app's Model/Msg, shared by the
//! runtime interpreter (ui_markup_view.zig), the comptime-compiled engine
//! (ui_markup_compiled.zig), and the model-contract describe step
//! (ui_markup_contract.zig). One definition means the three consumers
//! cannot disagree about WHICH Zig declarations markup can bind: fields,
//! public zero-arg methods, arena-taking scalar methods, and slice/array
//! iterables all resolve through these predicates.
//!
//! std-only on purpose: the contract describe step runs inside a tiny
//! emit program and `native check` parses its output with no canvas
//! dependency in sight.

const std = @import("std");
const expr = @import("ui_markup_expr.zig");
const schema = @import("ui_schema.zig");

/// Comptime walks over an app's Model and Msg scale with the type's
/// field/decl count, and the default 1000-backwards-branch quota dies at
/// real app sizes — inside toolkit code the app never asked to run,
/// before it uses any markup. Every Model/Msg shaped comptime walk
/// derives its quota from the scanned type instead of relying on the
/// default: generous linear headroom per field/decl (name compares,
/// fn-signature checks, `sliceElement` recursion) plus the item-type
/// dedupe's worst-case quadratic accumulation. Apps never raise the quota
/// for these scans; `ui_markup_huge_model_tests.zig` is the compile-cost
/// guard.
pub fn typeScanQuota(comptime T: type) u32 {
    const entries: u32 = switch (@typeInfo(T)) {
        .@"struct" => |info| @intCast(info.fields.len + info.decls.len),
        .@"union" => |info| @intCast(info.fields.len + info.decls.len),
        .@"enum" => |info| @intCast(info.fields.len + info.decls.len),
        else => 0,
    };
    return 2000 + entries * 64 + entries * entries;
}

/// Single-item const pointers are transparent in binding traversal: a
/// `*const Row` nested-record field or list element binds exactly like
/// the struct it points at. This is the committed-model idiom — shared
/// nodes referenced by pointer, the shape transpiled cores emit for
/// records and record arrays — and it mirrors `sliceElement`'s existing
/// pointer transparency for iterables. Mutable single-item pointers stay
/// opaque: markup reads models, so a bindable path must not smuggle a
/// mutation channel.
pub fn Pointee(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |info| if (info.size == .one and info.is_const) Pointee(info.child) else T,
        else => T,
    };
}

/// The element type a `for each` can iterate from this declaration:
/// slices, arrays, and single-item pointers to either.
pub fn sliceElement(comptime T: type) ?type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| if (info.size == .slice) info.child else if (info.size == .one) sliceElement(info.child) else null,
        else => null,
    };
}

/// An iterable-producing model fn: `fn (*const Model) []const Item`, or
/// with `with_arena` the build-arena form
/// `fn (*const Model, std.mem.Allocator) []const Item`.
pub fn isItemFn(comptime DeclType: type, comptime Item: type, comptime with_arena: bool) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len == 0 or info.params[0].type == null) return false;
    switch (@typeInfo(info.params[0].type.?)) {
        .pointer => {},
        else => return false,
    }
    const expected_params: usize = if (with_arena) 2 else 1;
    if (info.params.len != expected_params) return false;
    const Return = info.return_type orelse return false;
    if (sliceElement(Return) != Item) return false;
    if (with_arena and info.params[1].type != std.mem.Allocator) return false;
    return true;
}

/// An arena-taking scalar binding fn: `fn (self: *const T,
/// arena: std.mem.Allocator) V`. The `for each` arena form returns a slice
/// of items; this form returns one value (typically a formatted
/// `[]const u8` allocated from the arena).
pub fn isArenaScalarFn(comptime T: type, comptime DeclType: type) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    if (info.params.len != 2 or info.return_type == null) return false;
    if (info.params[0].type != *const T) return false;
    return info.params[1].type == std.mem.Allocator;
}

/// A zero-arg scalar binding fn: `fn (self: *const T) V`.
pub fn isZeroArgFn(comptime T: type, comptime DeclType: type) bool {
    const info = switch (@typeInfo(DeclType)) {
        .@"fn" => |fn_info| fn_info,
        else => return false,
    };
    return info.params.len == 1 and info.return_type != null and info.params[0].type == *const T;
}

/// The canvas `TextInputEvent` union's tag vocabulary, pinned here so the
/// declared-shape predicate below stays std-only. A drift test in
/// `ui_markup_contract_tests.zig` holds this list equal to the real union.
pub const text_input_event_tags = [_][]const u8{
    "insert_text",         "delete_backward", "delete_forward",       "delete_word_backward",
    "delete_word_forward", "delete_to_start", "delete_to_line_start", "clear",
    "move_caret",          "set_selection",   "set_composition",      "commit_composition",
    "cancel_composition",
};

/// The caret-direction member vocabulary (`canvas.TextCaretDirection`).
pub const text_caret_direction_members = [_][]const u8{
    "previous", "next", "previous_word", "next_word", "start", "end",
};

pub const text_caret_affinity_members = [_][]const u8{
    "upstream", "downstream",
};

/// A Msg arm payload union DECLARING the text-input event shape rather than
/// being `canvas.TextInputEvent` by identity — the transpiled-core case,
/// where the emitted module declares its own mirror union (type identity
/// cannot cross the emission boundary). Matched structurally, by the same
/// contract everywhere markup resolves `on-input`:
///   - a tagged union carrying exactly the thirteen canvas event tags;
///   - `insert_text` a bytes payload; the nine verb arms void;
///   - `move_caret` a record of `direction` (an enum with exactly the six
///     caret-direction member names) and `extend: bool`;
///   - `set_selection` a record of numeric `anchor`/`focus`, optionally
///     plus the native `upstream`/`downstream` caret-affinity enum;
///   - `set_composition` a record of bytes `text` and optional numeric
///     `cursor`.
/// Numeric fields accept integer or float (the transpiler's number model
/// classes each slot); the dispatch translation widens accordingly.
pub fn declaredTextInputUnion(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"union" => |u| u,
        else => return false,
    };
    if (info.tag_type == null) return false;
    if (info.fields.len != text_input_event_tags.len) return false;
    inline for (text_input_event_tags) |tag| {
        if (!@hasField(T, tag)) return false;
    }
    inline for (info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "insert_text")) {
            if (!isBytes(field.type)) return false;
        } else if (comptime std.mem.eql(u8, field.name, "move_caret")) {
            if (!isCaretMoveRecord(field.type)) return false;
        } else if (comptime std.mem.eql(u8, field.name, "set_selection")) {
            if (!isSelectionRecord(field.type)) return false;
        } else if (comptime std.mem.eql(u8, field.name, "set_composition")) {
            if (!isCompositionRecord(field.type)) return false;
        } else if (field.type != void) {
            return false;
        }
    }
    return true;
}

/// The canvas `ScrollState` field vocabulary — the TWO-AXIS record,
/// eight per-axis fields — pinned here so the declared-shape predicate
/// below stays std-only. A drift test in `ui_markup_contract_tests.zig`
/// holds this list equal to the real struct's fields (names and f32
/// types alike).
pub const scroll_state_field_names = [_][]const u8{
    "offset_x",          "offset_y",
    "velocity_x",        "velocity_y",
    "viewport_extent_x", "viewport_extent_y",
    "content_extent_x",  "content_extent_y",
};

/// The same vocabulary in the TS SDK's spelling (`@native-sdk/core/events`
/// `ScrollState`): transpiled cores emit their mirror record with the
/// field names the TS source wrote — your names are your names — so the
/// structural match accepts either spelling, never a mix.
pub const scroll_state_field_names_ts = [_][]const u8{
    "offsetX",         "offsetY",
    "velocityX",       "velocityY",
    "viewportExtentX", "viewportExtentY",
    "contentExtentX",  "contentExtentY",
};

/// The terminal-state vocabulary `canvas.TerminalState` carries — pinned
/// here so the declared-shape predicate below stays std-only. A drift
/// test in `ui_markup_contract_tests.zig` holds this list equal to the
/// real struct's fields. One spelling only: every field is a single
/// word, so the canvas and TS SDK spellings coincide.
pub const terminal_state_field_names = [_][]const u8{
    "scrollback", "history", "cols", "rows",
};

/// The RETIRED one-axis scroll-state vocabulary, kept only to recognize
/// a pre-two-axis mirror and teach the migration by name (see
/// `declaredLegacyScrollStateRecord`). Nothing dispatches through these
/// fields anymore.
pub const legacy_scroll_state_field_names = [_][]const u8{
    "offset", "velocity", "viewport_extent", "content_extent",
};

/// The retired vocabulary in the TS SDK's spelling.
pub const legacy_scroll_state_field_names_ts = [_][]const u8{
    "offset", "velocity", "viewportExtent", "contentExtent",
};

fn declaredRecordMatchesVocabulary(comptime T: type, comptime canvas_names: []const []const u8, comptime ts_names: []const []const u8) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len != canvas_names.len) return false;
    const canvas_spelling = comptime blk: {
        for (canvas_names) |name| {
            if (!@hasField(T, name)) break :blk false;
        }
        break :blk true;
    };
    const ts_spelling = comptime blk: {
        for (ts_names) |name| {
            if (!@hasField(T, name)) break :blk false;
        }
        break :blk true;
    };
    if (!canvas_spelling and !ts_spelling) return false;
    inline for (info.fields) |field| {
        if (!isNumeric(field.type)) return false;
    }
    return true;
}

/// A Msg arm payload record DECLARING the scroll-state shape rather than
/// being `canvas.ScrollState` by identity — the transpiled-core case,
/// where the emitted module declares its own mirror record (type identity
/// cannot cross the emission boundary). Matched structurally, the
/// `declaredTextInputUnion` contract applied to `on-scroll`: a struct of
/// exactly the eight per-axis field names in either the canvas spelling
/// (`viewport_extent_y`, Zig-declared mirrors and `canvas.ScrollState`
/// itself) or the TS SDK spelling (`viewportExtentY`, the emitted-core
/// mirror — transpiled fields keep their TS names), each numeric. Integer
/// or float per field (the transpiler's number model classes each slot);
/// the dispatch translation widens floats exactly and rounds
/// integer-classed fields to the nearest whole number.
pub fn declaredScrollStateRecord(comptime T: type) bool {
    return declaredRecordMatchesVocabulary(T, &scroll_state_field_names, &scroll_state_field_names_ts);
}

/// A Msg arm payload record DECLARING the terminal-state shape rather
/// than being `canvas.TerminalState` by identity — the transpiled-core
/// case, matched structurally like `declaredScrollStateRecord`: a struct
/// of exactly the four field names (scrollback/history/cols/rows — one
/// spelling, the words are single), each numeric.
pub fn declaredTerminalStateRecord(comptime T: type) bool {
    return declaredRecordMatchesVocabulary(T, &terminal_state_field_names, &terminal_state_field_names);
}

/// A markup `on-drag` Msg payload. `sourceId` is filled from the authored
/// binding (`on-drag="card_dropped:{card.id}"`); the runtime fills the
/// drag phase, point, and receiving view size. Keeping this as one closed
/// record makes the event usable from transpiled cores without type
/// identity crossing the generated-module boundary.
pub fn declaredWidgetDragDropRecord(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len != 6) return false;
    if (!@hasField(T, "sourceId") or !@hasField(T, "phase") or !@hasField(T, "x") or !@hasField(T, "y") or
        !@hasField(T, "viewWidth") or !@hasField(T, "viewHeight")) return false;
    if (!isNumeric(@FieldType(T, "sourceId"))) return false;
    if (!isDragPhaseNumber(@FieldType(T, "phase"))) return false;
    inline for (.{ "x", "y", "viewWidth", "viewHeight" }) |name| {
        if (!isDragGeometryNumber(@FieldType(T, name))) return false;
    }
    return true;
}

/// Live geometry starts as f32 and can be negative while pointer capture
/// carries a drag outside the view. Require a float at least as wide as the
/// source so every accepted record is injectable without a range trap.
fn isDragGeometryNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => |info| info.bits >= 32,
        else => false,
    };
}

/// Phase injection needs to represent all three wire values (0, 1, 2).
/// Floats do so exactly; integer records need an honest upper bound.
fn isDragPhaseNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .float => true,
        .int => std.math.maxInt(T) >= 2,
        else => false,
    };
}

/// A mirror of the RETIRED one-axis scroll state — `{offset, velocity,
/// viewport_extent, content_extent}` in either spelling. Recognized only
/// to fail with a teaching that names the new per-axis fields, so an app
/// carrying the pre-two-axis record shape hears exactly what to declare
/// instead of a generic payload rejection.
pub fn declaredLegacyScrollStateRecord(comptime T: type) bool {
    return declaredRecordMatchesVocabulary(T, &legacy_scroll_state_field_names, &legacy_scroll_state_field_names_ts);
}

/// The machine classes a value-carrying Msg arm may declare for the
/// markup value events (slider `on-change`, split `on-resize`): `f32` is
/// the canvas-native payload Zig cores declare; `f64` is the one-number
/// float arm transpiled cores emit (the timestamp-arm shape, float side),
/// matched structurally because type identity cannot cross the emission
/// boundary — the dispatch translation widens the runtime's applied f32
/// exactly. Integer arms are deliberately excluded: both value events
/// deliver a clamped 0..1 fraction (the slider and split contracts), so
/// an integer arm could only ever receive 0 or 1 — silently useless data
/// the teaching message refuses instead.
pub const ValueArmClass = enum { identity, float };

/// Classify a Msg arm payload as a value arm, or null when the arm
/// cannot carry the control's applied value.
pub fn valueArmClass(comptime T: type) ?ValueArmClass {
    if (T == f32) return .identity;
    if (T == f64) return .float;
    return null;
}

fn isBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |info| info.size == .slice and info.child == u8 and info.is_const,
        else => false,
    };
}

fn isNumeric(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => true,
        else => false,
    };
}

fn isCaretMoveRecord(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len != 2) return false;
    if (!@hasField(T, "direction") or !@hasField(T, "extend")) return false;
    inline for (info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "extend")) {
            if (field.type != bool) return false;
        } else {
            const members = switch (@typeInfo(field.type)) {
                .@"enum" => |e| e.fields,
                else => return false,
            };
            if (members.len != text_caret_direction_members.len) return false;
            inline for (text_caret_direction_members) |name| {
                if (!@hasField(field.type, name)) return false;
            }
        }
    }
    return true;
}

fn isSelectionRecord(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len != 2 and info.fields.len != 3) return false;
    if (!@hasField(T, "anchor") or !@hasField(T, "focus")) return false;
    inline for (info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "affinity")) {
            const members = switch (@typeInfo(field.type)) {
                .@"enum" => |e| e.fields,
                else => return false,
            };
            if (members.len != text_caret_affinity_members.len) return false;
            inline for (text_caret_affinity_members) |name| {
                if (!@hasField(field.type, name)) return false;
            }
        } else if (!isNumeric(field.type)) {
            return false;
        }
    }
    if (info.fields.len == 3 and !@hasField(T, "affinity")) return false;
    return true;
}

fn isCompositionRecord(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .@"struct" => |s| s,
        else => return false,
    };
    if (info.fields.len != 2) return false;
    if (!@hasField(T, "text") or !@hasField(T, "cursor")) return false;
    inline for (info.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "text")) {
            if (!isBytes(field.type)) return false;
        } else {
            const inner = switch (@typeInfo(field.type)) {
                .optional => |o| o.child,
                else => return false,
            };
            if (!isNumeric(inner)) return false;
        }
    }
    return true;
}

/// Types a binding leaf can produce a `Value` from, mirroring the
/// interpreter's runtime acceptance (`valueOf` returning null is exactly
/// when the interpreter reports an unresolvable binding).
pub fn supportedScalar(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .@"enum" => true,
        .pointer => |info| info.size == .slice and info.child == u8,
        .optional => |info| supportedScalar(info.child),
        else => false,
    };
}

/// The `Value` kind a leaf type produces, or null for optionals (none
/// resolves to boolean, some to the child's kind — only known at
/// runtime). Mirrors the compiled engine's `bindingVariant`.
pub fn scalarKindOf(comptime T: type) ?expr.ValueKind {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int => .integer,
        .float => .float,
        .@"enum" => .string,
        .pointer => .string,
        .optional => null,
        else => null,
    };
}

/// A markup literal's value: `true`/`false`, then integer, then float,
/// then plain text — the one classification the interpreter, the compiled
/// engine, and the contract checker all apply to attribute literals and
/// template-arg defaults.
pub fn literalValue(text: []const u8) expr.Value {
    if (std.mem.eql(u8, text, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, text, "false")) return .{ .boolean = false };
    if (std.fmt.parseInt(i64, text, 10)) |int| return .{ .integer = int } else |_| {}
    if (std.fmt.parseFloat(f32, text)) |float| return .{ .float = float } else |_| {}
    return .{ .string = text };
}

/// A bare attribute literal keeps the schema's declared text shape. Text
/// attributes are the one exception to the general literal inference above:
/// `placeholder="123"` is text, while numeric, whole-number, flag, option,
/// and key attributes retain their existing inference and truthiness rules.
/// Expression literals and template defaults intentionally continue to use
/// `literalValue` directly.
pub fn literalValueForAttribute(text: []const u8, attribute_name: []const u8) expr.Value {
    const info = schema.attrByName(attribute_name) orelse return literalValue(text);
    if (info.class == .text) return .{ .string = text };
    return literalValue(text);
}
