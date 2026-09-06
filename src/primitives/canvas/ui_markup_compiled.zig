//! Comptime-compiled markup views: parse a `.native` source entirely at
//! comptime and emit a `build(ui, model)` whose output is identical to the
//! interpreter's (ui_markup_view.zig) for the same model — same structural
//! widget ids node for node, same handler table, same dispatch results —
//! with no parser or interpreter in the binary.
//!
//! The runtime interpreter stays the dev/hot-reload engine; this is the
//! release engine. Both share one grammar: the parser's token-level
//! helpers, the expression parsers (`parseAttrExpression`,
//! `parseMessageExpression`), the element/attribute tables, and the value
//! conversion code (`Value`, `valueOf`, `literalValue`, `appendValue`) are
//! the interpreter's own, so the engines cannot drift.
//!
//! Errors: everything the interpreter reports as a runtime `MarkupBuild`
//! failure whose cause is knowable from the source and the Model/Msg types
//! — unknown elements/attributes, malformed expressions, bindings that
//! don't name model fields, unknown message tags, payload type mismatches —
//! becomes a compile error carrying the node's line/column and the
//! interpreter's message. That is also the compile-error test strategy:
//! invalid constructs are structurally unreachable at runtime because the
//! comptime walk `@compileError`s on them while resolving the tree (Zig
//! cannot unit-test `@compileError`, so ui_markup_compiled_tests.zig covers
//! the accepting side exhaustively and the interpreter's failure tests
//! enumerate the constructs this path rejects at compile time). The only
//! failures left for runtime are value-dependent ones the interpreter also
//! discovers at runtime (an optional binding or non-tag string feeding an
//! enum), which latch `ui.failed` exactly like the builder's own sugar.

const std = @import("std");
const builtin = @import("builtin");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const interpreter = @import("ui_markup_view.zig");

const Value = interpreter.Value;

/// A markup view compiled against a concrete Model/Msg pair. `source` is
/// parsed at comptime (no parser in the binary) and `build` unrolls binding
/// and message resolution to direct field/method access — what an
/// equivalent hand-written `view(ui, model)` compiles to. Single-file
/// documents only; a document with `<import>`s names its source set
/// through `CompiledMarkupImports`.
pub fn CompiledMarkupView(comptime ModelT: type, comptime MsgT: type, comptime source: []const u8) type {
    const parsed = markup.parseComptime(source);
    if (parsed.imports.len > 0) {
        @compileError("this markup imports other files - compile it with canvas.CompiledMarkupImports(Model, Msg, \"root.native\", &sources), where sources is a markup.SourceFile set embedding the root and every imported file");
    }
    return CompiledMarkupEngine(ModelT, MsgT, parsed, source, &.{});
}

/// The compiled engine's side of the import resolver seam (see the
/// "imports" section of ui_markup.zig): the app assembles a comptime
/// source set with `@embedFile` — one entry per file, paths relative to
/// the root file's directory — and resolution merges the closure at
/// comptime. The same set drives the runtime interpreter's embedded
/// resolution (`MarkupOptions.sources`), so both engines see one document.
pub fn CompiledMarkupImports(comptime ModelT: type, comptime MsgT: type, comptime root_name: []const u8, comptime sources: []const markup.SourceFile) type {
    return CompiledMarkupEngine(ModelT, MsgT, markup.resolveImportsComptime(root_name, sources), rootSourceOf(root_name, sources), sources);
}

/// The root file's embedded bytes out of a comptime source set — the
/// hot-reload baseline `fragment()` carries. The resolver already
/// requires the root to be present (with its own teaching error), so a
/// miss here is unreachable in practice.
fn rootSourceOf(comptime root_name: []const u8, comptime sources: []const markup.SourceFile) []const u8 {
    for (sources) |file| {
        if (std.mem.eql(u8, file.path, root_name)) return file.source;
    }
    return "";
}

/// Shared engine over an already-resolved comptime document, without a
/// hot-reload baseline: a fragment compiled through this shape has no
/// embedded source to compare a watched file against, so it cannot
/// register with the fragment watch (`CompiledMarkupView` and
/// `CompiledMarkupImports` are the registrable shapes).
pub fn CompiledMarkupDocument(comptime ModelT: type, comptime MsgT: type, comptime resolved_document: markup.MarkupDocument) type {
    return CompiledMarkupEngine(ModelT, MsgT, resolved_document, "", &.{});
}

/// The engine over an already-resolved comptime document. The document
/// is canonicalized first (the typed-document pass), so both engines
/// consume the same typed form; this engine's binding/message resolution
/// stays comptime-unrolled, so the pass changes nothing about the code it
/// emits — the parity suite is the proof. `fragment_source` and
/// `fragment_sources` are the embedded bytes the document was compiled
/// from, referenced only by the Debug-only fragment watch registration.
fn CompiledMarkupEngine(comptime ModelT: type, comptime MsgT: type, comptime resolved_document: markup.MarkupDocument, comptime fragment_source: []const u8, comptime fragment_sources: []const markup.SourceFile) type {
    return struct {
        pub const Ui = canvas.Ui(MsgT);

        pub const document = markup.canonicalizeComptime(resolved_document);

        /// Debug-only registration handle for the runtime's fragment
        /// hot-reload watch: `.fragment("src/header.native")` in
        /// `UiApp.Options.fragment_watch` names the on-disk source this
        /// fragment was compiled from, so a dev run reloads it in place
        /// when the file (or any file its imports reach) changes.
        /// Outside Debug this returns an empty handle — no path bytes,
        /// no embedded-baseline references — so release binaries carry
        /// no watch plumbing.
        pub fn fragment(comptime path: []const u8) markup.MarkupFragment {
            comptime {
                if (fragment_source.len == 0) @compileError("this compiled markup view has no embedded source baseline - only CompiledMarkupView / CompiledMarkupImports fragments can register with the fragment watch");
            }
            if (comptime builtin.mode != .Debug) return .{};
            return .{
                .key = fragmentKey(),
                .path = path,
                .source = fragment_source,
                .sources = fragment_sources,
            };
        }

        /// This fragment's identity for the watch's override lookup: the
        /// address of the comptime document, unique per compiled fragment
        /// type and shared by registration (`fragment`) and the build-time
        /// check, so the two cannot disagree.
        fn fragmentKey() *const anyopaque {
            return @ptrCast(&document);
        }

        /// Loop variables, template args, and slot captures in scope at a
        /// point in the tree. Names, kinds, and item types are comptime;
        /// the runtime value is a nested struct with one payload per
        /// entry: a `*const Item` for `for` items, a `Value` for scalar
        /// template args, a `[]const Item` for slice-valued template args,
        /// and the use-site scope chain for slot captures.
        const ScopeEntry = struct {
            name: []const u8,
            kind: Kind,
            Item: type = void,
            /// For value args: the comptime-known Value variant of the
            /// use-site expression (null when only runtime-known, e.g. a
            /// binding through an optional).
            variant: ?ValueVariant = null,
            /// For slot captures: the `<use>` site's children, the scope
            /// entries they must build under (the consumer's), and the
            /// runtime type of the consumer's scope chain. The capture's
            /// name is empty, which no binding head can equal, so lookups
            /// skip it.
            slot_nodes: []const markup.MarkupNode = &.{},
            slot_entries: []const ScopeEntry = &.{},
            SiteScope: type = void,
            /// True when a value arg came from a declaration default rather
            /// than an explicit use-site argument.
            defaulted: bool = false,
            const Kind = enum { item, value_arg, slice_arg, slot };
        };

        fn EntryPayload(comptime entry: ScopeEntry) type {
            return switch (entry.kind) {
                .item => *const entry.Item,
                .value_arg => Value,
                .slice_arg => []const entry.Item,
                .slot => entry.SiteScope,
            };
        }

        // Runtime scopes are anonymous `{ parent, item }` chains passed as
        // `anytype`: one link per entry, innermost last, so a link's type
        // never depends on comptime slice identity (a child list created
        // with `entries ++ ...` re-slices a fresh array, which would not
        // unify with the parent's `entries` under generic instantiation).

        const no_entries: []const ScopeEntry = &.{};

        /// Build the view for the current model. Signature-compatible with
        /// a hand-written view, so it slots into `UiApp.Options.view`
        /// directly. Markup mistakes are compile errors; the only runtime
        /// failures latch `ui.failed` (surfaced by `finalize`) exactly like
        /// the builder's own sugar (`ui.fmt`, `ui.each`).
        pub fn build(ui: *Ui, model: *const ModelT) Ui.Node {
            // Debug-only hot-reload seam: when the app registered this
            // fragment with the runtime's fragment watch (`fragment(path)`
            // in `UiApp.Options.fragment_watch`) and the watch adopted a
            // changed on-disk source, the interpreter builds the reloaded
            // document instead of the comptime tree. The engines are
            // parity-proven, so pixels and structural ids match until the
            // edit itself changes them; release builds compile this
            // branch out entirely.
            if (comptime builtin.mode == .Debug) {
                if (ui.markup_fragment_host) |host| {
                    if (host.override(host.context, fragmentKey())) |override_ptr| {
                        const live_document: *const markup.MarkupDocument = @ptrCast(@alignCast(override_ptr));
                        var live = interpreter.MarkupView(ModelT, MsgT).fromDocument(live_document.*);
                        return live.build(ui, model) catch {
                            // The reloaded source parses but cannot build
                            // against this Model/Msg (a binding naming no
                            // model field, an unknown message tag — what
                            // the compiled engine catches at comptime).
                            // Report the teaching diagnostic through the
                            // host and latch `ui.failed` so the frame
                            // aborts and the last good tree stays up; the
                            // next good save reloads and recovers.
                            host.report(host.context, .{
                                .line = live.diagnostic.line,
                                .column = live.diagnostic.column,
                                .message = live.diagnostic.message,
                                .path = live.diagnostic.path,
                            });
                            ui.failed = true;
                            return ui.column(.{}, .{});
                        };
                    }
                }
            }
            const root = comptime (document.root orelse @compileError("markup error: " ++ markup.component_file_view_message));
            comptime {
                checkTemplates();
                switch (root.kind) {
                    .element, .use_block => {},
                    .template_block => fail(root, markup.template_top_level_message),
                    .import_block => fail(root, markup.import_top_level_message),
                    .slot_block => fail(root, markup.slot_outside_template_message),
                    .text => fail(root, "text content is only allowed inside text-bearing elements"),
                    .for_block, .if_block, .else_block => fail(root, "structure tags are only allowed inside an element"),
                }
            }
            if (comptime (root.kind == .use_block)) {
                return buildUse(root, no_entries, ui, model, .{});
            }
            return buildElement(root, no_entries, ui, model, .{});
        }

        /// Comptime template wiring checks, mirroring the validator: a
        /// name, exactly one element child, at most one slot, and uses
        /// inside template bodies referencing only earlier templates —
        /// which also guarantees comptime expansion terminates (slot
        /// content is lexical, so it cannot re-enter an expansion).
        fn checkTemplates() void {
            comptime {
                @setEvalBranchQuota(50_000 + document.templates.len * 20_000);
                for (document.templates, 0..) |template_node, index| {
                    const name = template_node.attr("name") orelse fail(template_node, markup.template_name_message);
                    for (document.templates[0..index]) |earlier| {
                        const earlier_name = earlier.attr("name") orelse continue;
                        if (std.mem.eql(u8, earlier_name, name)) fail(template_node, markup.template_unique_name_message);
                    }
                    if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                        fail(template_node, markup.template_one_child_message);
                    }
                    if (markup.templateSecondSlot(template_node.children[0])) |second| {
                        fail(second, markup.template_one_slot_message);
                    }
                    checkUseOrder(template_node.children[0], index);
                }
            }
        }

        fn checkUseOrder(comptime node: markup.MarkupNode, comptime limit: usize) void {
            comptime {
                if (node.kind == .use_block) {
                    const name = node.attr("template") orelse fail(node, markup.use_template_attr_message);
                    const index = document.templateIndex(name) orelse fail(node, markup.use_undefined_template_message);
                    if (index >= limit) fail(node, markup.use_earlier_template_message);
                }
                for (node.children) |child| checkUseOrder(child, limit);
            }
        }

        // ------------------------------------------------------ building

        fn buildElement(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            return buildElementWithForwardedPress(node, entries, ui, model, scope, null);
        }

        fn buildElementWithForwardedPress(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, forwarded_press: ?MsgT) Ui.Node {
            var built = buildElementInner(node, entries, ui, model, scope, forwarded_press);
            if (forwarded_press) |msg| {
                // A press declared on <use> belongs to the expanded root.
                // The root-specific builder may also use it to render its
                // press affordance; this final stamp covers generic roots.
                built.on_press = msg;
                built.widget.semantics.focusable = true;
            }
            return built;
        }

        fn buildElementInner(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, forwarded_press: ?MsgT) Ui.Node {
            if (comptime std.mem.eql(u8, node.name, "markdown")) {
                return buildMarkdown(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "code")) {
                return buildCode(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "stepper")) {
                return buildStepper(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "step")) {
                // Steps inside a stepper are consumed by buildStepper.
                comptime fail(node, markup.step_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "timeline")) {
                return buildTimeline(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "timeline-item")) {
                return buildTimelineItem(node, entries, ui, model, scope, forwarded_press);
            }
            if (comptime std.mem.eql(u8, node.name, "chart")) {
                return buildChart(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "series")) {
                // Series inside a chart are consumed by buildChart.
                comptime fail(node, markup.series_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "video")) {
                return buildVideo(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "context-menu")) {
                // Direct context-menu children are consumed by their host
                // element below; one reaching here is misplaced.
                comptime fail(node, markup.context_menu_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "input-group")) {
                return buildInputGroup(node, entries, ui, model, scope);
            }
            if (comptime std.mem.eql(u8, node.name, "input-group-actions")) {
                // Actions rows inside an input-group are consumed by
                // buildInputGroup.
                comptime fail(node, markup.input_group_actions_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "span")) {
                // Spans inside a text paragraph are consumed by
                // buildSpanParagraph; one reaching here has no text
                // parent.
                comptime fail(node, markup.span_parent_message);
            }
            if (comptime std.mem.eql(u8, node.name, "reactions")) {
                // Reactions inside a bubble are consumed by the bubble's
                // build below; one reaching here has no bubble parent.
                comptime fail(node, markup.reactions_parent_message);
            }
            const kind = comptime (interpreter.elementKind(node.name) orelse fail(node, "unknown element"));
            // Interpreter parity: extract a direct context-menu child —
            // metadata on this element (lowered to the declared
            // platform-menu items), not content — so every content rule
            // below sees the remaining children only.
            const context_menu_split = comptime splitContextMenuChild(node);
            // Interpreter parity: extract a direct reactions child the
            // same way — the pill is bubble CHROME (it lowers onto the
            // bubble widget's chrome-text channel), not content.
            const reactions_split = comptime splitReactionsChild(context_menu_split.inner, kind);
            const inner = comptime reactions_split.inner;
            comptime {
                // Interpreter parity: the bubble's chrome-text channel
                // belongs to the reaction pill; a bare text attribute
                // would silently do nothing, so it is a compile error.
                if (kind == .bubble and node.attr("text") != null) {
                    fail(node, markup.bubble_text_attr_message);
                }
            }
            comptime {
                // Interpreter parity: value/text handlers on
                // non-hit-target kinds can never fire, so a dead handler
                // is a compile error here. on-press/on-toggle are exempt
                // — a bound press handler makes any element a hit target
                // and presses fall through to it.
                if (!canvas.widgetKindHitTarget(kind)) {
                    for (node.attrs) |attribute| {
                        if (std.mem.startsWith(u8, attribute.name, "on-") and markup.deadHandlerOnNonHitTarget(attribute.name)) {
                            fail(node, markup.non_hit_target_handler_message);
                        }
                        // Autofocus can never land here: nothing about
                        // this element is focusable.
                        if (std.mem.eql(u8, attribute.name, "autofocus")) {
                            fail(node, markup.autofocus_element_message);
                        }
                    }
                }
                // Interpreter parity: stacking kinds give every child the
                // full content box, so a gap can never space them — dead
                // layout data is a compile error here.
                if (canvas.widgetKindStacksChildren(kind)) {
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "gap")) {
                            fail(node, markup.stack_container_gap_message);
                        }
                    }
                }
                // Interpreter parity: only plain text leaves word-wrap
                // or elide; anywhere else the options are silently inert
                // dead layout data — a compile error here.
                if (kind != .text) {
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "wrap")) {
                            fail(node, markup.wrap_element_message);
                        }
                        if (std.mem.eql(u8, attribute.name, "overflow")) {
                            fail(node, markup.overflow_element_message);
                        }
                    }
                }
                // Interpreter parity: only textarea has a configurable
                // Enter-vs-newline policy.
                if (kind != .textarea) {
                    for (node.attrs) |attribute| {
                        if (std.mem.eql(u8, attribute.name, "submit-on-enter")) {
                            fail(node, markup.submit_on_enter_element_message);
                        }
                    }
                }
                // Interpreter parity: the overflow policy's closed
                // literal vocabulary. A compile error here; bindings
                // resolve at runtime like any enum option.
                for (node.attrs) |attribute| {
                    if (!std.mem.eql(u8, attribute.name, "overflow")) continue;
                    const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                    if (expression != .literal) continue;
                    if (!markup.nameInList(expression.literal, &markup.overflow_value_names)) {
                        fail(node, markup.overflow_value_message);
                    }
                }
                // Interpreter parity: the size register's closed literal
                // vocabulary — the control scale everywhere, the
                // typography rungs (heading/display) on text only. A
                // compile error here; bindings resolve at runtime like
                // any enum option.
                for (node.attrs) |attribute| {
                    if (!std.mem.eql(u8, attribute.name, "size")) continue;
                    const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                    if (expression != .literal) continue;
                    if (markup.nameInList(expression.literal, &markup.known_text_size_value_names)) {
                        if (kind != .text) fail(node, markup.text_size_element_message);
                    } else if (!markup.nameInList(expression.literal, &markup.known_control_size_value_names)) {
                        fail(node, markup.size_value_message);
                    }
                }
                // Interpreter parity: splits take exactly two static
                // pane children (the divider sits between fixed panes).
                if (kind == .split) {
                    var pane_count: usize = 0;
                    for (inner.children) |child| {
                        switch (child.kind) {
                            .element, .use_block => pane_count += 1,
                            else => fail(child, markup.split_children_message),
                        }
                    }
                    if (pane_count != 2) fail(node, markup.split_children_message);
                }
                // Interpreter parity: the image leaf's static shape.
                // Without its id binding the leaf can never draw —
                // statically dead markup, a compile error here too. And
                // it takes no children at all (icon's leaf policy): the
                // check reads the ORIGINAL node, so an extracted
                // context-menu still counts as a child exactly like the
                // validator's raw-node check.
                if (kind == .image) {
                    if (node.attr("image") == null) {
                        fail(node, markup.image_missing_image_message);
                    }
                    if (node.children.len > 0) {
                        fail(node, markup.image_children_message);
                    }
                }
                // Interpreter parity: the terminal leaf's static shape —
                // pty required (dead markup without it), no children.
                if (kind == .terminal) {
                    if (node.attr("pty") == null) {
                        fail(node, markup.terminal_missing_pty_message);
                    }
                    if (node.children.len > 0) {
                        fail(node, markup.terminal_children_message);
                    }
                }
                // Interpreter parity: the a11y lint's error half — an
                // unnamed interactive control or a misused role ships a
                // view a screen reader user cannot operate, so it is a
                // compile error here.
                if (markup.a11yNameError(node)) |message| {
                    fail(node, message);
                }
                if (markup.a11yRoleError(node)) |message| {
                    fail(node, message);
                }
            }
            var options: Ui.ElementOptions = .{};
            applyAttrs(node, entries, ui, model, scope, &options);
            // Interpreter parity: the extracted context-menu lowers
            // through the ordinary element path — its menu-items build
            // like any element — and the built nodes become the host's
            // declared items. An empty runtime result declares no menu.
            if (comptime (context_menu_split.menu != null)) {
                var menu_children: std.ArrayListUnmanaged(Ui.Node) = .empty;
                buildChildList(comptime context_menu_split.menu.?.children, entries, ui, model, scope, &menu_children);
                options.context_menu = ui.contextMenuItemsFromNodes(menu_children.items);
            }

            if (comptime (kind == .icon)) {
                // The shared icon value grammar, resolved at comptime
                // where it can be: a typo in a built-in name is a compile
                // error, while app: names and bound names ride the
                // explicit icon channel and degrade at draw time to the
                // missing-icon fallback plus a Debug warning naming the
                // value (interpreter parity).
                const icon_value = comptime blk: {
                    const raw = node.attr("name") orelse fail(node, markup.icon_missing_name_message);
                    if (inner.children.len > 0) fail(node, markup.icon_children_message);
                    break :blk iconValueChecked(node, raw, markup.icon_name_message);
                };
                switch (comptime icon_value) {
                    .builtin => |name| {
                        var built = ui.el(kind, options, .{});
                        built.widget.text = name;
                        return built;
                    },
                    .app => |spelled| options.icon = spelled,
                    .binding => options.icon = stringAttr(node, entries, "name", comptime node.attr("name").?, ui, model, scope, markup.icon_name_message),
                    .invalid => unreachable,
                }
                return ui.el(kind, options, .{});
            }

            // Interpreter parity: the span paragraph — a text element
            // with inline <span> children lowers through Ui.paragraph,
            // exactly like a builder span paragraph.
            if (comptime (kind == .text and markup.nodeHasSpanChildren(inner))) {
                return buildSpanParagraph(inner, entries, ui, model, scope, options);
            }

            // Interpreter parity: the list-row composite — a text-taking
            // element whose content is element children instead of the
            // text run flows those children inside its own chrome, and
            // mixing text and elements is a compile error here.
            const composite_children = comptime (interpreter.elementTakesChildren(kind) and markup.nodeHasElementContent(inner));
            comptime {
                if (composite_children) {
                    for (inner.children) |child| {
                        if (child.kind == .text) fail(child, markup.text_or_children_content_message);
                    }
                }
            }
            if (comptime (interpreter.elementTakesText(kind) and !composite_children)) {
                var built = ui.el(kind, options, .{});
                // Interpreter parity: content wins when present; an empty
                // element keeps its already-resolved text= attribute.
                if (comptime inner.children.len > 0) {
                    built.widget.text = interpolatedText(inner, entries, ui, model, scope);
                }
                // Avatars clip their runtime image to the avatar circle,
                // exactly like `Ui.avatar` and the interpreter (a no-op
                // while the id is 0 and the initials fallback renders).
                if (comptime (kind == .avatar)) built.widget.image_fit = .cover;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            buildChildren(inner, entries, ui, model, scope, &children);
            // Interpreter parity: tab triggers ARE segmented controls -
            // `<button>` children of a `<tabs>` strip lower to the
            // widget kind tab strips are built on (see
            // `interpreter.lowerTabsTriggers`).
            if (comptime (kind == .tabs)) interpreter.lowerTabsTriggers(children.items);
            var built = ui.el(kind, options, @as([]const Ui.Node, children.items));
            // Interpreter parity: the extracted reactions run lands on
            // the bubble widget's chrome-text channel — the render pass
            // draws it as the docked pill — and the dock rides
            // text_alignment (end is the default: the trailing dock
            // reactions conventionally hang from). The dock literal
            // resolves at comptime; the run interpolates like any text.
            if (comptime (reactions_split.pill != null)) {
                built.widget.text = interpolatedText(comptime reactions_split.pill.?, entries, ui, model, scope);
                built.widget.text_alignment = comptime blk: {
                    const raw = reactions_split.pill.?.attr("text-alignment") orelse break :blk .end;
                    break :blk std.meta.stringToEnum(canvas.TextAlign, raw) orelse
                        fail(reactions_split.pill.?, markup.reactions_alignment_value_message);
                };
            }
            return built;
        }

        /// One runtime step per child: elements and `use` expansions append
        /// a node, `slot` splices the use-site children in place, `for`
        /// blocks append per item (with an adjacent `else` paired at
        /// comptime for the empty case), and an `if` (with its adjacent
        /// `else` paired at comptime) branches on the test binding.
        const ChildStep = union(enum) {
            element: markup.MarkupNode,
            use: markup.MarkupNode,
            slot: markup.MarkupNode,
            for_block: struct { node: markup.MarkupNode, else_block: ?markup.MarkupNode },
            conditional: struct { if_block: markup.MarkupNode, else_block: ?markup.MarkupNode },
        };

        fn childSteps(comptime children: []const markup.MarkupNode) []const ChildStep {
            comptime {
                @setEvalBranchQuota(10_000);
                var steps: []const ChildStep = &.{};
                var index: usize = 0;
                while (index < children.len) : (index += 1) {
                    const child = children[index];
                    switch (child.kind) {
                        .element => steps = steps ++ &[_]ChildStep{.{ .element = child }},
                        .use_block => steps = steps ++ &[_]ChildStep{.{ .use = child }},
                        .slot_block => {
                            // Interpreter and validator parity: a slot is
                            // an attribute-less, childless leaf.
                            if (child.attrs.len > 0) fail(child, markup.slot_attrs_message);
                            if (child.children.len > 0) fail(child.children[0], markup.slot_children_message);
                            steps = steps ++ &[_]ChildStep{.{ .slot = child }};
                        },
                        .template_block => fail(child, markup.template_top_level_message),
                        .import_block => fail(child, markup.import_top_level_message),
                        .for_block => {
                            var else_block: ?markup.MarkupNode = null;
                            if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                                else_block = children[index + 1];
                                index += 1;
                            }
                            steps = steps ++ &[_]ChildStep{.{ .for_block = .{ .node = child, .else_block = else_block } }};
                        },
                        .if_block => {
                            var else_block: ?markup.MarkupNode = null;
                            if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                                else_block = children[index + 1];
                                index += 1;
                            }
                            steps = steps ++ &[_]ChildStep{.{ .conditional = .{ .if_block = child, .else_block = else_block } }};
                        },
                        .else_block => fail(child, markup.else_placement_message),
                        .text => fail(child, "text content is only allowed inside text-bearing elements"),
                    }
                }
                return steps;
            }
        }

        fn buildChildren(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            buildChildList(comptime node.children, entries, ui, model, scope, out);
        }

        fn buildChildList(comptime children: []const markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            const steps = comptime childSteps(children);
            inline for (0..steps.len) |index| {
                const step = comptime steps[index];
                if (comptime (step == .element)) {
                    const built = buildElement(comptime step.element, entries, ui, model, scope);
                    out.append(ui.arena, built) catch {
                        ui.failed = true;
                        return;
                    };
                } else if (comptime (step == .use)) {
                    const built = buildUse(comptime step.use, entries, ui, model, scope);
                    out.append(ui.arena, built) catch {
                        ui.failed = true;
                        return;
                    };
                } else if (comptime (step == .slot)) {
                    buildSlot(comptime step.slot, entries, ui, model, scope, out);
                } else if (comptime (step == .for_block)) {
                    const item_count = buildFor(comptime step.for_block.node, entries, ui, model, scope, out);
                    if (comptime (step.for_block.else_block != null)) {
                        if (item_count == 0) {
                            buildChildren(comptime step.for_block.else_block.?, entries, ui, model, scope, out);
                        }
                    }
                } else {
                    const conditional = comptime step.conditional;
                    const test_value = comptime (conditional.if_block.attr("test") orelse fail(conditional.if_block, "if requires a test attribute"));
                    const condition = evalExpr(conditional.if_block, entries, test_value, ui, model, scope);
                    if (condition.truthy()) {
                        buildChildren(conditional.if_block, entries, ui, model, scope, out);
                    } else if (comptime (conditional.else_block != null)) {
                        buildChildren(comptime conditional.else_block.?, entries, ui, model, scope, out);
                    }
                }
            }
        }

        /// `<slot/>` in a template body: splice the use-site children (the
        /// innermost slot capture) IN THE CONSUMER'S SCOPE — the capture
        /// carries the consumer's comptime entries and its runtime scope
        /// chain, so content sees the model paths and loop variables where
        /// the `<use>` was written, while its nodes land at the slot's
        /// position (structural ids hash identically to the interpreter's).
        fn buildSlot(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            const capture_index = comptime (innermostSlotIndex(entries) orelse fail(node, markup.slot_outside_template_message));
            const capture = comptime entries[capture_index];
            if (comptime (capture.slot_nodes.len == 0)) return;
            const site_scope = scopePayload(entries, capture_index, scope);
            buildChildList(comptime capture.slot_nodes, comptime capture.slot_entries, ui, model, site_scope, out);
        }

        fn innermostSlotIndex(comptime entries: []const ScopeEntry) ?usize {
            comptime {
                var index = entries.len;
                while (index > 0) {
                    index -= 1;
                    if (entries[index].kind == .slot) return index;
                }
                return null;
            }
        }

        /// Expands a `for` block; returns the item count so the caller can
        /// render a trailing `<else>` for the empty case.
        fn buildFor(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) usize {
            const each = comptime (node.attr("each") orelse fail(node, "for requires an each attribute"));
            comptime {
                _ = node.attr("as") orelse fail(node, "for requires an as attribute");
                if (node.children.len == 0) fail(node, markup.for_children_message);
                for (node.children) |child| {
                    switch (child.kind) {
                        .element, .use_block, .for_block, .if_block, .else_block => {},
                        else => fail(child, markup.for_children_message),
                    }
                }
            }
            // Comptime mirror of the interpreter's `each` resolution:
            // slice-valued template args in scope shadow model iterables.
            const scope_index_opt = comptime scopeIndex(entries, each);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg) {
                        fail(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)");
                    }
                }
                const items = scopePayload(entries, scope_index, scope);
                buildForItems(comptime entries[scope_index].Item, node, entries, items, ui, model, scope, out);
                return items.len;
            }
            const info = comptime (eachInfo(each) orelse fail(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)"));
            const items = eachItems(info, ui, model);
            buildForItems(info.Item, node, entries, items, ui, model, scope, out);
            return items.len;
        }

        fn buildForItems(comptime ItemT: type, comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, items: []const ItemT, ui: *Ui, model: *const ModelT, scope: anytype, out: *std.ArrayListUnmanaged(Ui.Node)) void {
            const as_name = comptime node.attr("as").?;
            const child_entries = comptime (entries ++ &[_]ScopeEntry{.{ .name = as_name, .kind = .item, .Item = ItemT }});
            for (items) |*item| {
                const child_scope = .{ .parent = scope, .item = @as(*const ItemT, item) };
                const first_emitted = out.items.len;
                buildChildren(node, child_entries, ui, model, child_scope, out);
                if (comptime (node.attr("key") != null)) {
                    // Mirror of the interpreter: the item key stamps every
                    // node this item emitted (unless the node claims its
                    // own identity); later slots get a slot-suffixed key.
                    const base = itemKey(ItemT, node, comptime node.attr("key").?, ui, item);
                    for (out.items[first_emitted..], 0..) |*built, slot| {
                        if (built.key == null and built.global_key == null) {
                            built.key = canvas.forSlotKey(ui.arena, base, slot) catch {
                                ui.failed = true;
                                return;
                            };
                        }
                    }
                }
            }
        }

        // ------------------------------------------------------- markdown

        const Md = canvas.markdown.Markdown(MsgT);

        /// Comptime mirror of the interpreter's `buildMarkdown`: attrs,
        /// message tags, and the details-expanded source resolve at
        /// comptime; only the source string and expanded flags are read at
        /// runtime. Misuse fails compilation with the interpreter's
        /// message.
        fn buildMarkdown(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.markdown_children_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "source")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-link")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-details")) continue;
                    if (std.mem.eql(u8, attribute.name, "details-expanded")) continue;
                    if (std.mem.eql(u8, attribute.name, "issue-link-base")) continue;
                    if (std.mem.eql(u8, attribute.name, "images")) continue;
                    fail(node, markup.markdown_attr_message);
                }
            }
            const source_path = comptime blk: {
                const raw = node.attr("source") orelse fail(node, markup.markdown_source_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_source_message);
                if (expression != .binding) fail(node, markup.markdown_source_message);
                break :blk expression.binding;
            };
            comptime requireVariant(pathVariant(node, entries, source_path, true), &.{.string}, node, markup.markdown_source_message);
            const source_text = switch (bindingValue(node, entries, source_path, ui, model, scope, true)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };

            var options: Md.Options = .{};
            if (comptime (node.attr("on-link") != null)) {
                options.on_link = comptime markdownLinkConstructor(node, node.attr("on-link").?);
            }
            if (comptime (node.attr("on-details") != null)) {
                options.on_details = comptime markdownDetailsConstructor(node, node.attr("on-details").?);
            }
            if (comptime (node.attr("details-expanded") != null)) {
                options.details_expanded = detailsExpandedItems(node, entries, comptime node.attr("details-expanded").?, ui, model, scope);
            }
            if (comptime (node.attr("images") != null)) {
                options.images = markdownImageItems(node, entries, comptime node.attr("images").?, ui, model, scope);
            }
            if (comptime (node.attr("issue-link-base") != null)) {
                const raw = comptime node.attr("issue-link-base").?;
                comptime {
                    const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_issue_link_base_message);
                    if (expression == .equals) fail(node, markup.markdown_issue_link_base_message);
                }
                comptime requireVariant(attrExprVariant(node, entries, "issue-link-base", raw), &.{.string}, node, markup.markdown_issue_link_base_message);
                const base = switch (attrExprValue(node, entries, "issue-link-base", raw, ui, model, scope)) {
                    .string => |text| text,
                    else => runtimeFail([]const u8, ui),
                };
                if (base.len > 0) options.issue_link_base = base;
            }
            return Md.view(ui, source_text, options);
        }

        // ----------------------------------------------------------- code

        fn buildCode(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.code_children_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    const known = std.mem.eql(u8, attribute.name, "source") or
                        std.mem.eql(u8, attribute.name, "language") or
                        std.mem.eql(u8, attribute.name, "editable") or
                        std.mem.eql(u8, attribute.name, "on-input") or
                        std.mem.eql(u8, attribute.name, "line-numbers") or
                        std.mem.eql(u8, attribute.name, "added-lines") or
                        std.mem.eql(u8, attribute.name, "removed-lines") or
                        std.mem.eql(u8, attribute.name, "wrap") or
                        std.mem.eql(u8, attribute.name, "width") or
                        std.mem.eql(u8, attribute.name, "height") or
                        std.mem.eql(u8, attribute.name, "min-width") or
                        std.mem.eql(u8, attribute.name, "grow") or
                        std.mem.eql(u8, attribute.name, "label") or
                        std.mem.eql(u8, attribute.name, "key") or
                        std.mem.eql(u8, attribute.name, "global-key");
                    if (!known) fail(node, markup.code_attr_message);
                }
            }
            const source_path = comptime blk: {
                const raw = node.attr("source") orelse fail(node, markup.code_source_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.code_source_message);
                if (expression != .binding) fail(node, markup.code_source_message);
                break :blk expression.binding;
            };
            comptime requireVariant(pathVariant(node, entries, source_path, true), &.{.string}, node, markup.code_source_message);
            const source = switch (bindingValue(node, entries, source_path, ui, model, scope, true)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };

            var options: Ui.CodeOptions = .{};
            var added_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            var removed_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            if (comptime (node.attr("language") != null)) {
                const name = comptime blk: {
                    const expression = markup.parseAttrExpression(node.attr("language").?) orelse fail(node, markup.code_language_message);
                    if (expression != .literal) fail(node, markup.code_language_message);
                    if (!canvas.code.isLanguageName(expression.literal)) fail(node, markup.code_language_message);
                    break :blk expression.literal;
                };
                options.language = canvas.code.languageFromName(name);
            }
            if (comptime (node.attr("line-numbers") != null)) {
                options.line_numbers = videoFlagValue(node, entries, comptime node.attr("line-numbers").?, ui, model, scope);
            }
            if (comptime (node.attr("added-lines") != null)) {
                const spec = codeLineSpecAttr(node, entries, comptime node.attr("added-lines").?, ui, model, scope);
                options.added_lines = canvas.code.parseLineNumberSpec(spec, &added_lines_storage) orelse blk: {
                    ui.failed = true;
                    break :blk added_lines_storage[0..0];
                };
            }
            if (comptime (node.attr("removed-lines") != null)) {
                const spec = codeLineSpecAttr(node, entries, comptime node.attr("removed-lines").?, ui, model, scope);
                options.removed_lines = canvas.code.parseLineNumberSpec(spec, &removed_lines_storage) orelse blk: {
                    ui.failed = true;
                    break :blk removed_lines_storage[0..0];
                };
            }
            if (comptime (node.attr("editable") != null)) {
                options.editable = videoFlagValue(node, entries, comptime node.attr("editable").?, ui, model, scope);
            }
            if (comptime (node.attr("on-input") != null)) {
                const expression = comptime (markup.parseMessageExpression(node.attr("on-input").?) orelse
                    fail(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")"));
                options.on_input = comptime (inputConstructor(expression.tag) orelse
                    fail(node, "on-input tag must carry a TextInputEvent payload"));
            }
            if (comptime (node.attr("wrap") != null)) {
                options.wrap = videoFlagValue(node, entries, comptime node.attr("wrap").?, ui, model, scope);
            }
            if (comptime (node.attr("width") != null)) {
                options.width = floatAttr(node, entries, comptime node.attr("width").?, ui, model, scope);
            }
            if (comptime (node.attr("height") != null)) {
                options.height = floatAttr(node, entries, comptime node.attr("height").?, ui, model, scope);
            }
            if (comptime (node.attr("min-width") != null)) {
                options.min_width = floatAttr(node, entries, comptime node.attr("min-width").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            return ui.code(options, source);
        }

        fn codeLineSpecAttr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const u8 {
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, markup.code_diff_lines_message));
            if (comptime expression == .literal) return expression.literal;
            comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, markup.code_diff_lines_message);
            return switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };
        }

        fn markdownLinkConstructor(comptime node: markup.MarkupNode, comptime raw: []const u8) Ui.LinkMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                const expression = markup.parseMessageExpression(raw) orelse fail(node, markup.markdown_on_link_message);
                if (expression.payload.len != 0) fail(node, markup.markdown_on_link_message);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == []const u8 and std.mem.eql(u8, field.name, expression.tag)) {
                        return Ui.linkMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                fail(node, markup.markdown_on_link_message);
            }
        }

        fn markdownDetailsConstructor(comptime node: markup.MarkupNode, comptime raw: []const u8) *const fn (index: usize) MsgT {
            comptime {
                @setEvalBranchQuota(10_000);
                const expression = markup.parseMessageExpression(raw) orelse fail(node, markup.markdown_on_details_message);
                if (expression.payload.len != 0) fail(node, markup.markdown_on_details_message);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == usize and std.mem.eql(u8, field.name, expression.tag)) {
                        return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
                fail(node, markup.markdown_on_details_message);
            }
        }

        /// Resolve `details-expanded` through the same sources `for each`
        /// accepts (scope slice args shadow model iterables), requiring a
        /// bool element type at comptime.
        fn detailsExpandedItems(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const bool {
            const path = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_details_expanded_message);
                if (expression != .binding) fail(node, markup.markdown_details_expanded_message);
                break :blk expression.binding;
            };
            const scope_index_opt = comptime scopeIndex(entries, path);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg or entries[scope_index].Item != bool) {
                        fail(node, markup.markdown_details_expanded_message);
                    }
                }
                return scopePayload(entries, scope_index, scope);
            }
            const info = comptime (eachInfo(path) orelse fail(node, markup.markdown_details_expanded_message));
            comptime {
                if (info.Item != bool) fail(node, markup.markdown_details_expanded_message);
            }
            return eachItems(info, ui, model);
        }

        /// Comptime twin of the interpreter's registered-image iterable
        /// binding. Scope slice arguments shadow model iterables.
        fn markdownImageItems(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const canvas.markdown.ResolvedImage {
            const path = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.markdown_images_message);
                if (expression != .binding) fail(node, markup.markdown_images_message);
                break :blk expression.binding;
            };
            const scope_index_opt = comptime scopeIndex(entries, path);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg or entries[scope_index].Item != canvas.markdown.ResolvedImage) {
                        fail(node, markup.markdown_images_message);
                    }
                }
                return scopePayload(entries, scope_index, scope);
            }
            const info = comptime (eachInfo(path) orelse fail(node, markup.markdown_images_message));
            comptime {
                if (info.Item != canvas.markdown.ResolvedImage) fail(node, markup.markdown_images_message);
            }
            return eachItems(info, ui, model);
        }

        // ------------------------------------------------ stepper/timeline

        /// Comptime mirror of the interpreter's `buildStepper`: attrs and
        /// step structure resolve at comptime; the active index and step
        /// labels are read at runtime. Misuse fails compilation with the
        /// interpreter's message.
        fn buildStepper(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "active")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    fail(node, markup.stepper_attr_message);
                }
                if (node.attr("active") == null) fail(node, markup.stepper_active_message);
                for (node.children) |child| {
                    if (child.kind == .slot_block) {
                        if (node.children.len != 1) fail(child, markup.stepper_children_message);
                        continue;
                    }
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
                        fail(child, markup.stepper_children_message);
                    }
                    for (child.attrs) |attribute| {
                        if (!std.mem.eql(u8, attribute.name, "kind")) fail(child, markup.step_attr_message);
                    }
                }
            }
            var options: Ui.StepperOptions = .{};
            const active_raw = comptime node.attr("active").?;
            comptime requireVariant(exprVariant(node, entries, active_raw), &.{.integer}, node, markup.stepper_active_message);
            options.active = switch (evalExpr(node, entries, active_raw, ui, model, scope)) {
                .integer => |int| if (int < 0) 0 else @intCast(int),
                else => runtimeFail(usize, ui),
            };
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            const slot_index: ?usize = comptime if (node.children.len == 1 and node.children[0].kind == .slot_block) innermostSlotIndex(entries) else null;
            if (comptime (node.children.len == 1 and node.children[0].kind == .slot_block and slot_index == null)) {
                comptime fail(node.children[0], markup.slot_outside_template_message);
            }
            const step_nodes = comptime if (slot_index) |index| entries[index].slot_nodes else node.children;
            const steps = ui.arena.alloc(Ui.StepperStep, step_nodes.len) catch {
                ui.failed = true;
                return ui.el(.row, .{}, .{});
            };
            if (comptime (slot_index != null)) {
                const index = comptime slot_index.?;
                const site_scope = scopePayload(entries, index, scope);
                inline for (0..step_nodes.len) |step_index| {
                    const child = comptime step_nodes[step_index];
                    if (comptime (child.kind != .element or !std.mem.eql(u8, child.name, "step"))) fail(child, markup.stepper_children_message);
                    comptime {
                        for (child.attrs) |attribute| {
                            if (!std.mem.eql(u8, attribute.name, "kind")) fail(child, markup.step_attr_message);
                        }
                    }
                    steps[step_index] = .{ .label = interpolatedText(child, comptime entries[index].slot_entries, ui, model, site_scope) };
                }
            } else {
                inline for (0..step_nodes.len) |index| {
                    steps[index] = .{ .label = interpolatedText(comptime step_nodes[index], entries, ui, model, scope) };
                }
            }
            return ui.stepper(options, steps);
        }

        /// Comptime mirror of the interpreter's `buildInputGroup`: the
        /// closed attribute set and the static child shape (one textarea
        /// first, then at most one actions row) check at comptime with
        /// the interpreter's messages; the textarea builds through the
        /// ordinary element path and the group lowers through
        /// `Ui.inputGroup`.
        fn buildInputGroup(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    if (std.mem.eql(u8, attribute.name, "width")) continue;
                    if (std.mem.eql(u8, attribute.name, "height")) continue;
                    if (std.mem.eql(u8, attribute.name, "min-width")) continue;
                    if (std.mem.eql(u8, attribute.name, "grow")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    fail(node, markup.input_group_attr_message);
                }
                var textarea_count: usize = 0;
                var actions_count: usize = 0;
                for (node.children) |child| {
                    if (child.kind != .element) fail(child, markup.input_group_children_message);
                    if (std.mem.eql(u8, child.name, "textarea")) {
                        if (textarea_count > 0 or actions_count > 0) fail(child, markup.input_group_children_message);
                        textarea_count += 1;
                        continue;
                    }
                    if (std.mem.eql(u8, child.name, "input-group-actions")) {
                        if (textarea_count == 0) fail(child, markup.input_group_textarea_message);
                        if (actions_count > 0) fail(child, markup.input_group_children_message);
                        actions_count += 1;
                        continue;
                    }
                    fail(child, markup.input_group_children_message);
                }
                if (textarea_count == 0) fail(node, markup.input_group_textarea_message);
            }
            var options: Ui.InputGroupOptions = .{};
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            if (comptime (node.attr("width") != null)) {
                options.width = floatAttr(node, entries, comptime node.attr("width").?, ui, model, scope);
            }
            if (comptime (node.attr("height") != null)) {
                options.height = floatAttr(node, entries, comptime node.attr("height").?, ui, model, scope);
            }
            if (comptime (node.attr("min-width") != null)) {
                options.min_width = floatAttr(node, entries, comptime node.attr("min-width").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            const entry = buildElement(comptime node.children[0], entries, ui, model, scope);
            var actions: ?Ui.Node = null;
            if (comptime (node.children.len > 1)) {
                actions = buildInputGroupActions(comptime node.children[1], entries, ui, model, scope);
            }
            return ui.inputGroup(options, entry, actions);
        }

        /// Comptime mirror of the interpreter's `buildInputGroupActions`.
        fn buildInputGroupActions(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "gap")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    fail(node, markup.input_group_actions_attr_message);
                }
                for (node.children) |child| {
                    if (child.kind == .text) fail(child, markup.input_group_actions_children_message);
                }
            }
            var options: Ui.InputGroupActionsOptions = .{};
            if (comptime (node.attr("gap") != null)) {
                options.gap = floatAttr(node, entries, comptime node.attr("gap").?, ui, model, scope);
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            buildChildren(node, entries, ui, model, scope, &children);
            return ui.inputGroupActions(options, @as([]const Ui.Node, children.items));
        }

        /// Comptime mirror of the interpreter's `buildTimeline`.
        fn buildTimeline(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "gap")) continue;
                    if (std.mem.eql(u8, attribute.name, "grow")) continue;
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    fail(node, markup.timeline_attr_message);
                }
            }
            var options: Ui.TimelineOptions = .{};
            if (comptime (node.attr("gap") != null)) {
                options.gap = floatAttr(node, entries, comptime node.attr("gap").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            buildChildren(node, entries, ui, model, scope, &children);
            return ui.timeline(options, @as([]const Ui.Node, children.items));
        }

        /// Comptime mirror of the interpreter's `buildTimelineItem`.
        fn buildTimelineItem(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, forwarded_press: ?MsgT) Ui.Node {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.timeline_item_children_message);
                if (node.attr("title") == null) fail(node, markup.timeline_item_title_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "title")) continue;
                    if (std.mem.eql(u8, attribute.name, "description")) continue;
                    if (std.mem.eql(u8, attribute.name, "meta")) continue;
                    if (std.mem.eql(u8, attribute.name, "indicator")) continue;
                    if (std.mem.eql(u8, attribute.name, "icon")) continue;
                    if (std.mem.eql(u8, attribute.name, "variant")) continue;
                    if (std.mem.eql(u8, attribute.name, "connector")) continue;
                    if (std.mem.eql(u8, attribute.name, "selected")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-press")) continue;
                    if (std.mem.startsWith(u8, attribute.name, "on-")) fail(node, markup.timeline_item_press_only_message);
                    if (std.mem.eql(u8, attribute.name, "key")) continue;
                    if (std.mem.eql(u8, attribute.name, "global-key")) continue;
                    fail(node, markup.timeline_item_attr_message);
                }
            }
            var options: Ui.TimelineItemOptions = .{ .title = "" };
            options.title = stringAttr(node, entries, "title", comptime node.attr("title").?, ui, model, scope, markup.timeline_item_text_attr_message);
            if (comptime (node.attr("description") != null)) {
                options.description = stringAttr(node, entries, "description", comptime node.attr("description").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("meta") != null)) {
                options.meta = stringAttr(node, entries, "meta", comptime node.attr("meta").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("indicator") != null)) {
                options.indicator = stringAttr(node, entries, "indicator", comptime node.attr("indicator").?, ui, model, scope, markup.timeline_item_text_attr_message);
            }
            if (comptime (node.attr("icon") != null)) {
                // Vector icon indicator: the shared icon value grammar,
                // resolved at comptime like every icon attribute.
                switch (comptime iconValueChecked(node, node.attr("icon").?, markup.button_icon_message)) {
                    .builtin, .app => |name| options.icon = name,
                    .binding => options.icon = stringAttr(node, entries, "icon", comptime node.attr("icon").?, ui, model, scope, markup.button_icon_message),
                    .invalid => unreachable,
                }
            }
            if (comptime (node.attr("variant") != null)) {
                const raw = comptime node.attr("variant").?;
                comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, "expected an option name");
                const expression = comptime markup.parseAttrExpression(raw).?;
                if (comptime (expression == .literal)) {
                    options.variant = comptime (std.meta.stringToEnum(canvas.WidgetVariant, expression.literal) orelse fail(node, "unknown option value"));
                } else {
                    const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail([]const u8, ui),
                    };
                    options.variant = std.meta.stringToEnum(canvas.WidgetVariant, text) orelse runtimeFail(canvas.WidgetVariant, ui);
                }
            }
            if (comptime (node.attr("connector") != null)) {
                options.connector = evalExpr(node, entries, comptime node.attr("connector").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("selected") != null)) {
                options.selected = evalExpr(node, entries, comptime node.attr("selected").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("on-press") != null)) {
                // Reuse the full message-attr machinery (payload bindings
                // included) through a scratch options value.
                const press_index = comptime blk: {
                    for (node.attrs, 0..) |attribute, index| {
                        if (std.mem.eql(u8, attribute.name, "on-press")) break :blk index;
                    }
                    unreachable;
                };
                var scratch: Ui.ElementOptions = .{};
                applyMessageAttr(node, comptime node.attrs[press_index], entries, ui, model, scope, &scratch);
                options.on_press = scratch.on_press;
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (forwarded_press) |msg| options.on_press = msg;
            return ui.timelineItem(options);
        }

        // ---------------------------------------------------------- chart

        /// Comptime mirror of the interpreter's `buildChart`: the closed
        /// attribute set, the static series children, and every series'
        /// kind/color/values resolution happen at comptime; only the data
        /// slices and scalar bindings are read at runtime. Misuse fails
        /// compilation with the interpreter's message.
        fn buildChart(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.startsWith(u8, attribute.name, "on-")) {
                        fail(node, markup.chart_display_only_message);
                    }
                    const known = std.mem.eql(u8, attribute.name, "y-min") or
                        std.mem.eql(u8, attribute.name, "y-max") or
                        std.mem.eql(u8, attribute.name, "grid-lines") or
                        std.mem.eql(u8, attribute.name, "baseline") or
                        std.mem.eql(u8, attribute.name, "x-labels") or
                        std.mem.eql(u8, attribute.name, "y-labels") or
                        std.mem.eql(u8, attribute.name, "hover-details") or
                        std.mem.eql(u8, attribute.name, "stroke-width") or
                        std.mem.eql(u8, attribute.name, "width") or
                        std.mem.eql(u8, attribute.name, "height") or
                        std.mem.eql(u8, attribute.name, "grow") or
                        std.mem.eql(u8, attribute.name, "padding") or
                        std.mem.eql(u8, attribute.name, "key") or
                        std.mem.eql(u8, attribute.name, "global-key") or
                        std.mem.eql(u8, attribute.name, "label");
                    if (!known) fail(node, markup.chart_attr_message);
                }
                if (node.children.len == 0) fail(node, markup.chart_series_required_message);
                for (node.children) |child| {
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "series")) {
                        fail(child, markup.chart_children_message);
                    }
                }
            }
            var options: Ui.ChartOptions = .{};
            if (comptime (node.attr("y-min") != null)) {
                options.y_min = floatAttr(node, entries, comptime node.attr("y-min").?, ui, model, scope);
            }
            if (comptime (node.attr("y-max") != null)) {
                options.y_max = floatAttr(node, entries, comptime node.attr("y-max").?, ui, model, scope);
            }
            if (comptime (node.attr("grid-lines") != null)) {
                const raw = comptime node.attr("grid-lines").?;
                comptime requireVariant(exprVariant(node, entries, raw), &.{.integer}, node, "expected a whole number");
                options.grid_lines = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                    .integer => |int| if (int < 0 or int > std.math.maxInt(u8)) runtimeFail(u8, ui) else @intCast(int),
                    else => runtimeFail(u8, ui),
                };
            }
            if (comptime (node.attr("baseline") != null)) {
                options.baseline = evalExpr(node, entries, comptime node.attr("baseline").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("x-labels") != null)) {
                options.x_labels = chartLabelsItems(node, entries, comptime node.attr("x-labels").?, ui, model, scope);
            }
            if (comptime (node.attr("y-labels") != null)) {
                options.y_labels = evalExpr(node, entries, comptime node.attr("y-labels").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("hover-details") != null)) {
                options.hover_details = evalExpr(node, entries, comptime node.attr("hover-details").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("stroke-width") != null)) {
                options.stroke_width = floatAttr(node, entries, comptime node.attr("stroke-width").?, ui, model, scope);
            }
            if (comptime (node.attr("width") != null)) {
                options.width = floatAttr(node, entries, comptime node.attr("width").?, ui, model, scope);
            }
            if (comptime (node.attr("height") != null)) {
                options.height = floatAttr(node, entries, comptime node.attr("height").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("padding") != null)) {
                options.padding = floatAttr(node, entries, comptime node.attr("padding").?, ui, model, scope);
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("label") != null)) {
                options.semantics.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            const series = ui.arena.alloc(canvas.ChartSeries, node.children.len) catch {
                ui.failed = true;
                return ui.el(.row, .{}, .{});
            };
            inline for (0..node.children.len) |index| {
                series[index] = buildSeries(comptime node.children[index], entries, ui, model, scope);
            }
            return ui.chart(options, series);
        }

        /// Comptime mirror of the interpreter's `buildSeries`: kind and
        /// color are closed literal vocabularies resolved at comptime,
        /// values must name an f32 iterable, label is ordinary text.
        fn buildSeries(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) canvas.ChartSeries {
            comptime {
                if (node.children.len != 0) fail(node.children[0], markup.series_children_message);
                if (node.attr("values") == null) fail(node, markup.series_values_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    if (std.mem.eql(u8, attribute.name, "values")) continue;
                    if (std.mem.eql(u8, attribute.name, "color")) continue;
                    if (std.mem.eql(u8, attribute.name, "label")) continue;
                    fail(node, markup.series_attr_message);
                }
            }
            var series = canvas.ChartSeries{};
            if (comptime (node.attr("kind") != null)) {
                const spelled = comptime blk: {
                    const expression = markup.parseAttrExpression(node.attr("kind").?) orelse fail(node, markup.series_kind_message);
                    if (expression != .literal) fail(node, markup.series_kind_message);
                    break :blk expression.literal;
                };
                if (comptime std.mem.eql(u8, spelled, "line")) {
                    series.kind = .line;
                } else if (comptime std.mem.eql(u8, spelled, "area")) {
                    // Area is the markup spelling of a filled line.
                    series.kind = .line;
                    series.fill = true;
                } else if (comptime std.mem.eql(u8, spelled, "bar")) {
                    series.kind = .bar;
                } else {
                    comptime fail(node, markup.series_kind_message);
                }
            }
            series.values = chartValuesItems(node, entries, comptime node.attr("values").?, ui, model, scope);
            if (comptime (node.attr("color") != null)) {
                series.color = comptime blk: {
                    const expression = markup.parseAttrExpression(node.attr("color").?) orelse fail(node, markup.series_color_message);
                    if (expression != .literal) fail(node, markup.series_color_message);
                    break :blk std.meta.stringToEnum(canvas.ChartSeriesColor, expression.literal) orelse
                        fail(node, markup.series_color_message);
                };
            }
            if (comptime (node.attr("label") != null)) {
                series.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, markup.series_label_message);
            }
            return series;
        }

        // ---------------------------------------------------------- video

        /// Comptime mirror of the interpreter's `buildVideo`: the leaf
        /// shape and the closed attribute set resolve at comptime with
        /// the interpreter's messages; the src string, flags, and
        /// sizing evaluate at runtime and lower through `Ui.video`.
        fn buildVideo(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            comptime {
                if (node.children.len > 0) fail(node.children[0], markup.video_children_message);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "kind")) continue;
                    const known = std.mem.eql(u8, attribute.name, "src") or
                        markup.videoFlagAttrName(attribute.name) or
                        std.mem.eql(u8, attribute.name, "width") or
                        std.mem.eql(u8, attribute.name, "height") or
                        std.mem.eql(u8, attribute.name, "grow") or
                        std.mem.eql(u8, attribute.name, "label") or
                        std.mem.eql(u8, attribute.name, "key") or
                        std.mem.eql(u8, attribute.name, "global-key");
                    if (!known) fail(node, markup.video_attr_message);
                }
            }
            var options: Ui.VideoOptions = .{};
            if (comptime (node.attr("src") != null)) {
                options.src = stringAttr(node, entries, "src", comptime node.attr("src").?, ui, model, scope, markup.video_src_message);
            }
            if (comptime (node.attr("controls") != null)) {
                options.controls = videoFlagValue(node, entries, comptime node.attr("controls").?, ui, model, scope);
            }
            if (comptime (node.attr("autoplay") != null)) {
                options.autoplay = videoFlagValue(node, entries, comptime node.attr("autoplay").?, ui, model, scope);
            }
            if (comptime (node.attr("loop") != null)) {
                options.loop = videoFlagValue(node, entries, comptime node.attr("loop").?, ui, model, scope);
            }
            if (comptime (node.attr("muted") != null)) {
                options.muted = videoFlagValue(node, entries, comptime node.attr("muted").?, ui, model, scope);
            }
            if (comptime (node.attr("width") != null)) {
                options.width = floatAttr(node, entries, comptime node.attr("width").?, ui, model, scope);
            }
            if (comptime (node.attr("height") != null)) {
                options.height = floatAttr(node, entries, comptime node.attr("height").?, ui, model, scope);
            }
            if (comptime (node.attr("grow") != null)) {
                options.grow = floatAttr(node, entries, comptime node.attr("grow").?, ui, model, scope);
            }
            if (comptime (node.attr("label") != null)) {
                options.label = stringAttr(node, entries, "label", comptime node.attr("label").?, ui, model, scope, "label expects text");
            }
            if (comptime (node.attr("key") != null)) {
                options.key = attrKey(node, entries, comptime node.attr("key").?, ui, model, scope, "keys must be integers or strings");
            }
            if (comptime (node.attr("global-key") != null)) {
                options.global_key = attrKey(node, entries, comptime node.attr("global-key").?, ui, model, scope, "keys must be integers or strings");
            }
            return ui.video(options);
        }

        /// One video flag's value (interpreter parity): bare presence
        /// declares true, a valued flag evaluates truthy.
        fn videoFlagValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) bool {
            if (comptime (raw.len == 0)) return true;
            return evalExpr(node, entries, raw, ui, model, scope).truthy();
        }

        /// Resolve a chart `x-labels` binding through the same sources
        /// `for each` accepts, requiring a string element type at
        /// comptime — the label twin of `chartValuesItems`.
        fn chartLabelsItems(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const []const u8 {
            const path = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.chart_x_labels_message);
                if (expression != .binding) fail(node, markup.chart_x_labels_message);
                break :blk expression.binding;
            };
            const scope_index_opt = comptime scopeIndex(entries, path);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg or entries[scope_index].Item != []const u8) {
                        fail(node, markup.chart_x_labels_message);
                    }
                }
                return scopePayload(entries, scope_index, scope);
            }
            const info = comptime (eachInfo(path) orelse fail(node, markup.chart_x_labels_message));
            comptime {
                if (info.Item != []const u8) fail(node, markup.chart_x_labels_message);
            }
            return eachItems(info, ui, model);
        }

        /// Resolve a series `values` binding through the same sources
        /// `for each` accepts (scope slice args shadow model iterables),
        /// requiring an f32 or f64 element type at comptime. f64
        /// iterables narrow into a build-arena f32 copy per sample (the
        /// interpreter's `f32Items` rule): transpiled TS cores carry
        /// every number array as f64 — the subset's one float class —
        /// and refusing them would leave markup charts unreachable from
        /// a TS model.
        fn chartValuesItems(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) []const f32 {
            const path = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.series_values_message);
                if (expression != .binding) fail(node, markup.series_values_message);
                break :blk expression.binding;
            };
            const scope_index_opt = comptime scopeIndex(entries, path);
            if (comptime (scope_index_opt != null)) {
                const scope_index = comptime scope_index_opt.?;
                comptime {
                    if (entries[scope_index].kind != .slice_arg or
                        (entries[scope_index].Item != f32 and entries[scope_index].Item != f64))
                    {
                        fail(node, markup.series_values_message);
                    }
                }
                return narrowedSeriesValues(entries[scope_index].Item, scopePayload(entries, scope_index, scope), ui);
            }
            const info = comptime (eachInfo(path) orelse fail(node, markup.series_values_message));
            comptime {
                if (info.Item != f32 and info.Item != f64) fail(node, markup.series_values_message);
            }
            return narrowedSeriesValues(info.Item, eachItems(info, ui, model), ui);
        }

        /// f32 series values pass through; f64 values copy down into the
        /// build arena (charts plot f32).
        fn narrowedSeriesValues(comptime Item: type, items: []const Item, ui: *Ui) []const f32 {
            if (comptime (Item == f32)) return items;
            const narrowed = ui.arena.alloc(f32, items.len) catch {
                ui.failed = true;
                return &.{};
            };
            for (narrowed, items) |*slot, value| slot.* = @floatCast(value);
            return narrowed;
        }

        /// Comptime icon-value classification with the invalid arm turned
        /// into a positioned compile error: the icon leaf, the inline
        /// icon attribute, and the timeline-item indicator all funnel
        /// through the one shared grammar (`markup.iconValueOf`).
        fn iconValueChecked(comptime node: markup.MarkupNode, comptime raw: []const u8, comptime base_message: []const u8) markup.IconValue {
            comptime {
                const value = markup.iconValueOf(raw, base_message);
                if (value == .invalid) fail(node, value.invalid);
                return value;
            }
        }

        fn stringAttr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime attribute_name: []const u8, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime message: []const u8) []const u8 {
            comptime requireVariant(attrExprVariant(node, entries, attribute_name, raw), &.{.string}, node, message);
            return switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };
        }

        fn floatAttr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) f32 {
            comptime requireVariant(exprVariant(node, entries, raw), &.{ .float, .integer }, node, "expected a number");
            return switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .float => |float| float,
                .integer => |int| @floatFromInt(int),
                else => runtimeFail(f32, ui),
            };
        }

        // ------------------------------------------------------ templates

        /// A `<use>` arg as resolved at comptime against the use site: a
        /// scalar `Value` (literal, equality, scalar binding, or the
        /// declaration's literal default when the use site omits it) or a
        /// slice (a model iterable path, or a slice arg re-passed from an
        /// enclosing template).
        const ArgSpec = struct {
            name: []const u8,
            raw: []const u8,
            kind: Kind,
            Item: type = void,
            variant: ?ValueVariant = null,
            each: ?EachInfo = null,
            site_index: ?usize = null,
            /// True when `raw` is the declaration's default literal (the
            /// use site omitted the arg): evaluated as a literal, never
            /// parsed as an expression.
            defaulted: bool = false,

            const Kind = enum { value, slice };
        };

        /// Expand a `<use>` site: resolve the template, check its declared
        /// args against the use attributes, evaluate the args against the
        /// use-site scope, and inline the template's single element child
        /// in place — structural ids hash through the parent chain at the
        /// expansion site, exactly as if the body were written inline. The
        /// body's scope holds the args plus the slot capture (the use-site
        /// children and the consumer's scope chain, consumed by the body's
        /// `<slot/>`), never the use site's loop variables directly.
        fn buildUse(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) Ui.Node {
            const template_name = comptime (node.attr("template") orelse fail(node, markup.use_template_attr_message));
            const template_index = comptime (document.templateIndex(template_name) orelse fail(node, markup.use_undefined_template_message));
            const template_node = comptime document.templates[template_index];
            comptime {
                if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                    fail(template_node, markup.template_one_child_message);
                }
                if (node.children.len != 0 and markup.templateSlot(template_node) == null) {
                    fail(node.children[0], markup.use_children_without_slot_message);
                }
            }
            const specs = comptime useArgSpecs(node, template_node, entries);
            const body_entries = comptime (argEntries(specs) ++ &[_]ScopeEntry{.{
                .name = "",
                .kind = .slot,
                .slot_nodes = node.children,
                .slot_entries = entries,
                .SiteScope = @TypeOf(scope),
            }});
            const body_scope = .{
                .parent = buildArgScope(specs, entries, node, ui, model, scope),
                .item = scope,
            };
            const forwarded_press: ?MsgT = if (comptime (node.attr("on-press") != null)) blk: {
                const press_attr = comptime node.attrEntry("on-press").?;
                var scratch: Ui.ElementOptions = .{};
                applyMessageAttr(node, press_attr, entries, ui, model, scope, &scratch);
                break :blk scratch.on_press;
            } else null;
            return buildElementWithForwardedPress(comptime template_node.children[0], body_entries, ui, model, body_scope, forwarded_press);
        }

        fn useArgSpecs(comptime node: markup.MarkupNode, comptime template_node: markup.MarkupNode, comptime site_entries: []const ScopeEntry) []const ArgSpec {
            comptime {
                @setEvalBranchQuota(10_000);
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "template")) continue;
                    if (std.mem.eql(u8, attribute.name, "on-press")) continue;
                    if (std.mem.startsWith(u8, attribute.name, "on-")) {
                        fail(node, markup.use_forwarded_event_message);
                    }
                    if (!markup.templateDeclaresArg(template_node, attribute.name)) {
                        fail(node, markup.use_extra_arg_message);
                    }
                }
                var specs: []const ArgSpec = &.{};
                var args = markup.templateArgs(template_node);
                while (args.next()) |token| {
                    const arg = markup.parseTemplateArg(token);
                    if (node.attr(arg.name)) |raw| {
                        specs = specs ++ &[_]ArgSpec{argSpec(node, site_entries, arg.name, raw)};
                        continue;
                    }
                    const default = arg.default orelse fail(node, markup.use_missing_arg_message);
                    // Defaults are literals only — a default cannot see
                    // any scope (interpreter and validator parity).
                    if (std.mem.indexOfScalar(u8, default, '{') != null) {
                        fail(template_node, markup.template_default_literal_message);
                    }
                    // Quotes are not string delimiters in a default; they
                    // would render verbatim (interpreter and validator
                    // parity).
                    if (default.len > 0 and (default[0] == '\'' or default[0] == '"')) {
                        fail(template_node, markup.template_default_quoted_message);
                    }
                    specs = specs ++ &[_]ArgSpec{.{
                        .name = arg.name,
                        .raw = default,
                        .kind = .value,
                        .variant = literalVariant(default),
                        .defaulted = true,
                    }};
                }
                return specs;
            }
        }

        fn literalVariant(comptime text: []const u8) ValueVariant {
            return switch (interpreter.literalValue(text)) {
                .string => .string,
                .integer => .integer,
                .float => .float,
                .boolean => .boolean,
            };
        }

        /// Comptime mirror of the interpreter's `argPayload` resolution
        /// order: scope entries shadow model iterables; a binding naming
        /// an iterable becomes a slice arg, anything else a value arg.
        fn argSpec(comptime node: markup.MarkupNode, comptime site_entries: []const ScopeEntry, comptime arg_name: []const u8, comptime raw: []const u8) ArgSpec {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message);
                if (expression == .binding) {
                    const path = expression.binding;
                    const head = interpreter.pathHead(path);
                    if (scopeIndex(site_entries, head)) |index| {
                        if (site_entries[index].kind == .slice_arg and interpreter.pathTail(path) == null) {
                            return .{ .name = arg_name, .raw = raw, .kind = .slice, .Item = site_entries[index].Item, .site_index = index };
                        }
                    } else if (eachInfo(path)) |info| {
                        // Strings stay scalars (interpreter parity): a
                        // binding producing []const u8 binds as a value
                        // arg, never as an iterable of bytes.
                        if (info.Item != u8) {
                            return .{ .name = arg_name, .raw = raw, .kind = .slice, .Item = info.Item, .each = info };
                        }
                    }
                }
                return .{ .name = arg_name, .raw = raw, .kind = .value, .variant = exprVariant(node, site_entries, raw) };
            }
        }

        fn argEntries(comptime specs: []const ArgSpec) []const ScopeEntry {
            comptime {
                var entries: []const ScopeEntry = &.{};
                for (specs) |spec| {
                    entries = entries ++ &[_]ScopeEntry{switch (spec.kind) {
                        .value => .{ .name = spec.name, .kind = .value_arg, .variant = spec.variant, .defaulted = spec.defaulted },
                        .slice => .{ .name = spec.name, .kind = .slice_arg, .Item = spec.Item },
                    }};
                }
                return entries;
            }
        }

        fn ArgPayload(comptime spec: ArgSpec) type {
            return switch (spec.kind) {
                .value => Value,
                .slice => []const spec.Item,
            };
        }

        /// The scope chain type for a template body: one link per arg,
        /// nothing from the use site — a template sees the model and its
        /// args, never the loop variables where it is used.
        fn ArgScope(comptime specs: []const ArgSpec) type {
            if (specs.len == 0) return struct {};
            return struct {
                parent: ArgScope(specs[0 .. specs.len - 1]),
                item: ArgPayload(specs[specs.len - 1]),
            };
        }

        fn buildArgScope(comptime specs: []const ArgSpec, comptime site_entries: []const ScopeEntry, comptime node: markup.MarkupNode, ui: *Ui, model: *const ModelT, site_scope: anytype) ArgScope(specs) {
            if (comptime (specs.len == 0)) return .{};
            return .{
                .parent = buildArgScope(comptime specs[0 .. specs.len - 1], site_entries, node, ui, model, site_scope),
                .item = argPayloadValue(comptime specs[specs.len - 1], site_entries, node, ui, model, site_scope),
            };
        }

        fn argPayloadValue(comptime spec: ArgSpec, comptime site_entries: []const ScopeEntry, comptime node: markup.MarkupNode, ui: *Ui, model: *const ModelT, site_scope: anytype) ArgPayload(spec) {
            if (comptime (spec.kind == .slice)) {
                if (comptime (spec.site_index != null)) {
                    return scopePayload(site_entries, comptime spec.site_index.?, site_scope);
                }
                return eachItems(comptime spec.each.?, ui, model);
            }
            if (comptime spec.defaulted) {
                // The declaration's literal default, exactly as the
                // interpreter evaluates it.
                return comptime interpreter.literalValue(spec.raw);
            }
            return evalExpr(node, site_entries, spec.raw, ui, model, site_scope);
        }

        // -------------------------------------------------- `for` sources

        const EachKind = enum { field, decl_slice, decl_fn, decl_fn_arena };
        const EachInfo = struct { Item: type, kind: EachKind, name: []const u8 };

        /// Comptime mirror of the interpreter's `iterateItems` resolution:
        /// a Model slice/array field, a public array/slice declaration, or
        /// a public function returning a slice (optionally taking an
        /// arena).
        fn eachInfo(comptime each: []const u8) ?EachInfo {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(ModelT).@"struct".fields) |field| {
                    if (!std.mem.eql(u8, field.name, each)) continue;
                    if (interpreter.sliceElement(field.type)) |Element| {
                        return .{ .Item = Element, .kind = .field, .name = field.name };
                    }
                }
                for (@typeInfo(ModelT).@"struct".decls) |decl| {
                    if (!std.mem.eql(u8, decl.name, each)) continue;
                    const DeclType = @TypeOf(@field(ModelT, decl.name));
                    if (interpreter.sliceElement(DeclType)) |Element| {
                        return .{ .Item = Element, .kind = .decl_slice, .name = decl.name };
                    }
                    switch (@typeInfo(DeclType)) {
                        .@"fn" => |fn_info| {
                            const Return = fn_info.return_type orelse continue;
                            const Element = interpreter.sliceElement(Return) orelse continue;
                            if (interpreter.isItemFn(DeclType, Element, false)) {
                                return .{ .Item = Element, .kind = .decl_fn, .name = decl.name };
                            }
                            if (interpreter.isItemFn(DeclType, Element, true)) {
                                return .{ .Item = Element, .kind = .decl_fn_arena, .name = decl.name };
                            }
                        },
                        else => {},
                    }
                }
                return null;
            }
        }

        fn eachItems(comptime info: EachInfo, ui: *Ui, model: *const ModelT) []const info.Item {
            return switch (comptime info.kind) {
                .field => interpreter.asSlice(info.Item, &@field(model, info.name)),
                .decl_slice => interpreter.asSlice(info.Item, &@field(ModelT, info.name)),
                .decl_fn => @field(ModelT, info.name)(model),
                .decl_fn_arena => @field(ModelT, info.name)(model, ui.arena),
            };
        }

        fn itemKey(comptime Item: type, comptime node: markup.MarkupNode, comptime field_path: []const u8, ui: *Ui, item: *const Item) canvas.UiKey {
            // Keys stay identity-stable data: fields and zero-arg
            // methods only, never arena-computed values (the interpreter
            // resolves keys with a null arena for the same reason).
            const Leaf = comptime (OnType(Item, field_path, false) orelse fail(node, "key does not name a field on the item"));
            comptime requireVariant(bindingVariant(Leaf), &.{ .integer, .string }, node, "key fields must be integers or strings");
            const value = interpreter.valueOf(Leaf, valueOn(Item, field_path, item, ui.arena)) orelse unreachable;
            return uiKeyFromValue(value);
        }

        // ---------------------------------------------------- attributes

        fn applyAttrs(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            applyImageSourceAttrs(node, entries, ui, model, scope, options);
            inline for (0..node.attrs.len) |attr_index| {
                const attribute = comptime node.attrs[attr_index];
                if (comptime std.mem.eql(u8, attribute.name, "kind")) {
                    // Engine hint for tooling; the interpreter skips it too.
                } else if (comptime std.mem.startsWith(u8, attribute.name, "on-")) {
                    applyMessageAttr(node, attribute, entries, ui, model, scope, options);
                } else if (comptime std.mem.eql(u8, attribute.name, "key")) {
                    options.key = attrKey(node, entries, attribute.value, ui, model, scope, "keys must be integers or strings");
                } else if (comptime std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = attrKey(node, entries, attribute.value, ui, model, scope, "keys must be integers or strings");
                } else if (comptime std.mem.eql(u8, attribute.name, "role")) {
                    options.semantics.role = roleValue(node, entries, attribute.value, ui, model, scope);
                } else if (comptime std.mem.eql(u8, attribute.name, "label")) {
                    comptime requireVariant(attrExprVariant(node, entries, attribute.name, attribute.value), &.{.string}, node, "label expects text");
                    options.semantics.label = switch (attrExprValue(node, entries, attribute.name, attribute.value, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail([]const u8, ui),
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "image")) {
                    applyImageAttr(node, attribute.value, entries, ui, model, scope, options);
                } else if (comptime markup.imageSourceAttrName(attribute.name)) {
                    // Consumed atomically by applyImageSourceAttrs above.
                } else if (comptime std.mem.eql(u8, attribute.name, "surface")) {
                    applySurfaceAttr(node, attribute.value, entries, ui, model, scope, options);
                } else if (comptime std.mem.eql(u8, attribute.name, "pty")) {
                    applyPtyAttr(node, attribute.value, entries, ui, model, scope, options);
                } else if (comptime (std.mem.eql(u8, attribute.name, "scrollback") and !std.mem.eql(u8, node.name, "terminal"))) {
                    // Terminal-scoped (validator parity for unvalidated
                    // paths): anywhere else the option is inert data.
                    comptime fail(node, markup.scrollback_element_message);
                } else if (comptime (std.mem.eql(u8, attribute.name, "text") and std.mem.eql(u8, node.name, "terminal"))) {
                    // Runtime-owned text channel (interpreter and
                    // validator parity).
                    comptime fail(node, markup.terminal_text_attr_message);
                } else if (comptime markup.videoFlagAttrName(attribute.name)) {
                    // The video element's flags, video-scoped (its own
                    // build consumed them): anywhere else they would be
                    // silently inert (interpreter and validator parity).
                    comptime fail(node, markup.video_flag_element_message);
                } else if (comptime std.mem.eql(u8, attribute.name, "name")) {
                    // Consumed by the icon branch in buildElement; a
                    // compile error on any other element (interpreter and
                    // validator parity).
                    comptime if (!std.mem.eql(u8, node.name, "icon")) fail(node, markup.icon_name_element_message);
                } else if (comptime std.mem.eql(u8, attribute.name, "icon")) {
                    // Inline icon scoped to the labeled interactive
                    // elements (button, toggle-button, list-item,
                    // menu-item): the same icon value grammar as
                    // <icon name>, checked at comptime so a built-in typo
                    // is a compile error (interpreter and validator
                    // parity); app: names and bound names resolve at draw
                    // time.
                    comptime if (!markup.iconAttrElement(node.name)) fail(node, markup.button_icon_element_message);
                    switch (comptime iconValueChecked(node, attribute.value, markup.button_icon_message)) {
                        .builtin, .app => |name| options.icon = name,
                        .binding => options.icon = stringAttr(node, entries, attribute.name, attribute.value, ui, model, scope, markup.button_icon_message),
                        .invalid => unreachable,
                    }
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor")) {
                    // Anchored floating placement, dropdown-menu-scoped:
                    // a literal side resolved at comptime (interpreter
                    // and validator parity).
                    options.anchor = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        break :blk std.meta.stringToEnum(canvas.WidgetAnchorPlacement, attribute.value) orelse
                            fail(node, markup.anchor_value_message);
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    options.anchor_alignment = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        if (node.attr("anchor") == null) fail(node, markup.anchor_dependent_attr_message);
                        break :blk std.meta.stringToEnum(canvas.WidgetAnchorAlignment, attribute.value) orelse
                            fail(node, markup.anchor_alignment_value_message);
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    options.anchor_offset = comptime blk: {
                        if (!markup.anchorElement(node.name)) fail(node, markup.anchor_element_message);
                        if (node.attr("anchor") == null) fail(node, markup.anchor_dependent_attr_message);
                        break :blk std.fmt.parseFloat(f32, attribute.value) catch
                            fail(node, markup.anchor_offset_value_message);
                    };
                } else if (comptime std.mem.eql(u8, attribute.name, "quiet-hover")) {
                    // The quiet-surface knob (`WidgetStyle.quiet_hover`)
                    // for image-forward content tiles: hover wash off,
                    // press/selection fills, focus ring, cursor intent,
                    // and hit testing untouched. Hit-target elements only
                    // (interpreter and validator parity); applied to
                    // `options.style`, so no flat option field backs it.
                    comptime if (!markup.hitTargetElement(node.name)) fail(node, markup.quiet_hover_element_message);
                    options.style.quiet_hover = evalExpr(node, entries, attribute.value, ui, model, scope).truthy();
                } else if (comptime (colorStyleField(attribute.name) != null)) {
                    // Style token refs resolve entirely at comptime: a typo
                    // in a token name is a compile error.
                    @field(options.style_tokens, colorStyleField(attribute.name).?) =
                        comptime colorTokenRef(node, attribute.value);
                } else if (comptime std.mem.eql(u8, attribute.name, "radius")) {
                    options.style_tokens.radius = comptime radiusTokenRef(node, attribute.value);
                } else {
                    setOption(node, comptime optionFieldName(node, attribute.name), attribute.name, attribute.value, entries, ui, model, scope, options);
                }
            }
        }

        /// Comptime mirror of the interpreter's `applyImageAttr`:
        /// `image="{binding}"` on avatar and image resolves to a `u64`
        /// ImageId the app registered at runtime — binding-only, and
        /// the binding must produce an integer, all checked at comptime
        /// with the interpreter's messages.
        fn applyImageAttr(comptime node: markup.MarkupNode, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            comptime {
                if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) fail(node, markup.image_binding_element_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.image_binding_message);
                if (expression != .binding) fail(node, markup.image_binding_message);
            }
            const path = comptime markup.parseAttrExpression(raw).?.binding;
            comptime requireVariant(pathVariant(node, entries, path, true), &.{.integer}, node, markup.image_binding_message);
            // Range-checked before the u64 cast (the interpreter fails
            // the same way): a signed model field (`image: i64 = -1`)
            // can deliver a negative — fail the build, never trap.
            options.image = switch (bindingValue(node, entries, path, ui, model, scope, true)) {
                .integer => |int| if (int < 0) runtimeFail(canvas.ImageId, ui) else @intCast(int),
                else => runtimeFail(canvas.ImageId, ui),
            };
        }

        /// Comptime mirror of the interpreter's atomic source-rectangle
        /// construction. Source-known shape mistakes are compile errors;
        /// bound numeric values evaluate through the shared expression
        /// path at runtime.
        fn applyImageSourceAttrs(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            const has_any = comptime blk: {
                for (markup.image_source_attr_names) |name| {
                    if (node.attr(name) != null) break :blk true;
                }
                break :blk false;
            };
            if (comptime !has_any) return;
            comptime {
                if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                    fail(node, markup.image_source_element_message);
                }
                if (node.attr("image") == null) fail(node, markup.image_source_binding_message);
                for (markup.image_source_attr_names) |name| {
                    if (node.attr(name) == null) fail(node, markup.image_source_complete_message);
                }
            }
            options.image_src = .{
                .x = floatAttr(node, entries, comptime node.attr("source-x").?, ui, model, scope),
                .y = floatAttr(node, entries, comptime node.attr("source-y").?, ui, model, scope),
                .width = floatAttr(node, entries, comptime node.attr("source-width").?, ui, model, scope),
                .height = floatAttr(node, entries, comptime node.attr("source-height").?, ui, model, scope),
            };
        }

        /// Comptime mirror of the interpreter's `applySurfaceAttr`:
        /// `surface="{binding}"` on media-surface resolves to the
        /// model-owned u64 surface id a producer targets —
        /// media-surface-only, binding-only, integer-valued, all checked
        /// at comptime with the interpreter's messages. The id rides
        /// `options.image` into `Widget.image_id`, the media surface's
        /// surface-id channel.
        fn applySurfaceAttr(comptime node: markup.MarkupNode, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            comptime {
                if (!std.mem.eql(u8, node.name, "media-surface")) fail(node, markup.media_surface_surface_element_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.media_surface_surface_message);
                if (expression != .binding) fail(node, markup.media_surface_surface_message);
            }
            const path = comptime markup.parseAttrExpression(raw).?.binding;
            comptime requireVariant(pathVariant(node, entries, path, true), &.{.integer}, node, markup.media_surface_surface_message);
            // Range-checked before the u64 cast (the interpreter fails
            // the same way): a signed model field (`surface: i64 = -1`)
            // can deliver a negative — fail the build, never trap.
            options.image = switch (bindingValue(node, entries, path, ui, model, scope, true)) {
                .integer => |int| if (int < 0) runtimeFail(canvas.ImageId, ui) else @intCast(int),
                else => runtimeFail(canvas.ImageId, ui),
            };
        }

        /// `pty="{binding}"` on terminal resolves to the model-owned u64
        /// pty effect key whose session the terminal renders —
        /// terminal-only, binding-only, integer-valued, all checked at
        /// comptime with the interpreter's messages (the media-surface
        /// `surface` grammar exactly). The key rides `options.pty` into
        /// `Widget.terminal.pty`.
        fn applyPtyAttr(comptime node: markup.MarkupNode, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            comptime {
                if (!std.mem.eql(u8, node.name, "terminal")) fail(node, markup.terminal_pty_element_message);
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.terminal_pty_message);
                if (expression != .binding) fail(node, markup.terminal_pty_message);
            }
            const path = comptime markup.parseAttrExpression(raw).?.binding;
            comptime requireVariant(pathVariant(node, entries, path, true), &.{.integer}, node, markup.terminal_pty_message);
            // Range-checked before the u64 cast (the interpreter fails
            // the same way): a signed model field can deliver a negative
            // — fail the build, never trap.
            options.pty = switch (bindingValue(node, entries, path, ui, model, scope, true)) {
                .integer => |int| if (int < 0) runtimeFail(u64, ui) else @intCast(int),
                else => runtimeFail(u64, ui),
            };
        }

        fn colorStyleField(comptime attr_name: []const u8) ?[]const u8 {
            comptime {
                @setEvalBranchQuota(10_000);
                for (interpreter.color_style_attr_fields) |entry| {
                    if (std.mem.eql(u8, attr_name, entry.markup)) return entry.zig;
                }
                return null;
            }
        }

        fn styleTokenLiteral(comptime node: markup.MarkupNode, comptime raw: []const u8) []const u8 {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, markup.style_token_literal_message);
                if (expression != .literal) fail(node, markup.style_token_literal_message);
                return expression.literal;
            }
        }

        fn colorTokenRef(comptime node: markup.MarkupNode, comptime raw: []const u8) canvas.ColorTokenName {
            comptime {
                return std.meta.stringToEnum(canvas.ColorTokenName, styleTokenLiteral(node, raw)) orelse
                    fail(node, markup.unknown_color_token_message);
            }
        }

        fn radiusTokenRef(comptime node: markup.MarkupNode, comptime raw: []const u8) canvas.RadiusTokenName {
            comptime {
                return std.meta.stringToEnum(canvas.RadiusTokenName, styleTokenLiteral(node, raw)) orelse
                    fail(node, markup.unknown_radius_token_message);
            }
        }

        fn optionFieldName(comptime node: markup.MarkupNode, comptime attr_name: []const u8) []const u8 {
            comptime {
                @setEvalBranchQuota(10_000);
                for (interpreter.attr_names) |name| {
                    if (std.mem.eql(u8, attr_name, name.markup)) return name.zig;
                }
                fail(node, "unknown attribute for this element");
            }
        }

        fn setOption(comptime node: markup.MarkupNode, comptime zig_field: []const u8, comptime attribute_name: []const u8, comptime raw: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            const FieldType = @FieldType(Ui.ElementOptions, zig_field);
            const variant = comptime attrExprVariant(node, entries, attribute_name, raw);
            switch (comptime @typeInfo(FieldType)) {
                .float => {
                    comptime requireVariant(variant, &.{ .float, .integer }, node, "expected a number");
                    @field(options, zig_field) = switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                        .float => |float| float,
                        .integer => |int| @floatFromInt(int),
                        else => runtimeFail(FieldType, ui),
                    };
                },
                .bool => @field(options, zig_field) = attrExprValue(node, entries, attribute_name, raw, ui, model, scope).truthy(),
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .bool => @field(options, zig_field) = attrExprValue(node, entries, attribute_name, raw, ui, model, scope).truthy(),
                    .float => {
                        comptime requireVariant(variant, &.{ .float, .integer }, node, "expected a number");
                        @field(options, zig_field) = switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                            .float => |float| float,
                            .integer => |int| @floatFromInt(int),
                            else => runtimeFail(optional.child, ui),
                        };
                    },
                    else => runtimeFail(optional.child, ui),
                },
                .int => {
                    comptime requireVariant(variant, &.{.integer}, node, "expected a whole number");
                    // Range-checked against the field's own integer type
                    // before the cast (the grid-lines pattern; the
                    // interpreter fails the same way): expression values
                    // are i64, so a literal or model binding can deliver
                    // 2147483648 to the i32 tooltip-delay — an unchecked
                    // @intCast TRAPPED on it instead of failing the
                    // build. The field type is the honest upper bound;
                    // no semantic cap is invented on top of it.
                    @field(options, zig_field) = switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                        .integer => |int| if (int < 0 or int > std.math.maxInt(FieldType)) runtimeFail(FieldType, ui) else @intCast(int),
                        else => runtimeFail(FieldType, ui),
                    };
                },
                .@"enum" => {
                    comptime requireVariant(variant, &.{.string}, node, "expected an option name");
                    const expression = comptime markup.parseAttrExpression(raw).?;
                    if (comptime (expression == .literal)) {
                        // Literal option names resolve at comptime: a typo
                        // is a compile error, not a failed rebuild.
                        @field(options, zig_field) = comptime (std.meta.stringToEnum(FieldType, expression.literal) orelse fail(node, "unknown option value"));
                    } else {
                        const text = switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                            .string => |text| text,
                            else => runtimeFail([]const u8, ui),
                        };
                        @field(options, zig_field) = std.meta.stringToEnum(FieldType, text) orelse runtimeFail(FieldType, ui);
                    }
                },
                .pointer => {
                    comptime requireVariant(variant, &.{.string}, node, "expected text");
                    @field(options, zig_field) = switch (attrExprValue(node, entries, attribute_name, raw, ui, model, scope)) {
                        .string => |text| text,
                        else => runtimeFail(FieldType, ui),
                    };
                },
                else => comptime fail(node, "attribute is not settable from markup"),
            }
        }

        fn attrKey(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime message: []const u8) ?canvas.UiKey {
            comptime requireVariant(exprVariant(node, entries, raw), &.{ .integer, .string }, node, message);
            const omitted_default = comptime blk: {
                const expression = markup.parseAttrExpression(raw) orelse break :blk false;
                if (expression != .binding) break :blk false;
                const path = expression.binding;
                if (interpreter.pathTail(path) != null) break :blk false;
                const index = scopeIndex(entries, interpreter.pathHead(path)) orelse break :blk false;
                break :blk entries[index].defaulted;
            };
            return optionalUiKeyFromValue(evalExpr(node, entries, raw, ui, model, scope), ui, omitted_default);
        }

        fn uiKeyFromValue(value: Value) canvas.UiKey {
            return switch (value) {
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                .string => |text| canvas.uiKey(text),
                else => unreachable,
            };
        }

        fn optionalUiKeyFromValue(value: Value, ui: *Ui, omitted_default: bool) ?canvas.UiKey {
            return switch (value) {
                // Keys are identity, not quantities: a negative integer
                // id maps bijectively into the u64 key space (the
                // interpreter's itemKey/attrKey rule), never a trap.
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                // Empty defaults are the template-language spelling for an
                // omitted optional key; preserve unkeyed structural identity.
                .string => |text| if (text.len == 0 and omitted_default) null else canvas.uiKey(text),
                else => blk: {
                    ui.failed = true;
                    break :blk null;
                },
            };
        }

        fn roleValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) canvas.WidgetRole {
            comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, "role expects a role name");
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
            if (comptime (expression == .literal)) {
                return comptime (std.meta.stringToEnum(canvas.WidgetRole, expression.literal) orelse fail(node, "unknown role"));
            }
            const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                .string => |text| text,
                else => runtimeFail([]const u8, ui),
            };
            return std.meta.stringToEnum(canvas.WidgetRole, text) orelse runtimeFail(canvas.WidgetRole, ui);
        }

        // ------------------------------------------------------ messages

        fn applyMessageAttr(comptime node: markup.MarkupNode, comptime attribute: markup.MarkupAttr, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: *Ui.ElementOptions) void {
            const expression = comptime (markup.parseMessageExpression(attribute.value) orelse fail(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")"));
            const event = comptime attribute.name[3..];
            if (comptime std.mem.eql(u8, event, "input")) {
                options.on_input = comptime (inputConstructor(expression.tag) orelse fail(node, "on-input tag must carry a TextInputEvent payload"));
                return;
            }
            if (comptime std.mem.eql(u8, event, "scroll")) {
                comptime {
                    if (!std.mem.eql(u8, node.name, "scroll")) fail(node, markup.on_scroll_element_message);
                }
                options.on_scroll = comptime (scrollConstructor(expression.tag) orelse
                    // The retired one-axis record gets the migration
                    // teaching (it names the new per-axis fields) instead
                    // of the generic payload rejection.
                    fail(node, if (legacyScrollTag(expression.tag)) markup.on_scroll_legacy_payload_message else markup.on_scroll_payload_message));
                return;
            }
            if (comptime std.mem.eql(u8, event, "terminal")) {
                comptime {
                    if (!std.mem.eql(u8, node.name, "terminal")) fail(node, markup.on_terminal_element_message);
                    // Bare tag only: the runtime supplies the payload, so
                    // an authored one would be silently discarded.
                    if (expression.payload.len > 0) fail(node, markup.on_terminal_payload_message);
                }
                options.on_terminal = comptime (terminalConstructor(expression.tag) orelse fail(node, markup.on_terminal_payload_message));
                return;
            }
            if (comptime std.mem.eql(u8, event, "resize")) {
                comptime {
                    if (!std.mem.eql(u8, node.name, "split")) fail(node, markup.on_resize_element_message);
                }
                options.on_resize = comptime (resizeConstructor(expression.tag) orelse fail(node, markup.on_resize_payload_message));
                return;
            }
            if (comptime std.mem.eql(u8, event, "drag")) {
                options.on_drag = constructDragMessage(node, expression, entries, ui, model, scope);
                return;
            }
            // The value-payload change event: a slider's `on-change` with a
            // bare tag naming a value-carrying arm dispatches the APPLIED
            // value through the `on_value` constructor (the `on-resize`
            // fraction mechanism) instead of a static Msg. Void arms keep
            // the static form below (interpreter parity).
            if (comptime (std.mem.eql(u8, event, "change") and std.mem.eql(u8, node.name, "slider") and expression.payload.len == 0)) {
                if (comptime valueConstructor(expression.tag)) |make| {
                    options.on_value = make;
                    return;
                }
            }
            const msg = constructMessage(node, expression, entries, ui, model, scope);
            if (comptime std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (comptime std.mem.eql(u8, event, "double-press")) {
                options.on_double_press = msg;
            } else if (comptime std.mem.eql(u8, event, "toggle")) {
                options.on_toggle = msg;
            } else if (comptime std.mem.eql(u8, event, "change")) {
                options.on_change = msg;
            } else if (comptime std.mem.eql(u8, event, "submit")) {
                options.on_submit = msg;
            } else if (comptime std.mem.eql(u8, event, "dismiss")) {
                // Only dismissible surfaces are ever dismissed by the
                // runtime (interpreter and validator parity).
                comptime {
                    if (!markup.dismissEventElement(node.name)) fail(node, markup.on_dismiss_element_message);
                }
                options.on_dismiss = msg;
            } else if (comptime std.mem.eql(u8, event, "hold")) {
                // Press family: like on-press, a bound hold makes any
                // element pressable.
                options.on_hold = msg;
            } else if (comptime std.mem.eql(u8, event, "hover-enter")) {
                // Hover family: binding either edge makes any element
                // hover-hittable (never pressable), so both are legal
                // everywhere like the press family (interpreter parity).
                options.on_hover_enter = msg;
            } else if (comptime std.mem.eql(u8, event, "hover-leave")) {
                options.on_hover_leave = msg;
            } else if (comptime std.mem.eql(u8, event, "reach-end")) {
                // The approach-end signal (infinite-scroll fetch) is
                // emitted for scroll containers only (interpreter and
                // validator parity).
                comptime {
                    if (!std.mem.eql(u8, node.name, "scroll")) fail(node, markup.on_reach_end_element_message);
                }
                options.on_reach_end = msg;
            } else {
                comptime fail(node, "unknown event attribute");
            }
        }

        fn inputConstructor(comptime tag: []const u8) ?Ui.InputMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == canvas.TextInputEvent and std.mem.eql(u8, field.name, tag)) {
                        return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                    // A declared mirror of the event union (transpiled
                    // cores, where type identity cannot cross the emission
                    // boundary): translated at dispatch, same handler shape.
                    if (interpreter.declaredTextInputUnion(field.type) and std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedInputMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
                return null;
            }
        }

        fn scrollConstructor(comptime tag: []const u8) ?Ui.ScrollMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == canvas.ScrollState and std.mem.eql(u8, field.name, tag)) {
                        return Ui.scrollMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                    // A declared mirror of the scroll-state record
                    // (transpiled cores, where type identity cannot cross
                    // the emission boundary): translated at dispatch, same
                    // handler shape.
                    if (interpreter.declaredScrollStateRecord(field.type) and std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedScrollMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
                return null;
            }
        }

        fn terminalConstructor(comptime tag: []const u8) ?Ui.TerminalMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == canvas.TerminalState and std.mem.eql(u8, field.name, tag)) {
                        return Ui.terminalMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                    // A declared mirror of the terminal-state record
                    // (transpiled cores): translated at dispatch, same
                    // handler shape.
                    if (interpreter.declaredTerminalStateRecord(field.type) and std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedTerminalMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
                return null;
            }
        }

        /// Whether `tag` names an arm carrying the RETIRED one-axis
        /// scroll record — recognized only so the on-scroll rejection
        /// can teach the two-axis migration by field name.
        fn legacyScrollTag(comptime tag: []const u8) bool {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (interpreter.declaredLegacyScrollStateRecord(field.type) and std.mem.eql(u8, field.name, tag)) {
                        return true;
                    }
                }
                return false;
            }
        }

        fn resizeConstructor(comptime tag: []const u8) ?Ui.ValueMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    if (field.type == f32 and std.mem.eql(u8, field.name, tag)) {
                        return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                    // A declared one-number float arm (transpiled cores):
                    // the fraction widens exactly at dispatch. Integer
                    // arms stay excluded — a 0..1 fraction rounded into
                    // an integer would be silently useless data.
                    if (field.type == f64 and std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
                return null;
            }
        }

        /// The slider `on-change` value form: an arm carrying the applied
        /// 0..1 fraction as `f32` (the canvas-native shape) or the
        /// transpiled one-number float arm (`f64`, widened exactly).
        /// Interpreter parity.
        fn valueConstructor(comptime tag: []const u8) ?Ui.ValueMsgFn {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields) |field| {
                    const class = interpreter.valueArmClass(field.type) orelse continue;
                    if (!std.mem.eql(u8, field.name, tag)) continue;
                    return switch (class) {
                        .identity => Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name)),
                        .float => Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type),
                    };
                }
                return null;
            }
        }

        fn msgTagIndex(comptime tag: []const u8) ?usize {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(MsgT).@"union".fields, 0..) |field, index| {
                    if (std.mem.eql(u8, field.name, tag)) return index;
                }
                return null;
            }
        }

        fn constructMessage(comptime node: markup.MarkupNode, comptime expression: markup.MessageExpression, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) MsgT {
            const tag_index = comptime (msgTagIndex(expression.tag) orelse fail(node, "unknown message tag"));
            const field = comptime @typeInfo(MsgT).@"union".fields[tag_index];
            if (comptime (field.type == void)) {
                comptime {
                    if (expression.payload.len > 0) fail(node, "message does not take a payload");
                }
                return @unionInit(MsgT, field.name, {});
            }
            comptime {
                if (expression.payload.len == 0) fail(node, "message requires a payload");
            }
            const variant = comptime pathVariant(node, entries, expression.payload, true);
            const value = bindingValue(node, entries, expression.payload, ui, model, scope, true);
            return @unionInit(MsgT, field.name, coerce(field.type, node, variant, ui, value));
        }

        fn constructDragMessage(comptime node: markup.MarkupNode, comptime expression: markup.MessageExpression, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) MsgT {
            comptime {
                if (expression.payload.len == 0) fail(node, markup.on_drag_payload_message);
            }
            const tag_index = comptime (msgTagIndex(expression.tag) orelse fail(node, markup.on_drag_payload_message));
            const field = comptime @typeInfo(MsgT).@"union".fields[tag_index];
            comptime {
                if (!interpreter.declaredWidgetDragDropRecord(field.type)) fail(node, markup.on_drag_payload_message);
            }
            const variant = comptime pathVariant(node, entries, expression.payload, true);
            const value = bindingValue(node, entries, expression.payload, ui, model, scope, true);
            var payload: field.type = std.mem.zeroes(field.type);
            payload.sourceId = coerce(@FieldType(field.type, "sourceId"), node, variant, ui, value);
            return @unionInit(MsgT, field.name, payload);
        }

        /// Runtime mirror of the interpreter's `coerce`, with the
        /// type-determined mismatches promoted to compile errors. Only
        /// value-dependent conversions (optional bindings, enum tags from
        /// arbitrary strings) can still fail, latching `ui.failed`.
        fn coerce(comptime T: type, comptime node: markup.MarkupNode, comptime variant: ?ValueVariant, ui: *Ui, value: Value) T {
            switch (comptime @typeInfo(T)) {
                .int => {
                    comptime requireVariant(variant, &.{.integer}, node, "payload type does not match the message");
                    // Range-checked against the payload's own integer
                    // type before the cast (the interpreter fails the
                    // same way): a binding's i64 can deliver a negative
                    // to an unsigned payload or overflow a small one.
                    // Signed payloads keep their negative range.
                    return switch (value) {
                        .integer => |int| if (int < std.math.minInt(T) or int > std.math.maxInt(T)) runtimeFail(T, ui) else @intCast(int),
                        else => runtimeFail(T, ui),
                    };
                },
                .float => {
                    comptime requireVariant(variant, &.{ .float, .integer }, node, "payload type does not match the message");
                    return switch (value) {
                        .float => |float| @floatCast(float),
                        .integer => |int| @floatFromInt(int),
                        else => runtimeFail(T, ui),
                    };
                },
                .@"enum" => {
                    comptime requireVariant(variant, &.{.string}, node, "payload type does not match the message");
                    return switch (value) {
                        .string => |text| std.meta.stringToEnum(T, text) orelse runtimeFail(T, ui),
                        else => runtimeFail(T, ui),
                    };
                },
                .pointer => {
                    comptime requireVariant(variant, &.{.string}, node, "payload type does not match the message");
                    return switch (value) {
                        .string => |text| text,
                        else => runtimeFail(T, ui),
                    };
                },
                .bool => return value.truthy(),
                else => comptime fail(node, "payload type does not match the message"),
            }
        }

        // --------------------------------------------------- expressions

        const invalid_expression_message = markup.invalid_expression_message;

        fn attrExprValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime attribute_name: []const u8, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) Value {
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
            if (comptime (expression == .literal)) {
                return comptime interpreter.literalValueForAttribute(expression.literal, attribute_name);
            }
            return evalExpr(node, entries, raw, ui, model, scope);
        }

        fn evalExpr(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) Value {
            const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
            if (comptime (expression == .literal)) {
                return comptime interpreter.literalValue(expression.literal);
            }
            if (comptime (expression == .binding)) {
                return bindingValue(node, entries, comptime expression.binding, ui, model, scope, true);
            }
            if (comptime (expression == .expression)) {
                return evalExpressionTree(node, entries, comptime expression.expression, ui, model, scope);
            }
            // Arena-computed bindings are excluded from equality on
            // purpose (same rule as the interpreter): comparing freshly
            // formatted strings is a smell — compare source fields, or
            // bind a bool-returning fn.
            const sides = comptime expression.equals;
            return .{ .boolean = Value.eql(
                bindingValue(node, entries, sides.left, ui, model, scope, false),
                bindingValue(node, entries, sides.right, ui, model, scope, false),
            ) };
        }

        /// Evaluate a full `{expression}`: the tree parses at comptime
        /// (syntax, bounds, function names/arity are compile errors with
        /// the evaluator's teaching messages), binding nodes resolve
        /// through the same comptime-unrolled path access as bare
        /// bindings, and the SHARED evaluator computes the result at
        /// runtime — identical Value inputs through identical arithmetic
        /// and formatting code as the interpreter, so results match bit
        /// for bit. Value-dependent failures (division by zero, overflow)
        /// latch `ui.failed` exactly like the engine's other runtime
        /// conversions.
        fn evalExpressionTree(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime inner: []const u8, ui: *Ui, model: *const ModelT, scope: anytype) Value {
            const tree = comptime parsedExpression(node, inner);
            // Static type discipline: definite mismatches are compile
            // errors carrying the same message the interpreter reports.
            _ = comptime expressionTreeVariant(node, entries, inner);
            var values: [markup.expr.max_expression_nodes]Value = undefined;
            inline for (0..markup.expr.max_expression_nodes) |index| {
                if (comptime (index < tree.len and tree.nodes[index].kind == .binding)) {
                    // Comparison operands reject arena-computed scalars,
                    // the same teaching rule as `{a == b}`.
                    values[index] = bindingValue(node, entries, comptime tree.nodes[index].text, ui, model, scope, comptime !tree.nodes[index].comparison_operand);
                }
            }
            const outcome = markup.expr.eval(&tree, &values, ui.arena) catch {
                ui.failed = true;
                return .{ .boolean = false };
            };
            return switch (outcome) {
                .value => |value| value,
                .fail => blk: {
                    ui.failed = true;
                    break :blk .{ .boolean = false };
                },
            };
        }

        fn parsedExpression(comptime node: markup.MarkupNode, comptime inner: []const u8) markup.expr.ExprTree {
            comptime {
                @setEvalBranchQuota(4_000 + inner.len * 400);
                var tree: markup.expr.ExprTree = .{};
                var diagnostic: markup.expr.Diagnostic = .{};
                if (!markup.expr.parse(inner, &tree, &diagnostic)) fail(node, diagnostic.message);
                const frozen = tree;
                return frozen;
            }
        }

        /// The comptime-known result kind of a full expression: binding
        /// kinds come from the same leaf-type resolution as bare bindings
        /// (so an unresolvable path is a compile error with the
        /// interpreter's message), and the shared type checker promotes
        /// every definite mismatch to a compile error.
        fn expressionTreeVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime inner: []const u8) ?ValueVariant {
            comptime {
                @setEvalBranchQuota(4_000 + inner.len * 400);
                const tree = parsedExpression(node, inner);
                var kinds: [markup.expr.max_expression_nodes]?markup.expr.ValueKind = @splat(null);
                for (tree.nodes[0..tree.len], 0..) |expr_node, index| {
                    if (expr_node.kind != .binding) continue;
                    kinds[index] = kindFromVariant(pathVariant(node, entries, expr_node.text, !expr_node.comparison_operand));
                }
                var diagnostic: markup.expr.Diagnostic = .{};
                const result = markup.expr.checkTypes(&tree, &kinds, &diagnostic) catch fail(node, diagnostic.message);
                return variantFromKind(result);
            }
        }

        fn kindFromVariant(variant: ?ValueVariant) ?markup.expr.ValueKind {
            return switch (variant orelse return null) {
                .string => .string,
                .integer => .integer,
                .float => .float,
                .boolean => .boolean,
            };
        }

        fn variantFromKind(kind: ?markup.expr.ValueKind) ?ValueVariant {
            return switch (kind orelse return null) {
                .string => .string,
                .integer => .integer,
                .float => .float,
                .boolean => .boolean,
            };
        }

        /// The comptime-known `Value` variant an expression produces, or
        /// null when it is only runtime-known (a binding through an
        /// optional). Used to promote type mismatches to compile errors.
        fn exprVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime raw: []const u8) ?ValueVariant {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message);
                return switch (expression) {
                    .literal => |text| @as(ValueVariant, switch (interpreter.literalValue(text)) {
                        .string => .string,
                        .integer => .integer,
                        .float => .float,
                        .boolean => .boolean,
                    }),
                    .binding => |path| pathVariant(node, entries, path, true),
                    .equals => .boolean,
                    .expression => |inner| expressionTreeVariant(node, entries, inner),
                };
            }
        }

        fn attrExprVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime attribute_name: []const u8, comptime raw: []const u8) ?ValueVariant {
            comptime {
                const expression = markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message);
                if (expression == .literal) {
                    return switch (interpreter.literalValueForAttribute(expression.literal, attribute_name)) {
                        .string => .string,
                        .integer => .integer,
                        .float => .float,
                        .boolean => .boolean,
                    };
                }
                return exprVariant(node, entries, raw);
            }
        }

        /// Innermost scope entry whose name matches `head`.
        fn scopeIndex(comptime entries: []const ScopeEntry, comptime head: []const u8) ?usize {
            comptime {
                @setEvalBranchQuota(10_000);
                var index = entries.len;
                while (index > 0) {
                    index -= 1;
                    if (std.mem.eql(u8, entries[index].name, head)) return index;
                }
                return null;
            }
        }

        fn scopePayload(comptime entries: []const ScopeEntry, comptime index: usize, scope: anytype) EntryPayload(entries[index]) {
            if (comptime (index == entries.len - 1)) return scope.item;
            return scopePayload(entries[0 .. entries.len - 1], index, scope.parent);
        }

        /// Comptime mirror of the interpreter's `evalBinding` resolution
        /// for loop items and model paths: the Zig type a binding path
        /// resolves to, or a compile error with the interpreter's message.
        /// Value args have no leaf type; `pathVariant` handles them.
        /// `allow_arena` gates arena-taking scalar fns (allowed everywhere
        /// except inside `{a == b}` equality, with a teaching error).
        fn BindingLeaf(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, comptime allow_arena: bool) type {
            comptime {
                const head = interpreter.pathHead(path);
                if (scopeIndex(entries, head)) |index| {
                    const entry = entries[index];
                    if (entry.kind == .slice_arg) fail(node, "slice-valued template args are only usable with for each");
                    if (entry.kind == .value_arg) fail(node, "template arg values have no fields");
                    const Item = entry.Item;
                    if (interpreter.pathTail(path)) |tail| {
                        return OnType(Item, tail, allow_arena) orelse {
                            if (!allow_arena and OnType(Item, tail, true) != null) {
                                fail(node, markup.arena_scalar_equality_message);
                            }
                            fail(node, "binding does not name a field on the loop item");
                        };
                    }
                    if (!supportedValue(Item)) fail(node, "loop items of this type cannot be used as values");
                    return Item;
                }
                return OnType(ModelT, path, allow_arena) orelse {
                    if (!allow_arena and OnType(ModelT, path, true) != null) {
                        fail(node, markup.arena_scalar_equality_message);
                    }
                    if (interpreter.fieldIsTextBuffer(ModelT, head)) {
                        fail(node, markup.binding_text_buffer_message);
                    }
                    fail(node, "binding does not name a model field");
                };
            }
        }

        /// The comptime-known Value variant a binding path produces:
        /// template value args carry their use-site variant, loop items
        /// and model paths derive it from the resolved leaf type.
        fn pathVariant(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, comptime allow_arena: bool) ?ValueVariant {
            comptime {
                const head = interpreter.pathHead(path);
                if (scopeIndex(entries, head)) |index| {
                    if (entries[index].kind == .value_arg) {
                        if (interpreter.pathTail(path) != null) fail(node, "template arg values have no fields");
                        return entries[index].variant;
                    }
                }
                return bindingVariant(BindingLeaf(node, entries, path, allow_arena));
            }
        }

        fn bindingValue(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, comptime path: []const u8, ui: *Ui, model: *const ModelT, scope: anytype, comptime allow_arena: bool) Value {
            const head = comptime interpreter.pathHead(path);
            const index_opt = comptime scopeIndex(entries, head);
            if (comptime (index_opt != null)) {
                const index = comptime index_opt.?;
                const entry = comptime entries[index];
                if (comptime (entry.kind == .value_arg)) {
                    comptime {
                        if (interpreter.pathTail(path) != null) fail(node, "template arg values have no fields");
                    }
                    return scopePayload(entries, index, scope);
                }
                if (comptime (entry.kind == .slice_arg)) {
                    comptime fail(node, "slice-valued template args are only usable with for each");
                }
                const Leaf = comptime BindingLeaf(node, entries, path, allow_arena);
                const item = scopePayload(entries, index, scope);
                if (comptime (interpreter.pathTail(path) != null)) {
                    const tail = comptime interpreter.pathTail(path).?;
                    return interpreter.valueOf(Leaf, valueOn(entry.Item, tail, item, ui.arena)) orelse unreachable;
                }
                return interpreter.valueOf(Leaf, item.*) orelse unreachable;
            }
            const Leaf = comptime BindingLeaf(node, entries, path, allow_arena);
            return interpreter.valueOf(Leaf, valueOn(ModelT, path, model, ui.arena)) orelse unreachable;
        }

        // ----------------------------------------------- path resolution

        /// Comptime mirror of the interpreter's `resolveOn`: the type a
        /// dotted path resolves to on T — struct fields, zero-arg methods,
        /// and (when `allow_arena`) arena-taking scalar methods — or null
        /// when the path names nothing `valueOf` can represent (which is
        /// exactly when the interpreter fails).
        fn OnType(comptime OuterT: type, comptime path: []const u8, comptime allow_arena: bool) ?type {
            comptime {
                @setEvalBranchQuota(10_000);
                // Single-item const pointers are transparent
                // (`reflect.Pointee`): a `*const Row` loop item or shared
                // model node resolves like the struct it points at.
                const T = interpreter.Pointee(OuterT);
                if (@typeInfo(T) != .@"struct") return null;
                const head = interpreter.pathHead(path);
                const tail_opt = interpreter.pathTail(path);
                for (@typeInfo(T).@"struct".fields) |field| {
                    if (!std.mem.eql(u8, field.name, head)) continue;
                    if (tail_opt) |tail| {
                        if (@typeInfo(interpreter.Pointee(field.type)) != .@"struct") return null;
                        return OnType(field.type, tail, allow_arena);
                    }
                    if (!supportedValue(field.type)) return null;
                    return field.type;
                }
                for (@typeInfo(T).@"struct".decls) |decl| {
                    const DeclType = @TypeOf(@field(T, decl.name));
                    switch (@typeInfo(DeclType)) {
                        .@"fn" => |fn_info| {
                            if (fn_info.params.len == 1 and fn_info.return_type != null and fn_info.params[0].type == *const T) {
                                if (std.mem.eql(u8, decl.name, head) and tail_opt == null) {
                                    if (!supportedValue(fn_info.return_type.?)) return null;
                                    return fn_info.return_type.?;
                                }
                            }
                            if (allow_arena and interpreter.isArenaScalarFn(T, DeclType)) {
                                if (std.mem.eql(u8, decl.name, head) and tail_opt == null) {
                                    if (!supportedValue(fn_info.return_type.?)) return null;
                                    return fn_info.return_type.?;
                                }
                            }
                        },
                        else => {},
                    }
                }
                return null;
            }
        }

        /// Direct access for a path `OnType` resolved: field chains compile
        /// to member access, method leaves to a direct call (arena-taking
        /// leaves receive the build arena).
        fn valueOn(comptime T: type, comptime path: []const u8, ptr: *const T, arena: std.mem.Allocator) (OnType(T, path, true).?) {
            // Mirror OnType's `reflect.Pointee` transparency: a resolved
            // path through a single-item const pointer dereferences it and
            // continues on the struct it shares (OnType already proved the
            // pointer shape, so only const single-item pointers reach this
            // branch).
            if (comptime (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one)) {
                return valueOn(@typeInfo(T).pointer.child, path, ptr.*, arena);
            }
            const head = comptime interpreter.pathHead(path);
            if (comptime (interpreter.pathTail(path) != null)) {
                const tail = comptime interpreter.pathTail(path).?;
                return valueOn(@FieldType(T, head), tail, &@field(ptr, head), arena);
            }
            if (comptime hasField(T, head)) return @field(ptr, head);
            if (comptime interpreter.isArenaScalarFn(T, @TypeOf(@field(T, head)))) {
                return @field(T, head)(ptr, arena);
            }
            return @field(T, head)(ptr);
        }

        fn hasField(comptime T: type, comptime name: []const u8) bool {
            comptime {
                @setEvalBranchQuota(10_000);
                for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) return true;
                }
                return false;
            }
        }

        // --------------------------------------------------------- text

        const TextSegment = union(enum) {
            literal: []const u8,
            binding: []const u8,
            expression: []const u8,
        };

        fn textSegments(comptime node: markup.MarkupNode, comptime text: []const u8) []const TextSegment {
            comptime {
                @setEvalBranchQuota(comptime_text_quota_base + text.len * comptime_text_quota_per_byte);
                var segments: []const TextSegment = &.{};
                var rest = text;
                while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                    segments = segments ++ &[_]TextSegment{.{ .literal = rest[0..open] }};
                    const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse fail(node, "unterminated interpolation");
                    const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
                    if (markup.isBindingPath(inner)) {
                        segments = segments ++ &[_]TextSegment{.{ .binding = inner }};
                    } else {
                        segments = segments ++ &[_]TextSegment{.{ .expression = inner }};
                    }
                    rest = rest[close + 1 ..];
                }
                segments = segments ++ &[_]TextSegment{.{ .literal = rest }};
                return segments;
            }
        }

        const comptime_text_quota_base = 2_000;
        const comptime_text_quota_per_byte = 100;

        // ------------------------------------------------ span paragraphs

        /// Comptime mirror of the interpreter's `buildSpanParagraph`: a
        /// text element with inline `<span>` children lowers through
        /// `Ui.paragraph` — plain runs (parser-spliced separators
        /// included) keep the paragraph style, span children carry their
        /// own channels — so byte rebasing, span-aware wrapping, and
        /// semantics match a builder span paragraph exactly: the widget
        /// announces as ONE text run (spans are visual, never semantic
        /// children). Misuse fails compilation with the interpreter's
        /// message.
        fn buildSpanParagraph(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype, options: Ui.ElementOptions) Ui.Node {
            comptime {
                // A span paragraph always word-wraps (builder parity), so
                // the single-line policies are dead data here.
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "wrap") or std.mem.eql(u8, attribute.name, "overflow")) {
                        fail(node, markup.span_paragraph_wrap_message);
                    }
                }
                for (node.children) |child| {
                    if (child.kind != .text and !markup.nodeIsSpan(child)) {
                        fail(child, markup.text_inline_children_message);
                    }
                }
            }
            const spans = ui.arena.alloc(canvas.TextSpan, node.children.len) catch {
                ui.failed = true;
                return ui.el(.text, options, .{});
            };
            inline for (0..node.children.len) |index| {
                const child = comptime node.children[index];
                if (comptime (child.kind == .text)) {
                    spans[index] = .{ .text = interpolatedRun(node, comptime child.text, entries, ui, model, scope) };
                } else {
                    spans[index] = buildSpan(child, entries, ui, model, scope);
                }
            }
            return ui.paragraph(options, spans);
        }

        /// Comptime mirror of the interpreter's `buildSpan`: the shared
        /// shape check at comptime, literal weight, scale, and foreground
        /// resolved at comptime (a typo or dead multiplier is a compile
        /// error), bound weight, scale, and the flags resolved at runtime
        /// like any option attribute.
        fn buildSpan(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) canvas.TextSpan {
            comptime {
                if (markup.spanShapeError(node)) |info| failInfo(info);
            }
            var span = canvas.TextSpan{};
            if (comptime (node.attr("weight") != null)) {
                const raw = comptime node.attr("weight").?;
                const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
                if (comptime (expression == .literal)) {
                    span.weight = comptime (std.meta.stringToEnum(canvas.TextSpanWeight, expression.literal) orelse
                        fail(node, markup.span_weight_value_message));
                } else {
                    comptime requireVariant(exprVariant(node, entries, raw), &.{.string}, node, markup.span_weight_value_message);
                    const text = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .string => |value| value,
                        else => runtimeFail([]const u8, ui),
                    };
                    span.weight = std.meta.stringToEnum(canvas.TextSpanWeight, text) orelse runtimeFail(canvas.TextSpanWeight, ui);
                }
            }
            if (comptime (node.attr("scale") != null)) {
                const raw = comptime node.attr("scale").?;
                const expression = comptime (markup.parseAttrExpression(raw) orelse fail(node, invalid_expression_message));
                if (comptime (expression == .literal)) {
                    // A literal multiplier resolves at comptime; the shared
                    // shape check already proved it positive and finite.
                    span.scale = comptime (std.fmt.parseFloat(f32, expression.literal) catch
                        fail(node, markup.span_scale_value_message));
                } else {
                    // Bound scale: the binding must be a number, and the
                    // value is held to the validator's positive-finite
                    // bound (interpreter parity) — the engine draws
                    // anything else at the base size, and a silently dead
                    // binding is worse than a failed build.
                    comptime requireVariant(exprVariant(node, entries, raw), &.{ .float, .integer }, node, markup.span_scale_value_message);
                    const multiplier: f32 = switch (evalExpr(node, entries, raw, ui, model, scope)) {
                        .float => |float| float,
                        .integer => |int| @floatFromInt(int),
                        else => runtimeFail(f32, ui),
                    };
                    span.scale = if (std.math.isFinite(multiplier) and multiplier > 0) multiplier else runtimeFail(f32, ui);
                }
            }
            if (comptime (node.attr("mono") != null)) {
                span.monospace = evalExpr(node, entries, comptime node.attr("mono").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("italic") != null)) {
                span.italic = evalExpr(node, entries, comptime node.attr("italic").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("underline") != null)) {
                span.underline = evalExpr(node, entries, comptime node.attr("underline").?, ui, model, scope).truthy();
            }
            if (comptime (node.attr("foreground") != null)) {
                span.color = comptime (std.meta.stringToEnum(canvas.TextSpanColor, node.attr("foreground").?) orelse
                    fail(node, markup.unknown_color_token_message));
            }
            span.text = interpolatedRun(node, comptime node.children[0].text, entries, ui, model, scope);
            return span;
        }

        fn interpolatedText(comptime node: markup.MarkupNode, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) []const u8 {
            const text = comptime blk: {
                if (node.children.len > 1) fail(node, "text elements take a single run of text");
                var content: []const u8 = "";
                for (node.children) |child| {
                    if (child.kind != .text) {
                        // A span here sits inside a single-style label,
                        // not a paragraph (interpreter and validator
                        // parity).
                        if (markup.nodeIsSpan(child)) fail(child, markup.span_text_only_message);
                        fail(node, "text elements may only contain text");
                    }
                    content = child.text;
                }
                break :blk content;
            };
            return interpolatedRun(node, text, entries, ui, model, scope);
        }

        /// Interpolate ONE text run (`{...}` bindings and expressions)
        /// into the build arena: the shared body behind plain text leaves
        /// and every span-paragraph run. `node` positions diagnostics.
        fn interpolatedRun(comptime node: markup.MarkupNode, comptime text: []const u8, comptime entries: []const ScopeEntry, ui: *Ui, model: *const ModelT, scope: anytype) []const u8 {
            if (comptime (std.mem.indexOfScalar(u8, text, '{') == null)) return text;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            const segments = comptime textSegments(node, text);
            inline for (0..segments.len) |index| {
                const segment = comptime segments[index];
                if (comptime (segment == .literal)) {
                    out.appendSlice(ui.arena, comptime segment.literal) catch return runtimeFail([]const u8, ui);
                } else if (comptime (segment == .binding)) {
                    const value = bindingValue(node, entries, comptime segment.binding, ui, model, scope, true);
                    interpreter.appendValue(&out, ui.arena, value) catch return runtimeFail([]const u8, ui);
                } else {
                    const value = evalExpressionTree(node, entries, comptime segment.expression, ui, model, scope);
                    interpreter.appendValue(&out, ui.arena, value) catch return runtimeFail([]const u8, ui);
                }
            }
            return out.items;
        }

        // ------------------------------------------------------- values

        const ValueVariant = enum { string, integer, float, boolean };

        /// Types `valueOf` can represent, mirroring the interpreter's
        /// runtime acceptance (unsupported types make it return null, which
        /// the interpreter reports as an unresolvable binding).
        fn supportedValue(comptime T: type) bool {
            return switch (@typeInfo(T)) {
                .bool, .int, .float, .comptime_int, .@"enum" => true,
                .pointer => |info| info.size == .slice and info.child == u8,
                .optional => |info| supportedValue(info.child),
                else => false,
            };
        }

        /// The `Value` variant a leaf type produces, or null for optionals
        /// (none resolves to boolean, some to the child's variant — only
        /// known at runtime).
        fn bindingVariant(comptime T: type) ?ValueVariant {
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

        fn requireVariant(comptime variant: ?ValueVariant, comptime allowed: []const ValueVariant, comptime node: markup.MarkupNode, comptime message: []const u8) void {
            comptime {
                const known = variant orelse return; // runtime-known: checked when the value flows
                for (allowed) |candidate| {
                    if (known == candidate) return;
                }
                fail(node, message);
            }
        }

        /// A runtime conversion the interpreter would fail the build on:
        /// latch `ui.failed` (finalize surfaces it) and produce an inert
        /// placeholder that never escapes the failed build.
        fn runtimeFail(comptime T: type, ui: *Ui) T {
            ui.failed = true;
            return zeroValue(T);
        }

        fn zeroValue(comptime T: type) T {
            return switch (comptime @typeInfo(T)) {
                .int, .float => 0,
                .bool => false,
                .@"enum" => |info| @field(T, info.fields[0].name),
                .pointer => "",
                else => comptime @compileError("no placeholder for " ++ @typeName(T)),
            };
        }

        // -------------------------------------------------- diagnostics

        /// Comptime mirror of the interpreter's context-menu extraction:
        /// splits one direct `<context-menu>` child off the element (the
        /// menu is metadata, not content) after running the SAME shared
        /// checks — single menu, eligible host, and the closed item
        /// shape (`markup.contextMenuShapeError`).
        const ContextMenuSplit = struct {
            inner: markup.MarkupNode,
            menu: ?markup.MarkupNode,
        };

        fn splitContextMenuChild(comptime node: markup.MarkupNode) ContextMenuSplit {
            comptime {
                var menu: ?markup.MarkupNode = null;
                for (node.children) |child| {
                    if (!markup.nodeIsContextMenu(child)) continue;
                    if (menu != null) fail(child, markup.context_menu_single_message);
                    if (!markup.contextMenuHostEligible(node)) fail(child, markup.context_menu_host_message);
                    if (markup.contextMenuShapeError(child)) |info| failInfo(info);
                    menu = child;
                }
                if (menu == null) return .{ .inner = node, .menu = null };
                var filtered: []const markup.MarkupNode = &.{};
                for (node.children) |child| {
                    if (markup.nodeIsContextMenu(child)) continue;
                    filtered = filtered ++ &[_]markup.MarkupNode{child};
                }
                var inner = node;
                inner.children = filtered;
                return .{ .inner = inner, .menu = menu };
            }
        }

        /// Comptime mirror of the interpreter's reactions extraction:
        /// splits one direct `<reactions>` child off a bubble (the pill
        /// is chrome, not content) after the SAME shared checks — bubble
        /// host only, a single pill, and the closed shape
        /// (`markup.reactionsShapeError`).
        const ReactionsSplit = struct {
            inner: markup.MarkupNode,
            pill: ?markup.MarkupNode,
        };

        fn splitReactionsChild(comptime node: markup.MarkupNode, comptime kind: canvas.WidgetKind) ReactionsSplit {
            comptime {
                var pill: ?markup.MarkupNode = null;
                for (node.children) |child| {
                    if (!markup.nodeIsReactions(child)) continue;
                    if (kind != .bubble) fail(child, markup.reactions_parent_message);
                    if (pill != null) fail(child, markup.reactions_single_message);
                    if (markup.reactionsShapeError(child)) |info| failInfo(info);
                    pill = child;
                }
                if (pill == null) return .{ .inner = node, .pill = null };
                var filtered: []const markup.MarkupNode = &.{};
                for (node.children) |child| {
                    if (markup.nodeIsReactions(child)) continue;
                    filtered = filtered ++ &[_]markup.MarkupNode{child};
                }
                var inner = node;
                inner.children = filtered;
                return .{ .inner = inner, .pill = pill };
            }
        }

        /// `fail` from a shared shape check's positioned error info.
        fn failInfo(comptime info: markup.MarkupErrorInfo) noreturn {
            if (info.path.len > 0) {
                @compileError(std.fmt.comptimePrint("markup error in {s} at line {d}, column {d}: {s}", .{
                    info.path,
                    info.line,
                    info.column,
                    info.message,
                }));
            }
            @compileError(std.fmt.comptimePrint("markup error at line {d}, column {d}: {s}", .{
                info.line,
                info.column,
                info.message,
            }));
        }

        fn fail(comptime node: markup.MarkupNode, comptime message: []const u8) noreturn {
            if (node.src_path.len > 0) {
                @compileError(std.fmt.comptimePrint("markup error in {s} at line {d}, column {d}: {s}", .{
                    node.src_path,
                    node.line,
                    node.column,
                    message,
                }));
            }
            @compileError(std.fmt.comptimePrint("markup error at line {d}, column {d}: {s}", .{
                node.line,
                node.column,
                message,
            }));
        }
    };
}
