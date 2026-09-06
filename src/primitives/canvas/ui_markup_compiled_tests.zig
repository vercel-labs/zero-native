//! Parity tests for the comptime-compiled markup path: for the same model,
//! `CompiledMarkupView(...).build` must produce exactly what the runtime
//! interpreter produces — identical structural ids node for node, identical
//! handler tables, identical dispatch results, identical interpolated text.
//!
//! Compile-error coverage: Zig cannot unit-test `@compileError`, so the
//! rejecting side is guaranteed structurally — every invalid construct the
//! interpreter reports at runtime (see "markup build failures carry position
//! and message" in ui_markup_view_tests.zig) is resolved during the comptime
//! walk and fails compilation with the same message plus line/column. These
//! tests pin down the accepting side: everything valid builds identically.

const std = @import("std");
const canvas = @import("root.zig");
const geometry = @import("geometry");
const markup_view = @import("ui_markup_view.zig");
const fixture = @import("ui_markup_view_tests.zig");

const testing = std.testing;

// ------------------------------------------------------ shared assertions

/// Identical trees: same structural ids node for node and the same handler
/// table entry for entry (messages by value, input/value constructors by
/// function identity — both engines instantiate `Ui.inputMsg` on the same
/// comptime tag, so parity implies pointer equality).
fn expectSameTree(comptime MsgT: type, expected: canvas.Ui(MsgT).Tree, actual: canvas.Ui(MsgT).Tree) !void {
    var expected_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer expected_ids.deinit(testing.allocator);
    var actual_ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer actual_ids.deinit(testing.allocator);
    try fixture.collectIds(expected.root, &expected_ids, testing.allocator);
    try fixture.collectIds(actual.root, &actual_ids, testing.allocator);
    try testing.expectEqualSlices(canvas.ObjectId, expected_ids.items, actual_ids.items);

    try testing.expectEqual(expected.handlers.len, actual.handlers.len);
    for (expected.handlers, actual.handlers) |expected_handler, actual_handler| {
        try testing.expectEqual(expected_handler.id, actual_handler.id);
        try testing.expectEqual(expected_handler.event, actual_handler.event);
        try testing.expectEqual(std.meta.activeTag(expected_handler.action), std.meta.activeTag(actual_handler.action));
        switch (expected_handler.action) {
            .message => |msg| try expectSameMsg(MsgT, msg, actual_handler.action.message),
            .input => |make| try testing.expectEqual(make, actual_handler.action.input),
            .value => |make| try testing.expectEqual(make, actual_handler.action.value),
            .scroll => |make| try testing.expectEqual(make, actual_handler.action.scroll),
            .terminal => |make| try testing.expectEqual(make, actual_handler.action.terminal),
            // Context-menu handler entries carry one ?Msg per declared
            // item (separators are null slots); markup `<context-menu>`
            // and the Zig builder both produce them.
            .context_menu => |msgs| {
                const actual_msgs = actual_handler.action.context_menu;
                try testing.expectEqual(msgs.len, actual_msgs.len);
                for (msgs, actual_msgs) |expected_msg, actual_msg| {
                    try testing.expectEqual(expected_msg == null, actual_msg == null);
                    if (expected_msg) |msg| try expectSameMsg(MsgT, msg, actual_msg.?);
                }
            },
        }
    }
}

/// Messages are equal when their tag and payload agree; string payloads
/// compare by bytes (each engine formats arena-computed payloads into its
/// own arena, so pointer identity is not part of the contract).
fn expectSameMsg(comptime MsgT: type, expected: MsgT, actual: MsgT) !void {
    try testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
    switch (expected) {
        inline else => |payload, tag| {
            const actual_payload = @field(actual, @tagName(tag));
            if (@TypeOf(payload) == []const u8) {
                try testing.expectEqualStrings(payload, actual_payload);
            } else {
                try testing.expect(std.meta.eql(payload, actual_payload));
            }
        },
    }
}

fn expectSameTexts(expected: canvas.Widget, actual: canvas.Widget) !void {
    try testing.expectEqual(expected.kind, actual.kind);
    try testing.expectEqualStrings(expected.text, actual.text);
    try testing.expectEqual(expected.state.selected, actual.state.selected);
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectSameTexts(expected_child, actual_child);
    }
}

// --------------------------------------------------- inbox fixture parity

const InboxUi = canvas.Ui(fixture.Msg);
const InboxInterpreter = markup_view.MarkupView(fixture.Model, fixture.Msg);
const InboxCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.inbox_markup_source);

const SegmentedCompiled = canvas.CompiledMarkupView(fixture.SegmentedModel, fixture.SegmentedMsg, fixture.segmented_markup_source);

const EjectedStepperDefaultMarkup =
    \\<template name="stepper" args="active key= global_key= label=">
    \\  <stepper active="{active}" key="{key}" global-key="{global_key}" label="{label}">
    \\    <slot/>
    \\  </stepper>
    \\</template>
    \\<use template="stepper" active="1"><step>Plan</step><step>Ship</step></use>
;
const EjectedStepperDefaultCompiled = canvas.CompiledMarkupView(fixture.TemplateModel, fixture.TemplateMsg, EjectedStepperDefaultMarkup);

const ForwardedModel = struct { id: u32 = 7 };
const ForwardedMsg = union(enum) { open: u32 };
const ForwardedUi = canvas.Ui(ForwardedMsg);
const ForwardedCompiled = canvas.CompiledMarkupView(ForwardedModel, ForwardedMsg,
    \\<template name="item" args="title">
    \\  <timeline-item title="{title}" />
    \\</template>
    \\<use template="item" title="Build" on-press="open:{id}" />
);
test "compiled segmented-control and vector icon button match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.SegmentedModel{};
    var interpreter_view = try markup_view.MarkupView(fixture.SegmentedModel, fixture.SegmentedMsg).init(arena, fixture.segmented_markup_source);
    var interpreter_ui = fixture.SegmentedUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = fixture.SegmentedUi.init(arena);
    const compiled = try compiled_ui.finalize(SegmentedCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.SegmentedMsg, interpreted, compiled);
    try testing.expectEqual(canvas.WidgetKind.segmented_control, compiled.root.children[0].kind);
    try testing.expectEqualStrings("settings", compiled.root.children[2].icon);
}

test "compiled ejected stepper defaults preserve unkeyed identity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.TemplateModel{};
    const labels = [_]TemplateUi.StepperStep{ .{ .label = "Plan" }, .{ .label = "Ship" } };

    var library_ui = TemplateUi.init(arena);
    const library = try library_ui.finalize(library_ui.stepper(.{ .active = 1 }, &labels));
    var compiled_ui = TemplateUi.init(arena);
    const compiled = try compiled_ui.finalize(EjectedStepperDefaultCompiled.build(&compiled_ui, &model));
    try testing.expectEqualDeep(library.root, compiled.root);
}

test "compiled template use forwards a typed root press" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ui = ForwardedUi.init(arena);
    const tree = try ui.finalize(ForwardedCompiled.build(&ui, &ForwardedModel{}));
    try testing.expectEqual(ForwardedMsg{ .open = 7 }, tree.msgForPointer(tree.root.id, .up).?);
    try testing.expectEqual(@as(usize, 1), tree.root.children.len);
}
const zero_card_padding_markup =
    \\<card padding="0">
    \\  <text>Flush</text>
    \\</card>
;
const ZeroCardPaddingCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, zero_card_padding_markup);

const selection_label_content_markup =
    \\<column gap="8">
    \\  <checkbox checked="true" on-toggle="add">Done</checkbox>
    \\  <checkbox on-toggle="add" text="Later" />
    \\  <radio-group label="Density">
    \\    <radio checked="true" on-change="add">Default</radio>
    \\    <radio on-change="add" text="Compact" />
    \\  </radio-group>
    \\</column>
;
const SelectionLabelContentCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, selection_label_content_markup);

const digit_text_attribute_markup =
    \\<column padding="8">
    \\  <text-field placeholder="123" label="456" />
    \\</column>
;
const DigitTextAttributeCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, digit_text_attribute_markup);

test "compiled digit-only text attributes stay text while numeric attributes stay numeric" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter = try InboxInterpreter.init(arena, digit_text_attribute_markup);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(DigitTextAttributeCompiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    const field = fixture.findByKind(compiled.root, .text_field).?;
    try testing.expectEqualStrings("123", field.placeholder);
    try testing.expectEqualStrings("456", field.semantics.label);
    try testing.expectEqual(@as(f32, 8), compiled.root.layout.padding.top);
}

test "checkbox and radio element content builds identically in both markup engines" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.testModel();

    var interpreter = try InboxInterpreter.init(arena, selection_label_content_markup);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(SelectionLabelContentCompiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(fixture.findByText(compiled.root, .checkbox, "Done") != null);
    try testing.expect(fixture.findByText(compiled.root, .checkbox, "Later") != null);
    try testing.expect(fixture.findByText(compiled.root, .radio, "Default") != null);
    try testing.expect(fixture.findByText(compiled.root, .radio, "Compact") != null);
}

test "explicit zero card padding survives interpreted and compiled markup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.testModel();

    var interpreter = try InboxInterpreter.init(arena, zero_card_padding_markup);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(ZeroCardPaddingCompiled.build(&compiled_ui, &model));

    try testing.expectEqual(canvas.WidgetKind.card, interpreted.root.kind);
    try testing.expectEqual(geometry.InsetsF{}, interpreted.root.layout.padding);
    try testing.expect(!interpreted.root.layout.padding_is_kind_default);
    try testing.expectEqualDeep(interpreted.root.layout.padding, compiled.root.layout.padding);
    try testing.expect(!compiled.root.layout.padding_is_kind_default);
}

fn interpretInbox(arena: std.mem.Allocator, model: *const fixture.Model) !InboxUi.Tree {
    var view = try InboxInterpreter.init(arena, fixture.inbox_markup_source);
    var ui = InboxUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileInbox(arena: std.mem.Allocator, model: *const fixture.Model) !InboxUi.Tree {
    var ui = InboxUi.init(arena);
    return ui.finalize(InboxCompiled.build(&ui, model));
}

const ContextMenuCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.context_menu_markup_source);
const DragContextMenuCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.drag_context_menu_markup_source);

test "compiled drag-only context-menu host matches the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.testModel();

    var interpreter_view = try InboxInterpreter.init(arena, fixture.drag_context_menu_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(DragContextMenuCompiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(compiled.root.semantics.actions.drag);
    try testing.expect(canvas.widgetClaimsPress(compiled.root));
    try testing.expectEqual(fixture.Msg.add, compiled.msgForContextMenu(compiled.root.id, 0).?);
}

test "compiled context-menus build the interpreter's declared items and handler entries exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.testModel();

    var interpreter_view = try InboxInterpreter.init(arena, fixture.context_menu_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(ContextMenuCompiled.build(&compiled_ui, &model));

    // Same ids, same handler table (context_menu entries msg for msg),
    // same texts — and the declared items agree slot for slot.
    try expectSameTree(fixture.Msg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expectEqual(@as(usize, 3), interpreted.root.children.len);
    for (interpreted.root.children, compiled.root.children) |expected_row, actual_row| {
        try testing.expectEqual(expected_row.context_menu.len, actual_row.context_menu.len);
        for (expected_row.context_menu, actual_row.context_menu) |expected_item, actual_item| {
            try testing.expectEqualStrings(expected_item.label, actual_item.label);
            try testing.expectEqual(expected_item.enabled, actual_item.enabled);
            try testing.expectEqual(expected_item.separator, actual_item.separator);
        }
    }
    // Selection dispatch parity through the shared handler entry.
    const row = compiled.root.children[1];
    try testing.expectEqual(fixture.Msg{ .toggle = 2 }, compiled.msgForContextMenu(row.id, 0).?);
    try testing.expectEqual(
        interpreted.msgForContextMenu(interpreted.root.children[1].id, 0).?,
        compiled.msgForContextMenu(row.id, 0).?,
    );
}

test "compiled inbox view builds the interpreter's and the hand-written tree exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.testModel();

    const interpreted = try interpretInbox(arena, &model);
    const compiled = try compileInbox(arena, &model);
    var hand_ui = InboxUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handView(&hand_ui, &model));

    // The three engines agree node for node and handler for handler: the
    // compiled path covers `for` over a pub const array (filters) and an
    // arena fn (visible), `{a == b}` equality, on-input/on-submit/on-press/
    // on-toggle messages, and interpolation.
    try expectSameTree(fixture.Msg, hand, interpreted);
    try expectSameTree(fixture.Msg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Pointer dispatch parity.
    const add_button = fixture.findByKind(compiled.root, .button).?;
    try testing.expectEqual(fixture.Msg.add, compiled.msgForPointer(add_button.id, .up).?);
    const interpreted_checkbox = fixture.findByKind(interpreted.root, .checkbox).?;
    const compiled_checkbox = fixture.findByKind(compiled.root, .checkbox).?;
    try testing.expectEqual(interpreted_checkbox.id, compiled_checkbox.id);
    try testing.expectEqual(
        interpreted.msgForPointer(interpreted_checkbox.id, .up).?,
        compiled.msgForPointer(compiled_checkbox.id, .up).?,
    );

    // Keyboard dispatch parity, including the on-input constructor.
    const text_field = fixture.findByKind(compiled.root, .text_field).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "x" };
    try testing.expectEqualStrings("x", compiled.msgForKeyboard(text_field.id, typed).?.draft.insert_text);
    const submit = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(
        interpreted.msgForKeyboard(text_field.id, submit).?,
        compiled.msgForKeyboard(text_field.id, submit).?,
    );

    // Interpolated text parity down to the byte.
    try testing.expectEqualStrings("2 open", fixture.findByKind(compiled.root, .status_bar).?.text);
}

test "compiled keyed rows keep ids across model changes and filters dispatch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.testModel();

    const first = try compileInbox(arena, &model);
    const first_checkbox = fixture.findByKind(first.root, .checkbox).?;

    // Dispatch the done filter through a compiled-view button.
    var done_msg: ?fixture.Msg = null;
    for (first.handlers) |handler| {
        if (handler.action == .message and handler.action.message == .set_filter) {
            if (handler.action.message.set_filter == .done) done_msg = handler.action.message;
        }
    }
    try testing.expectEqual(fixture.Filter.done, done_msg.?.set_filter);
    model.filter = done_msg.?.set_filter;

    const second = try compileInbox(arena, &model);
    const second_checkbox = fixture.findByKind(second.root, .checkbox).?;
    try testing.expect(first_checkbox.id != second_checkbox.id);
    try testing.expectEqual(@as(u32, 2), second.msgForPointer(second_checkbox.id, .up).?.toggle);

    // Back to all: the original first row returns with its original id, and
    // the interpreter agrees at every step.
    model.filter = .all;
    const third = try compileInbox(arena, &model);
    try testing.expectEqual(first_checkbox.id, fixture.findByKind(third.root, .checkbox).?.id);
    try expectSameTree(fixture.Msg, try interpretInbox(arena, &model), third);
}

// ------------------------- field-slice for, if/else, global-key fixture

const EntryStatus = enum { open, closed };

const Entry = struct {
    id: u32,
    label: []const u8,
    status: EntryStatus = .open,
};

const EntriesMsg = union(enum) {
    open_entry: u32,
    refresh,
    feed_scrolled: canvas.ScrollState,
};

const EntriesModel = struct {
    /// A plain slice field: the third `for` source kind (the inbox fixture
    /// covers pub const arrays and arena fns).
    entries: []const Entry = &.{},
    /// Optional binding: truthiness is only runtime-known.
    banner: ?[]const u8 = null,
    closed_status: EntryStatus = .closed,
};

const entries_markup =
    \\<column gap="4">
    \\  <if test="{banner}">
    \\    <text>bannered</text>
    \\  </if>
    \\  <else>
    \\    <text>plain</text>
    \\  </else>
    \\  <for each="entries" as="e" key="id">
    \\    <row global-key="{e.id}" gap="2" cross="center">
    \\      <if test="{e.status == closed_status}">
    \\        <badge>closed</badge>
    \\      </if>
    \\      <else>
    \\        <badge>open</badge>
    \\      </else>
    \\      <text grow="1">{e.label} #{e.id}</text>
    \\      <button size="sm" on-press="open_entry:{e.id}">Open</button>
    \\    </row>
    \\  </for>
    \\  <if test="{banner}">
    \\    <status-bar>{banner}</status-bar>
    \\  </if>
    \\</column>
;

const EntriesUi = canvas.Ui(EntriesMsg);
const EntriesInterpreter = markup_view.MarkupView(EntriesModel, EntriesMsg);
const EntriesCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, entries_markup);

fn interpretEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var view = try EntriesInterpreter.init(arena, entries_markup);
    var ui = EntriesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var ui = EntriesUi.init(arena);
    return ui.finalize(EntriesCompiled.build(&ui, model));
}

fn findText(widget: canvas.Widget, text: []const u8) ?canvas.Widget {
    if (std.mem.eql(u8, widget.text, text)) return widget;
    for (widget.children) |child| {
        if (findText(child, text)) |found| return found;
    }
    return null;
}

test "compiled field-slice for, if/else, and optional bindings match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second", .status = .closed },
        .{ .id = 33, .label = "third" },
    };

    // Optional none: the else branch renders, the trailing if disappears.
    var model = EntriesModel{ .entries = &entries };
    const plain_interpreted = try interpretEntries(arena, &model);
    const plain_compiled = try compileEntries(arena, &model);
    try expectSameTree(EntriesMsg, plain_interpreted, plain_compiled);
    try expectSameTexts(plain_interpreted.root, plain_compiled.root);
    try testing.expect(findText(plain_compiled.root, "plain") != null);
    try testing.expect(findText(plain_compiled.root, "bannered") == null);
    try testing.expect(findText(plain_compiled.root, "second #22") != null);
    try testing.expect(findText(plain_compiled.root, "closed") != null);
    try testing.expect(findText(plain_compiled.root, "open") != null);

    // Optional some: both ifs flip, and the status bar interpolates the
    // optional's payload.
    model.banner = "hello";
    const bannered_interpreted = try interpretEntries(arena, &model);
    const bannered_compiled = try compileEntries(arena, &model);
    try expectSameTree(EntriesMsg, bannered_interpreted, bannered_compiled);
    try expectSameTexts(bannered_interpreted.root, bannered_compiled.root);
    try testing.expect(findText(bannered_compiled.root, "bannered") != null);
    try testing.expect(findText(bannered_compiled.root, "plain") == null);
    try testing.expectEqualStrings("hello", fixture.findByKind(bannered_compiled.root, .status_bar).?.text);

    // Message payloads built from loop items dispatch identically.
    const open_button = fixture.findByKind(plain_compiled.root, .button).?;
    try testing.expectEqual(
        plain_interpreted.msgForPointer(open_button.id, .up).?,
        plain_compiled.msgForPointer(open_button.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 11), plain_compiled.msgForPointer(open_button.id, .up).?.open_entry);
}

test "compiled global-key rows keep their ids across reorders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const forward = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second" },
    };
    const reversed = [_]Entry{
        .{ .id = 22, .label = "second" },
        .{ .id = 11, .label = "first" },
    };

    var model = EntriesModel{ .entries = &forward };
    const before = try compileEntries(arena, &model);
    const first_before = findText(before.root, "first #11").?;

    model.entries = &reversed;
    const after = try compileEntries(arena, &model);
    const first_after = findText(after.root, "first #11").?;

    // global-key (declared in markup, resolved at comptime) pins identity
    // independent of position — and the interpreter agrees.
    try testing.expectEqual(first_before.id, first_after.id);
    try expectSameTree(EntriesMsg, try interpretEntries(arena, &model), after);
}

// ------------------------------------------------ on-scroll parity

const scroll_feed_markup =
    \\<scroll on-scroll="feed_scrolled" on-reach-end="refresh">
    \\  <column gap="4">
    \\    <for each="entries" as="e" key="id">
    \\      <text>{e.label}</text>
    \\    </for>
    \\  </column>
    \\</scroll>
;

const ScrollFeedCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, scroll_feed_markup);

test "compiled on-scroll binds the ScrollState constructor identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{.{ .id = 11, .label = "first" }};
    const model = EntriesModel{ .entries = &entries };

    var view = try markup_view.MarkupView(EntriesModel, EntriesMsg).init(arena, scroll_feed_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(ScrollFeedCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines dispatch the same typed scroll Msg for the container.
    const feed = fixture.findByKind(compiled.root, .scroll_view).?;
    const state = canvas.ScrollState{ .offset_y = 40, .viewport_extent_y = 80, .content_extent_y = 200 };
    try testing.expectEqual(@as(f32, 40), compiled.msgForScroll(feed.id, state).?.feed_scrolled.offset_y);
    try testing.expectEqual(
        interpreted.msgForScroll(feed.id, state).?.feed_scrolled.offset_y,
        compiled.msgForScroll(feed.id, state).?.feed_scrolled.offset_y,
    );

    // And the same approach-end Msg (`on-reach-end`, the infinite-scroll
    // fetch signal) through both handler tables.
    try testing.expectEqual(EntriesMsg.refresh, compiled.msgForReachEnd(feed.id).?);
    try testing.expectEqual(interpreted.msgForReachEnd(feed.id).?, compiled.msgForReachEnd(feed.id).?);
}

// ------------------------------------------------ overscroll parity

const overscroll_feed_markup =
    \\<scroll overscroll="rubber_band">
    \\  <column gap="4">
    \\    <for each="entries" as="e" key="id">
    \\      <text>{e.label}</text>
    \\    </for>
    \\  </column>
    \\</scroll>
;

const OverscrollFeedCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, overscroll_feed_markup);

test "compiled overscroll stamps the region edge behavior identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{.{ .id = 11, .label = "first" }};
    const model = EntriesModel{ .entries = &entries };

    var view = try markup_view.MarkupView(EntriesModel, EntriesMsg).init(arena, overscroll_feed_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(OverscrollFeedCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines stamp the per-region opt-in on the scroll widget.
    const compiled_feed = fixture.findByKind(compiled.root, .scroll_view).?;
    const interpreted_feed = fixture.findByKind(interpreted.root, .scroll_view).?;
    try testing.expectEqual(canvas.WidgetOverscroll.rubber_band, compiled_feed.overscroll);
    try testing.expectEqual(canvas.WidgetOverscroll.rubber_band, interpreted_feed.overscroll);
}

// ------------------------------------------- split layout-tween parity

const split_tween_markup =
    \\<split value="0.3" resize-duration="180" resize-easing="spring" grow="1">
    \\  <panel><text>sidebar</text></panel>
    \\  <panel><text>content</text></panel>
    \\</split>
;

const SplitTweenCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, split_tween_markup);

test "compiled split tween pair lowers into the layout-tween declaration identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{.{ .id = 11, .label = "first" }};
    const model = EntriesModel{ .entries = &entries };

    var view = try markup_view.MarkupView(EntriesModel, EntriesMsg).init(arena, split_tween_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(SplitTweenCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines stamp the same declaration the runtime lowers into a
    // layout tween: value is the target, duration arms it, easing shapes
    // it. Bare splits keep the zero (snap) defaults, so existing
    // documents lower byte-identically.
    const compiled_split = fixture.findByKind(compiled.root, .split).?;
    const interpreted_split = fixture.findByKind(interpreted.root, .split).?;
    try testing.expectEqual(@as(u32, 180), compiled_split.resize_duration_ms);
    try testing.expectEqual(@as(u32, 180), interpreted_split.resize_duration_ms);
    try testing.expectEqual(canvas.Easing.spring, compiled_split.resize_easing);
    try testing.expectEqual(canvas.Easing.spring, interpreted_split.resize_easing);
    try testing.expectEqual(interpreted_split.value, compiled_split.value);
}

// ---------------------------------------- anchored-tooltip intent parity

const tooltip_intent_markup =
    \\<column gap="12">
    \\  <stack>
    \\    <text>Bold</text>
    \\    <tooltip anchor="above" tooltip-delay="250">Bold the selection</tooltip>
    \\  </stack>
    \\  <stack>
    \\    <text>Link</text>
    \\    <tooltip anchor="below" anchor-offset="8">Insert a link</tooltip>
    \\  </stack>
    \\  <tooltip>Copied!</tooltip>
    \\</column>
;

const TooltipIntentCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, tooltip_intent_markup);

test "compiled anchored tooltips stamp the hover-intent declaration identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{.{ .id = 11, .label = "first" }};
    const model = EntriesModel{ .entries = &entries };

    var view = try markup_view.MarkupView(EntriesModel, EntriesMsg).init(arena, tooltip_intent_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(TooltipIntentCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines stamp the declaration the runtime's hover-intent
    // machine reads: the anchor floats the leaf against its parent, and
    // tooltip-delay overrides the token default (-1 keeps it). The bare
    // static tooltip keeps null anchor and the -1 default, so existing
    // documents lower byte-identically.
    inline for (.{ interpreted.root, compiled.root }) |root| {
        const declared = fixture.findByText(root, .tooltip, "Bold the selection").?;
        try testing.expectEqual(@as(i32, 250), declared.tooltip_delay_ms);
        try testing.expectEqual(canvas.WidgetAnchorPlacement.above, declared.layout.anchor.?.placement);

        const defaulted = fixture.findByText(root, .tooltip, "Insert a link").?;
        try testing.expectEqual(@as(i32, -1), defaulted.tooltip_delay_ms);
        try testing.expectEqual(canvas.WidgetAnchorPlacement.below, defaulted.layout.anchor.?.placement);
        try testing.expectEqual(@as(f32, 8), defaulted.layout.anchor.?.offset);

        const static = fixture.findByText(root, .tooltip, "Copied!").?;
        try testing.expectEqual(@as(i32, -1), static.tooltip_delay_ms);
        try testing.expectEqual(@as(?canvas.WidgetAnchor, null), static.layout.anchor);
    }
}

// ------------------------------------------- tooltip-delay range guard

const TooltipDelayModel = struct { delay: i64 = 0 };

const tooltip_delay_binding_markup =
    \\<stack>
    \\  <text>Bold</text>
    \\  <tooltip anchor="above" tooltip-delay="{delay}">Bold the selection</tooltip>
    \\</stack>
;

const tooltip_delay_boundary_markup =
    \\<column gap="12">
    \\  <stack>
    \\    <text>Bold</text>
    \\    <tooltip anchor="above" tooltip-delay="0">Bold the selection</tooltip>
    \\  </stack>
    \\  <stack>
    \\    <text>Link</text>
    \\    <tooltip anchor="below" tooltip-delay="2147483647">Insert a link</tooltip>
    \\  </stack>
    \\</column>
;

const tooltip_delay_overflow_literal_markup =
    \\<stack>
    \\  <text>Bold</text>
    \\  <tooltip anchor="above" tooltip-delay="2147483648">Bold the selection</tooltip>
    \\</stack>
;

const TooltipDelayUi = canvas.Ui(EntriesMsg);
const TooltipDelayBindingCompiled = canvas.CompiledMarkupView(TooltipDelayModel, EntriesMsg, tooltip_delay_binding_markup);
const TooltipDelayBoundaryCompiled = canvas.CompiledMarkupView(TooltipDelayModel, EntriesMsg, tooltip_delay_boundary_markup);
const TooltipDelayOverflowLiteralCompiled = canvas.CompiledMarkupView(TooltipDelayModel, EntriesMsg, tooltip_delay_overflow_literal_markup);

test "compiled tooltip-delay past i32 max fails the build instead of trapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A literal one past maxInt(i32): the option field's own type is
    // the bound (the grid-lines pattern), so the cast that used to
    // trap latches the failed build the interpreter's teaching error
    // mirrors, and finalize surfaces it.
    var literal_ui = TooltipDelayUi.init(arena);
    const literal_node = TooltipDelayOverflowLiteralCompiled.build(&literal_ui, &TooltipDelayModel{});
    try testing.expect(literal_ui.failed);
    try testing.expectError(error.OutOfMemory, literal_ui.finalize(literal_node));

    // Bindings deliver i64 model values into the same cast seam, so an
    // out-of-range model value fails the same way — per-build, since
    // only the value (not the document) is wrong.
    var overflow_ui = TooltipDelayUi.init(arena);
    const overflow_model = TooltipDelayModel{ .delay = @as(i64, std.math.maxInt(i32)) + 1 };
    const overflow_node = TooltipDelayBindingCompiled.build(&overflow_ui, &overflow_model);
    try testing.expect(overflow_ui.failed);
    try testing.expectError(error.OutOfMemory, overflow_ui.finalize(overflow_node));

    // The same document lowers when the model holds an in-range value.
    var ok_ui = TooltipDelayUi.init(arena);
    const ok_model = TooltipDelayModel{ .delay = 250 };
    const ok_tree = try ok_ui.finalize(TooltipDelayBindingCompiled.build(&ok_ui, &ok_model));
    try testing.expectEqual(@as(i32, 250), fixture.findByText(ok_tree.root, .tooltip, "Bold the selection").?.tooltip_delay_ms);

    // Boundary values pass: 0 (the instant-show escape hatch) and the
    // type's exact max.
    var boundary_ui = TooltipDelayUi.init(arena);
    const boundary_tree = try boundary_ui.finalize(TooltipDelayBoundaryCompiled.build(&boundary_ui, &TooltipDelayModel{}));
    try testing.expectEqual(@as(i32, 0), fixture.findByText(boundary_tree.root, .tooltip, "Bold the selection").?.tooltip_delay_ms);
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), fixture.findByText(boundary_tree.root, .tooltip, "Insert a link").?.tooltip_delay_ms);
}

// --------------------- multi-child for bodies and the for-empty else

const multi_entries_markup =
    \\<column gap="4">
    \\  <for each="entries" as="e" key="id">
    \\    <if test="{e.status == closed_status}">
    \\      <badge>closed</badge>
    \\    </if>
    \\    <else>
    \\      <badge>open</badge>
    \\    </else>
    \\    <text>{e.label}</text>
    \\    <text>#{e.id}</text>
    \\  </for>
    \\  <else>
    \\    <text>Nothing yet</text>
    \\  </else>
    \\</column>
;

const MultiEntriesCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, multi_entries_markup);

fn interpretMultiEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var view = try EntriesInterpreter.init(arena, multi_entries_markup);
    var ui = EntriesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileMultiEntries(arena: std.mem.Allocator, model: *const EntriesModel) !EntriesUi.Tree {
    var ui = EntriesUi.init(arena);
    return ui.finalize(MultiEntriesCompiled.build(&ui, model));
}

test "compiled multi-child for bodies and the for-empty else match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 11, .label = "first" },
        .{ .id = 22, .label = "second", .status = .closed },
    };

    // Non-empty: each item emits an if/else badge arm plus two same-kind
    // texts as siblings (no wrapper node), and the trailing else stays out.
    var model = EntriesModel{ .entries = &entries };
    const interpreted = try interpretMultiEntries(arena, &model);
    const compiled = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(findText(compiled.root, "Nothing yet") == null);
    try testing.expect(findText(compiled.root, "first") != null);
    try testing.expect(findText(compiled.root, "#22") != null);
    try testing.expect(findText(compiled.root, "closed") != null);
    try testing.expect(findText(compiled.root, "open") != null);

    // Same-kind siblings from one keyed item stay distinct: the item key
    // slot-suffix keeps every structural id in the tree unique.
    var ids: std.ArrayListUnmanaged(canvas.ObjectId) = .empty;
    defer ids.deinit(testing.allocator);
    try fixture.collectIds(compiled.root, &ids, testing.allocator);
    for (ids.items, 0..) |id, index| {
        for (ids.items[index + 1 ..]) |other| try testing.expect(id != other);
    }

    // Keyed identity survives reorders for every node an item emits.
    const label_before = findText(compiled.root, "first").?;
    const number_before = findText(compiled.root, "#11").?;
    const reversed = [_]Entry{
        .{ .id = 22, .label = "second", .status = .closed },
        .{ .id = 11, .label = "first" },
    };
    model.entries = &reversed;
    const reordered = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, try interpretMultiEntries(arena, &model), reordered);
    try testing.expectEqual(label_before.id, findText(reordered.root, "first").?.id);
    try testing.expectEqual(number_before.id, findText(reordered.root, "#11").?.id);

    // Empty: the trailing else renders the empty state in both engines.
    model.entries = &.{};
    const empty_interpreted = try interpretMultiEntries(arena, &model);
    const empty_compiled = try compileMultiEntries(arena, &model);
    try expectSameTree(EntriesMsg, empty_interpreted, empty_compiled);
    try expectSameTexts(empty_interpreted.root, empty_compiled.root);
    try testing.expect(findText(empty_compiled.root, "Nothing yet") != null);
    try testing.expect(findText(empty_interpreted.root, "Nothing yet") != null);
}

test "the compiled path accepts every element the validator knows" {
    for (canvas.ui_markup.known_element_names) |name| {
        try testing.expect(markup_view.elementKind(name) != null);
    }
}

const icon_markup_source =
    "<row gap=\"8\">\n" ++
    "  <icon name=\"search\" width=\"16\" height=\"16\" foreground=\"accent\" />\n" ++
    "  <text>Search</text>\n" ++
    "</row>";

test "compiled icons match the interpreter and carry the validated name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, icon_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, icon_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    const icon = compiled.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.icon, icon.kind);
    try testing.expectEqualStrings("search", icon.text);
    try testing.expectEqual(canvas.WidgetKind.icon, interpreted.root.children[0].kind);
    try testing.expectEqualStrings("search", interpreted.root.children[0].text);
}

const button_icon_markup_source =
    "<row gap=\"8\">\n" ++
    "  <button icon=\"save\" on-press=\"add\">Save</button>\n" ++
    "  <button icon=\"refresh-cw\" on-press=\"add\" label=\"Refresh\"></button>\n" ++
    "  <toggle-button icon=\"arrow-up\" on-toggle=\"add\">Newest</toggle-button>\n" ++
    "  <list-item icon=\"folder\" on-press=\"add\">Projects</list-item>\n" ++
    "  <menu-item icon=\"trash\" on-press=\"add\">Delete</menu-item>\n" ++
    "</row>";

test "compiled button icons match the interpreter and carry the validated name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, button_icon_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, button_icon_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    for ([_]InboxUi.Tree{ interpreted, compiled }) |tree| {
        const labeled = tree.root.children[0];
        try testing.expectEqual(canvas.WidgetKind.button, labeled.kind);
        try testing.expectEqualStrings("save", labeled.icon);
        try testing.expectEqualStrings("Save", labeled.text);
        // Icon + label are ONE hit target: the icon has no child node and
        // the button's own press handler dispatches.
        try testing.expectEqual(@as(usize, 0), labeled.children.len);
        try testing.expect(tree.msgFor(labeled.id, .press) != null);
        const icon_only = tree.root.children[1];
        try testing.expectEqualStrings("refresh-cw", icon_only.icon);
        try testing.expectEqualStrings("", icon_only.text);
        try testing.expectEqualStrings("Refresh", icon_only.semantics.label);
        // The wider labeled interactive set compiles to the same
        // widgets in both engines.
        const chip = tree.root.children[2];
        try testing.expectEqual(canvas.WidgetKind.toggle_button, chip.kind);
        try testing.expectEqualStrings("arrow-up", chip.icon);
        const row_item = tree.root.children[3];
        try testing.expectEqual(canvas.WidgetKind.list_item, row_item.kind);
        try testing.expectEqualStrings("folder", row_item.icon);
        const menu_row = tree.root.children[4];
        try testing.expectEqual(canvas.WidgetKind.menu_item, menu_row.kind);
        try testing.expectEqualStrings("trash", menu_row.icon);
    }
}

const open_icon_markup_source =
    "<row gap=\"8\">\n" ++
    "  <icon name=\"app:wave\" width=\"16\" height=\"16\" />\n" ++
    "  <icon name=\"{filter}\" width=\"16\" height=\"16\" />\n" ++
    "  <button icon=\"app:wave\" on-press=\"add\">Wave</button>\n" ++
    "  <button icon=\"{filter}\" on-press=\"add\">Filter</button>\n" ++
    "</row>";

test "compiled app: and bound icons match the interpreter and ride the explicit icon channel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, open_icon_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, open_icon_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    for ([_]InboxUi.Tree{ interpreted, compiled }) |tree| {
        // Both open forms carry the name on `Widget.icon` (the explicit
        // channel the draw path resolves, with the missing-icon fallback
        // for names that resolve nowhere): the app: reference verbatim,
        // the binding as whatever the model produced.
        try testing.expectEqualStrings("app:wave", tree.root.children[0].icon);
        try testing.expectEqualStrings("all", tree.root.children[1].icon);
        try testing.expectEqualStrings("app:wave", tree.root.children[2].icon);
        try testing.expectEqualStrings("all", tree.root.children[3].icon);
    }
}

const list_row_markup_source =
    "<column>\n" ++
    "  <list-item on-press=\"add\" label=\"Groceries row\" padding=\"8\" gap=\"8\">\n" ++
    "    <text grow=\"1\">Groceries</text>\n" ++
    "    <badge variant=\"secondary\">3</badge>\n" ++
    "  </list-item>\n" ++
    "  <list-item on-press=\"add\">Piranesi</list-item>\n" ++
    "</column>";

test "compiled list-row composites match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = fixture.Model{};

    var interpreter_view = try InboxInterpreter.init(arena, list_row_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try interpreter_view.build(&interpreter_ui, &model));

    const Compiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, list_row_markup_source);
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.Msg, interpreted, compiled);
    for ([_]InboxUi.Tree{ interpreted, compiled }) |tree| {
        // Element children in place of the text run: the row keeps the
        // flat list-item kind and flows the children inside it.
        const composite = tree.root.children[0];
        try testing.expectEqual(canvas.WidgetKind.list_item, composite.kind);
        try testing.expectEqual(@as(usize, 2), composite.children.len);
        try testing.expectEqual(@as(usize, 0), composite.text.len);
        try testing.expectEqualStrings("Groceries row", composite.semantics.label);
        try testing.expect(tree.msgFor(composite.id, .press) != null);
        // The classic text leaf keeps working next to it.
        const leaf = tree.root.children[1];
        try testing.expectEqual(canvas.WidgetKind.list_item, leaf.kind);
        try testing.expectEqualStrings("Piranesi", leaf.text);
        try testing.expectEqual(@as(usize, 0), leaf.children.len);
    }
}

// --------------------------------------------- component catalog parity

const CatalogUi = fixture.CatalogUi;
const CatalogInterpreter = markup_view.MarkupView(fixture.CatalogModel, fixture.CatalogMsg);
const CatalogCompiled = canvas.CompiledMarkupView(fixture.CatalogModel, fixture.CatalogMsg, fixture.catalog_markup_source);

fn interpretCatalog(arena: std.mem.Allocator, model: *const fixture.CatalogModel) !CatalogUi.Tree {
    var view = try CatalogInterpreter.init(arena, fixture.catalog_markup_source);
    var ui = CatalogUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileCatalog(arena: std.mem.Allocator, model: *const fixture.CatalogModel) !CatalogUi.Tree {
    var ui = CatalogUi.init(arena);
    return ui.finalize(CatalogCompiled.build(&ui, model));
}

test "compiled catalog elements match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.catalogTestModel();

    const interpreted = try interpretCatalog(arena, &model);
    const compiled = try compileCatalog(arena, &model);
    var hand_ui = CatalogUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handCatalogView(&hand_ui, &model));

    // All three engines agree on every new element: ids, handlers, texts.
    try expectSameTree(fixture.CatalogMsg, hand, interpreted);
    try expectSameTree(fixture.CatalogMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Dispatch parity across the new control kinds.
    const select = fixture.findByKind(compiled.root, .select).?;
    try testing.expectEqual(
        interpreted.msgForPointer(select.id, .up).?,
        compiled.msgForPointer(select.id, .up).?,
    );
    const switch_control = fixture.findByKind(compiled.root, .switch_control).?;
    try testing.expectEqual(fixture.CatalogMsg.toggle_bold, compiled.msgForPointer(switch_control.id, .up).?);
    const pears_cell = fixture.findByText(compiled.root, .data_cell, "Pears").?;
    try testing.expectEqual(
        interpreted.msgForPointer(pears_cell.id, .up).?,
        compiled.msgForPointer(pears_cell.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(pears_cell.id, .up).?.pick_row);

    // Text entry parity on the input element, including on-input.
    const input = fixture.findByKind(compiled.root, .input).?;
    const typed = canvas.WidgetKeyboardEvent{ .phase = .text_input, .text = "q" };
    try testing.expectEqualStrings("q", compiled.msgForKeyboard(input.id, typed).?.query_edit.insert_text);
    const submit = canvas.WidgetKeyboardEvent{ .phase = .key_down, .key = "enter" };
    try testing.expectEqual(
        interpreted.msgForKeyboard(input.id, submit).?,
        compiled.msgForKeyboard(input.id, submit).?,
    );
    const combobox = fixture.findByKind(compiled.root, .combobox).?;
    try testing.expectEqual(fixture.CatalogMsg.submit_query, compiled.msgForKeyboard(combobox.id, submit).?);
    try testing.expectEqual(fixture.CatalogMsg.open_picker, compiled.msgForKeyboard(combobox.id, .{ .phase = .key_down, .key = "space" }).?);
}

test "compiled catalog stays in parity when conditional surfaces flip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.catalogTestModel();
    model.loading = false;
    model.dialog_open = true;
    model.tab = 1;
    model.bold = true;
    model.page = 3;

    const interpreted = try interpretCatalog(arena, &model);
    const compiled = try compileCatalog(arena, &model);
    try expectSameTree(fixture.CatalogMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The dialog branch renders with its title and dispatching child.
    const dialog = fixture.findByKind(compiled.root, .dialog).?;
    try testing.expectEqualStrings("Confirm", dialog.text);
    try testing.expect(fixture.findByKind(compiled.root, .spinner) == null);
    const yes_button = fixture.findByText(compiled.root, .button, "Yes").?;
    try testing.expectEqual(fixture.CatalogMsg.submit_query, compiled.msgForPointer(yes_button.id, .up).?);
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(fixture.findByText(compiled.root, .button, "Prev").?.id, .up).?.set_page);
}

// ---------------------------------------------- arena-scalar binding parity

const ExpensesUi = fixture.ExpensesUi;
const ExpensesInterpreter = markup_view.MarkupView(fixture.ExpensesModel, fixture.ExpensesMsg);
const ExpensesCompiled = canvas.CompiledMarkupView(fixture.ExpensesModel, fixture.ExpensesMsg, fixture.expenses_markup_source);

fn interpretExpenses(arena: std.mem.Allocator, model: *const fixture.ExpensesModel) !ExpensesUi.Tree {
    var view = try ExpensesInterpreter.init(arena, fixture.expenses_markup_source);
    var ui = ExpensesUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileExpenses(arena: std.mem.Allocator, model: *const fixture.ExpensesModel) !ExpensesUi.Tree {
    var ui = ExpensesUi.init(arena);
    return ui.finalize(ExpensesCompiled.build(&ui, model));
}

test "compiled arena-scalar bindings match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.expensesTestModel();

    const interpreted = try interpretExpenses(arena, &model);
    const compiled = try compileExpenses(arena, &model);
    var hand_ui = ExpensesUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handExpensesView(&hand_ui, &model));

    // All three engines agree: the arena scalar flows through text
    // content, interpolation, an attribute value (label), a message
    // payload, an if test, and an item-level arena method.
    try expectSameTree(fixture.ExpensesMsg, hand, interpreted);
    try expectSameTree(fixture.ExpensesMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    try testing.expectEqualStrings("2 expenses · $12.94", fixture.findByKind(compiled.root, .status_bar).?.text);
    const labeled = fixture.findByText(compiled.root, .text, "all: 2 expenses · $12.94").?;
    try testing.expectEqualStrings("2 expenses · $12.94", labeled.semantics.label);
    try testing.expect(fixture.findByText(compiled.root, .badge, "summarized") != null);

    // Payload dispatch parity: the arena string rides the typed message.
    const pick_button = fixture.findByKind(compiled.root, .button).?;
    try testing.expectEqualStrings("$12.34", compiled.msgForPointer(pick_button.id, .up).?.pick);
    try testing.expectEqualStrings(
        interpreted.msgForPointer(pick_button.id, .up).?.pick,
        compiled.msgForPointer(pick_button.id, .up).?.pick,
    );
}

test "compiled string bindings pass to templates as value args" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.expensesTestModel();
    const source =
        "<template name=\"line\" args=\"title\"><text>{title}</text></template>\n" ++
        "<column>\n" ++
        "  <use template=\"line\" title=\"{filter}\" />\n" ++
        "  <use template=\"line\" title=\"{summary}\" />\n" ++
        "</column>";
    const Compiled = canvas.CompiledMarkupView(fixture.ExpensesModel, fixture.ExpensesMsg, source);

    var compiled_ui = ExpensesUi.init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try ExpensesInterpreter.init(arena, source);
    var interpreted_ui = ExpensesUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    try expectSameTree(fixture.ExpensesMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expect(findText(compiled.root, "all") != null);
    try testing.expect(findText(compiled.root, "2 expenses · $12.94") != null);
}

// -------------------------------------------------- markdown element parity

const DocUi = fixture.DocUi;
const DocInterpreter = markup_view.MarkupView(fixture.DocModel, fixture.DocMsg);
const DocCompiled = canvas.CompiledMarkupView(fixture.DocModel, fixture.DocMsg, fixture.doc_markup_source);

fn interpretDoc(arena: std.mem.Allocator, model: *const fixture.DocModel) !DocUi.Tree {
    var view = try DocInterpreter.init(arena, fixture.doc_markup_source);
    var ui = DocUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileDoc(arena: std.mem.Allocator, model: *const fixture.DocModel) !DocUi.Tree {
    var ui = DocUi.init(arena);
    return ui.finalize(DocCompiled.build(&ui, model));
}

test "compiled markdown element matches the interpreter and the hand-written Md.view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.DocModel{};

    const interpreted = try interpretDoc(arena, &model);
    const compiled = try compileDoc(arena, &model);
    var hand_ui = DocUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handDocView(&hand_ui, &model));

    try expectSameTree(fixture.DocMsg, hand, interpreted);
    try expectSameTree(fixture.DocMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Link dispatch parity, including the payload URL.
    const link = fixture.findByRole(compiled.root, .link).?;
    try testing.expectEqualStrings("https://example.com/guide", compiled.msgForPointer(link.id, .up).?.open_url);
    try testing.expectEqualStrings(
        interpreted.msgForPointer(link.id, .up).?.open_url,
        compiled.msgForPointer(link.id, .up).?.open_url,
    );

    // Autolink parity: issue refs through the issue-link-base binding and
    // bare URLs resolve to the same targets in both engines.
    try testing.expectEqualStrings("ghissue://12", fixture.findSpanLink(compiled.root, "#12").?);
    try testing.expectEqualStrings(
        fixture.findSpanLink(interpreted.root, "#12").?,
        fixture.findSpanLink(compiled.root, "#12").?,
    );
    try testing.expectEqualStrings(
        fixture.findSpanLink(interpreted.root, "https://status.example.com").?,
        fixture.findSpanLink(compiled.root, "https://status.example.com").?,
    );

    // Details dispatch parity: the summary press carries the block index.
    const summary_item = fixture.findByKind(compiled.root, .list_item).?;
    try testing.expectEqual(@as(usize, 0), compiled.msgForPointer(summary_item.id, .up).?.toggle_details);
    try testing.expect(findText(compiled.root, "Enable for 5% of traffic.") == null);

    // Expanding through the caller-owned flag keeps the engines in step.
    model.details_expanded[0] = true;
    const expanded_interpreted = try interpretDoc(arena, &model);
    const expanded_compiled = try compileDoc(arena, &model);
    try expectSameTree(fixture.DocMsg, expanded_interpreted, expanded_compiled);
    try expectSameTexts(expanded_interpreted.root, expanded_compiled.root);
    try testing.expect(findText(expanded_compiled.root, "Enable for 5% of traffic.") != null);

    // The summary keeps its id across the expand (keyed by details index).
    try testing.expectEqual(summary_item.id, fixture.findByKind(expanded_compiled.root, .list_item).?.id);
}

// ------------------------------------------------------ code element parity

const CodeUi = fixture.CodeUi;
const CodeInterpreter = markup_view.MarkupView(fixture.CodeModel, fixture.CodeMsg);
const CodeCompiled = canvas.CompiledMarkupView(fixture.CodeModel, fixture.CodeMsg, fixture.code_markup_source);

test "compiled code element matches the interpreter and Ui.code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = fixture.CodeModel{};

    var view = try CodeInterpreter.init(arena, fixture.code_markup_source);
    var interpreted_ui = CodeUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));
    var compiled_ui = CodeUi.init(arena);
    const compiled = try compiled_ui.finalize(CodeCompiled.build(&compiled_ui, &model));
    var hand_ui = CodeUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handCodeView(&hand_ui, &model));

    try expectSameTree(fixture.CodeMsg, hand, interpreted);
    try expectSameTree(fixture.CodeMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try testing.expectEqual(canvas.ScrollAxes.horizontal, fixture.findByKind(compiled.root, .scroll_view).?.scroll_axes);

    model.wrap_code = true;
    model.show_lines = false;
    var wrapped_ui = CodeUi.init(arena);
    const wrapped = try wrapped_ui.finalize(CodeCompiled.build(&wrapped_ui, &model));
    try testing.expect(fixture.findByKind(wrapped.root, .scroll_view) == null);
    try testing.expect(fixture.findByText(wrapped.root, .text, "1") == null);

    model.editable_code = true;
    var editable_compiled_ui = CodeUi.init(arena);
    const editable_compiled = try editable_compiled_ui.finalize(CodeCompiled.build(&editable_compiled_ui, &model));
    var editable_interpreted_ui = CodeUi.init(arena);
    const editable_interpreted = try editable_interpreted_ui.finalize(try view.build(&editable_interpreted_ui, &model));
    var editable_hand_ui = CodeUi.init(arena);
    const editable_hand = try editable_hand_ui.finalize(fixture.handCodeView(&editable_hand_ui, &model));
    try expectSameTree(fixture.CodeMsg, editable_hand, editable_interpreted);
    try expectSameTree(fixture.CodeMsg, editable_hand, editable_compiled);
    try testing.expectEqual(canvas.WidgetKind.textarea, editable_compiled.root.kind);
    try testing.expect(editable_compiled.root.runtime_flags.code_editor);
}

// ------------------------------------------- template/use + style parity

fn expectSameStyles(expected: canvas.Widget, actual: canvas.Widget) !void {
    try testing.expect(std.meta.eql(expected.style, actual.style));
    try testing.expectEqual(expected.children.len, actual.children.len);
    for (expected.children, actual.children) |expected_child, actual_child| {
        try expectSameStyles(expected_child, actual_child);
    }
}

const TemplateUi = fixture.TemplateUi;
const TemplateInterpreter = markup_view.MarkupView(fixture.TemplateModel, fixture.TemplateMsg);
const TemplateCompiled = canvas.CompiledMarkupView(fixture.TemplateModel, fixture.TemplateMsg, fixture.template_markup_source);

fn interpretTemplates(arena: std.mem.Allocator, model: *const fixture.TemplateModel, tokens: canvas.DesignTokens) !TemplateUi.Tree {
    var view = try TemplateInterpreter.init(arena, fixture.template_markup_source);
    var ui = TemplateUi.init(arena);
    return ui.finalizeWithTokens(try view.build(&ui, model), tokens);
}

fn compileTemplates(arena: std.mem.Allocator, model: *const fixture.TemplateModel, tokens: canvas.DesignTokens) !TemplateUi.Tree {
    var ui = TemplateUi.init(arena);
    return ui.finalizeWithTokens(TemplateCompiled.build(&ui, model), tokens);
}

test "compiled templates with slice and value args match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.templateTestModel();
    const tokens = canvas.DesignTokens{};

    const interpreted = try interpretTemplates(arena, &model, tokens);
    const compiled = try compileTemplates(arena, &model, tokens);
    var hand_ui = TemplateUi.init(arena);
    const hand = try hand_ui.finalizeWithTokens(fixture.handTemplateView(&hand_ui, &model), tokens);

    // All three engines agree: ids, handlers, texts, and resolved styles.
    // The fixture covers a value arg (title), a slice arg iterated by a
    // for inside the template, a nested use whose arg binds a loop item
    // field, and style token attributes.
    try expectSameTree(fixture.TemplateMsg, hand, interpreted);
    try expectSameTree(fixture.TemplateMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    try expectSameStyles(hand.root, interpreted.root);
    try expectSameStyles(hand.root, compiled.root);

    // Dispatch parity for a handler declared inside a template body.
    const pear_button = fixture.findByText(compiled.root, .button, "pear").?;
    try testing.expectEqual(
        interpreted.msgForPointer(pear_button.id, .up).?,
        compiled.msgForPointer(pear_button.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(pear_button.id, .up).?.pick);

    // Style token references resolved to the same concrete values.
    const badge = fixture.findByText(compiled.root, .badge, "apple").?;
    try testing.expectEqualDeep(tokens.colors.surface, badge.style.background.?);
    try testing.expectEqual(tokens.radius.md, badge.style.radius.?);
}

test "compiled template expansion keeps ids per use site and re-resolves tokens" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.templateTestModel();

    const light = try compileTemplates(arena, &model, canvas.DesignTokens{});
    const top_text = fixture.findByText(light.root, .text, "Top").?;
    const bottom_text = fixture.findByText(light.root, .text, "Bottom").?;
    try testing.expect(top_text.id != bottom_text.id);

    // Retheme rebuild: same ids, new resolved colors — and the
    // interpreter agrees on both.
    const dark_tokens = canvas.DesignTokens.theme(.{ .color_scheme = .dark });
    const dark = try compileTemplates(arena, &model, dark_tokens);
    const dark_top_text = fixture.findByText(dark.root, .text, "Top").?;
    try testing.expectEqual(top_text.id, dark_top_text.id);
    try testing.expectEqualDeep(dark_tokens.colors.text_muted, dark_top_text.style.foreground.?);
    try testing.expect(!std.meta.eql(top_text.style.foreground.?, dark_top_text.style.foreground.?));

    const dark_interpreted = try interpretTemplates(arena, &model, dark_tokens);
    try expectSameTree(fixture.TemplateMsg, dark_interpreted, dark);
    try expectSameStyles(dark_interpreted.root, dark.root);
}

// ------------------------------------------- avatar image binding parity

const AvatarUi = fixture.AvatarUi;
const AvatarInterpreter = markup_view.MarkupView(fixture.AvatarModel, fixture.AvatarMsg);
const AvatarCompiled = canvas.CompiledMarkupView(fixture.AvatarModel, fixture.AvatarMsg, fixture.avatar_markup_source);

test "compiled avatar image binding matches the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.AvatarModel{ .user_image = 7 };

    var view = try AvatarInterpreter.init(arena, fixture.avatar_markup_source);
    var interpreted_ui = AvatarUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = AvatarUi.init(arena);
    const compiled = try compiled_ui.finalize(AvatarCompiled.build(&compiled_ui, &model));

    var hand_ui = AvatarUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handAvatarView(&hand_ui, &model));

    try expectSameTree(fixture.AvatarMsg, hand, interpreted);
    try expectSameTree(fixture.AvatarMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The field binding and the fn binding both resolve to the widget's
    // image id at comptime-unrolled access, with the Ui.avatar cover fit.
    const field_avatar = fixture.findByText(compiled.root, .avatar, "CT").?;
    try testing.expectEqual(@as(canvas.ImageId, 7), field_avatar.image_id);
    try testing.expectEqual(canvas.ImageFit.cover, field_avatar.image_fit);
    try testing.expectEqual(@as(canvas.ImageId, 8), fixture.findByText(compiled.root, .avatar, "NS").?.image_id);

    // 0 keeps the initials fallback in both engines.
    const empty_model = fixture.AvatarModel{};
    var empty_ui = AvatarUi.init(arena);
    const empty = try empty_ui.finalize(AvatarCompiled.build(&empty_ui, &empty_model));
    try testing.expectEqual(@as(canvas.ImageId, 0), fixture.findByText(empty.root, .avatar, "CT").?.image_id);
    try testing.expectEqualStrings("CT", fixture.findByText(empty.root, .avatar, "CT").?.text);
}

// ------------------------------- negative id bindings fail, never trap

const AvatarNegativeCompiled = canvas.CompiledMarkupView(fixture.AvatarModel, fixture.AvatarMsg, fixture.avatar_negative_markup_source);
const SurfaceUi = fixture.SurfaceUi;
const SurfaceCompiled = canvas.CompiledMarkupView(fixture.SurfaceModel, fixture.SurfaceMsg, fixture.surface_markup_source);
const SurfaceNegativeCompiled = canvas.CompiledMarkupView(fixture.SurfaceModel, fixture.SurfaceMsg, fixture.surface_negative_markup_source);

test "compiled avatar and media-surface id bindings refuse negative model values instead of trapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The u64 surface id resolves like the interpreter's.
    var ok_ui = SurfaceUi.init(arena);
    const ok_tree = try ok_ui.finalize(SurfaceCompiled.build(&ok_ui, &fixture.SurfaceModel{}));
    const surface = ok_tree.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.media_surface, surface.kind);
    try testing.expectEqual(@as(canvas.ImageId, 5), surface.image_id);

    // A negative i64 binding into either u64 id seam latches the
    // failed build (the interpreter's teaching error mirrors it), and
    // finalize surfaces the failure — never an @intCast trap.
    var avatar_ui = AvatarUi.init(arena);
    const avatar_node = AvatarNegativeCompiled.build(&avatar_ui, &fixture.AvatarModel{});
    try testing.expect(avatar_ui.failed);
    try testing.expectError(error.OutOfMemory, avatar_ui.finalize(avatar_node));

    var surface_ui = SurfaceUi.init(arena);
    const surface_node = SurfaceNegativeCompiled.build(&surface_ui, &fixture.SurfaceModel{});
    try testing.expect(surface_ui.failed);
    try testing.expectError(error.OutOfMemory, surface_ui.finalize(surface_node));
}

// ------------------------------------------------ image leaf id binding

const ImageLeafUi = fixture.ImageLeafUi;
const ImageLeafInterpreter = markup_view.MarkupView(fixture.ImageLeafModel, fixture.ImageLeafMsg);
const ImageLeafCompiled = canvas.CompiledMarkupView(fixture.ImageLeafModel, fixture.ImageLeafMsg, fixture.image_markup_source);
const ImageLeafNegativeCompiled = canvas.CompiledMarkupView(fixture.ImageLeafModel, fixture.ImageLeafMsg, fixture.image_negative_markup_source);

test "compiled image leaf binding matches the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.ImageLeafModel{ .cover = 42 };

    var view = try ImageLeafInterpreter.init(arena, fixture.image_markup_source);
    var interpreted_ui = ImageLeafUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = ImageLeafUi.init(arena);
    const compiled = try compiled_ui.finalize(ImageLeafCompiled.build(&compiled_ui, &model));

    var hand_ui = ImageLeafUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handImageLeafView(&hand_ui, &model));

    try expectSameTree(fixture.ImageLeafMsg, hand, interpreted);
    try expectSameTree(fixture.ImageLeafMsg, hand, compiled);

    // The field binding, source-coordinate bindings, and id fn all
    // resolve through comptime-unrolled access.
    const cover = compiled.root.children[0];
    try testing.expectEqual(canvas.WidgetKind.image, cover.kind);
    try testing.expectEqual(@as(canvas.ImageId, 42), cover.image_id);
    try testing.expectEqualDeep(@as(?geometry.RectF, geometry.RectF.init(4, 8, 32, 24)), cover.image_src);
    try testing.expectEqual(@as(canvas.ImageId, 43), compiled.root.children[1].image_id);
    try testing.expectEqual(@as(?geometry.RectF, null), compiled.root.children[1].image_src);

    // 0 draws nothing in both engines — the not-loaded-yet state.
    const empty_model = fixture.ImageLeafModel{};
    var empty_ui = ImageLeafUi.init(arena);
    const empty = try empty_ui.finalize(ImageLeafCompiled.build(&empty_ui, &empty_model));
    try testing.expectEqual(@as(canvas.ImageId, 0), empty.root.children[0].image_id);
}

test "compiled image leaf binding refuses negative model values instead of trapping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A negative i64 binding into the u64 id seam latches the failed
    // build (the interpreter's teaching error mirrors it), and
    // finalize surfaces the failure — never an @intCast trap.
    var image_ui = ImageLeafUi.init(arena);
    const image_node = ImageLeafNegativeCompiled.build(&image_ui, &fixture.ImageLeafModel{});
    try testing.expect(image_ui.failed);
    try testing.expectError(error.OutOfMemory, image_ui.finalize(image_node));
}

// -------------------------------------------------- terminal element

const TerminalElementUi = fixture.TerminalElementUi;
const TerminalElementInterpreter = markup_view.MarkupView(fixture.TerminalElementModel, fixture.TerminalElementMsg);
const TerminalElementCompiled = canvas.CompiledMarkupView(fixture.TerminalElementModel, fixture.TerminalElementMsg, fixture.terminal_markup_source);

test "compiled terminal element matches the interpreter and the hand-written ui.terminal tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.TerminalElementModel{};

    var view = try TerminalElementInterpreter.init(arena, fixture.terminal_markup_source);
    var interpreted_ui = TerminalElementUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = TerminalElementUi.init(arena);
    const compiled = try compiled_ui.finalize(TerminalElementCompiled.build(&compiled_ui, &model));

    var hand_ui = TerminalElementUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handTerminalElementView(&hand_ui, &model));

    try expectSameTree(fixture.TerminalElementMsg, hand, interpreted);
    try expectSameTree(fixture.TerminalElementMsg, hand, compiled);

    // All three lowerings bind the model-owned key and the echo.
    for ([_]TerminalElementUi.Tree{ hand, interpreted, compiled }) |tree| {
        const widget = fixture.findWidgetKind(tree.root, .terminal) orelse return error.TestExpectedTerminal;
        try testing.expectEqual(@as(u64, 7), widget.terminal.pty);
        try testing.expectEqual(@as(u32, 4), widget.terminal.scrollback);
        try testing.expect(widget.terminal.grid == null);
    }
}

// --------------------------------------------- video playback element

const VideoElementUi = fixture.VideoElementUi;
const VideoElementInterpreter = markup_view.MarkupView(fixture.VideoElementModel, fixture.VideoElementMsg);
const VideoElementCompiled = canvas.CompiledMarkupView(fixture.VideoElementModel, fixture.VideoElementMsg, fixture.video_markup_source);
const VideoElementPlainCompiled = canvas.CompiledMarkupView(fixture.VideoElementModel, fixture.VideoElementMsg, fixture.video_plain_markup_source);

test "compiled video element matches the interpreter and the hand-written ui.video tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.VideoElementModel{};

    var view = try VideoElementInterpreter.init(arena, fixture.video_markup_source);
    var interpreted_ui = VideoElementUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = VideoElementUi.init(arena);
    const compiled = try compiled_ui.finalize(VideoElementCompiled.build(&compiled_ui, &model));

    var hand_ui = VideoElementUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handVideoElementView(&hand_ui, &model));

    try expectSameTree(fixture.VideoElementMsg, hand, interpreted);
    try expectSameTree(fixture.VideoElementMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The compiled lowering binds the framework-owned playback surface
    // and stamps the chrome's runtime-consumed verbs, exactly like the
    // interpreter and the hand-written builder call.
    const surface = compiled.root.children[0].children[0];
    try testing.expectEqual(canvas.WidgetKind.media_surface, surface.kind);
    try testing.expectEqual(canvas.video_playback_surface_id, surface.image_id);
    const toggle = fixture.findVideoControl(compiled.root, .toggle) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetKind.button, toggle.kind);
    const scrub = fixture.findVideoControl(compiled.root, .scrub) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetKind.slider, scrub.kind);

    // Both engines recorded the same declaration for the app loop's
    // reconcile.
    const compiled_declaration = compiled_ui.video_declaration orelse return error.TestUnexpectedResult;
    const interpreted_declaration = interpreted_ui.video_declaration orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(interpreted_declaration.src, compiled_declaration.src);
    try testing.expectEqual(interpreted_declaration.autoplay, compiled_declaration.autoplay);
    try testing.expectEqual(interpreted_declaration.loop, compiled_declaration.loop);
    try testing.expectEqual(interpreted_declaration.muted, compiled_declaration.muted);

    // The controls-less shape compiles to the bare surface: no chrome.
    var plain_ui = VideoElementUi.init(arena);
    const plain = try plain_ui.finalize(VideoElementPlainCompiled.build(&plain_ui, &model));
    try testing.expectEqual(canvas.WidgetKind.media_surface, plain.root.children[0].kind);
    try testing.expect(fixture.findVideoControl(plain.root, .toggle) == null);
    try testing.expect(fixture.findVideoControl(plain.root, .scrub) == null);
}

// ------------------------------------------------------ text wrap parity

const WrapUi = fixture.WrapUi;
const WrapInterpreter = markup_view.MarkupView(fixture.WrapModel, fixture.WrapMsg);
const WrapCompiled = canvas.CompiledMarkupView(fixture.WrapModel, fixture.WrapMsg, fixture.wrap_markup_source);

test "compiled wrap attribute matches the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.WrapModel{};

    var view = try WrapInterpreter.init(arena, fixture.wrap_markup_source);
    var interpreted_ui = WrapUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = WrapUi.init(arena);
    const compiled = try compiled_ui.finalize(WrapCompiled.build(&compiled_ui, &model));

    var hand_ui = WrapUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handWrapView(&hand_ui, &model));

    try expectSameTree(fixture.WrapMsg, hand, interpreted);
    try expectSameTree(fixture.WrapMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Both engines produce the single-span paragraph conversion.
    const compiled_wrapped = compiled.root.children[0];
    try testing.expectEqual(@as(usize, 1), compiled_wrapped.spans.len);
    try testing.expectEqualStrings(model.message, compiled_wrapped.text);
    try testing.expectEqual(@as(usize, 0), compiled.root.children[1].spans.len);
    try testing.expect(!compiled.root.children[1].text_no_wrap);
    // And both stamp wrap="false" as the honest single-line mode.
    const compiled_no_wrap = compiled.root.children[2];
    try testing.expectEqual(@as(usize, 0), compiled_no_wrap.spans.len);
    try testing.expect(compiled_no_wrap.text_no_wrap);
    try testing.expect(interpreted.root.children[2].text_no_wrap);
    // Both engines land overflow="clip" on the widget; unmarked leaves
    // keep the ellipsis default.
    try testing.expectEqual(canvas.TextOverflow.clip, compiled.root.children[3].text_overflow);
    try testing.expectEqual(canvas.TextOverflow.clip, interpreted.root.children[3].text_overflow);
    try testing.expectEqual(canvas.TextOverflow.ellipsis, compiled.root.children[1].text_overflow);
    try testing.expectEqual(canvas.TextOverflow.ellipsis, interpreted.root.children[1].text_overflow);
    // The definite width lands in both bounds.
    try testing.expectEqual(@as(f32, 360), compiled.root.layout.min_size.width);
    try testing.expectEqual(@as(f32, 360), compiled.root.layout.max_size.width);
}

// ------------------------------------------------ text size rung parity

const TypeScaleUi = fixture.TypeScaleUi;
const TypeScaleInterpreter = markup_view.MarkupView(fixture.TypeScaleModel, fixture.TypeScaleMsg);
const TypeScaleCompiled = canvas.CompiledMarkupView(fixture.TypeScaleModel, fixture.TypeScaleMsg, fixture.type_scale_markup_source);

test "compiled text size rungs match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.TypeScaleModel{};

    var view = try TypeScaleInterpreter.init(arena, fixture.type_scale_markup_source);
    var interpreted_ui = TypeScaleUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = TypeScaleUi.init(arena);
    const compiled = try compiled_ui.finalize(TypeScaleCompiled.build(&compiled_ui, &model));

    var hand_ui = TypeScaleUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handTypeScaleView(&hand_ui, &model));

    try expectSameTree(fixture.TypeScaleMsg, hand, interpreted);
    try expectSameTree(fixture.TypeScaleMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Both engines stamp the typography rungs onto the text widgets, and
    // the wrapped display line keeps the single-span paragraph conversion.
    try testing.expectEqual(canvas.WidgetSize.heading, compiled.root.children[0].size);
    try testing.expectEqual(canvas.WidgetSize.display, compiled.root.children[1].size);
    try testing.expectEqual(canvas.WidgetSize.display, interpreted.root.children[1].size);
    const compiled_wrapped = compiled.root.children[2];
    try testing.expectEqual(canvas.WidgetSize.display, compiled_wrapped.size);
    try testing.expectEqual(@as(usize, 1), compiled_wrapped.spans.len);
}

// -------------------------------- text alignment and grid columns parity

const AlignUi = fixture.AlignUi;
const AlignInterpreter = markup_view.MarkupView(fixture.AlignModel, fixture.AlignMsg);
const AlignCompiled = canvas.CompiledMarkupView(fixture.AlignModel, fixture.AlignMsg, fixture.align_markup_source);

test "compiled text-alignment and grid columns match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.AlignModel{};

    var view = try AlignInterpreter.init(arena, fixture.align_markup_source);
    var interpreted_ui = AlignUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = AlignUi.init(arena);
    const compiled = try compiled_ui.finalize(AlignCompiled.build(&compiled_ui, &model));

    var hand_ui = AlignUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handAlignView(&hand_ui, &model));

    try expectSameTree(fixture.AlignMsg, hand, interpreted);
    try expectSameTree(fixture.AlignMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Both engines land the alignment and the column counts.
    try testing.expectEqual(canvas.TextAlign.center, compiled.root.children[0].text_alignment);
    try testing.expectEqualDeep((canvas.DesignTokens{}).colors.info, compiled.root.children[0].style.foreground.?);
    try testing.expectEqual(@as(usize, 4), compiled.root.children[1].layout.columns);
    try testing.expectEqual(@as(usize, 3), compiled.root.children[2].layout.columns);
}

// --------------------------------- pressable rows (press fall-through)

const pressable_rows_markup =
    \\<column gap="4">
    \\  <for each="entries" as="e" key="id">
    \\    <panel on-press="open_entry:{e.id}" padding="8" role="listitem" label="{e.label}">
    \\      <row gap="8" cross="center">
    \\        <text grow="1">{e.label}</text>
    \\        <badge>#{e.id}</badge>
    \\      </row>
    \\    </panel>
    \\  </for>
    \\  <row on-press="refresh" gap="8">
    \\    <text>Refresh feed</text>
    \\  </row>
    \\</column>
;

const PressableRowsCompiled = canvas.CompiledMarkupView(EntriesModel, EntriesMsg, pressable_rows_markup);

test "compiled pressable rows (panel and layout containers) match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const entries = [_]Entry{
        .{ .id = 7, .label = "Ship the IR" },
        .{ .id = 9, .label = "Write decisions" },
    };
    const model = EntriesModel{ .entries = &entries };

    var view = try EntriesInterpreter.init(arena, pressable_rows_markup);
    var interpreter_ui = EntriesUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = EntriesUi.init(arena);
    const compiled = try compiled_ui.finalize(PressableRowsCompiled.build(&compiled_ui, &model));
    try expectSameTree(EntriesMsg, interpreted, compiled);

    // Both engines make the pressable panel row a press claimer that
    // dispatches the payload-carrying Msg, with its text falling through.
    const first_row = fixture.findByKind(compiled.root, .panel).?;
    try testing.expectEqualStrings("Ship the IR", first_row.semantics.label);
    try testing.expect(canvas.widgetClaimsPress(first_row));
    try testing.expectEqual(@as(u32, 7), compiled.msgForPointer(first_row.id, .up).?.open_entry);
    try testing.expect(!canvas.widgetClaimsPress(first_row.children[0].children[0]));

    // A LAYOUT container with on-press is a widget-level hit target in
    // both engines — the handler stamps the press action.
    var pressable_row: ?canvas.Widget = null;
    for (compiled.root.children) |child| {
        if (child.kind == .row and child.semantics.actions.press) pressable_row = child;
    }
    try testing.expect(pressable_row != null);
    try testing.expect(canvas.widgetIsHitTarget(pressable_row.?));
    try testing.expectEqual(EntriesMsg.refresh, compiled.msgForPointer(pressable_row.?.id, .up).?);
}

// -------------------------------------------------- anchored picker parity

const PickerCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.picker_markup_source);

test "compiled anchored picker (anchor, on-dismiss, on-hold) matches the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.Model{};

    var view = try InboxInterpreter.init(arena, fixture.picker_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(PickerCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.Msg, interpreted, compiled);

    // Both engines resolve the anchor attributes into the same layout
    // channel and bind the dismiss/hold handlers identically.
    const dropdown = fixture.findByKind(compiled.root, .dropdown_menu).?;
    const anchor = dropdown.layout.anchor orelse return error.TestUnexpectedResult;
    try testing.expectEqual(canvas.WidgetAnchorPlacement.below, anchor.placement);
    try testing.expectEqual(canvas.WidgetAnchorAlignment.stretch, anchor.alignment);
    try testing.expectEqual(@as(f32, 6), anchor.offset);
    try testing.expect(compiled.msgFor(dropdown.id, .dismiss) != null);
    const crumb = fixture.findByKind(compiled.root, .button).?;
    try testing.expect(compiled.msgFor(crumb.id, .hold) != null);
    try testing.expect(crumb.semantics.actions.press);
}

// ------------------------------------------------------- hover-pair parity

const HoverCompiled = canvas.CompiledMarkupView(fixture.Model, fixture.Msg, fixture.hover_markup_source);

test "compiled hover pair (on-hover-enter, on-hover-leave) matches the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.Model{};

    var view = try InboxInterpreter.init(arena, fixture.hover_markup_source);
    var interpreter_ui = InboxUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = InboxUi.init(arena);
    const compiled = try compiled_ui.finalize(HoverCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.Msg, interpreted, compiled);

    // Both engines stamp the listener flag (hover-hittable, never
    // pressable) and bind both edges through the handler table.
    const panel = fixture.findByKind(compiled.root, .panel).?;
    const row = fixture.findByKind(compiled.root, .row).?;
    try testing.expect(panel.hover_msgs and row.hover_msgs);
    try testing.expect(!row.semantics.actions.press);
    try testing.expect(!canvas.widgetIsHitTarget(row));
    try testing.expect(canvas.widgetIsHoverMsgHitTarget(row));
    try testing.expectEqual(fixture.Msg.add, compiled.msgFor(panel.id, .hover_enter).?);
    try testing.expectEqual(@as(u32, 0), compiled.msgFor(panel.id, .hover_leave).?.toggle);
    try testing.expect(compiled.msgFor(row.id, .hover_leave) == null);
}

// -------------------------------------------------- split panes and trees

const PaneCompiled = canvas.CompiledMarkupView(fixture.PaneModel, fixture.PaneMsg, fixture.pane_markup_source);

test "compiled split and tree match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.PaneModel{};

    var view = try markup_view.MarkupView(fixture.PaneModel, fixture.PaneMsg).init(arena, fixture.pane_markup_source);
    var interpreter_ui = fixture.PaneUi.init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    var compiled_ui = fixture.PaneUi.init(arena);
    const compiled = try compiled_ui.finalize(PaneCompiled.build(&compiled_ui, &model));
    try expectSameTree(fixture.PaneMsg, interpreted, compiled);

    var hand_ui = fixture.PaneUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handPaneView(&hand_ui, &model));
    try expectSameTree(fixture.PaneMsg, hand, compiled);

    // The synthesized divider and the resize dispatch agree across engines.
    try testing.expectEqual(canvas.WidgetKind.split_divider, compiled.root.children[1].kind);
    try testing.expectEqual(@as(f32, 0.7), compiled.msgForResize(compiled.root.id, 0.7).?.sidebar_resized);
    try testing.expectEqual(
        interpreted.msgForResize(interpreted.root.id, 0.7).?.sidebar_resized,
        compiled.msgForResize(compiled.root.id, 0.7).?.sidebar_resized,
    );

    // Tree rows: role, expanded state, and both dispatch channels.
    const row = fixture.findByKind(compiled.root, .panel).?;
    try testing.expectEqual(canvas.WidgetRole.treeitem, row.semantics.role);
    try testing.expectEqual(@as(?bool, true), row.state.expanded);
    try testing.expectEqual(@as(u32, 1), compiled.msgForPointer(row.id, .up).?.select_folder);
    try testing.expectEqual(@as(u32, 1), compiled.msgFor(row.id, .toggle).?.toggle_folder);
}

// --------------------------------- imports, slots, and defaults parity

const ImportCompiled = canvas.CompiledMarkupImports(
    fixture.TemplateModel,
    fixture.TemplateMsg,
    "view.native",
    &fixture.import_view_sources,
);

fn interpretImports(arena: std.mem.Allocator, model: *const fixture.TemplateModel) !TemplateUi.Tree {
    const document = try fixture.resolveImportSet(arena, &fixture.import_view_sources, "view.native");
    var view = TemplateInterpreter.fromDocument(document);
    var ui = TemplateUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileImports(arena: std.mem.Allocator, model: *const fixture.TemplateModel) !TemplateUi.Tree {
    var ui = TemplateUi.init(arena);
    return ui.finalize(ImportCompiled.build(&ui, model));
}

test "compiled imports with slots and defaults match the interpreter and the hand-written view" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.templateTestModel();

    const interpreted = try interpretImports(arena, &model);
    const compiled = try compileImports(arena, &model);
    var hand_ui = TemplateUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handImportView(&hand_ui, &model));

    // Three engines, one tree: the comptime source-set resolution and the
    // runtime set resolution produce the same merged document, and slot
    // content (built in the consumer's scope, spliced at the slot) hashes
    // the same structural ids as hand-written inlining. The fixture
    // covers a transitive import chain, an imported template using
    // another imported template, a defaulted arg omitted inside slot
    // content, and an empty slot.
    try expectSameTree(fixture.TemplateMsg, hand, interpreted);
    try expectSameTree(fixture.TemplateMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Defaulted arg parity down to the interpolated byte.
    try testing.expect(fixture.findByText(compiled.root, .badge, "Top header") != null);
    try testing.expect(fixture.findByText(compiled.root, .badge, "apple muted") != null);
    try testing.expect(fixture.findByText(compiled.root, .badge, "Bottom header") != null);

    // Dispatch parity for a handler declared in slot content: it captured
    // the consumer's loop variable.
    const pear_button = fixture.findByText(compiled.root, .button, "pear").?;
    try testing.expectEqual(
        interpreted.msgForPointer(pear_button.id, .up).?,
        compiled.msgForPointer(pear_button.id, .up).?,
    );
    try testing.expectEqual(@as(u32, 2), compiled.msgForPointer(pear_button.id, .up).?.pick);

    // Rebuild stability: same ids on a second build.
    const rebuilt = try compileImports(arena, &model);
    try testing.expectEqual(pear_button.id, fixture.findByText(rebuilt.root, .button, "pear").?.id);
}

test "compiled slot content follows model changes like the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Slot content iterates model.top at the use site: growing the list
    // grows both engines' trees identically.
    var model = fixture.templateTestModel();
    model.top = &[_]fixture.Fruit{
        .{ .id = 1, .name = "apple" },
        .{ .id = 2, .name = "pear" },
        .{ .id = 9, .name = "quince" },
    };
    const interpreted = try interpretImports(arena, &model);
    const compiled = try compileImports(arena, &model);
    try expectSameTree(fixture.TemplateMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);
    const quince_button = fixture.findByText(compiled.root, .button, "quince").?;
    try testing.expectEqual(@as(u32, 9), compiled.msgForPointer(quince_button.id, .up).?.pick);
}

// ---------------------------------------------------- chart fixture parity

const ChartUi = fixture.ChartUi;
const ChartInterpreter = markup_view.MarkupView(fixture.ChartModel, fixture.ChartMsg);
const ChartCompiled = canvas.CompiledMarkupView(fixture.ChartModel, fixture.ChartMsg, fixture.chart_markup_source);

fn interpretChart(arena: std.mem.Allocator, model: *const fixture.ChartModel) !ChartUi.Tree {
    var view = try ChartInterpreter.init(arena, fixture.chart_markup_source);
    var ui = ChartUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileChart(arena: std.mem.Allocator, model: *const fixture.ChartModel) !ChartUi.Tree {
    var ui = ChartUi.init(arena);
    return ui.finalize(ChartCompiled.build(&ui, model));
}

fn expectSameChartData(expected: canvas.ChartData, actual: canvas.ChartData) !void {
    try testing.expectEqual(expected.y_min, actual.y_min);
    try testing.expectEqual(expected.y_max, actual.y_max);
    try testing.expectEqual(expected.grid_lines, actual.grid_lines);
    try testing.expectEqual(expected.baseline, actual.baseline);
    try testing.expectEqual(expected.y_labels, actual.y_labels);
    try testing.expectEqual(expected.hover_details, actual.hover_details);
    try testing.expectEqual(expected.x_labels.len, actual.x_labels.len);
    for (expected.x_labels, actual.x_labels) |expected_label, actual_label| {
        try testing.expectEqualStrings(expected_label, actual_label);
    }
    try testing.expectEqual(expected.series.len, actual.series.len);
    for (expected.series, actual.series) |expected_series, actual_series| {
        try testing.expectEqual(expected_series.kind, actual_series.kind);
        try testing.expectEqual(expected_series.fill, actual_series.fill);
        try testing.expectEqual(expected_series.color, actual_series.color);
        try testing.expectEqualStrings(expected_series.label, actual_series.label);
        try testing.expectEqual(expected_series.values.len, actual_series.values.len);
        for (expected_series.values, actual_series.values) |expected_value, actual_value| {
            // NaN gaps compare as gaps: both engines pass them through.
            if (std.math.isNan(expected_value)) {
                try testing.expect(std.math.isNan(actual_value));
            } else {
                try testing.expectEqual(expected_value, actual_value);
            }
        }
    }
}

fn firstChartWidget(widget: canvas.Widget) ?canvas.Widget {
    return fixture.findByKind(widget, .chart);
}

test "compiled charts match the interpreter and the hand-written Ui.chart tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.ChartModel{};

    const interpreted = try interpretChart(arena, &model);
    const compiled = try compileChart(arena, &model);
    var hand_ui = ChartUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handChartView(&hand_ui, &model));

    try expectSameTree(fixture.ChartMsg, hand, interpreted);
    try expectSameTree(fixture.ChartMsg, hand, compiled);

    // Chart payload parity: options, series kinds/colors/labels, and the
    // bound data (NaN gaps included) agree across all three engines.
    const interpreted_chart = firstChartWidget(interpreted.root).?;
    const compiled_chart = firstChartWidget(compiled.root).?;
    const hand_chart = firstChartWidget(hand.root).?;
    try expectSameChartData(hand_chart.chart, interpreted_chart.chart);
    try expectSameChartData(hand_chart.chart, compiled_chart.chart);
    try testing.expectEqualStrings(hand_chart.semantics.label, compiled_chart.semantics.label);
    // The chart role derives from the widget KIND at semantics
    // publication (widget_semantics maps .chart kind -> .chart role), so
    // the markup path carries the same accessibility surface as the
    // builder: same kind, same label, same derived role.
    try testing.expectEqual(hand_chart.semantics.role, compiled_chart.semantics.role);
    try testing.expectEqual(canvas.WidgetKind.chart, compiled_chart.kind);
}

const ChartF64Interpreter = markup_view.MarkupView(fixture.ChartF64Model, fixture.ChartMsg);
const ChartF64Compiled = canvas.CompiledMarkupView(fixture.ChartF64Model, fixture.ChartMsg, fixture.chart_f64_markup_source);

test "compiled charts bind f64 series (the transpiled-core float class) identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.ChartF64Model{};

    var view = try ChartF64Interpreter.init(arena, fixture.chart_f64_markup_source);
    var interpreted_ui = ChartUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));
    var compiled_ui = ChartUi.init(arena);
    const compiled = try compiled_ui.finalize(ChartF64Compiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.ChartMsg, interpreted, compiled);
    const interpreted_chart = firstChartWidget(interpreted.root).?;
    const compiled_chart = firstChartWidget(compiled.root).?;
    try expectSameChartData(interpreted_chart.chart, compiled_chart.chart);

    // The narrowing itself: f64 model samples land as exact f32 casts,
    // NaN gaps preserved, in BOTH engines (field and arena-fn sources).
    try testing.expectEqual(@as(f32, 0.25), compiled_chart.chart.series[0].values[0]);
    try testing.expect(std.math.isNan(compiled_chart.chart.series[0].values[1]));
    try testing.expectEqual(@as(f32, 0.125), compiled_chart.chart.series[1].values[0]);
    try testing.expectEqual(@as(f32, 0.5), compiled_chart.chart.series[1].values[3]);
}

// ---------------------------------------------- input-group fixture parity

const ComposerUi = fixture.ComposerUi;
const ComposerInterpreter = markup_view.MarkupView(fixture.ComposerModel, fixture.ComposerMsg);
const ComposerCompiled = canvas.CompiledMarkupView(fixture.ComposerModel, fixture.ComposerMsg, fixture.composer_markup_source);

test "compiled input-groups match the interpreter and the hand-written Ui.inputGroup tree" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var model = fixture.ComposerModel{};
    model.draft_buffer.set("hello");

    var view = try ComposerInterpreter.init(arena, fixture.composer_markup_source);
    var interpreted_ui = ComposerUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = ComposerUi.init(arena);
    const compiled = try compiled_ui.finalize(ComposerCompiled.build(&compiled_ui, &model));

    var hand_ui = ComposerUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handComposerView(&hand_ui, &model));

    try expectSameTree(fixture.ComposerMsg, hand, interpreted);
    try expectSameTree(fixture.ComposerMsg, hand, compiled);

    // Group payload parity: the field chrome treatment (dissolved entry
    // chrome, grow-stretched entry, group semantics) agrees across all
    // three engines.
    const compiled_group = fixture.findByKind(compiled.root, .input_group).?;
    const hand_group = fixture.findByKind(hand.root, .input_group).?;
    try testing.expectEqual(canvas.WidgetKind.input_group, compiled_group.kind);
    try testing.expectEqualStrings(hand_group.semantics.label, compiled_group.semantics.label);
    try testing.expectEqual(hand_group.semantics.role, compiled_group.semantics.role);
    try testing.expectEqual(@as(usize, 2), compiled_group.children.len);
    try testing.expectEqual(@as(f32, 1), compiled_group.children[0].layout.grow);
    try testing.expectEqual(@as(u8, 0), compiled_group.children[0].style.background.?.a);
    try testing.expectEqual(@as(u8, 0), compiled_group.children[0].style.border.?.a);
    try testing.expectEqual(@as(u8, 0), compiled_group.children[0].style.focus_ring.?.a);
    try testing.expectEqualStrings("hello", compiled_group.children[0].text);
}

const chart_template_markup =
    \\<template name="spark" args="data"><chart height="32"><series kind="area" values="{data}" /></chart></template>
    \\<column>
    \\  <use template="spark" data="{latency}" />
    \\</column>
;

const ChartTemplateCompiled = canvas.CompiledMarkupView(fixture.ChartModel, fixture.ChartMsg, chart_template_markup);

test "compiled chart series resolve through slice-valued template args like the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.ChartModel{};

    var view = try ChartInterpreter.init(arena, chart_template_markup);
    var interpreted_ui = ChartUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = ChartUi.init(arena);
    const compiled = try compiled_ui.finalize(ChartTemplateCompiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.ChartMsg, interpreted, compiled);
    const compiled_chart = firstChartWidget(compiled.root).?;
    try expectSameChartData(firstChartWidget(interpreted.root).?.chart, compiled_chart.chart);
    try testing.expectEqual(@as(f32, 12), compiled_chart.chart.series[0].values[0]);
}

// ------------------------------------------------- span paragraph parity

const SpanUi = canvas.Ui(fixture.SpanMsg);
const SpanInterpreter = markup_view.MarkupView(fixture.SpanModel, fixture.SpanMsg);
const SpanCompiled = canvas.CompiledMarkupView(fixture.SpanModel, fixture.SpanMsg, fixture.span_markup_source);

test "compiled span paragraphs build the interpreter's and the hand-written paragraphs exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.SpanModel{};

    var view = try SpanInterpreter.init(arena, fixture.span_markup_source);
    var interpreted_ui = SpanUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = SpanUi.init(arena);
    const compiled = try compiled_ui.finalize(SpanCompiled.build(&compiled_ui, &model));

    var hand_ui = SpanUi.init(arena);
    const hand = try hand_ui.finalize(fixture.handSpanView(&hand_ui, &model));

    // The three engines agree node for node: mixed weight/mono/italic/
    // color runs, bindings inside spans, a bound weight, single-space
    // collapsing, the abutting punctuation run, and the later span
    // additions — scaled (literal and bound) and underlined runs.
    try expectSameTree(fixture.SpanMsg, hand, interpreted);
    try expectSameTree(fixture.SpanMsg, hand, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Span lists agree style for style and byte for byte.
    for (interpreted.root.children, compiled.root.children) |interpreted_child, compiled_child| {
        try testing.expect(canvas.text_spans.textSpansEqual(interpreted_child.spans, compiled_child.spans));
    }
    const compiled_disk = compiled.root.children[0];
    try testing.expectEqualStrings("Disk 182 GB of 512 GB used; run native doctor!", compiled_disk.text);
    try testing.expectEqual(@as(usize, 12), compiled_disk.spans.len);
    try testing.expectEqual(canvas.TextSpanWeight.bold, compiled_disk.spans[2].weight);
    try testing.expect(compiled_disk.spans[10].monospace);

    // The later span additions: the compiled engine lowers the
    // comptime-literal scale, the runtime-bound scale, and the underline
    // decoration to the same channels the interpreter and the
    // hand-written paragraph carry (textSpansEqual above already held
    // the full lists equal — these pins state the interesting values).
    const compiled_title = compiled.root.children[2];
    try testing.expectEqualStrings("182 GB free on 512 GB at native doctor", compiled_title.text);
    try testing.expectEqual(@as(f32, 1.5), compiled_title.spans[0].scale);
    try testing.expect(compiled_title.spans[4].underline);
    try testing.expectEqual(@as(f32, 1.3), compiled_title.spans[8].scale);

    // Accessibility parity pin: one text run, no semantic children —
    // scaled and underlined runs change nothing.
    try testing.expectEqual(@as(usize, 0), compiled_disk.children.len);
    try testing.expectEqual(@as(usize, 0), compiled_title.children.len);
    try testing.expectEqualStrings("Total line", compiled.root.children[1].semantics.label);
}

// ------------------------------------------------ bubble reaction parity

const ReactionsCompiled = canvas.CompiledMarkupView(fixture.SpanModel, fixture.SpanMsg, fixture.reactions_markup_source);

test "compiled reactions lower onto the bubble's chrome-text channel exactly like the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const model = fixture.SpanModel{};

    var view = try SpanInterpreter.init(arena, fixture.reactions_markup_source);
    var interpreted_ui = SpanUi.init(arena);
    const interpreted = try interpreted_ui.finalize(try view.build(&interpreted_ui, &model));

    var compiled_ui = SpanUi.init(arena);
    const compiled = try compiled_ui.finalize(ReactionsCompiled.build(&compiled_ui, &model));

    try expectSameTree(fixture.SpanMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // The pill run lands on widget.text, the reactions child is
    // consumed, and the dock literal resolves at comptime: end without
    // an attribute, start when declared. Interpolation in the run
    // resolves at runtime like any text.
    const received = compiled.root.children[0];
    try testing.expectEqualStrings("+2", received.text);
    try testing.expectEqual(canvas.TextAlign.end, received.text_alignment);
    try testing.expectEqual(@as(usize, 1), received.children.len);
    const sent = compiled.root.children[1];
    try testing.expectEqualStrings("182 GB +1", sent.text);
    try testing.expectEqual(canvas.TextAlign.start, sent.text_alignment);
    try testing.expectEqual(@as(usize, 0), compiled.root.children[2].text.len);
}

// ------------------------------------------- committed-model (pointer) shape

const Track = struct {
    id: i64,
    title: []const u8,
    plays: f64,
    starred: bool,
};

const LibraryMeta = struct {
    name: []const u8,
    track_total: i64,
};

const LibraryMsg = union(enum) {
    open_track: i64,
    star_track: i64,
    refresh,
};

/// The committed-model shape transpiled cores emit: record arrays are
/// slices of shared `*const` nodes and nested records are `*const`
/// fields. `reflect.Pointee` makes both bind exactly like their by-value
/// counterparts.
const LibraryModel = struct {
    meta: *const LibraryMeta,
    tracks: []const *const Track,
    selected: ?i64 = null,
};

const library_markup =
    \\<column gap="4">
    \\  <text>{meta.name} holds {meta.track_total}</text>
    \\  <if test="{selected}">
    \\    <text>picked</text>
    \\  </if>
    \\  <for each="tracks" as="t" key="id">
    \\    <row key="{t.id}" gap="2" cross="center">
    \\      <text grow="1">{t.title} ({t.plays})</text>
    \\      <if test="{t.starred}">
    \\        <badge>starred</badge>
    \\      </if>
    \\      <button size="sm" on-press="open_track:{t.id}">Open</button>
    \\    </row>
    \\  </for>
    \\  <else>
    \\    <text>empty library</text>
    \\  </else>
    \\</column>
;

const LibraryUi = canvas.Ui(LibraryMsg);
const LibraryInterpreter = markup_view.MarkupView(LibraryModel, LibraryMsg);
const LibraryCompiled = canvas.CompiledMarkupView(LibraryModel, LibraryMsg, library_markup);

fn interpretLibrary(arena: std.mem.Allocator, model: *const LibraryModel) !LibraryUi.Tree {
    var view = try LibraryInterpreter.init(arena, library_markup);
    var ui = LibraryUi.init(arena);
    return ui.finalize(try view.build(&ui, model));
}

fn compileLibrary(arena: std.mem.Allocator, model: *const LibraryModel) !LibraryUi.Tree {
    var ui = LibraryUi.init(arena);
    return ui.finalize(LibraryCompiled.build(&ui, model));
}

test "compiled pointer-item lists and pointer-record paths match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = LibraryMeta{ .name = "field notes", .track_total = 2 };
    const first = Track{ .id = 7, .title = "one", .plays = 3.5, .starred = false };
    const second = Track{ .id = 9, .title = "two", .plays = 12, .starred = true };
    const tracks = [_]*const Track{ &first, &second };
    var model = LibraryModel{ .meta = &meta, .tracks = &tracks };

    const interpreted = try interpretLibrary(arena, &model);
    const compiled = try compileLibrary(arena, &model);
    try expectSameTree(LibraryMsg, interpreted, compiled);
    try expectSameTexts(interpreted.root, compiled.root);

    // Dotted paths through the `*const` record field interpolate its
    // fields; pointer items bind their struct's fields, floats included.
    try testing.expect(findText(compiled.root, "field notes holds 2") != null);
    try testing.expect(findText(compiled.root, "one (3.5)") != null);
    try testing.expect(findText(compiled.root, "two (12)") != null);
    try testing.expect(findText(compiled.root, "starred") != null);
    try testing.expect(findText(compiled.root, "picked") == null);
    try testing.expect(findText(compiled.root, "empty library") == null);

    // Message payloads built from pointer items dispatch identically.
    const open_button = fixture.findByKind(compiled.root, .button).?;
    try testing.expectEqual(
        interpreted.msgForPointer(open_button.id, .up).?,
        compiled.msgForPointer(open_button.id, .up).?,
    );
    try testing.expectEqual(@as(i64, 7), compiled.msgForPointer(open_button.id, .up).?.open_track);

    // The optional scalar flips the gate at runtime, like every optional.
    model.selected = 9;
    const picked = try compileLibrary(arena, &model);
    try testing.expect(findText(picked.root, "picked") != null);

    // An empty pointer list renders the for-else branch.
    model.tracks = &.{};
    const emptied_interpreted = try interpretLibrary(arena, &model);
    const emptied_compiled = try compileLibrary(arena, &model);
    try expectSameTree(LibraryMsg, emptied_interpreted, emptied_compiled);
    try testing.expect(findText(emptied_compiled.root, "empty library") != null);
}

test "the compiled engine binds on-input to a declared mirror union in parity with the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<column>
        \\  <text-field text="{draft}" label="Draft" on-input="edit" on-submit="submit" />
        \\</column>
    ;
    const model = fixture.MirrorModel{ .draft = "hi" };

    const Compiled = canvas.CompiledMarkupView(fixture.MirrorModel, fixture.MirrorMsg, source);
    var compiled_ui = canvas.Ui(fixture.MirrorMsg).init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try markup_view.MarkupView(fixture.MirrorModel, fixture.MirrorMsg).init(arena, source);
    var interpreter_ui = canvas.Ui(fixture.MirrorMsg).init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));

    const field = fixture.findByKind(compiled.root, .text_field).?;
    try testing.expectEqual(fixture.findByKind(interpreted.root, .text_field).?.id, field.id);

    // Both engines translate the runtime event into the DECLARED union.
    const compiled_insert = compiled.msgForTextEdit(field.id, .{ .insert_text = "abc" }).?;
    const interpreted_insert = interpreted.msgForTextEdit(field.id, .{ .insert_text = "abc" }).?;
    try testing.expectEqualStrings("abc", compiled_insert.edit.insert_text);
    try testing.expectEqualStrings("abc", interpreted_insert.edit.insert_text);
    const compiled_move = compiled.msgForTextEdit(field.id, .{ .move_caret = .{ .direction = .end, .extend = false } }).?;
    try testing.expectEqual(fixture.MirrorCaretDirection.end, compiled_move.edit.move_caret.direction);
    try testing.expectEqual(
        interpreted.msgForTextEdit(field.id, .delete_backward).?,
        compiled.msgForTextEdit(field.id, .delete_backward).?,
    );
}

// ---------------------------- declared scroll-state + value arms (parity)

test "compiled on-scroll binds a declared scroll-state mirror identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<scroll value="{scroll_top}" on-scroll="library_scrolled">
        \\  <text>rows</text>
        \\</scroll>
    ;
    const model = fixture.MirrorControlsModel{};

    const Compiled = canvas.CompiledMarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg, source);
    var compiled_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try markup_view.MarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg).init(arena, source);
    var interpreter_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    try expectSameTree(fixture.MirrorControlsMsg, interpreted, compiled);

    // Both engines translate the runtime state into the DECLARED record:
    // float fields widen exactly, integer-classed fields round.
    const region = fixture.findByKind(compiled.root, .scroll_view).?;
    const state = canvas.ScrollState{ .offset_x = 12.5, .offset_y = 41.5, .velocity_y = -3.25, .viewport_extent_x = 320.2, .viewport_extent_y = 480.4, .content_extent_x = 960.7, .content_extent_y = 2000.6 };
    const compiled_msg = compiled.msgForScroll(region.id, state).?;
    try testing.expectEqual(@as(f64, 41.5), compiled_msg.library_scrolled.offsetY);
    try testing.expectEqual(@as(f64, 12.5), compiled_msg.library_scrolled.offsetX);
    try testing.expectEqual(@as(i64, 480), compiled_msg.library_scrolled.viewportExtentY);
    try testing.expectEqual(@as(i64, 2001), compiled_msg.library_scrolled.contentExtentY);
    try testing.expectEqual(@as(i64, 961), compiled_msg.library_scrolled.contentExtentX);
    try testing.expectEqual(
        interpreted.msgForScroll(region.id, state).?,
        compiled.msgForScroll(region.id, state).?,
    );
}

test "compiled slider on-change value arms match the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<column>
        \\  <slider value="{seek_fraction}" label="Seek" on-change="scrubbed" />
        \\  <slider value="{volume}" label="Volume" on-change="set_volume" />
        \\  <slider value="{volume}" label="Nudge" on-change="nudged" />
        \\</column>
    ;
    const model = fixture.MirrorControlsModel{};

    const Compiled = canvas.CompiledMarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg, source);
    var compiled_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try markup_view.MarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg).init(arena, source);
    var interpreter_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    try expectSameTree(fixture.MirrorControlsMsg, interpreted, compiled);

    const seek = fixture.findByKind(compiled.root, .slider).?;
    // The transpiled f64 arm carries the applied fraction widened exactly,
    // through both engines' handler tables.
    try testing.expectEqual(@as(f64, 0.25), compiled.msgForChange(seek.id, 0.25).?.scrubbed);
    try testing.expectEqual(
        interpreted.msgForChange(seek.id, 0.25).?,
        compiled.msgForChange(seek.id, 0.25).?,
    );
}

test "compiled split on-resize binds a declared float arm identically to the interpreter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<split value="{seek_fraction}" on-resize="scrubbed">
        \\  <column><text>left</text></column>
        \\  <column><text>right</text></column>
        \\</split>
    ;
    const model = fixture.MirrorControlsModel{};

    const Compiled = canvas.CompiledMarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg, source);
    var compiled_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const compiled = try compiled_ui.finalize(Compiled.build(&compiled_ui, &model));

    var view = try markup_view.MarkupView(fixture.MirrorControlsModel, fixture.MirrorControlsMsg).init(arena, source);
    var interpreter_ui = canvas.Ui(fixture.MirrorControlsMsg).init(arena);
    const interpreted = try interpreter_ui.finalize(try view.build(&interpreter_ui, &model));
    try expectSameTree(fixture.MirrorControlsMsg, interpreted, compiled);

    try testing.expectEqual(
        interpreted.msgForResize(interpreted.root.id, 0.25).?,
        compiled.msgForResize(compiled.root.id, 0.25).?,
    );
}
