//! Contract-check conformance and fixtures.
//!
//! The dual-checker drift risk is handled the way the dual engines handle
//! it: one fixture set drives BOTH the contract checker (what
//! `native check` runs against the emitted artifact) and the runtime
//! interpreter (whose accept/reject set the compiled engine already
//! matches through the parity suite in ui_markup_compiled_tests.zig), and
//! every fixture must land on the same side with the same message. A
//! contract check passing what an app build rejects — or vice versa —
//! fails here first.
//!
//! Fixture rejects are REACHABLE under the test model on purpose: the
//! interpreter only diagnoses branches it builds, while the contract
//! checker (like the compiled engine) is total over the document.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const contract = @import("ui_markup_contract.zig");
const markup_view = @import("ui_markup_view.zig");

const testing = std.testing;

// ------------------------------------------------------------- fixtures

const Priority = enum { low, high };

const Card = struct {
    id: u32,
    done: bool = false,
    weight: f32 = 1,
    label_storage: [16]u8 = [_]u8{0} ** 16,
    label_len: usize = 0,

    pub fn label(card: *const Card) []const u8 {
        return card.label_storage[0..card.label_len];
    }

    pub fn badge(card: *const Card, arena: std.mem.Allocator) []const u8 {
        return std.fmt.allocPrint(arena, "#{d}", .{card.id}) catch "";
    }
};

const Profile = struct {
    name: []const u8 = "sam",
    age: u32 = 30,
};

/// The transpiled-core mirror of `canvas.ScrollState` (field names pinned
/// by the reflect drift test below; classes per field).
const MirrorScroll = struct {
    offset_x: f64,
    offset_y: f64,
    velocity_x: f64,
    velocity_y: f64,
    viewport_extent_x: f64,
    viewport_extent_y: f64,
    content_extent_x: f64,
    content_extent_y: f64,
};

/// The RETIRED one-axis mirror: classifies as `legacy_scroll_state` so
/// the on-scroll checker teaches the per-axis migration by name.
const LegacyMirrorScroll = struct {
    offset: f64,
    velocity: f64,
    viewport_extent: f64,
    content_extent: f64,
};

const Msg = union(enum) {
    add,
    remove: u32,
    rename: []const u8,
    set_priority: Priority,
    scale: f32,
    draft: canvas.TextInputEvent,
    scrolled: canvas.ScrollState,
    mirror_scrolled: MirrorScroll,
    legacy_scrolled: LegacyMirrorScroll,
    pane: f32,
    pane_wide: f64,
    tick,
};

const Model = struct {
    count: usize = 2,
    name: []const u8 = "board",
    ratio: f32 = 0.5,
    active: bool = true,
    priority: Priority = .low,
    profile: Profile = .{},
    cards: [2]Card = .{ .{ .id = 1 }, .{ .id = 2 } },
    hidden: u8 = 0,
    history: [4]f32 = .{ 0.1, 0.4, 0.2, 0.8 },
    samples: [3]f64 = .{ 0.25, 0.5, 1 },
    stages: [4][]const u8 = .{ "one", "two", "three", "four" },
    draft_buffer: canvas.TextBuffer(16) = .{},

    pub fn total(model: *const Model) i64 {
        return @intCast(model.count);
    }

    pub fn upper_name(model: *const Model, arena: std.mem.Allocator) []const u8 {
        const out = arena.dupe(u8, model.name) catch return "";
        _ = std.ascii.upperString(out, model.name);
        return out;
    }

    pub fn visible(model: *const Model, arena: std.mem.Allocator) []const Card {
        return arena.dupe(Card, &model.cards) catch &.{};
    }
};

const specials = contract.Specials{
    .TextInputEvent = canvas.TextInputEvent,
    .ScrollState = canvas.ScrollState,
    .TerminalState = canvas.TerminalState,
};

const model_contract = contract.describe(Model, Msg, specials);

const FixtureUi = canvas.Ui(Msg);
const FixtureView = markup_view.MarkupView(Model, Msg);

/// Build one source through the interpreter against the fixture model;
/// null = accepted, otherwise the build diagnostic's message.
fn interpreterMessage(arena: std.mem.Allocator, document: markup.MarkupDocument) !?[]const u8 {
    var view = FixtureView.fromDocument(document);
    var ui = FixtureUi.init(arena);
    const model = Model{};
    _ = view.build(&ui, &model) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MarkupBuild => return view.diagnostic.message,
    };
    return null;
}

fn contractMessage(arena: std.mem.Allocator, document: markup.MarkupDocument, usage: ?*contract.Usage) !?[]const u8 {
    const info = try contract.checkDocument(arena, document, &model_contract, usage);
    if (info) |found| return found.message;
    return null;
}

fn parseFixture(arena: std.mem.Allocator, source: []const u8) !markup.MarkupDocument {
    var parser = markup.Parser.init(arena, source);
    const document = try parser.parse();
    // The contract check runs after structural validation everywhere it
    // is wired; fixtures must be structurally clean so the two checkers
    // are compared on contract ground only.
    if (markup.validate(document)) |info| {
        std.debug.print("fixture failed structural validation: {s} at {d}:{d}\n", .{ info.message, info.line, info.column });
        return error.FixtureInvalid;
    }
    return document;
}

const Fixture = struct {
    name: []const u8,
    source: []const u8,
    /// Null = both checkers must accept; otherwise both must reject and
    /// the interpreter's message must equal this while the contract
    /// checker's message must start with it (the contract checker appends
    /// the token/type teaching suffix).
    expect: ?[]const u8,
};

const fixtures = [_]Fixture{
    .{
        .name = "the full surface accepts",
        .source =
        \\<column gap="{count}" padding="16">
        \\  <text-field placeholder="{name}" on-input="draft" on-submit="add" />
        \\  <text>{upper_name} has {count + 1} cards ({percent(ratio, 0)})</text>
        \\  <text>{profile.name} is {profile.age}</text>
        \\  <badge>{total}</badge>
        \\  <if test="{active}">
        \\    <button on-press="set_priority:{priority}">go</button>
        \\  </if>
        \\  <for each="cards" key="id" as="c">
        \\    <row>
        \\      <checkbox checked="{c.done}" on-toggle="remove:{c.id}" label="Done" />
        \\      <text>{c.label} {c.badge}</text>
        \\      <slider value="{c.weight}" on-change="scale:{c.weight}" label="Weight" />
        \\    </row>
        \\  </for>
        \\  <for each="visible" as="v">
        \\    <text>{v.label}</text>
        \\  </for>
        \\  <else>
        \\    <text>empty</text>
        \\  </else>
        \\  <scroll on-scroll="scrolled">
        \\    <column><text>body</text></column>
        \\  </scroll>
        \\  <split on-resize="pane">
        \\    <panel><text>a</text></panel>
        \\    <panel><text>b</text></panel>
        \\  </split>
        \\  <button on-press="rename:{name}">rename</button>
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "digit-only text attributes remain text",
        .source =
        \\<column padding="8">
        \\  <text-field placeholder="123" label="456" />
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a missing model field rejects",
        .source =
        \\<column>
        \\  <text>{missing}</text>
        \\</column>
        ,
        .expect = "binding does not name a model field",
    },
    .{
        // Bindings inside inline spans are ordinary rendered text: the
        // walk reaches the span's run and its attribute expressions like
        // any element's.
        .name = "span paragraphs with bindings inside spans accept",
        .source =
        \\<column>
        \\  <text><span weight="bold">{name}</span> holds <span mono="{active}">{count}</span> cards</text>
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a missing binding inside a span rejects",
        .source =
        \\<column>
        \\  <text>value <span weight="bold">{missing}</span></text>
        \\</column>
        ,
        .expect = "binding does not name a model field",
    },
    .{
        // A span's scale binding is a number channel: float and integer
        // model values both multiply the base size; underline resolves
        // truthy like the other flags.
        .name = "span scale and underline bindings accept numbers and flags",
        .source =
        \\<column>
        \\  <text><span scale="{ratio}">{name}</span> of <span scale="{count}" underline="{active}">{count}</span></text>
        \\</column>
        ,
        .expect = null,
    },
    .{
        // A name cannot multiply a size: the contract holds scale
        // bindings to numbers with the same teaching message the engines
        // fail with.
        .name = "a string-valued span scale binding rejects",
        .source =
        \\<column>
        \\  <text><span scale="{name}">x</span> y</text>
        \\</column>
        ,
        .expect = markup.span_scale_value_message,
    },
    .{
        // The buffer is the edit model, not the text: both checkers
        // teach the pub fn accessor shape with the SAME message (the
        // shared constant pins the vocabularies together, like
        // binding_model_message).
        .name = "binding a TextBuffer field directly rejects with the edit-model teaching",
        .source =
        \\<column>
        \\  <text>{draft_buffer}</text>
        \\</column>
        ,
        .expect = markup.binding_text_buffer_message,
    },
    .{
        .name = "a missing loop item field rejects",
        .source =
        \\<column>
        \\  <for each="cards" as="c">
        \\    <text>{c.nope}</text>
        \\  </for>
        \\</column>
        ,
        .expect = "binding does not name a field on the loop item",
    },
    .{
        .name = "an orphan message tag rejects",
        .source =
        \\<column>
        \\  <button on-press="nope">x</button>
        \\</column>
        ,
        .expect = "unknown message tag",
    },
    .{
        .name = "a payload on a void tag rejects",
        .source =
        \\<column>
        \\  <button on-press="add:{count}">x</button>
        \\</column>
        ,
        .expect = "message does not take a payload",
    },
    .{
        .name = "a missing payload rejects",
        .source =
        \\<column>
        \\  <button on-press="remove">x</button>
        \\</column>
        ,
        .expect = "message requires a payload",
    },
    .{
        .name = "a wrong-typed payload rejects",
        .source =
        \\<column>
        \\  <button on-press="remove:{name}">x</button>
        \\</column>
        ,
        .expect = "payload type does not match the message",
    },
    .{
        .name = "an unknown iterable rejects",
        .source =
        \\<column>
        \\  <for each="nope" as="c">
        \\    <text>x</text>
        \\  </for>
        \\</column>
        ,
        .expect = "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)",
    },
    .{
        .name = "a scalar named as an iterable rejects",
        .source =
        \\<column>
        \\  <for each="count" as="c">
        \\    <text>x</text>
        \\  </for>
        \\</column>
        ,
        .expect = "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)",
    },
    .{
        .name = "a missing key field rejects",
        .source =
        \\<column>
        \\  <for each="cards" key="nope" as="c">
        \\    <text>{c.label}</text>
        \\  </for>
        \\</column>
        ,
        .expect = "key does not name a field on the item",
    },
    .{
        .name = "ordering a string binding rejects with the model type named",
        .source =
        \\<column>
        \\  <text>{name > 3}</text>
        \\</column>
        ,
        .expect = markup.expr.ordering_type_message,
    },
    .{
        .name = "a string binding in a number attribute rejects",
        .source =
        \\<column>
        \\  <row width="{name}"><text>x</text></row>
        \\</column>
        ,
        .expect = "expected a number",
    },
    .{
        // The value-payload change event: a slider's bare on-change tag
        // naming an f32 arm dispatches the applied fraction.
        .name = "a slider on-change value arm (f32) accepts",
        .source =
        \\<slider value="{ratio}" on-change="scale" label="Weight" />
        ,
        .expect = null,
    },
    .{
        // The transpiled one-number float arm matches structurally.
        .name = "a slider on-change value arm (f64) accepts",
        .source =
        \\<slider value="{ratio}" on-change="pane_wide" label="Weight" />
        ,
        .expect = null,
    },
    .{
        // A non-value payload arm keeps the static-form contract: a bare
        // tag with a payload the value event cannot fill is the ordinary
        // missing-payload teaching.
        .name = "a slider on-change naming a non-value payload arm rejects",
        .source =
        \\<slider value="{ratio}" on-change="remove" label="Weight" />
        ,
        .expect = "message requires a payload",
    },
    .{
        // The declared scroll-state mirror binds on-scroll like the canvas
        // type (transpiled cores).
        .name = "a declared scroll-state mirror arm accepts on-scroll",
        .source =
        \\<scroll on-scroll="mirror_scrolled">
        \\  <column><text>body</text></column>
        \\</scroll>
        ,
        .expect = null,
    },
    .{
        .name = "an on-scroll tag without a scroll-state payload rejects",
        .source =
        \\<scroll on-scroll="pane">
        \\  <column><text>body</text></column>
        \\</scroll>
        ,
        .expect = markup.on_scroll_payload_message,
    },
    .{
        // The RETIRED one-axis record gets the migration teaching that
        // names the new per-axis fields, not the generic rejection.
        .name = "an on-scroll tag carrying the retired one-axis record teaches the two-axis migration",
        .source =
        \\<scroll on-scroll="legacy_scrolled">
        \\  <column><text>body</text></column>
        \\</scroll>
        ,
        .expect = markup.on_scroll_legacy_payload_message,
    },
    .{
        // The transpiled one-number float arm carries the split fraction.
        .name = "a split on-resize f64 arm accepts",
        .source =
        \\<split value="{ratio}" on-resize="pane_wide">
        \\  <panel><text>a</text></panel>
        \\  <panel><text>b</text></panel>
        \\</split>
        ,
        .expect = null,
    },
    .{
        .name = "a whole-number binding in resize-duration accepts",
        .source =
        \\<split value="{ratio}" resize-duration="{count}" resize-easing="standard" on-resize="pane">
        \\  <panel><text>a</text></panel>
        \\  <panel><text>b</text></panel>
        \\</split>
        ,
        .expect = null,
    },
    .{
        .name = "a string binding in resize-duration rejects like any whole-class attribute",
        .source =
        \\<split value="{ratio}" resize-duration="{name}" on-resize="pane">
        \\  <panel><text>a</text></panel>
        \\  <panel><text>b</text></panel>
        \\</split>
        ,
        .expect = "expected a whole number",
    },
    .{
        .name = "an arena-computed binding in equality rejects",
        .source =
        \\<column>
        \\  <button selected="{upper_name == name}">x</button>
        \\</column>
        ,
        .expect = markup.arena_scalar_equality_message,
    },
    .{
        .name = "on-input on a non-TextInputEvent tag rejects",
        .source =
        \\<column>
        \\  <text-field label="Title" on-input="add" />
        \\</column>
        ,
        .expect = "on-input tag must carry a TextInputEvent payload",
    },
    .{
        .name = "a template arg type mismatch rejects at the use site's kind",
        .source =
        \\<template name="pane" args="w">
        \\  <column width="{w}">
        \\    <text>pane</text>
        \\  </column>
        \\</template>
        \\<column>
        \\  <use template="pane" w="{name}" />
        \\</column>
        ,
        .expect = "expected a number",
    },
    .{
        .name = "a template arg carrying the right kind accepts",
        .source =
        \\<template name="pane" args="w label trend=flat">
        \\  <column width="{w}">
        \\    <text>{label} {trend}</text>
        \\    <slot/>
        \\  </column>
        \\</template>
        \\<column>
        \\  <for each="cards" as="c">
        \\    <use template="pane" w="{c.weight}" label="{c.label}">
        \\      <text>{c.badge}</text>
        \\    </use>
        \\  </for>
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a slice template arg iterates in the body and re-passes",
        .source =
        \\<template name="lane" args="items">
        \\  <column>
        \\    <for each="items" as="entry">
        \\      <text>{entry.label}</text>
        \\    </for>
        \\  </column>
        \\</template>
        \\<template name="board" args="items">
        \\  <row>
        \\    <use template="lane" items="{items}" />
        \\  </row>
        \\</template>
        \\<column>
        \\  <use template="board" items="{cards}" />
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a slice template arg used as a value rejects",
        .source =
        \\<template name="lane" args="items">
        \\  <column>
        \\    <text>{items}</text>
        \\  </column>
        \\</template>
        \\<column>
        \\  <use template="lane" items="{cards}" />
        \\</column>
        ,
        .expect = "slice-valued template args are only usable with for each",
    },
    .{
        .name = "a value template arg with a field path rejects",
        .source =
        \\<template name="chip" args="title">
        \\  <badge>{title.length}</badge>
        \\</template>
        \\<column>
        \\  <use template="chip" title="{name}" />
        \\</column>
        ,
        .expect = "template arg values have no fields",
    },
    .{
        .name = "a chart with f32 series bindings accepts",
        .source =
        \\<column>
        \\  <chart y-min="0" y-max="{ratio}" grid-lines="2" baseline="true" label="History">
        \\    <series kind="area" values="{history}" color="accent" label="load" />
        \\  </chart>
        \\</column>
        ,
        .expect = null,
    },
    .{
        // f64 is the transpiled-core float class: TS number arrays emit
        // as []const f64 and both engines narrow them per sample.
        .name = "a chart with f64 series bindings (the transpiled-core float class) accepts",
        .source =
        \\<column>
        \\  <chart y-min="0" y-max="1" label="Window">
        \\    <series kind="bar" values="{samples}" />
        \\  </chart>
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a series values binding to a non-f32 iterable rejects",
        .source =
        \\<column>
        \\  <chart>
        \\    <series values="{cards}" />
        \\  </chart>
        \\</column>
        ,
        .expect = markup.series_values_message,
    },
    .{
        .name = "a series values binding to a scalar rejects",
        .source =
        \\<column>
        \\  <chart>
        \\    <series values="{ratio}" />
        \\  </chart>
        \\</column>
        ,
        .expect = markup.series_values_message,
    },
    .{
        .name = "a chart y bound that is not a number rejects",
        .source =
        \\<column>
        \\  <chart y-min="{name}">
        \\    <series values="{history}" />
        \\  </chart>
        \\</column>
        ,
        .expect = "expected a number",
    },
    .{
        .name = "a chart with string x-labels, y-labels, and hover-details accepts",
        .source =
        \\<column>
        \\  <chart x-labels="{stages}" y-labels="true" hover-details="{active}">
        \\    <series values="{history}" />
        \\  </chart>
        \\</column>
        ,
        .expect = null,
    },
    .{
        .name = "a chart x-labels binding to a non-string iterable rejects",
        .source =
        \\<column>
        \\  <chart x-labels="{history}">
        \\    <series values="{history}" />
        \\  </chart>
        \\</column>
        ,
        .expect = markup.chart_x_labels_message,
    },
};

test "the contract checker and the interpreter accept and reject identically" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (fixtures) |fixture| {
        const document = parseFixture(arena, fixture.source) catch |err| {
            std.debug.print("fixture: {s}\n", .{fixture.name});
            return err;
        };
        const from_interpreter = try interpreterMessage(arena, document);
        const from_contract = try contractMessage(arena, document, null);
        if (fixture.expect) |expected| {
            const interpreter_found = from_interpreter orelse {
                std.debug.print("fixture accepted by the interpreter but expected: {s} ({s})\n", .{ expected, fixture.name });
                return error.TestExpectedError;
            };
            const contract_found = from_contract orelse {
                std.debug.print("fixture accepted by the contract check but expected: {s} ({s})\n", .{ expected, fixture.name });
                return error.TestExpectedError;
            };
            try testing.expectEqualStrings(expected, interpreter_found);
            if (!std.mem.startsWith(u8, contract_found, expected)) {
                std.debug.print("contract message drifted ({s}):\n  expected prefix: {s}\n  got: {s}\n", .{ fixture.name, expected, contract_found });
                return error.TestExpectedError;
            }
        } else {
            if (from_interpreter) |message| {
                std.debug.print("interpreter rejected an accept fixture ({s}): {s}\n", .{ fixture.name, message });
                return error.TestUnexpectedError;
            }
            if (from_contract) |message| {
                std.debug.print("contract check rejected an accept fixture ({s}): {s}\n", .{ fixture.name, message });
                return error.TestUnexpectedError;
            }
        }
    }
}

test "the contract check is total where the interpreter is lazy" {
    // A bad binding inside an if branch the model never takes: the
    // interpreter cannot see it (it only diagnoses what it builds), while
    // the contract check — like the compiled engine, which fails this at
    // comptime — rejects it. This asymmetry is the point of check time.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\<column>
        \\  <if test="{active}">
        \\    <text>fine</text>
        \\  </if>
        \\  <else>
        \\    <text>{missing}</text>
        \\  </else>
        \\</column>
    ;
    const document = try parseFixture(arena, source);
    try testing.expectEqual(null, try interpreterMessage(arena, document));
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expect(std.mem.startsWith(u8, message, contract.binding_model_message));
}

test "the TextBuffer teaching message is byte-identical between checker and interpreter" {
    // The conformance fixture pins the interpreter to the shared
    // constant and the checker to its prefix; this pins the checker to
    // the WHOLE message (no token suffix - the field is named in the
    // teaching text itself).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<column>
        \\  <text>{draft_buffer}</text>
        \\</column>
    );
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expectEqualStrings(markup.binding_text_buffer_message, message);
}

test "unknown names get a did-you-mean over the model's actual vocabulary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<column>
        \\  <text>{cout}</text>
        \\</column>
    );
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expect(std.mem.indexOf(u8, message, "did you mean \"count\"?") != null);
}

test "expression type errors name the model field and its Zig type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<column>
        \\  <text>{name > 3}</text>
        \\</column>
    );
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expect(std.mem.indexOf(u8, message, "name: []const u8") != null);
}

test "the media-surface surface binding checks as a model integer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An integer-producing binding passes — the exact grammar `native
    // check`'s model-aware pass applies to TS and Zig cores alike.
    const good = try parseFixture(arena,
        \\<column>
        \\  <media-surface surface="{count}" label="Preview" />
        \\</column>
    );
    try testing.expectEqual(null, try contractMessage(arena, good, null));

    // A non-integer binding is refused with the surface teaching.
    const wrong = try parseFixture(arena,
        \\<column>
        \\  <media-surface surface="{name}" label="Preview" />
        \\</column>
    );
    const message = (try contractMessage(arena, wrong, null)).?;
    try testing.expectEqualStrings(markup.media_surface_surface_message, message);
}

test "the image leaf's image binding checks as a model integer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // An integer-producing binding passes on avatar and the image leaf
    // alike — the exact grammar `native check`'s model-aware pass
    // applies to TS and Zig cores.
    const good = try parseFixture(arena,
        \\<column>
        \\  <image image="{count}" label="Cover art" />
        \\  <avatar image="{count}">CT</avatar>
        \\</column>
    );
    try testing.expectEqual(null, try contractMessage(arena, good, null));

    // A non-integer binding is refused with the image teaching.
    const wrong = try parseFixture(arena,
        \\<column>
        \\  <image image="{name}" label="Cover art" />
        \\</column>
    );
    const message = (try contractMessage(arena, wrong, null)).?;
    try testing.expectEqualStrings(markup.image_binding_message, message);
}

test "registered-image source rectangle bindings check as numbers" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const good = try parseFixture(arena,
        \\<column>
        \\  <image image="{count}" source-x="{ratio}" source-y="{count}" source-width="32" source-height="16" label="Atlas tile" />
        \\</column>
    );
    try testing.expectEqual(null, try contractMessage(arena, good, null));

    const wrong = try parseFixture(arena,
        \\<column>
        \\  <image image="{count}" source-x="{name}" source-y="0" source-width="32" source-height="16" label="Atlas tile" />
        \\</column>
    );
    const message = (try contractMessage(arena, wrong, null)).?;
    try testing.expect(std.mem.startsWith(u8, message, "expected a number"));
}

test "app: icon references check against the contract's registered icon list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var with_icons = model_contract;
    with_icons.app_icons = &.{ "wave", "wave-pulse" };

    // Registered app: references and string-producing bindings pass, on
    // both the icon leaf and the inline attribute.
    const good = try parseFixture(arena,
        \\<row>
        \\  <icon name="app:wave" />
        \\  <button icon="app:wave-pulse" on-press="add">Pulse</button>
        \\  <button icon="{name}" on-press="add">Bound</button>
        \\</row>
    );
    try testing.expectEqual(null, try contract.checkDocument(arena, good, &with_icons, null));

    // An unknown app name fails with a did-you-mean over the REGISTERED
    // list - the vocabulary only the contract can see.
    const unknown = try parseFixture(arena,
        \\<row>
        \\  <icon name="app:wavee" />
        \\</row>
    );
    const unknown_message = (try contract.checkDocument(arena, unknown, &with_icons, null)).?.message;
    try testing.expect(std.mem.startsWith(u8, unknown_message, contract.unknown_app_icon_message));
    try testing.expect(std.mem.indexOf(u8, unknown_message, "did you mean \"wave\"?") != null);

    // An app that registers nothing gets the registration lesson, not a
    // bare unknown-name miss.
    const no_icons_message = (try contract.checkDocument(arena, unknown, &model_contract, null)).?.message;
    try testing.expectEqualStrings(contract.no_app_icons_message, no_icons_message);

    // Icon bindings are names: a non-string binding is a kind error.
    const wrong_kind = try parseFixture(arena,
        \\<row>
        \\  <button icon="{count}" on-press="add">N</button>
        \\</row>
    );
    const kind_message = (try contract.checkDocument(arena, wrong_kind, &with_icons, null)).?.message;
    try testing.expectEqualStrings(contract.icon_binding_kind_message, kind_message);

    // The markup-side prefix and the contract's std-only mirror cannot
    // drift.
    try testing.expectEqualStrings(markup.app_icon_prefix, contract.app_icon_prefix);
}

test "segmented-control bindings and messages check through the model contract" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<row>
        \\  <segmented-control selected="{active}" icon="settings" on-press="add">Settings</segmented-control>
        \\</row>
    );
    var usage = try contract.Usage.init(arena, &model_contract);
    try testing.expectEqual(null, try contract.checkDocument(arena, document, &model_contract, &usage));
}

test "the contract checker validates a forwarded template-root press" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseFixture(arena,
        \\<template name="item" args="title">
        \\  <timeline-item title="{title}" />
        \\</template>
        \\<row>
        \\  <use template="item" title="Build" on-press="remove:{profile.age}" />
        \\</row>
    );
    try testing.expectEqual(null, try contract.checkDocument(arena, document, &model_contract, null));
}
test "the contract checker validates stepper slot content in the consumer scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<template name="stepper" args="active">
        \\  <stepper active="{active}">
        \\    <slot/>
        \\  </stepper>
        \\</template>
        \\<row>
        \\  <use template="stepper" active="{count}">
        \\    <step>{missing}</step>
        \\  </use>
        \\</row>
    );
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expect(std.mem.startsWith(u8, message, contract.binding_model_message));
}

// ------------------------------------------------------------ dead state

test "dead state warns on unbound model state and undispatched Msg tags" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena, fixtures[0].source);
    var usage = try contract.Usage.init(arena, &model_contract);
    try testing.expectEqual(null, try contractMessage(arena, document, &usage));

    const warnings = try contract.deadState(arena, &model_contract, &usage);
    var saw_hidden = false;
    var saw_tick = false;
    for (warnings) |warning| {
        if (std.mem.indexOf(u8, warning.message, "\"hidden\"") != null) saw_hidden = true;
        if (std.mem.indexOf(u8, warning.message, "\"tick\"") != null) saw_tick = true;
        // Everything the fixture binds must stay off the list.
        try testing.expect(std.mem.indexOf(u8, warning.message, "\"count\"") == null);
        try testing.expect(std.mem.indexOf(u8, warning.message, "\"cards\"") == null);
        try testing.expect(std.mem.indexOf(u8, warning.message, "\"visible\"") == null);
    }
    try testing.expect(saw_hidden);
    try testing.expect(saw_tick);
}

const OptOutModel = struct {
    count: usize = 0,
    hidden: u8 = 0,

    pub const view_unbound = .{"hidden"};
};

const OptOutMsg = union(enum) {
    add,
    tick,

    pub const view_unbound = .{"tick"};
};

test "pub const view_unbound opts update-only state out of the dead-state lint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opt_contract = comptime contract.describe(OptOutModel, OptOutMsg, specials);
    var parser = markup.Parser.init(arena,
        \\<column>
        \\  <button on-press="add">{count}</button>
        \\</column>
    );
    const document = try parser.parse();
    var usage = try contract.Usage.init(arena, &opt_contract);
    try testing.expectEqual(null, try contract.checkDocument(arena, document, &opt_contract, &usage));
    const warnings = try contract.deadState(arena, &opt_contract, &usage);
    try testing.expectEqual(@as(usize, 0), warnings.len);
}

// -------------------------------------------------------------- imports

test "the contract check follows argument kinds through the import closure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const component =
        \\<template name="lane" args="width title">
        \\  <column width="{width}">
        \\    <text>{title}</text>
        \\    <slot/>
        \\  </column>
        \\</template>
    ;
    const good_root =
        \\<import src="components/lane.native"/>
        \\<row>
        \\  <use template="lane" width="{ratio}" title="{name}">
        \\    <text>{count}</text>
        \\  </use>
        \\</row>
    ;
    const bad_root =
        \\<import src="components/lane.native"/>
        \\<row>
        \\  <use template="lane" width="{name}" title="{name}" />
        \\</row>
    ;
    const sources = [_]markup.SourceFile{
        .{ .path = "components/lane.native", .source = component },
    };
    var loader = markup.SourceSetLoader{ .set = &sources };

    var diagnostic: markup.MarkupErrorInfo = .{};
    const good = try markup.resolveImports(arena, "view.native", good_root, loader.loader(), &diagnostic);
    try testing.expectEqual(null, markup.validate(good));
    try testing.expectEqual(null, try contractMessage(arena, good, null));

    const bad = try markup.resolveImports(arena, "view.native", bad_root, loader.loader(), &diagnostic);
    try testing.expectEqual(null, markup.validate(bad));
    const info = (try contract.checkDocument(arena, bad, &model_contract, null)).?;
    try testing.expectEqualStrings("expected a number", info.message);
    // The mismatch is diagnosed where the template body consumes the arg,
    // so the position names the imported component file.
    try testing.expectEqualStrings("components/lane.native", info.path);
}

// ------------------------------------------------------------- artifact

test "a contract round-trips through the ZON artifact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stamped = model_contract;
    stamped.source_hash = 0xdead_beef_dead_beef;
    stamped.app_icons = &.{ "wave", "wave-pulse" };
    var out: std.Io.Writer.Allocating = .init(arena);
    try contract.writeArtifact(stamped, &out.writer);

    const parsed = try contract.parseArtifact(arena, out.written());
    try testing.expectEqual(contract.format_version, parsed.format);
    try testing.expectEqual(stamped.source_hash, parsed.source_hash);
    try testing.expectEqual(@as(usize, 2), parsed.app_icons.len);
    try testing.expectEqualStrings("wave", parsed.app_icons[0]);
    try testing.expectEqualStrings("wave-pulse", parsed.app_icons[1]);
    // Artifacts from before the app_icons field parse with the default
    // (no registered icons) - the additive-with-default contract. The
    // FORMAT VERSION is a separate gate: parsing tolerates missing
    // fields, and the reader (tools/native-sdk markup check) refuses
    // any format it does not know — format 1 classified the retired
    // one-axis scroll record as a scroll_state payload, which would be
    // a false pass today.
    const legacy = try contract.parseArtifact(arena, ".{ .format = 1 }");
    try testing.expectEqual(@as(usize, 0), legacy.app_icons.len);
    try testing.expect(legacy.format != contract.format_version);
    try testing.expectEqualStrings(model_contract.model_type, parsed.model_type);
    try testing.expectEqual(model_contract.model.scalars.len, parsed.model.scalars.len);
    try testing.expectEqual(model_contract.iterables.len, parsed.iterables.len);
    try testing.expectEqual(model_contract.msgs.len, parsed.msgs.len);
    for (model_contract.msgs, parsed.msgs) |original, round_tripped| {
        try testing.expectEqualStrings(original.name, round_tripped.name);
        try testing.expectEqual(original.payload, round_tripped.payload);
    }
    // The round-tripped contract checks documents identically.
    const document = try parseFixture(arena, fixtures[0].source);
    try testing.expectEqual(null, try contract.checkDocument(arena, document, &parsed, null));
}

test "appIconNames reflects the app root's icon table by name" {
    // Duck-typed on `.name`: the emit step reads the same `pub const
    // app_icons` table main hands to registerAppIcons, without this
    // std-only module knowing the canvas Entry type.
    const app = struct {
        pub const app_icons = [_]struct { name: []const u8 }{
            .{ .name = "wave" },
            .{ .name = "wave-pulse" },
        };
    };
    const names = comptime contract.appIconNames(app);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("wave", names[0]);
    try testing.expectEqualStrings("wave-pulse", names[1]);
    // No declaration means no registered icons.
    try testing.expectEqual(@as(usize, 0), comptime contract.appIconNames(struct {}).len);
}

test "describe classifies the model surface the way the engines resolve it" {
    // Spot-check the reflection against the fixture model: kinds, arena
    // flags, payload classes, and the iterable item groups.
    const c = model_contract;
    try testing.expect(findScalar(c.model, "count").?.kind == .integer);
    try testing.expect(findScalar(c.model, "name").?.kind == .string);
    try testing.expect(findScalar(c.model, "ratio").?.kind == .float);
    try testing.expect(findScalar(c.model, "active").?.kind == .boolean);
    try testing.expect(findScalar(c.model, "priority").?.kind == .string);
    try testing.expect(findScalar(c.model, "total").?.fn_backed);
    try testing.expect(findScalar(c.model, "upper_name").?.arena);
    try testing.expect(findScalar(c.model, "cards") == null);

    var found_profile = false;
    for (c.model.groups) |group| {
        if (std.mem.eql(u8, group.name, "profile")) {
            found_profile = true;
            try testing.expect(findScalar(group.group, "age").?.kind == .integer);
        }
    }
    try testing.expect(found_profile);

    var found_cards = false;
    var found_visible = false;
    for (c.iterables) |iterable| {
        if (std.mem.eql(u8, iterable.name, "cards")) {
            found_cards = true;
            try testing.expect(findScalar(iterable.item, "done").?.kind == .boolean);
            try testing.expect(findScalar(iterable.item, "label").?.fn_backed);
            try testing.expect(findScalar(iterable.item, "badge").?.arena);
        }
        if (std.mem.eql(u8, iterable.name, "visible")) {
            found_visible = true;
            try testing.expect(iterable.fn_backed);
        }
    }
    try testing.expect(found_cards);
    try testing.expect(found_visible);

    try testing.expectEqual(contract.PayloadClass.none, findMsg(c, "add").?.payload);
    try testing.expectEqual(contract.PayloadClass.integer, findMsg(c, "remove").?.payload);
    try testing.expectEqual(contract.PayloadClass.string, findMsg(c, "rename").?.payload);
    try testing.expectEqual(contract.PayloadClass.enum_tag, findMsg(c, "set_priority").?.payload);
    try testing.expectEqual(contract.PayloadClass.float, findMsg(c, "scale").?.payload);
    try testing.expectEqual(contract.PayloadClass.text_input, findMsg(c, "draft").?.payload);
    try testing.expectEqual(contract.PayloadClass.scroll_state, findMsg(c, "scrolled").?.payload);
}

fn findScalar(group: contract.Group, name: []const u8) ?contract.Scalar {
    for (group.scalars) |scalar| {
        if (std.mem.eql(u8, scalar.name, name)) return scalar;
    }
    return null;
}

fn findMsg(c: contract.Contract, name: []const u8) ?contract.MsgTag {
    for (c.msgs) |tag| {
        if (std.mem.eql(u8, tag.name, name)) return tag;
    }
    return null;
}

// ------------------------------------------------------------- staleness

test "hashSourceDir changes when a source file changes and ignores non-core files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const x = 1;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "view.native", .data = "<column/>" });

    const first = try contract.hashSourceDirAt(arena, io, tmp.dir, ".");

    // A markup edit must not invalidate the contract (it is derived from
    // the core side only)...
    try tmp.dir.writeFile(io, .{ .sub_path = "view.native", .data = "<row/>" });
    try testing.expectEqual(first, try contract.hashSourceDirAt(arena, io, tmp.dir, "."));

    // ...while any Zig edit must.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "pub const x = 2;\n" });
    try testing.expect(first != try contract.hashSourceDirAt(arena, io, tmp.dir, "."));
}

test "hashSourceDir: a core.ts edit invalidates the contract on the TS track" {
    // The wave-2 trap: `src/core.ts` is the Model/Msg truth on the TS
    // track, but it is not a `.zig` file — a hash over Zig sources only
    // kept a scaffold-era contract "fresh" through every core edit, and
    // `native check` reported phantom unknown-tag/unknown-field errors
    // naming the user's NEW state. TypeScript sources must invalidate.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "core.ts", .data = "export const model = { count: 0 };\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.native", .data = "<column/>" });

    const first = try contract.hashSourceDirAt(arena, io, tmp.dir, ".");

    // Editing the TypeScript core must change the hash...
    try tmp.dir.writeFile(io, .{ .sub_path = "core.ts", .data = "export const model = { count: 0, phase: \"rest\" };\n" });
    const second = try contract.hashSourceDirAt(arena, io, tmp.dir, ".");
    try testing.expect(first != second);

    // ...and a new imported .ts module under src/ must too (the checker
    // runs the core's whole import graph).
    try tmp.dir.writeFile(io, .{ .sub_path = "timers.ts", .data = "export const tick = 1;\n" });
    try testing.expect(second != try contract.hashSourceDirAt(arena, io, tmp.dir, "."));
}

test "a wrong-typed series values binding names the model item type" {
    // The teaching error carries the fix: the binding named, and what it
    // actually iterates.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const document = try parseFixture(arena,
        \\<column>
        \\  <chart>
        \\    <series values="{cards}" />
        \\  </chart>
        \\</column>
    );
    const message = (try contractMessage(arena, document, null)).?;
    try testing.expect(std.mem.startsWith(u8, message, markup.series_values_message));
    try testing.expect(std.mem.indexOf(u8, message, "\"cards\" iterates") != null);
    try testing.expect(std.mem.indexOf(u8, message, "Card") != null);
}

// -------------------------------------------- committed-model (pointer) shape

const PointerMeta = struct {
    title: []const u8 = "lib",
    total: i64 = 0,
};

/// A self-referential pointer node: legal in committed models (shared
/// nodes may link), and the describe walk must stop at the cycle instead
/// of recursing forever.
const PointerNode = struct {
    id: i64 = 0,
    next: ?*const PointerNode = null,
    parent: *const PointerMeta = &.{},
};

const PointerModel = struct {
    meta: *const PointerMeta = &.{},
    rows: []const *const PointerNode = &.{},
    head: *const PointerNode = &.{},
};

const PointerMsg = union(enum) { open: i64 };

test "describe traverses *const record fields and pointer-item lists like the engines" {
    const c = comptime contract.describe(PointerModel, PointerMsg, specials);

    // The `*const` record field is a traversable group named for the
    // struct it shares.
    var found_meta = false;
    for (c.model.groups) |group| {
        if (std.mem.eql(u8, group.name, "meta")) {
            found_meta = true;
            try testing.expect(findScalar(group.group, "title").?.kind == .string);
            try testing.expect(findScalar(group.group, "total").?.kind == .integer);
        }
    }
    try testing.expect(found_meta);

    // A `[]const *const T` iterable binds item fields like `[]const T`.
    var found_rows = false;
    for (c.iterables) |iterable| {
        if (std.mem.eql(u8, iterable.name, "rows")) {
            found_rows = true;
            try testing.expect(!iterable.item_scalar);
            try testing.expect(findScalar(iterable.item, "id").?.kind == .integer);
        }
    }
    try testing.expect(found_rows);

    // The cyclic `next` pointer stopped the walk (the group exists via
    // `head`, but no infinite nesting), and the optional pointer stayed
    // unbindable — optionals of records gate through scalar flags.
    var found_head = false;
    for (c.model.groups) |group| {
        if (std.mem.eql(u8, group.name, "head")) {
            found_head = true;
            var nested_next = false;
            for (group.group.groups) |nested| {
                if (std.mem.eql(u8, nested.name, "next")) nested_next = true;
            }
            try testing.expect(!nested_next);
        }
    }
    try testing.expect(found_head);
}

// ----------------------------------------------- declared text-input unions

test "the reflect tag vocabulary never drifts from canvas.TextInputEvent" {
    const reflect = @import("ui_markup_reflect.zig");
    const event_fields = @typeInfo(canvas.TextInputEvent).@"union".fields;
    try testing.expectEqual(reflect.text_input_event_tags.len, event_fields.len);
    inline for (event_fields) |field| {
        var found = false;
        for (reflect.text_input_event_tags) |tag| {
            if (std.mem.eql(u8, tag, field.name)) found = true;
        }
        try testing.expect(found);
    }
    const direction_fields = @typeInfo(canvas.TextCaretDirection).@"enum".fields;
    try testing.expectEqual(reflect.text_caret_direction_members.len, direction_fields.len);
    inline for (direction_fields) |field| {
        var found = false;
        for (reflect.text_caret_direction_members) |member| {
            if (std.mem.eql(u8, member, field.name)) found = true;
        }
        try testing.expect(found);
    }
}

test "the reflect field vocabulary never drifts from canvas.ScrollState" {
    const reflect = @import("ui_markup_reflect.zig");
    const state_fields = @typeInfo(canvas.ScrollState).@"struct".fields;
    try testing.expectEqual(reflect.scroll_state_field_names.len, state_fields.len);
    inline for (state_fields) |field| {
        // Every real field appears in the pinned vocabulary, and every
        // real field is the f32 the translation widens from — a canvas
        // field changing type (or gaining a sibling) fails here first.
        try testing.expectEqual(f32, field.type);
        var found = false;
        for (reflect.scroll_state_field_names) |name| {
            if (std.mem.eql(u8, name, field.name)) found = true;
        }
        try testing.expect(found);
    }
}

test "a declared scroll-state mirror classifies as a scroll_state payload" {
    var saw_mirror = false;
    var saw_legacy = false;
    var saw_wide_pane = false;
    for (model_contract.msgs) |tag| {
        if (std.mem.eql(u8, tag.name, "mirror_scrolled")) {
            saw_mirror = true;
            try testing.expectEqual(contract.PayloadClass.scroll_state, tag.payload);
        }
        if (std.mem.eql(u8, tag.name, "legacy_scrolled")) {
            saw_legacy = true;
            try testing.expectEqual(contract.PayloadClass.legacy_scroll_state, tag.payload);
        }
        if (std.mem.eql(u8, tag.name, "pane_wide")) {
            saw_wide_pane = true;
            try testing.expectEqual(contract.PayloadClass.float, tag.payload);
            try testing.expectEqualStrings("f64", tag.payload_type);
        }
    }
    try testing.expect(saw_mirror);
    try testing.expect(saw_legacy);
    try testing.expect(saw_wide_pane);
}

test "a declared mirror union classifies as a text_input payload" {
    const mirror_fixture = @import("ui_markup_view_tests.zig");
    const mirror_contract = comptime contract.describe(
        mirror_fixture.MirrorModel,
        mirror_fixture.MirrorMsg,
        specials,
    );
    var saw_edit = false;
    for (mirror_contract.msgs) |tag| {
        if (std.mem.eql(u8, tag.name, "edit")) {
            saw_edit = true;
            try testing.expectEqual(contract.PayloadClass.text_input, tag.payload);
        }
    }
    try testing.expect(saw_edit);
}
