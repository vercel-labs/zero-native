//! The model–view contract, checked in both directions at check time.
//!
//! The comptime engine already proves view→model at app build time and the
//! interpreter at view build time; this module makes the same contract
//! available to `native check` in milliseconds, without compiling the app:
//!
//! - `describe` reflects a concrete Model/Msg into a serializable
//!   `Contract` — every scalar binding a view could resolve (fields,
//!   public zero-arg methods, arena-taking scalar methods, nested struct
//!   fields), every iterable `for each` could name, and every Msg tag with
//!   its payload class. The reflection walks the SAME predicates the
//!   engines resolve with (ui_markup_reflect.zig), so the three passes
//!   cannot disagree about what markup can bind.
//! - `emitMain` is the body of the per-app `zig build model-contract`
//!   step: it serializes the contract as ZON into
//!   `zig-out/model-contract.zon` together with a hash over the app's Zig
//!   sources, so a stale artifact is detectable instead of a false pass.
//! - `checkDocument` walks a RESOLVED markup document (imports merged,
//!   `validate` already green) against a contract: binding paths,
//!   iterables and their key fields, message tags and payload classes,
//!   `app:` icon references against the registered icon table, and
//!   the typed expression layer with real binding kinds — the same
//!   accept/reject set as the engines, one grammar earlier in the loop.
//!   Template args are part of a template's interface: use-site argument
//!   kinds flow into the body, and slot content checks in the consumer's
//!   scope, exactly like both engines build.
//! - `deadState` is the reverse direction: model state and Msg tags no
//!   checked view binds or dispatches, reported as WARNINGS (fields that
//!   only update/fx logic reads are legitimate — the opt-out is a
//!   `pub const view_unbound = .{ "name", ... };` declaration on Model or
//!   Msg). Warnings never fail a check unless the caller asks (the CLI's
//!   --strict), which is the promotion hook.
//!
//! std-only by design: `native check` links this module standalone, and
//! the emit program needs nothing beyond the app's own types.

const std = @import("std");
const markup = @import("ui_markup.zig");
const schema = @import("ui_schema.zig");
const expr = @import("ui_markup_expr.zig");
const reflect = @import("ui_markup_reflect.zig");

pub const ValueKind = expr.ValueKind;

// ----------------------------------------------------------- the contract

/// Bumped when the artifact layout or its checking semantics change; a
/// reader refuses versions it does not know (loudly, degrading to
/// structural checks — never a false pass). Version 2: the scroll-state
/// payload class became TWO-AXIS — a format-1 artifact classified the
/// retired four-field record as `.scroll_state`, which both engines now
/// reject, so accepting the stale artifact would be a false pass.
/// Version 3: the `terminal_state` payload class arrived and `on-terminal`
/// gained a bare-tag rule — a format-2 artifact classified a four-field
/// terminal message as `.unsupported` and would reject valid `<terminal>`
/// markup, so a stale artifact must force regeneration rather than pass.
/// Version 4: `drag_drop` classifies the closed release-geometry record
/// used by `on-drag`; older artifacts call it unsupported and would reject
/// a valid binding.
/// Version 5: that record gained the numeric live `phase` field so apps can
/// preview insertion/reordering on change and restore on cancellation.
/// Version 6: live drag geometry requires floating-point fields so captured
/// out-of-view coordinates cannot trap an integer conversion at dispatch.
pub const format_version: u32 = 6;

/// Where the app's build step writes the artifact, relative to the app
/// directory (a build product lives under zig-out, not in durable state).
pub const default_artifact_path = "zig-out/model-contract.zon";
pub const default_source_root = "src";

/// The dead-state opt-out spelling: a public declaration listing names
/// that are intentionally unbound by views (update-only fields, Msg tags
/// only Zig code dispatches). A tuple of string literals keeps it
/// invisible to the binding engines.
pub const opt_out_decl = "view_unbound";

/// The app-icon table spelling: `pub const app_icons` on the app root —
/// the same static table `main` hands to `canvas.icons.registerAppIcons`
/// at boot, so the registered vocabulary and the contract's copy cannot
/// drift (one declaration feeds both). Entries only need a `name` field
/// here; this module never touches the parsed icon data.
pub const app_icons_decl = "app_icons";

/// The markup spelling of an app-icon reference (`app:<name>`); mirrors
/// `ui_markup.app_icon_prefix` (this layer stays std-only, and the
/// conformance suite holds the two equal).
pub const app_icon_prefix = "app:";

/// Reflect the app root's `pub const app_icons` table into the name list
/// the contract carries. Duck-typed on `.name` so the Entry type stays
/// the canvas layer's business; absent decl means "no registered icons".
pub fn appIconNames(comptime app: type) []const []const u8 {
    comptime {
        if (!@hasDecl(app, app_icons_decl)) return &.{};
        var names: []const []const u8 = &.{};
        for (@field(app, app_icons_decl)) |entry| {
            names = names ++ &[_][]const u8{entry.name};
        }
        return names;
    }
}

/// One scalar binding leaf: a field, a public zero-arg method, or an
/// arena-taking scalar method.
pub const Scalar = struct {
    name: []const u8,
    /// Null when only runtime-known (an optional resolves to its inner
    /// kind or boolean false).
    kind: ?ValueKind = null,
    type_name: []const u8 = "",
    /// Arena-computed (`fn (*const T, std.mem.Allocator) V`): allowed
    /// everywhere a scalar binding is, except as `==` comparison operands.
    arena: bool = false,
    fn_backed: bool = false,
};

pub const NamedGroup = struct {
    name: []const u8,
    type_name: []const u8 = "",
    group: Group = .{},
};

/// One struct type's binding surface: scalar leaves plus nested struct
/// fields a dotted path can traverse.
pub const Group = struct {
    scalars: []const Scalar = &.{},
    groups: []const NamedGroup = &.{},
};

/// One `for each` source: a slice/array field, a public slice/array
/// declaration, or a public fn returning a slice (with or without arena).
pub const Iterable = struct {
    name: []const u8,
    item_type: []const u8 = "",
    /// Kind of the bare loop variable when the item type is itself a
    /// scalar (a []const []const u8 iterates strings); null for structs.
    item_kind: ?ValueKind = null,
    item_scalar: bool = false,
    item: Group = .{},
    fn_backed: bool = false,
};

/// Payload classes a markup dispatch can (or cannot) construct. The
/// special classes match the engines exactly: text_input/scroll_state
/// tags bind through on-input/on-scroll only, and `unsupported` payloads
/// cannot be built from markup at all. `legacy_scroll_state` is the
/// RETIRED one-axis scroll record, recognized only so `on-scroll` can
/// teach the two-axis migration by field name.
pub const PayloadClass = enum { none, string, integer, float, boolean, enum_tag, text_input, scroll_state, legacy_scroll_state, terminal_state, drag_drop, unsupported };

pub const MsgTag = struct {
    name: []const u8,
    payload: PayloadClass = .none,
    payload_type: []const u8 = "",
};

pub const Contract = struct {
    format: u32 = format_version,
    /// Hash over the app's Zig sources at emit time (`hashSourceDir`); a
    /// checker recomputes it and degrades to structural checking on any
    /// mismatch. 0 for contracts derived in-process (tests).
    source_hash: u64 = 0,
    source_root: []const u8 = default_source_root,
    model_type: []const u8 = "",
    msg_type: []const u8 = "",
    model: Group = .{},
    iterables: []const Iterable = &.{},
    msgs: []const MsgTag = &.{},
    /// Names opted out of the dead-state lint via `pub const view_unbound`.
    model_unbound: []const []const u8 = &.{},
    msg_unbound: []const []const u8 = &.{},
    /// The app's registered icon vocabulary (`pub const app_icons` on the
    /// app root, the same table `canvas.icons.registerAppIcons` installs
    /// at boot): what markup `app:<name>` references check against. The
    /// engines cannot prove these at build time (registration is a
    /// runtime act), so the contract is where `app:` names get their
    /// typed check. Additive with a default: artifacts from before the
    /// field parse as "no registered icons", never a false pass.
    app_icons: []const []const u8 = &.{},
};

// ------------------------------------------------------------ reflection

/// The payload types the engines special-case; passed in by the canvas
/// layer so this module stays std-only.
pub const Specials = struct {
    TextInputEvent: type,
    ScrollState: type,
    TerminalState: type,
};

/// Reflect a concrete Model/Msg pair into a contract, at comptime. The
/// walk mirrors the interpreter's binding resolution exactly: what this
/// includes is precisely what a view can bind, and nothing else.
pub fn describe(comptime Model: type, comptime Msg: type, comptime specials: Specials) Contract {
    comptime {
        @setEvalBranchQuota(4 * (reflect.typeScanQuota(Model) + reflect.typeScanQuota(Msg)));
        return .{
            .model_type = @typeName(Model),
            .msg_type = @typeName(Msg),
            .model = describeGroup(Model),
            .iterables = describeIterables(Model),
            .msgs = describeMsgs(Msg, specials),
            .model_unbound = optOutNames(Model),
            .msg_unbound = optOutNames(Msg),
        };
    }
}

fn describeGroup(comptime T: type) Group {
    return describeGroupSeen(T, &.{});
}

fn describeGroupSeen(comptime T: type, comptime seen: []const type) Group {
    comptime {
        var scalars: []const Scalar = &.{};
        var groups: []const NamedGroup = &.{};
        for (@typeInfo(T).@"struct".fields) |field| {
            if (reflect.supportedScalar(field.type)) {
                scalars = scalars ++ &[_]Scalar{.{
                    .name = field.name,
                    .kind = reflect.scalarKindOf(field.type),
                    .type_name = @typeName(field.type),
                }};
                continue;
            }
            // `reflect.Pointee` transparency: a `*const Row` field
            // traverses like the struct it shares. Pointer models can
            // cycle (unlike by-value structs), so already-described
            // types stop the walk — the engines resolve such paths
            // segment by segment and never recurse into the type graph.
            const Nested = reflect.Pointee(field.type);
            if (@typeInfo(Nested) == .@"struct" and !typeListed(Nested, seen ++ &[_]type{T})) {
                groups = groups ++ &[_]NamedGroup{.{
                    .name = field.name,
                    .type_name = @typeName(Nested),
                    .group = describeGroupSeen(Nested, seen ++ &[_]type{T}),
                }};
            }
        }
        for (@typeInfo(T).@"struct".decls) |decl| {
            const DeclType = @TypeOf(@field(T, decl.name));
            if (@typeInfo(DeclType) != .@"fn") continue;
            const info = @typeInfo(DeclType).@"fn";
            if (reflect.isZeroArgFn(T, DeclType) and reflect.supportedScalar(info.return_type.?)) {
                scalars = scalars ++ &[_]Scalar{.{
                    .name = decl.name,
                    .kind = reflect.scalarKindOf(info.return_type.?),
                    .type_name = @typeName(info.return_type.?),
                    .fn_backed = true,
                }};
                continue;
            }
            if (reflect.isArenaScalarFn(T, DeclType) and reflect.supportedScalar(info.return_type.?)) {
                scalars = scalars ++ &[_]Scalar{.{
                    .name = decl.name,
                    .kind = reflect.scalarKindOf(info.return_type.?),
                    .type_name = @typeName(info.return_type.?),
                    .arena = true,
                    .fn_backed = true,
                }};
            }
        }
        return .{ .scalars = scalars, .groups = groups };
    }
}

fn typeListed(comptime T: type, comptime seen: []const type) bool {
    for (seen) |S| {
        if (S == T) return true;
    }
    return false;
}

fn describeItem(comptime Item: type) Iterable {
    comptime {
        // `reflect.Pointee` transparency: `[]const *const Row` iterates
        // items that bind like Row itself.
        const Bare = reflect.Pointee(Item);
        return .{
            .name = "",
            .item_type = @typeName(Bare),
            .item_kind = if (reflect.supportedScalar(Item)) reflect.scalarKindOf(Item) else null,
            .item_scalar = reflect.supportedScalar(Item),
            .item = if (@typeInfo(Bare) == .@"struct") describeGroup(Bare) else .{},
        };
    }
}

fn describeIterables(comptime Model: type) []const Iterable {
    comptime {
        var iterables: []const Iterable = &.{};
        for (@typeInfo(Model).@"struct".fields) |field| {
            if (reflect.sliceElement(field.type)) |Item| {
                var entry = describeItem(Item);
                entry.name = field.name;
                iterables = iterables ++ &[_]Iterable{entry};
            }
        }
        for (@typeInfo(Model).@"struct".decls) |decl| {
            const DeclType = @TypeOf(@field(Model, decl.name));
            if (reflect.sliceElement(DeclType)) |Item| {
                var entry = describeItem(Item);
                entry.name = decl.name;
                iterables = iterables ++ &[_]Iterable{entry};
                continue;
            }
            if (@typeInfo(DeclType) != .@"fn") continue;
            const Return = @typeInfo(DeclType).@"fn".return_type orelse continue;
            const Item = reflect.sliceElement(Return) orelse continue;
            if (reflect.isItemFn(DeclType, Item, false) or reflect.isItemFn(DeclType, Item, true)) {
                var entry = describeItem(Item);
                entry.name = decl.name;
                entry.fn_backed = true;
                iterables = iterables ++ &[_]Iterable{entry};
            }
        }
        return iterables;
    }
}

fn describeMsgs(comptime Msg: type, comptime specials: Specials) []const MsgTag {
    comptime {
        var tags: []const MsgTag = &.{};
        for (@typeInfo(Msg).@"union".fields) |field| {
            tags = tags ++ &[_]MsgTag{.{
                .name = field.name,
                .payload = payloadClassOf(field.type, specials),
                .payload_type = if (field.type == void) "" else @typeName(field.type),
            }};
        }
        return tags;
    }
}

fn payloadClassOf(comptime T: type, comptime specials: Specials) PayloadClass {
    if (T == void) return .none;
    if (T == specials.TextInputEvent) return .text_input;
    // A declared mirror of the text-input event union (transpiled cores,
    // where type identity cannot cross the emission boundary) binds
    // through on-input exactly like the canvas type — same resolution as
    // both engines' inputConstructor.
    if (reflect.declaredTextInputUnion(T)) return .text_input;
    if (T == specials.ScrollState) return .scroll_state;
    // A declared mirror of the scroll-state record (transpiled cores) binds
    // through on-scroll exactly like the canvas type — same resolution as
    // both engines' scrollConstructor.
    if (reflect.declaredScrollStateRecord(T)) return .scroll_state;
    // The retired ONE-AXIS record classifies separately so on-scroll can
    // teach the two-axis migration by field name instead of rejecting
    // the payload generically.
    if (reflect.declaredLegacyScrollStateRecord(T)) return .legacy_scroll_state;
    if (T == specials.TerminalState) return .terminal_state;
    // A declared mirror of the terminal-state record (transpiled cores)
    // binds through on-terminal exactly like the canvas type — same
    // resolution as both engines' terminalConstructor.
    if (reflect.declaredTerminalStateRecord(T)) return .terminal_state;
    if (reflect.declaredWidgetDragDropRecord(T)) return .drag_drop;
    return switch (@typeInfo(T)) {
        .int => .integer,
        .float => .float,
        .bool => .boolean,
        .@"enum" => .enum_tag,
        .pointer => |info| if (info.size == .slice and info.child == u8) .string else .unsupported,
        else => .unsupported,
    };
}

fn optOutNames(comptime T: type) []const []const u8 {
    comptime {
        if (!@hasDecl(T, opt_out_decl)) return &.{};
        const value = @field(T, opt_out_decl);
        const V = @TypeOf(value);
        const teaching = "pub const " ++ opt_out_decl ++ " lists names as string literals: pub const " ++ opt_out_decl ++ " = .{ \"field_name\" };";
        var names: []const []const u8 = &.{};
        switch (@typeInfo(V)) {
            .@"struct" => |info| {
                if (!info.is_tuple) @compileError(teaching);
                for (info.fields) |field| {
                    const name: []const u8 = @field(value, field.name);
                    names = names ++ &[_][]const u8{name};
                }
            },
            .array, .pointer => {
                for (value) |name| {
                    const slice: []const u8 = name;
                    names = names ++ &[_][]const u8{slice};
                }
            },
            else => @compileError(teaching),
        }
        return names;
    }
}

// -------------------------------------------------------------- messages
//
// The view→model failure vocabulary is the ENGINES' vocabulary: the
// conformance suite (ui_markup_contract_tests.zig) drives the interpreter
// over the same fixtures and asserts these strings match its diagnostics,
// so the two checkers cannot drift apart silently.

pub const binding_model_message = "binding does not name a model field";
pub const binding_item_message = "binding does not name a field on the loop item";
pub const value_arg_fields_message = "template arg values have no fields";
pub const slice_arg_value_message = "slice-valued template args are only usable with for each";
pub const item_value_message = "loop items of this type cannot be used as values";
pub const each_message = "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)";
pub const key_field_message = "key does not name a field on the item";
pub const key_kind_message = "key fields must be integers or strings";
pub const attr_key_kind_message = "keys must be integers or strings";
pub const unknown_tag_message = "unknown message tag";
pub const no_payload_message = "message does not take a payload";
pub const payload_required_message = "message requires a payload";
pub const payload_type_message = "payload type does not match the message";
pub const on_input_payload_message = "on-input tag must carry a TextInputEvent payload";
pub const number_attr_message = "expected a number";
pub const whole_attr_message = "expected a whole number";
pub const text_attr_message = "expected text";
pub const option_attr_message = "expected an option name";
pub const role_attr_message = "role expects a role name";
pub const label_attr_message = "label expects text";

// Contract-only findings (no engine counterpart, like the dead-state
// lint): `app:` icon names are runtime registrations the engines cannot
// prove, so this pass is where they get their typed check.
pub const unknown_app_icon_message = "app: does not name a registered app icon (the contract's app_icons list)";
pub const no_app_icons_message = "app: references a registered app icon, but this app registers none - declare pub const app_icons on the app root, pass it to canvas.icons.registerAppIcons at boot, and refresh the contract";
pub const icon_binding_kind_message = "icon bindings must produce a string naming an icon (a built-in name or app:<name>)";

// ------------------------------------------------- attribute kind classes

/// What kind of value each generic option attribute consumes, mirroring
/// how both engines apply `Ui.ElementOptions` fields (float fields take
/// numbers, enum fields take option-name strings, bool fields take any
/// truthy value, ...). Derived from the registry's value classes; a
/// conformance test in ui_markup_view_tests.zig derives the same classes
/// from the real field types, so registry, check-time pass, and
/// build-time pass cannot drift.
pub const AttrClass = enum { number, whole, truthy, text, option };

pub const AttrKindRule = struct { name: []const u8, class: AttrClass };

pub const attr_kind_rules = blk: {
    @setEvalBranchQuota(10_000);
    var rules: [schema.option_field_pairs.len]AttrKindRule = undefined;
    var index: usize = 0;
    for (schema.attrs) |entry| {
        if (entry.group != .option or entry.field.len == 0) continue;
        rules[index] = .{ .name = entry.name, .class = switch (entry.class) {
            .text => .text,
            .number => .number,
            .whole => .whole,
            .flag => .truthy,
            .option => .option,
            else => @compileError("field-backed option attr with a non-generic value class: " ++ entry.name),
        } };
        index += 1;
    }
    break :blk rules;
};

fn attrClass(name: []const u8) ?AttrClass {
    for (attr_kind_rules) |rule| {
        if (std.mem.eql(u8, rule.name, name)) return rule.class;
    }
    return null;
}

// ------------------------------------------------------------ dead state

/// Which contract entries the checked views actually bound: fed by
/// `checkDocument` across every view in an app, read once by `deadState`.
/// Name-based on purpose — a []const u8 field appears both as a scalar
/// and (as a byte iterable) in the iterables list, and binding it either
/// way counts.
pub const Usage = struct {
    scalar_used: []bool,
    group_used: []bool,
    iterable_used: []bool,
    msg_used: []bool,

    pub fn init(arena: std.mem.Allocator, contract: *const Contract) error{OutOfMemory}!Usage {
        const usage = Usage{
            .scalar_used = try arena.alloc(bool, contract.model.scalars.len),
            .group_used = try arena.alloc(bool, contract.model.groups.len),
            .iterable_used = try arena.alloc(bool, contract.iterables.len),
            .msg_used = try arena.alloc(bool, contract.msgs.len),
        };
        @memset(usage.scalar_used, false);
        @memset(usage.group_used, false);
        @memset(usage.iterable_used, false);
        @memset(usage.msg_used, false);
        return usage;
    }

    fn markModel(self: *Usage, contract: *const Contract, name: []const u8) void {
        for (contract.model.scalars, 0..) |scalar, index| {
            if (std.mem.eql(u8, scalar.name, name)) self.scalar_used[index] = true;
        }
        for (contract.model.groups, 0..) |group, index| {
            if (std.mem.eql(u8, group.name, name)) self.group_used[index] = true;
        }
        for (contract.iterables, 0..) |iterable, index| {
            if (std.mem.eql(u8, iterable.name, name)) self.iterable_used[index] = true;
        }
    }

    fn markMsg(self: *Usage, contract: *const Contract, name: []const u8) void {
        for (contract.msgs, 0..) |tag, index| {
            if (std.mem.eql(u8, tag.name, name)) self.msg_used[index] = true;
        }
    }

    fn usedName(self: *const Usage, contract: *const Contract, name: []const u8) bool {
        for (contract.model.scalars, 0..) |scalar, index| {
            if (self.scalar_used[index] and std.mem.eql(u8, scalar.name, name)) return true;
        }
        for (contract.model.groups, 0..) |group, index| {
            if (self.group_used[index] and std.mem.eql(u8, group.name, name)) return true;
        }
        for (contract.iterables, 0..) |iterable, index| {
            if (self.iterable_used[index] and std.mem.eql(u8, iterable.name, name)) return true;
        }
        return false;
    }
};

/// Model→view lint: model state and Msg tags no checked view binds or
/// dispatches. WARNING class — model-only state is legitimate; the
/// opt-out is `pub const view_unbound = .{ "name" };` on Model/Msg, and
/// promotion to a failure is the caller's call (the CLI's --strict).
/// Positions are zeroed: these findings live on the Zig side, which the
/// contract does not carry source spans for.
pub fn deadState(arena: std.mem.Allocator, contract: *const Contract, usage: *const Usage) error{OutOfMemory}![]const markup.MarkupErrorInfo {
    var out: std.ArrayListUnmanaged(markup.MarkupErrorInfo) = .empty;
    // One finding per top-level name: a []const u8 fn is both a string
    // scalar and (as bytes) an iterable, and one warning is the truth.
    var reported: std.ArrayListUnmanaged([]const u8) = .empty;
    for (contract.model.scalars, 0..) |scalar, index| {
        if (usage.scalar_used[index]) continue;
        if (usage.usedName(contract, scalar.name)) continue;
        if (nameListed(contract.model_unbound, scalar.name)) continue;
        if (nameListed(reported.items, scalar.name)) continue;
        try reported.append(arena, scalar.name);
        const message = if (scalar.fn_backed)
            try std.fmt.allocPrint(arena, "model fn \"{s}\" ({s}) is never bound in markup - bind it, remove it, or add it to pub const view_unbound if only update/fx logic or a Zig-built view calls it", .{ scalar.name, scalar.type_name })
        else
            try std.fmt.allocPrint(arena, "model field \"{s}\" ({s}) is never bound in markup - bind it, or add it to pub const view_unbound if only update/fx logic or a Zig-built view reads it", .{ scalar.name, scalar.type_name });
        try out.append(arena, .{ .message = message });
    }
    for (contract.model.groups, 0..) |group, index| {
        if (usage.group_used[index]) continue;
        if (usage.usedName(contract, group.name)) continue;
        if (nameListed(contract.model_unbound, group.name)) continue;
        if (nameListed(reported.items, group.name)) continue;
        try reported.append(arena, group.name);
        try out.append(arena, .{ .message = try std.fmt.allocPrint(arena, "model field \"{s}\" ({s}) has no markup binding into any of its fields - bind one, or add it to pub const view_unbound if only update/fx logic or a Zig-built view reads it", .{ group.name, group.type_name }) });
    }
    for (contract.iterables, 0..) |iterable, index| {
        if (usage.iterable_used[index]) continue;
        if (usage.usedName(contract, iterable.name)) continue;
        if (nameListed(contract.model_unbound, iterable.name)) continue;
        if (std.mem.eql(u8, iterable.name, opt_out_decl)) continue;
        if (nameListed(reported.items, iterable.name)) continue;
        try reported.append(arena, iterable.name);
        try out.append(arena, .{ .message = try std.fmt.allocPrint(arena, "model iterable \"{s}\" (items: {s}) is never iterated in markup - use it with for each, or add it to pub const view_unbound if only update/fx logic or a Zig-built view reads it", .{ iterable.name, iterable.item_type }) });
    }
    for (contract.msgs, 0..) |tag, index| {
        if (usage.msg_used[index]) continue;
        if (nameListed(contract.msg_unbound, tag.name)) continue;
        try out.append(arena, .{ .message = try std.fmt.allocPrint(arena, "Msg tag \"{s}\" is never dispatched from markup - wire it to an on-* event, or add it to pub const view_unbound if only Zig code sends it", .{tag.name}) });
    }
    return out.items;
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

// ------------------------------------------------------------- the check

/// Check one RESOLVED document (imports merged, `markup.validate` green)
/// against a contract. Returns the first view→model failure, or null.
/// A document without a view root is a component file: its templates are
/// checked through every view that imports them, where use-site argument
/// kinds exist. `usage` (optional) accumulates dead-state facts across an
/// app's documents.
pub fn checkDocument(
    arena: std.mem.Allocator,
    document: markup.MarkupDocument,
    contract: *const Contract,
    usage: ?*Usage,
) error{OutOfMemory}!?markup.MarkupErrorInfo {
    const root = document.root orelse return null;
    if (document.imports.len > 0) {
        return .{
            .line = document.imports[0].line,
            .column = document.imports[0].column,
            .message = markup.import_unresolved_message,
            .path = document.imports[0].src_path,
        };
    }
    var checker = Checker{
        .arena = arena,
        .document = document,
        .contract = contract,
        .usage = usage,
    };
    checker.checkNode(root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ContractCheck => return checker.failure,
    };
    return null;
}

const CheckErr = error{ OutOfMemory, ContractCheck };

const max_scope_depth = 16;
const max_use_depth = 128;

/// A resolved binding: its value kind when statically known, and the Zig
/// type name for teaching messages.
const Resolved = struct {
    kind: ?ValueKind = null,
    type_name: []const u8 = "",
};

const ItemRef = struct {
    type_name: []const u8 = "",
    kind: ?ValueKind = null,
    scalar: bool = false,
    group: *const Group,
};

const SlotCapture = struct {
    nodes: []const markup.MarkupNode,
    len: usize,
    floor: usize,
    template_ctx: ?usize,
};

const Binder = union(enum) {
    item: ItemRef,
    slice: ItemRef,
    value: ?ValueKind,
    slot: SlotCapture,
};

const ScopeEntry = struct {
    name: []const u8,
    binder: Binder,
};

const Checker = struct {
    arena: std.mem.Allocator,
    document: markup.MarkupDocument,
    contract: *const Contract,
    usage: ?*Usage,
    failure: markup.MarkupErrorInfo = .{},
    entries: [max_scope_depth]ScopeEntry = undefined,
    len: usize = 0,
    /// Bindings resolve entries[floor..len] then the model: a template
    /// body sees its args and its own loop variables, never the loop
    /// variables at the expansion site (interpreter parity).
    floor: usize = 0,
    use_depth: usize = 0,
    template_ctx: ?usize = null,

    // ------------------------------------------------------ diagnostics

    fn fail(self: *Checker, node: markup.MarkupNode, message: []const u8) CheckErr {
        self.failure = .{ .line = node.line, .column = node.column, .message = message, .path = node.src_path };
        return error.ContractCheck;
    }

    fn failAttr(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, message: []const u8) CheckErr {
        self.failure = .{ .line = attribute.line, .column = attribute.column, .message = message, .path = node.src_path };
        return error.ContractCheck;
    }

    /// The engines' message plus a token/did-you-mean suffix — the base
    /// stays a prefix so the conformance suite can hold the vocabularies
    /// equal.
    fn failNamed(self: *Checker, node: markup.MarkupNode, base: []const u8, token: []const u8, candidates: NameSource) CheckErr {
        const message = self.namedMessage(base, token, candidates) catch return error.OutOfMemory;
        return self.fail(node, message);
    }

    fn namedMessage(self: *Checker, base: []const u8, token: []const u8, candidates: NameSource) error{OutOfMemory}![]const u8 {
        if (nearestCandidate(token, candidates)) |suggestion| {
            return std.fmt.allocPrint(self.arena, "{s} (\"{s}\" - did you mean \"{s}\"?)", .{ base, token, suggestion });
        }
        return std.fmt.allocPrint(self.arena, "{s} (\"{s}\")", .{ base, token });
    }

    // ------------------------------------------------------------ scope

    fn lookup(self: *const Checker, head: []const u8) ?*const ScopeEntry {
        var index = self.len;
        while (index > self.floor) {
            index -= 1;
            if (std.mem.eql(u8, self.entries[index].name, head)) return &self.entries[index];
        }
        return null;
    }

    fn slotCapture(self: *const Checker) ?SlotCapture {
        var index = self.len;
        while (index > self.floor) {
            index -= 1;
            if (self.entries[index].binder == .slot) return self.entries[index].binder.slot;
        }
        return null;
    }

    // --------------------------------------------------------- bindings

    fn markModel(self: *Checker, name: []const u8) void {
        if (self.usage) |usage| usage.markModel(self.contract, name);
    }

    fn resolveBinding(self: *Checker, node: markup.MarkupNode, path: []const u8, allow_arena: bool) CheckErr!Resolved {
        const head = pathHead(path);
        if (self.lookup(head)) |entry| {
            switch (entry.binder) {
                .item => |item| {
                    if (pathTail(path)) |tail| {
                        switch (resolveOnGroup(item.group, tail, allow_arena)) {
                            .ok => |resolved| return resolved,
                            .arena_blocked => return self.fail(node, markup.arena_scalar_equality_message),
                            .missing => return self.failNamed(node, binding_item_message, path, .{ .group = item.group }),
                        }
                    }
                    if (!item.scalar) return self.fail(node, item_value_message);
                    return .{ .kind = item.kind, .type_name = item.type_name };
                },
                .value => |kind| {
                    if (pathTail(path) != null) return self.fail(node, value_arg_fields_message);
                    return .{ .kind = kind };
                },
                .slice => return self.fail(node, slice_arg_value_message),
                // Slot captures carry an empty name, which no binding
                // head can equal.
                .slot => unreachable,
            }
        }
        switch (resolveOnGroup(&self.contract.model, path, allow_arena)) {
            .ok => |resolved| {
                self.markModel(head);
                return resolved;
            },
            .arena_blocked => return self.fail(node, markup.arena_scalar_equality_message),
            .missing => {
                // A TextBuffer field is the edit model, not bindable
                // text: the reflected contract carries it as a group
                // whose type name spells the buffer out (engine parity).
                for (self.contract.model.groups) |group| {
                    if (std.mem.eql(u8, group.name, head) and std.mem.indexOf(u8, group.type_name, "TextBuffer(") != null) {
                        return self.fail(node, markup.binding_text_buffer_message);
                    }
                }
                return self.failNamed(node, binding_model_message, path, .{ .model = self.contract });
            },
        }
    }

    // ------------------------------------------------------ expressions

    /// Static kind of an attribute value, with every binding resolved
    /// against the contract and the whole expression run through the
    /// shared type checker with those kinds — `{count > 'a'}` fails here
    /// with the evaluator's teaching message and the model field's type.
    fn expressionKind(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, raw: []const u8, attribute_aware: bool) CheckErr!?ValueKind {
        const expression = markup.parseAttrExpression(raw) orelse {
            return self.failAttr(node, attribute, markup.invalid_expression_message);
        };
        return switch (expression) {
            .literal => |text| expr.kindOf(if (attribute_aware)
                reflect.literalValueForAttribute(text, attribute.name)
            else
                reflect.literalValue(text)),
            .binding => |path| (try self.resolveBinding(node, path, true)).kind,
            .equals => |sides| blk: {
                // Arena-computed bindings are excluded from equality on
                // purpose (engine parity): compare source fields, or bind
                // a bool-returning fn.
                _ = try self.resolveBinding(node, sides.left, false);
                _ = try self.resolveBinding(node, sides.right, false);
                break :blk .boolean;
            },
            .expression => |inner| try self.exprTreeKind(node, inner),
        };
    }

    fn attrKind(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, raw: []const u8) CheckErr!?ValueKind {
        return self.expressionKind(node, attribute, raw, true);
    }

    fn unclassifiedKind(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, raw: []const u8) CheckErr!?ValueKind {
        return self.expressionKind(node, attribute, raw, false);
    }

    fn exprTreeKind(self: *Checker, node: markup.MarkupNode, inner: []const u8) CheckErr!?ValueKind {
        var tree: expr.ExprTree = .{};
        var diagnostic: expr.Diagnostic = .{};
        if (!expr.parse(inner, &tree, &diagnostic)) {
            return self.fail(node, diagnostic.message);
        }
        var kinds: [expr.max_expression_nodes]?ValueKind = @splat(null);
        var names: [expr.max_expression_nodes][]const u8 = undefined;
        var types: [expr.max_expression_nodes][]const u8 = undefined;
        var binding_count: usize = 0;
        for (tree.nodes[0..tree.len], 0..) |expr_node, index| {
            if (expr_node.kind != .binding) continue;
            // Comparison operands reject arena-computed scalars, the same
            // teaching rule as `{a == b}`.
            const resolved = try self.resolveBinding(node, expr_node.text, !expr_node.comparison_operand);
            kinds[index] = resolved.kind;
            if (resolved.type_name.len > 0 and binding_count < names.len) {
                names[binding_count] = expr_node.text;
                types[binding_count] = resolved.type_name;
                binding_count += 1;
            }
        }
        const result = expr.checkTypes(&tree, &kinds, &diagnostic) catch {
            return self.failExprType(node, diagnostic.message, names[0..binding_count], types[0..binding_count]);
        };
        return result;
    }

    /// A type-discipline failure with the model bindings named: the
    /// evaluator's teaching message, then which binding is which Zig type.
    fn failExprType(self: *Checker, node: markup.MarkupNode, base: []const u8, names: []const []const u8, types: []const []const u8) CheckErr {
        if (names.len == 0) return self.fail(node, base);
        var out: std.ArrayListUnmanaged(u8) = .empty;
        out.appendSlice(self.arena, base) catch return error.OutOfMemory;
        out.appendSlice(self.arena, " (where ") catch return error.OutOfMemory;
        const shown = @min(names.len, 4);
        for (names[0..shown], types[0..shown], 0..) |name, type_name, index| {
            if (index > 0) out.appendSlice(self.arena, ", ") catch return error.OutOfMemory;
            out.appendSlice(self.arena, name) catch return error.OutOfMemory;
            out.appendSlice(self.arena, ": ") catch return error.OutOfMemory;
            out.appendSlice(self.arena, type_name) catch return error.OutOfMemory;
        }
        out.appendSlice(self.arena, ")") catch return error.OutOfMemory;
        return self.fail(node, out.items);
    }

    fn requireAttrKind(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, kind: ?ValueKind, allowed: []const ValueKind, message: []const u8) CheckErr!void {
        const known = kind orelse return;
        for (allowed) |candidate| {
            if (known == candidate) return;
        }
        return self.failAttr(node, attribute, message);
    }

    fn checkClassAttr(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, class: AttrClass) CheckErr!void {
        const kind = try self.attrKind(node, attribute, attribute.value);
        switch (class) {
            .number => try self.requireAttrKind(node, attribute, kind, &.{ .integer, .float }, number_attr_message),
            .whole => try self.requireAttrKind(node, attribute, kind, &.{.integer}, whole_attr_message),
            .text => try self.requireAttrKind(node, attribute, kind, &.{.string}, text_attr_message),
            .option => try self.requireAttrKind(node, attribute, kind, &.{.string}, option_attr_message),
            // Bool fields accept any value through truthiness (engine
            // parity) — resolving the bindings was the whole check.
            .truthy => {},
        }
    }

    // --------------------------------------------------------- messages

    fn findMsg(self: *Checker, tag: []const u8) ?MsgTag {
        for (self.contract.msgs) |candidate| {
            if (std.mem.eql(u8, candidate.name, tag)) {
                if (self.usage) |usage| usage.markMsg(self.contract, tag);
                return candidate;
            }
        }
        return null;
    }

    fn checkMessageAttr(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr) CheckErr!void {
        const expression = markup.parseMessageExpression(attribute.value) orelse return;
        const event = attribute.name[3..];
        const tag = self.findMsg(expression.tag);
        if (std.mem.eql(u8, event, "input")) {
            const found = tag orelse return self.failAttr(node, attribute, on_input_payload_message);
            if (found.payload != .text_input) return self.failAttr(node, attribute, on_input_payload_message);
            return;
        }
        if (std.mem.eql(u8, event, "scroll")) {
            const found = tag orelse return self.failAttr(node, attribute, markup.on_scroll_payload_message);
            // The retired one-axis record gets the migration teaching —
            // it names the new per-axis fields — instead of the generic
            // payload rejection.
            if (found.payload == .legacy_scroll_state) return self.failAttr(node, attribute, markup.on_scroll_legacy_payload_message);
            if (found.payload != .scroll_state) return self.failAttr(node, attribute, markup.on_scroll_payload_message);
            return;
        }
        if (std.mem.eql(u8, event, "terminal")) {
            // The runtime supplies the TerminalState payload, so the tag
            // is BARE: an authored `:{binding}` would be silently
            // discarded, which is the teaching error (dead data), not a
            // pass.
            if (expression.payload.len > 0) return self.failAttr(node, attribute, markup.on_terminal_payload_message);
            const found = tag orelse return self.failAttr(node, attribute, markup.on_terminal_payload_message);
            if (found.payload != .terminal_state) return self.failAttr(node, attribute, markup.on_terminal_payload_message);
            return;
        }
        if (std.mem.eql(u8, event, "resize")) {
            // f32 is the canvas-native arm; f64 the transpiled one-number
            // float arm (engine parity — integer arms stay excluded, a
            // fraction rounded into an integer would be useless data).
            const found = tag orelse return self.failAttr(node, attribute, markup.on_resize_payload_message);
            const resize_ok = found.payload == .float and
                (std.mem.eql(u8, found.payload_type, "f32") or std.mem.eql(u8, found.payload_type, "f64"));
            if (!resize_ok) {
                return self.failAttr(node, attribute, markup.on_resize_payload_message);
            }
            return;
        }
        if (std.mem.eql(u8, event, "drag")) {
            const found = tag orelse return self.failAttr(node, attribute, markup.on_drag_payload_message);
            if (found.payload != .drag_drop or expression.payload.len == 0) {
                return self.failAttr(node, attribute, markup.on_drag_payload_message);
            }
            const resolved = try self.resolveBinding(node, expression.payload, true);
            try self.requirePayloadKind(node, attribute, resolved, &.{.integer}, found);
            return;
        }
        // The value-payload change event (engine parity): a slider's
        // on-change with a bare tag naming a value-carrying arm — f32 (the
        // canvas-native shape) or the transpiled one-number float arm
        // (f64) — dispatches the applied 0..1 fraction. Void arms fall
        // through to the static form below.
        if (std.mem.eql(u8, event, "change") and std.mem.eql(u8, node.name, "slider") and expression.payload.len == 0) {
            if (tag) |found| {
                const value_arm = found.payload == .float and
                    (std.mem.eql(u8, found.payload_type, "f32") or std.mem.eql(u8, found.payload_type, "f64"));
                if (value_arm) return;
            }
        }
        const found = tag orelse return self.failNamed(node, unknown_tag_message, expression.tag, .{ .msgs = self.contract });
        if (found.payload == .none) {
            if (expression.payload.len > 0) return self.failAttr(node, attribute, no_payload_message);
            return;
        }
        if (expression.payload.len == 0) return self.failAttr(node, attribute, payload_required_message);
        const resolved = try self.resolveBinding(node, expression.payload, true);
        switch (found.payload) {
            .integer => try self.requirePayloadKind(node, attribute, resolved, &.{.integer}, found),
            .float => try self.requirePayloadKind(node, attribute, resolved, &.{ .float, .integer }, found),
            .string, .enum_tag => try self.requirePayloadKind(node, attribute, resolved, &.{.string}, found),
            // Bool payloads accept any value through truthiness.
            .boolean => {},
            // These payloads cannot be constructed from a markup binding
            // (input/scroll payloads bind through their own events).
            .text_input, .scroll_state, .legacy_scroll_state, .terminal_state, .drag_drop, .unsupported => return self.failPayloadType(node, attribute, resolved, found),
            .none => unreachable,
        }
    }

    fn requirePayloadKind(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, resolved: Resolved, allowed: []const ValueKind, tag: MsgTag) CheckErr!void {
        const known = resolved.kind orelse return;
        for (allowed) |candidate| {
            if (known == candidate) return;
        }
        return self.failPayloadType(node, attribute, resolved, tag);
    }

    fn failPayloadType(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr, resolved: Resolved, tag: MsgTag) CheckErr {
        const message = if (resolved.type_name.len > 0)
            std.fmt.allocPrint(self.arena, "{s} (\"{s}\" carries {s}; the binding is {s})", .{ payload_type_message, tag.name, tag.payload_type, resolved.type_name }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(self.arena, "{s} (\"{s}\" carries {s})", .{ payload_type_message, tag.name, tag.payload_type }) catch return error.OutOfMemory;
        return self.failAttr(node, attribute, message);
    }

    // -------------------------------------------------------- iterables

    fn resolveIterable(self: *Checker, node: markup.MarkupNode, name: []const u8, message: []const u8) CheckErr!ItemRef {
        if (self.lookup(name)) |entry| {
            if (entry.binder == .slice) return entry.binder.slice;
            return self.fail(node, message);
        }
        for (self.contract.iterables) |*iterable| {
            if (std.mem.eql(u8, iterable.name, name)) {
                self.markModel(name);
                return itemRefOf(iterable);
            }
        }
        return self.failNamed(node, message, name, .{ .iterables = self.contract });
    }

    fn checkFor(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        const each = node.attr("each") orelse return;
        const as_name = node.attr("as") orelse return;
        const item = try self.resolveIterable(node, each, each_message);
        if (node.attr("key")) |field| {
            // Keys stay identity-stable data: fields and zero-arg methods
            // only, never arena-computed values (engine parity).
            switch (resolveOnGroup(item.group, field, false)) {
                .ok => |resolved| {
                    if (resolved.kind) |known| {
                        if (known != .integer and known != .string) {
                            return self.fail(node, key_kind_message);
                        }
                    }
                },
                .arena_blocked, .missing => {
                    return self.failNamed(node, key_field_message, field, .{ .group = item.group });
                },
            }
        }
        if (self.len >= max_scope_depth) return self.fail(node, "for nesting is too deep");
        self.entries[self.len] = .{ .name = as_name, .binder = .{ .item = item } };
        self.len += 1;
        defer self.len -= 1;
        try self.checkChildList(node.children);
    }

    // -------------------------------------------------------- templates

    fn checkUse(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        const template_name = node.attr("template") orelse return;
        const template_index = self.document.templateIndex(template_name) orelse {
            return self.fail(node, markup.use_undefined_template_message);
        };
        // The define-before-use rule again at check time: it is what
        // bounds expansion, so an unvalidated document cannot recurse.
        if (self.template_ctx) |ctx_index| {
            if (template_index >= ctx_index) {
                return self.fail(node, markup.use_earlier_template_message);
            }
        }
        if (self.use_depth >= max_use_depth) {
            return self.fail(node, "template expansion nests too deeply");
        }
        const template_node = self.document.templates[template_index];
        if (template_node.children.len != 1 or template_node.children[0].kind != .element) return;

        // A use-site press is forwarded to the expanded template root. It
        // is a message expression, not a template argument, and its payload
        // resolves in the consumer's scope.
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "on-press")) {
                try self.checkMessageAttr(node, attribute);
            }
        }

        // Evaluate every arg's kind against the pristine use-site scope
        // before any entry is pushed, so args cannot see each other.
        const saved_len = self.len;
        const saved_floor = self.floor;
        const saved_ctx = self.template_ctx;
        var arg_count: usize = 0;
        var args = markup.templateArgs(template_node);
        while (args.next()) |token| {
            const arg = markup.parseTemplateArg(token);
            if (saved_len + arg_count >= max_scope_depth) {
                return self.fail(node, "template args nest too deep");
            }
            const binder: Binder = if (attrOf(node, arg.name)) |attribute|
                try self.argBinder(node, attribute)
            else if (arg.default) |default| blk: {
                if (std.mem.indexOfScalar(u8, default, '{') != null) {
                    return self.fail(template_node, markup.template_default_literal_message);
                }
                // Quotes are not string delimiters in a default; they
                // would render verbatim (engine and validator parity).
                if (default.len > 0 and (default[0] == '\'' or default[0] == '"')) {
                    return self.fail(template_node, markup.template_default_quoted_message);
                }
                break :blk .{ .value = expr.kindOf(reflect.literalValue(default)) };
            } else return self.fail(node, markup.use_missing_arg_message);
            self.entries[saved_len + arg_count] = .{ .name = arg.name, .binder = binder };
            arg_count += 1;
        }
        if (saved_len + arg_count >= max_scope_depth) {
            return self.fail(node, "template args nest too deep");
        }
        self.entries[saved_len + arg_count] = .{
            .name = "",
            .binder = .{ .slot = .{
                .nodes = node.children,
                .len = saved_len,
                .floor = saved_floor,
                .template_ctx = saved_ctx,
            } },
        };
        arg_count += 1;

        self.len = saved_len + arg_count;
        self.floor = saved_len;
        self.use_depth += 1;
        self.template_ctx = template_index;
        defer {
            self.len = saved_len;
            self.floor = saved_floor;
            self.use_depth -= 1;
            self.template_ctx = saved_ctx;
        }
        try self.checkElement(template_node.children[0]);
    }

    /// A template arg's binder, mirroring the engines' resolution order:
    /// a bare binding naming a slice arg in scope re-passes it; a binding
    /// naming a model iterable (strings stay scalars) binds as a slice;
    /// anything else is a value arg carrying its use-site kind — which is
    /// how argument types flow through a template's interface.
    fn argBinder(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr) CheckErr!Binder {
        const expression = markup.parseAttrExpression(attribute.value) orelse {
            return self.failAttr(node, attribute, markup.invalid_expression_message);
        };
        if (expression == .binding) {
            const path = expression.binding;
            if (self.lookup(pathHead(path))) |entry| {
                if (entry.binder == .slice and pathTail(path) == null) {
                    return entry.binder;
                }
            } else {
                for (self.contract.iterables) |*iterable| {
                    if (std.mem.eql(u8, iterable.name, path) and !std.mem.eql(u8, iterable.item_type, "u8")) {
                        self.markModel(path);
                        return .{ .slice = itemRefOf(iterable) };
                    }
                }
            }
        }
        return .{ .value = try self.unclassifiedKind(node, attribute, attribute.value) };
    }

    fn checkSlot(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        _ = node;
        const capture = self.slotCapture() orelse return;
        if (capture.nodes.len == 0) return;
        // Slot content checks in the CONSUMER's scope, exactly where the
        // <use> was written (engine parity).
        var saved_entries: [max_scope_depth]ScopeEntry = undefined;
        const saved_len = self.len;
        const saved_floor = self.floor;
        const saved_ctx = self.template_ctx;
        for (self.entries[capture.len..saved_len], 0..) |entry, offset| {
            saved_entries[offset] = entry;
        }
        self.len = capture.len;
        self.floor = capture.floor;
        self.template_ctx = capture.template_ctx;
        defer {
            for (saved_entries[0 .. saved_len - capture.len], 0..) |entry, offset| {
                self.entries[capture.len + offset] = entry;
            }
            self.len = saved_len;
            self.floor = saved_floor;
            self.template_ctx = saved_ctx;
        }
        try self.checkChildList(capture.nodes);
    }

    // ------------------------------------------------------------ walk

    fn checkNode(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        switch (node.kind) {
            .element => try self.checkElement(node),
            .use_block => try self.checkUse(node),
            else => {},
        }
    }

    fn checkChildList(self: *Checker, children: []const markup.MarkupNode) CheckErr!void {
        var index: usize = 0;
        while (index < children.len) : (index += 1) {
            const child = children[index];
            switch (child.kind) {
                .element => try self.checkElement(child),
                .use_block => try self.checkUse(child),
                .slot_block => try self.checkSlot(child),
                .text => try self.checkTextRun(child),
                .for_block => {
                    try self.checkFor(child);
                    if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                        index += 1;
                        try self.checkChildList(children[index].children);
                    }
                },
                .if_block => {
                    if (child.attr("test")) |test_value| {
                        // Conditions are truthy over any kind; resolving
                        // the bindings is the check.
                        const test_attr = attrOf(child, "test").?;
                        _ = try self.attrKind(child, test_attr, test_value);
                    }
                    try self.checkChildList(child.children);
                    if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                        index += 1;
                        try self.checkChildList(children[index].children);
                    }
                },
                .else_block, .template_block, .import_block => {},
            }
        }
    }

    fn checkTextRun(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        var rest = node.text;
        while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return;
            const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
            if (markup.isBindingPath(inner)) {
                _ = try self.resolveBinding(node, inner, true);
            } else {
                _ = try self.exprTreeKind(node, inner);
            }
            rest = rest[close + 1 ..];
        }
    }

    fn checkElement(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        if (std.mem.eql(u8, node.name, "span")) return self.checkSpan(node);
        if (std.mem.eql(u8, node.name, "markdown")) return self.checkMarkdown(node);
        if (std.mem.eql(u8, node.name, "code")) return self.checkCode(node);
        if (std.mem.eql(u8, node.name, "stepper")) return self.checkStepper(node);
        if (std.mem.eql(u8, node.name, "timeline-item")) return self.checkTimelineItem(node);
        if (std.mem.eql(u8, node.name, "chart")) return self.checkChart(node);
        if (std.mem.eql(u8, node.name, "video")) return self.checkVideo(node);
        if (std.mem.eql(u8, node.name, "timeline")) {
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "gap") or std.mem.eql(u8, attribute.name, "grow")) {
                    try self.checkClassAttr(node, attribute, .number);
                } else if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                    try self.checkKeyAttr(node, attribute);
                } else if (std.mem.eql(u8, attribute.name, "label")) {
                    const kind = try self.attrKind(node, attribute, attribute.value);
                    try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
                }
            }
            return self.checkChildList(node.children);
        }
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "kind")) continue;
            if (std.mem.startsWith(u8, attribute.name, "on-")) {
                try self.checkMessageAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "role")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, role_attr_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "image")) {
                // Runtime image ids are model integers (engine parity).
                if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                    return self.failAttr(node, attribute, markup.image_binding_element_message);
                }
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.integer}, markup.image_binding_message);
                continue;
            }
            if (markup.imageSourceAttrName(attribute.name)) {
                // Structural validation owns the atomic/scoped rectangle
                // rules; the model-aware pass verifies every coordinate
                // binding is numeric and marks it used.
                try self.checkClassAttr(node, attribute, .number);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "surface")) {
                // Media-surface ids are model integers (engine parity —
                // the runtime-image-id shape exactly).
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.integer}, markup.media_surface_surface_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "pty")) {
                // Terminal pty keys are model integers (engine parity —
                // the surface/image binding shape exactly): resolve the
                // binding so an undefined field is caught here and a
                // valid one is marked used (never a false dead-state
                // finding), and a non-integer is the teaching error.
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.integer}, markup.terminal_pty_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "icon") or
                (std.mem.eql(u8, attribute.name, "name") and std.mem.eql(u8, node.name, "icon")))
            {
                try self.checkIconAttr(node, attribute);
                continue;
            }
            // Literal-vocabulary attributes (built-in icon names, anchors,
            // style tokens) are the structural validator's job; unknown
            // attributes are too.
            if (attrClass(attribute.name)) |class| {
                try self.checkClassAttr(node, attribute, class);
            }
        }
        try self.checkChildList(node.children);
    }

    fn checkKeyAttr(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr) CheckErr!void {
        const kind = try self.attrKind(node, attribute, attribute.value);
        try self.requireAttrKind(node, attribute, kind, &.{ .integer, .string }, attr_key_kind_message);
    }

    /// Icon-valued attributes (`<icon name>`, the inline icon attribute,
    /// timeline-item's indicator icon): bare literals stay the structural
    /// validator's closed built-in vocabulary; this pass adds the two
    /// forms only the contract can see — `app:<name>` against the app's
    /// registered `app_icons` list (with a did-you-mean over it), and
    /// `{bindings}` against the model (an icon name is a string).
    fn checkIconAttr(self: *Checker, node: markup.MarkupNode, attribute: markup.MarkupAttr) CheckErr!void {
        switch (markup.attrTyped(attribute)) {
            .literal => |text| {
                if (!std.mem.startsWith(u8, text, app_icon_prefix)) return;
                const bare = text[app_icon_prefix.len..];
                if (nameListed(self.contract.app_icons, bare)) return;
                if (self.contract.app_icons.len == 0) {
                    return self.failAttr(node, attribute, no_app_icons_message);
                }
                return self.failNamed(node, unknown_app_icon_message, bare, .{ .names = self.contract.app_icons });
            },
            .binding => |path| {
                const resolved = try self.resolveBinding(node, path, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.string}, icon_binding_kind_message);
            },
            else => {},
        }
    }

    fn checkMarkdown(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "source")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.string}, markup.markdown_source_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "on-link")) {
                const expression = markup.parseMessageExpression(attribute.value) orelse continue;
                const tag = self.findMsg(expression.tag) orelse return self.failAttr(node, attribute, markup.markdown_on_link_message);
                if (tag.payload != .string or !std.mem.eql(u8, tag.payload_type, "[]const u8")) {
                    return self.failAttr(node, attribute, markup.markdown_on_link_message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "on-details")) {
                const expression = markup.parseMessageExpression(attribute.value) orelse continue;
                const tag = self.findMsg(expression.tag) orelse return self.failAttr(node, attribute, markup.markdown_on_details_message);
                if (tag.payload != .integer or !std.mem.eql(u8, tag.payload_type, "usize")) {
                    return self.failAttr(node, attribute, markup.markdown_on_details_message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "details-expanded")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const item = try self.resolveIterable(node, expression.binding, markup.markdown_details_expanded_message);
                if (!std.mem.eql(u8, item.type_name, "bool")) {
                    return self.failAttr(node, attribute, markup.markdown_details_expanded_message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "images")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const item = try self.resolveIterable(node, expression.binding, markup.markdown_images_message);
                if (!std.mem.eql(u8, item.type_name, "ResolvedImage") and
                    !std.mem.endsWith(u8, item.type_name, ".ResolvedImage"))
                {
                    return self.failAttr(node, attribute, markup.markdown_images_message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, markup.markdown_issue_link_base_message);
            }
        }
    }

    fn checkCode(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "source")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.string}, markup.code_source_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "line-numbers") or
                std.mem.eql(u8, attribute.name, "wrap") or
                std.mem.eql(u8, attribute.name, "editable"))
            {
                if (attribute.value.len == 0) continue;
                _ = try self.attrKind(node, attribute, attribute.value);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "added-lines") or
                std.mem.eql(u8, attribute.name, "removed-lines"))
            {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression == .literal) continue;
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, markup.code_diff_lines_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "on-input")) {
                try self.checkMessageAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "width") or
                std.mem.eql(u8, attribute.name, "height") or
                std.mem.eql(u8, attribute.name, "min-width") or
                std.mem.eql(u8, attribute.name, "grow"))
            {
                try self.checkClassAttr(node, attribute, .number);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
            }
        }
    }

    fn checkStepper(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "active")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.integer}, markup.stepper_active_message);
            } else if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
            } else if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
            }
        }
        for (node.children) |child| {
            if (child.kind == .slot_block) {
                // Ejected steppers pass their actual children through the
                // slot. Check those children in the consumer's scope.
                try self.checkSlot(child);
                continue;
            }
            for (child.children) |run| {
                if (run.kind == .text) try self.checkTextRun(run);
            }
        }
    }

    /// `<chart>` and its `<series>` children: options resolve like the
    /// engines' (numbers, whole numbers, truthy flags, text), and every
    /// series `values` binding must name an f32 or f64 iterable — a wrong item
    /// type fails with the model type named, so the fix is visible from
    /// the finding.
    fn checkChart(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            const number_attr = std.mem.eql(u8, attribute.name, "y-min") or
                std.mem.eql(u8, attribute.name, "y-max") or
                std.mem.eql(u8, attribute.name, "stroke-width") or
                std.mem.eql(u8, attribute.name, "width") or
                std.mem.eql(u8, attribute.name, "height") or
                std.mem.eql(u8, attribute.name, "grow") or
                std.mem.eql(u8, attribute.name, "padding");
            if (number_attr) {
                try self.checkClassAttr(node, attribute, .number);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "grid-lines")) {
                try self.checkClassAttr(node, attribute, .whole);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "baseline") or
                std.mem.eql(u8, attribute.name, "y-labels") or
                std.mem.eql(u8, attribute.name, "hover-details"))
            {
                _ = try self.attrKind(node, attribute, attribute.value);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "x-labels")) {
                // Like series values, but the iterable's items are
                // strings: a wrong item type fails with the model type
                // named, so the fix is visible from the finding.
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const item = try self.resolveIterable(node, expression.binding, markup.chart_x_labels_message);
                if (!std.mem.eql(u8, item.type_name, "[]const u8")) {
                    const message = std.fmt.allocPrint(self.arena, "{s} (\"{s}\" iterates {s})", .{
                        markup.chart_x_labels_message, expression.binding, item.type_name,
                    }) catch return error.OutOfMemory;
                    return self.failAttr(node, attribute, message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
            }
        }
        for (node.children) |child| {
            if (child.kind != .element or !std.mem.eql(u8, child.name, "series")) continue;
            try self.checkSeries(child);
        }
    }

    /// `<video>`: a bound `src` must resolve to a string model field
    /// (the playback source is text — engine parity), the flags resolve
    /// truthy over any kind like every flag attribute (bare presence is
    /// true and resolves nothing), and sizing/identity resolve like the
    /// engines'.
    fn checkVideo(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "src")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const resolved = try self.resolveBinding(node, expression.binding, true);
                try self.requireAttrKind(node, attribute, resolved.kind, &.{.string}, markup.video_src_message);
                continue;
            }
            if (markup.videoFlagAttrName(attribute.name)) {
                if (attribute.value.len == 0) continue;
                _ = try self.attrKind(node, attribute, attribute.value);
                continue;
            }
            const number_attr = std.mem.eql(u8, attribute.name, "width") or
                std.mem.eql(u8, attribute.name, "height") or
                std.mem.eql(u8, attribute.name, "grow");
            if (number_attr) {
                try self.checkClassAttr(node, attribute, .number);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, label_attr_message);
            }
        }
    }

    fn checkSeries(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "values")) {
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .binding) continue;
                const item = try self.resolveIterable(node, expression.binding, markup.series_values_message);
                // f32 is the canvas-native series element; f64 the
                // transpiled-core one (both engines narrow it per sample).
                if (!std.mem.eql(u8, item.type_name, "f32") and !std.mem.eql(u8, item.type_name, "f64")) {
                    const message = std.fmt.allocPrint(self.arena, "{s} (\"{s}\" iterates {s})", .{
                        markup.series_values_message, expression.binding, item.type_name,
                    }) catch return error.OutOfMemory;
                    return self.failAttr(node, attribute, message);
                }
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "label")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, markup.series_label_message);
            }
            // kind and color are closed literal vocabularies — the
            // structural validator's job.
        }
    }

    /// One `<span>` inside a text paragraph: weight resolves like any
    /// option-name attribute (bindings must produce a string), scale
    /// bindings must produce a NUMBER (the multiplier on the paragraph's
    /// base size — positivity is a value check, the engines' job), the
    /// flags resolve truthy over any kind, and the run's `{bindings}`
    /// check through the child walk exactly like any rendered text.
    /// foreground is a closed literal vocabulary — the structural
    /// validator's job.
    fn checkSpan(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            if (std.mem.eql(u8, attribute.name, "weight")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, markup.span_weight_value_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "scale")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{ .integer, .float }, markup.span_scale_value_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "mono") or std.mem.eql(u8, attribute.name, "italic") or std.mem.eql(u8, attribute.name, "underline")) {
                _ = try self.attrKind(node, attribute, attribute.value);
                continue;
            }
        }
        try self.checkChildList(node.children);
    }

    fn checkTimelineItem(self: *Checker, node: markup.MarkupNode) CheckErr!void {
        for (node.attrs) |attribute| {
            const text_attr = std.mem.eql(u8, attribute.name, "title") or
                std.mem.eql(u8, attribute.name, "description") or
                std.mem.eql(u8, attribute.name, "meta") or
                std.mem.eql(u8, attribute.name, "indicator");
            if (text_attr) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, markup.timeline_item_text_attr_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "variant")) {
                const kind = try self.attrKind(node, attribute, attribute.value);
                try self.requireAttrKind(node, attribute, kind, &.{.string}, option_attr_message);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "connector") or std.mem.eql(u8, attribute.name, "selected")) {
                _ = try self.attrKind(node, attribute, attribute.value);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "icon")) {
                try self.checkIconAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "on-press")) {
                try self.checkMessageAttr(node, attribute);
                continue;
            }
            if (std.mem.eql(u8, attribute.name, "key") or std.mem.eql(u8, attribute.name, "global-key")) {
                try self.checkKeyAttr(node, attribute);
            }
        }
    }
};

fn attrOf(node: markup.MarkupNode, name: []const u8) ?markup.MarkupAttr {
    for (node.attrs) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return attribute;
    }
    return null;
}

fn itemRefOf(iterable: *const Iterable) ItemRef {
    return .{
        .type_name = iterable.item_type,
        .kind = iterable.item_kind,
        .scalar = iterable.item_scalar,
        .group = &iterable.item,
    };
}

const GroupResolve = union(enum) {
    ok: Resolved,
    arena_blocked,
    missing,
};

/// Resolve a dotted path on a group: nested groups for every segment but
/// the last, then a scalar leaf. Mirrors the interpreter's `resolveOn`
/// (fields, zero-arg methods, arena methods) over the contract's data.
fn resolveOnGroup(group: *const Group, path: []const u8, allow_arena: bool) GroupResolve {
    const head = pathHead(path);
    if (pathTail(path)) |tail| {
        for (group.groups) |*named| {
            if (std.mem.eql(u8, named.name, head)) return resolveOnGroup(&named.group, tail, allow_arena);
        }
        return .missing;
    }
    for (group.scalars) |scalar| {
        if (!std.mem.eql(u8, scalar.name, head)) continue;
        if (scalar.arena and !allow_arena) return .arena_blocked;
        return .{ .ok = .{ .kind = scalar.kind, .type_name = scalar.type_name } };
    }
    return .missing;
}

fn pathHead(path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return path;
    return path[0..dot];
}

fn pathTail(path: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    return path[dot + 1 ..];
}

// ----------------------------------------------------------- did-you-mean

const NameSource = union(enum) {
    model: *const Contract,
    group: *const Group,
    iterables: *const Contract,
    msgs: *const Contract,
    /// A plain name list (the contract's registered app icons).
    names: []const []const u8,
};

fn nearestCandidate(token: []const u8, source: NameSource) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    switch (source) {
        .model => |contract| {
            for (contract.model.scalars) |scalar| considerName(token, scalar.name, &best, &best_distance);
            for (contract.model.groups) |group| considerName(token, group.name, &best, &best_distance);
            for (contract.iterables) |iterable| considerName(token, iterable.name, &best, &best_distance);
        },
        .group => |group| {
            for (group.scalars) |scalar| considerName(token, scalar.name, &best, &best_distance);
            for (group.groups) |nested| considerName(token, nested.name, &best, &best_distance);
        },
        .iterables => |contract| {
            for (contract.iterables) |iterable| considerName(token, iterable.name, &best, &best_distance);
        },
        .msgs => |contract| {
            for (contract.msgs) |tag| considerName(token, tag.name, &best, &best_distance);
        },
        .names => |names| {
            for (names) |name| considerName(token, name, &best, &best_distance);
        },
    }
    return best;
}

fn considerName(token: []const u8, name: []const u8, best: *?[]const u8, best_distance: *usize) void {
    const distance = editDistance(token, name) orelse return;
    if (distance < best_distance.*) {
        best_distance.* = distance;
        best.* = name;
    }
}

/// Bounded Levenshtein distance; null when either side is too long for
/// the fixed buffer (binding names are short).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (b.len > 63 or a.len > 255) return null;
    var previous: [64]usize = undefined;
    var current: [64]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |a_char, i| {
        current[0] = i + 1;
        for (b, 0..) |b_char, j| {
            const substitution_cost: usize = if (a_char == b_char) 0 else 1;
            current[j + 1] = @min(
                previous[j] + substitution_cost,
                @min(current[j] + 1, previous[j + 1] + 1),
            );
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

// -------------------------------------------------------------- artifact

/// Hash the app's core sources: every `.zig` and `.ts` file under
/// `root_path`, path-sorted, path and contents both mixed in. TypeScript
/// cores are hashed too because on that track the Model/Msg truth lives
/// in `src/core.ts` — a core edit changes no `.zig` file, and a contract
/// that stays "fresh" through it reports phantom unknown-tag and
/// unknown-field errors against the user's new state. The emit step
/// stamps this into the artifact; `native check` recomputes it and
/// DEGRADES to structural checking on any mismatch — a stale contract
/// can hide new fields or resurrect deleted ones, so it must never pass
/// silently.
pub fn hashSourceDir(allocator: std.mem.Allocator, io: std.Io, root_path: []const u8) !u64 {
    return hashSourceDirAt(allocator, io, std.Io.Dir.cwd(), root_path);
}

pub fn hashSourceDirAt(allocator: std.mem.Allocator, io: std.Io, base: std.Io.Dir, root_path: []const u8) !u64 {
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var root = try base.openDir(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.path, ".zig") or std.mem.endsWith(u8, entry.path, ".ts")) {
            try paths.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }
    std.mem.sort([]const u8, paths.items, {}, stringLessThan);
    var hasher = std.hash.Wyhash.init(0x5eed_c0de);
    for (paths.items) |path| {
        hasher.update(path);
        hasher.update(&.{0});
        var file = try root.openFile(io, path, .{});
        defer file.close(io);
        var read_buffer: [16 * 1024]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const contents = try reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(contents);
        hasher.update(contents);
        hasher.update(&.{0});
    }
    return hasher.final();
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Parse a serialized contract artifact. The result's slices are
/// allocated from `allocator` (hand it an arena).
pub fn parseArtifact(allocator: std.mem.Allocator, source: []const u8) error{ OutOfMemory, ParseZon }!Contract {
    const source_z = try allocator.dupeZ(u8, source);
    return std.zon.parse.fromSliceAlloc(Contract, allocator, source_z, null, .{});
}

/// Serialize a contract as ZON (the artifact format `parseArtifact`
/// reads back).
pub fn writeArtifact(contract: Contract, writer: *std.Io.Writer) !void {
    try std.zon.stringify.serializeMaxDepth(contract, .{}, writer, 256);
    try writer.writeByte('\n');
}

// ------------------------------------------------------------- emit main

/// The whole body of the per-app contract emit program: the app's build
/// wires a tiny root that calls this with its own module. Apps without a
/// public Model/Msg pair have no markup contract; the step is a silent
/// no-op for them.
pub fn emitMain(comptime app: type, comptime specials: Specials, init: std.process.Init) !void {
    if (comptime !(@hasDecl(app, "Model") and @hasDecl(app, "Msg"))) return;
    if (comptime (@typeInfo(app.Model) != .@"struct" or @typeInfo(app.Msg) != .@"union")) return;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var src_root: []const u8 = default_source_root;
    var out_path: []const u8 = default_artifact_path;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--src") and index + 1 < args.len) {
            index += 1;
            src_root = args[index];
        } else if (std.mem.eql(u8, args[index], "--out") and index + 1 < args.len) {
            index += 1;
            out_path = args[index];
        }
    }
    var contract = comptime describe(app.Model, app.Msg, specials);
    // The registered icon vocabulary rides the same artifact: one
    // `pub const app_icons` declaration feeds boot-time registration and
    // this reflection, so `native check` verifies `app:` markup
    // references against exactly what the app registers.
    contract.app_icons = comptime appIconNames(app);
    contract.source_root = src_root;
    contract.source_hash = try hashSourceDir(allocator, init.io, src_root);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeArtifact(contract, &out.writer);
    if (std.fs.path.dirname(out_path)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch {};
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = out.written() });
}
