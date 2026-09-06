//! Markup interpreter: turns a parsed markup document into `Ui(Msg)` nodes
//! against a concrete Model/Msg pair (grammar reference:
//! skill-data/native-ui/SKILL.md).
//!
//! The document is runtime data but binding and message resolution is
//! comptime-unrolled: loop item types are collected from the Model at
//! comptime, `for` scopes carry type-erased item pointers tagged into that
//! comptime list, and paths resolve through `inline for` field/method
//! matching. A markup view builds exactly what an equivalent hand-written
//! `view(ui, model)` would: same structural ids, same handler table.

const std = @import("std");
const canvas = @import("root.zig");
const markup = @import("ui_markup.zig");
const ui_provenance = @import("ui_provenance.zig");

pub const BuildError = error{ MarkupBuild, OutOfMemory };

pub const BuildDiagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    message: []const u8 = "",
    /// Source file the position refers to (relative to the markup root),
    /// stamped by import resolution; empty for single-file documents.
    path: []const u8 = "",
};

/// A resolved binding value. Enums resolve to their tag name so equality
/// against enum-typed loop variables and literals works uniformly. Defined
/// in the expression core (ui_markup_expr.zig) and shared with the
/// comptime-compiled path so both engines convert, compare, and evaluate
/// values through the same code.
pub const Value = markup.expr.Value;

pub fn MarkupView(comptime ModelT: type, comptime MsgT: type) type {
    return struct {
        const Self = @This();
        pub const Ui = canvas.Ui(MsgT);

        document: markup.MarkupDocument,
        diagnostic: BuildDiagnostic = .{},

        pub fn init(arena: std.mem.Allocator, source: []const u8) (markup.ParseError || error{OutOfMemory})!Self {
            var parser = markup.Parser.init(arena, source);
            const document = try parser.parse();
            return .{ .document = try markup.canonicalize(arena, document) };
        }

        pub fn initDiagnostic(arena: std.mem.Allocator, source: []const u8, diagnostic: *markup.MarkupErrorInfo) (markup.ParseError || error{OutOfMemory})!Self {
            var parser = markup.Parser.init(arena, source);
            defer diagnostic.* = parser.diagnostic;
            const document = try parser.parse();
            return .{ .document = try markup.canonicalize(arena, document) };
        }

        /// Wrap an already-resolved document (the import resolver's
        /// output, or a parsed single-file document). Canonicalize it
        /// first (`markup.canonicalize`) so attribute expressions parse
        /// once instead of per frame; an uncanonicalized document builds
        /// identically through `attrTyped`'s fallback, just slower.
        pub fn fromDocument(document: markup.MarkupDocument) Self {
            return .{ .document = document };
        }

        /// Build the view for the current model. Compatible with the
        /// hand-written `view(ui, model)` shape.
        pub fn build(self: *Self, ui: *Ui, model: *const ModelT) BuildError!Ui.Node {
            if (self.document.imports.len > 0) {
                return self.failNode(self.document.imports[0], markup.import_unresolved_message);
            }
            const root = self.document.root orelse {
                self.diagnostic = .{ .line = 1, .column = 1, .message = markup.component_file_view_message };
                return error.MarkupBuild;
            };
            var scope = Scope{ .model = model, .arena = ui.arena };
            return self.buildNode(ui, &scope, root);
        }

        // ------------------------------------------------------- scopes

        /// Types a `for` loop can iterate: element types of Model slice or
        /// array fields, public array/slice declarations, and public
        /// functions returning slices (optionally taking an arena).
        const item_types = collectItemTypes(ModelT);

        /// Shared eval-branch budget for this view's Model/Msg
        /// scaled comptime walks (`inline for` over model fields/decls,
        /// msg variants, and `item_types`); see `typeScanQuota`.
        const scan_quota = typeScanQuota(ModelT) + typeScanQuota(MsgT);

        /// A named value in scope: a `for` loop item (typed pointer tagged
        /// into `item_types`), a slice-valued template arg (iterable by a
        /// `for each` inside the template), a scalar template arg (usable
        /// in bindings, interpolation, and equality), or the anonymous
        /// slot capture a `<use>` with children pushes for its body.
        const ScopeEntry = struct {
            name: []const u8,
            payload: Payload,
            defaulted: bool = false,

            const Payload = union(enum) {
                item: struct { type_index: usize, ptr: *const anyopaque },
                slice: struct { type_index: usize, ptr: *const anyopaque, len: usize },
                value: Value,
                slot: SlotCapture,
            };
        };

        /// A `<use>` site's children plus the scope state they must build
        /// under: the consumer's scope, restored when the template body
        /// reaches its `<slot/>`. Pushed with an empty name (never a
        /// binding head), so lookups skip it.
        const SlotCapture = struct {
            nodes: []const markup.MarkupNode,
            len: usize,
            floor: usize,
            template_ctx: ?usize,
            /// The use site's template chain: slot content is authored at
            /// the use site, so its provenance restores to the consumer's
            /// chain exactly like its scope does.
            chain: []const ui_provenance.UseSite = &.{},
        };

        const max_scope_depth = 16;

        const Scope = struct {
            model: *const ModelT,
            /// The build arena, threaded to arena-taking scalar binding fns
            /// (`pub fn summary(m: *const Model, arena: std.mem.Allocator)
            /// []const u8`). Strings they produce live exactly as long as
            /// the built tree.
            arena: std.mem.Allocator,
            entries: [max_scope_depth]ScopeEntry = undefined,
            len: usize = 0,
            /// Bindings resolve entries[floor..len] then the model: a
            /// template body sees its args and its own loop variables but
            /// not the loop variables at the expansion site.
            floor: usize = 0,
            /// Template expansion depth: a hard cap on runtime recursion
            /// for documents the validator never saw. Legit nesting is
            /// bounded by define-before-use (checked per expansion via
            /// `template_ctx`) plus lexical slot-content depth.
            use_depth: usize = 0,
            /// Index of the template whose body is currently building, or
            /// null in root/consumer scope. A use inside a body may only
            /// reference earlier templates (the validator's rule, enforced
            /// again here so an unvalidated document cannot recurse).
            template_ctx: ?usize = null,
            /// Template instantiation chain for provenance stamping: the
            /// `<use>` sites (outermost first) that put the node currently
            /// building where it is. Arena-allocated snapshots — pushed by
            /// `buildUse`, restored by `<slot/>` content — so every
            /// stamped `NodeSource` shares one immutable slice.
            source_chain: []const ui_provenance.UseSite = &.{},

            fn lookup(self: *const Scope, head: []const u8) ?*const ScopeEntry {
                var index = self.len;
                while (index > self.floor) {
                    index -= 1;
                    if (std.mem.eql(u8, self.entries[index].name, head)) return &self.entries[index];
                }
                return null;
            }

            /// The innermost slot capture visible to the current template
            /// body (never looks below the floor: an inner template with
            /// no use-site children must not see an outer capture).
            fn slotCapture(self: *const Scope) ?SlotCapture {
                var index = self.len;
                while (index > self.floor) {
                    index -= 1;
                    if (self.entries[index].payload == .slot) return self.entries[index].payload.slot;
                }
                return null;
            }
        };

        // ------------------------------------------------------ building

        fn buildNode(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            switch (node.kind) {
                .element => return self.buildElement(ui, scope, node),
                .use_block => return self.buildUse(ui, scope, node),
                .template_block => return self.failNode(node, markup.template_top_level_message),
                .import_block => return self.failNode(node, markup.import_top_level_message),
                .slot_block => return self.failNode(node, markup.slot_outside_template_message),
                .text => return self.failNode(node, "text content is only allowed inside text-bearing elements"),
                .for_block, .if_block, .else_block => return self.failNode(node, "structure tags are only allowed inside an element"),
            }
        }

        /// Build one element and, when the builder collects provenance,
        /// stamp the node's authored source (file, span, template chain)
        /// onto the built `Ui.Node`. Every element — composites included —
        /// funnels through here, so the stamp covers the whole vocabulary
        /// in one place. `finalize` pairs the stamp with the structural id.
        fn buildElement(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            return self.buildElementForwardedPress(ui, scope, node, null);
        }

        fn buildElementForwardedPress(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            var built = try self.buildElementInner(ui, scope, node, forwarded_press);
            if (forwarded_press) |msg| {
                // A press declared on <use> belongs to the expanded root.
                // Set it after the root-specific builder has run so generic
                // template roots become interactive as well.
                built.on_press = msg;
                built.widget.semantics.focusable = true;
            }
            if (ui.provenance_sink != null) {
                const source = try ui.arena.create(ui_provenance.NodeSource);
                source.* = .{
                    .src_path = node.src_path,
                    .span = node.span,
                    .line = node.line,
                    .column = node.column,
                    .chain = scope.source_chain,
                };
                built.source = source;
            }
            return built;
        }

        fn buildElementInner(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (std.mem.eql(u8, node.name, "markdown")) {
                return self.buildMarkdown(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "code")) {
                return self.buildCode(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "stepper")) {
                return self.buildStepper(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "step")) {
                // Steps inside a stepper are consumed by buildStepper.
                return self.failNode(node, markup.step_parent_message);
            }
            if (std.mem.eql(u8, node.name, "timeline")) {
                return self.buildTimeline(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "timeline-item")) {
                return self.buildTimelineItem(ui, scope, node, forwarded_press);
            }
            if (std.mem.eql(u8, node.name, "chart")) {
                return self.buildChart(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "series")) {
                // Series inside a chart are consumed by buildChart.
                return self.failNode(node, markup.series_parent_message);
            }
            if (std.mem.eql(u8, node.name, "video")) {
                return self.buildVideo(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "context-menu")) {
                // Direct context-menu children are consumed by their host
                // element below; one reaching here is misplaced.
                return self.failNode(node, markup.context_menu_parent_message);
            }
            if (std.mem.eql(u8, node.name, "input-group")) {
                return self.buildInputGroup(ui, scope, node);
            }
            if (std.mem.eql(u8, node.name, "input-group-actions")) {
                // Actions rows inside an input-group are consumed by
                // buildInputGroup.
                return self.failNode(node, markup.input_group_actions_parent_message);
            }
            if (std.mem.eql(u8, node.name, "span")) {
                // Spans inside a text paragraph are consumed by
                // buildSpanParagraph; one reaching here has no text
                // parent.
                return self.failNode(node, markup.span_parent_message);
            }
            if (std.mem.eql(u8, node.name, "reactions")) {
                // Reactions inside a bubble are consumed by the bubble's
                // build below; one reaching here has no bubble parent.
                return self.failNode(node, markup.reactions_parent_message);
            }
            const kind = elementKind(node.name) orelse {
                return self.failNode(node, "unknown element");
            };
            // Extract a direct context-menu child: it is metadata on this
            // element (lowered to the declared platform-menu items), not
            // content, so every content rule below sees the remaining
            // children only. Mirrors the validator and the compiled
            // engine.
            var inner = node;
            var context_menu_child: ?markup.MarkupNode = null;
            for (node.children) |child| {
                if (!markup.nodeIsContextMenu(child)) continue;
                if (context_menu_child != null) return self.failNode(child, markup.context_menu_single_message);
                if (!markup.contextMenuHostEligible(node)) return self.failNode(child, markup.context_menu_host_message);
                if (markup.contextMenuShapeError(child)) |info| {
                    self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                    return error.MarkupBuild;
                }
                context_menu_child = child;
            }
            // Extract a direct reactions child the same way: the pill is
            // bubble CHROME (it lowers onto the bubble widget's
            // chrome-text channel), not content, so every content rule
            // below sees the remaining children only. Mirrors the
            // validator and the compiled engine.
            var reactions_child: ?markup.MarkupNode = null;
            for (node.children) |child| {
                if (!markup.nodeIsReactions(child)) continue;
                if (kind != .bubble) return self.failNode(child, markup.reactions_parent_message);
                if (reactions_child != null) return self.failNode(child, markup.reactions_single_message);
                if (markup.reactionsShapeError(child)) |info| {
                    self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                    return error.MarkupBuild;
                }
                reactions_child = child;
            }
            // The bubble's chrome-text channel belongs to the reaction
            // pill; a bare text attribute would silently do nothing, so
            // it is a build error. Mirrors the validator and the
            // compiled engine.
            if (kind == .bubble) {
                if (node.attrEntry("text")) |_| {
                    return self.failNode(node, markup.bubble_text_attr_message);
                }
            }
            if (context_menu_child != null or reactions_child != null) {
                const filtered = try ui.arena.alloc(markup.MarkupNode, node.children.len);
                var filtered_len: usize = 0;
                for (node.children) |child| {
                    if (markup.nodeIsContextMenu(child)) continue;
                    if (markup.nodeIsReactions(child)) continue;
                    filtered[filtered_len] = child;
                    filtered_len += 1;
                }
                inner.children = filtered[0..filtered_len];
            }
            // Value/text handlers on non-hit-target kinds can never fire
            // (the element has no control or text behavior); reject
            // instead of silently accepting a dead handler. on-press and
            // on-toggle are exempt: a bound press handler makes any
            // element a hit target, and presses on non-interactive
            // content inside it fall through to it. Mirrors the validator
            // and the compiled engine's compile error.
            if (!canvas.widgetKindHitTarget(kind)) {
                for (node.attrs) |attribute| {
                    if (std.mem.startsWith(u8, attribute.name, "on-") and markup.deadHandlerOnNonHitTarget(attribute.name)) {
                        return self.failNode(node, markup.non_hit_target_handler_message);
                    }
                    // Autofocus can never land here: nothing about this
                    // element is focusable. Mirrors the validator and
                    // the compiled engine's compile error.
                    if (std.mem.eql(u8, attribute.name, "autofocus")) {
                        return self.failNode(node, markup.autofocus_element_message);
                    }
                }
            }
            // Stacking kinds give every child the full content box, so a
            // gap can never space them; reject the dead layout data
            // instead of silently stacking children on top of each other.
            // Mirrors the validator and the compiled engine's compile
            // error.
            if (canvas.widgetKindStacksChildren(kind)) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "gap")) {
                        return self.failNode(node, markup.stack_container_gap_message);
                    }
                }
            }
            // Only plain text leaves word-wrap or elide; anywhere else
            // the options are silently inert dead layout data. Mirrors
            // the validator and the compiled engine's compile error.
            if (kind != .text) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "wrap")) {
                        return self.failNode(node, markup.wrap_element_message);
                    }
                    if (std.mem.eql(u8, attribute.name, "overflow")) {
                        return self.failNode(node, markup.overflow_element_message);
                    }
                }
            }
            // Only textarea has a configurable Enter-vs-newline policy.
            // Mirrors validation and the compiled engine.
            if (kind != .textarea) {
                for (node.attrs) |attribute| {
                    if (std.mem.eql(u8, attribute.name, "submit-on-enter")) {
                        return self.failNode(node, markup.submit_on_enter_element_message);
                    }
                }
            }
            // The overflow policy's closed literal vocabulary. Mirrors
            // the validator and the compiled engine's compile error;
            // bindings resolve below like any enum option.
            for (node.attrs) |attribute| {
                if (!std.mem.eql(u8, attribute.name, "overflow")) continue;
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .literal) continue;
                if (!markup.nameInList(expression.literal, &markup.overflow_value_names)) {
                    return self.failNode(node, markup.overflow_value_message);
                }
            }
            // The size register's closed literal vocabulary: the control
            // scale everywhere, the typography rungs (heading/display) on
            // text only. Mirrors the validator and the compiled engine's
            // compile error; bindings resolve below like any enum option.
            for (node.attrs) |attribute| {
                if (!std.mem.eql(u8, attribute.name, "size")) continue;
                const expression = markup.parseAttrExpression(attribute.value) orelse continue;
                if (expression != .literal) continue;
                if (markup.nameInList(expression.literal, &markup.known_text_size_value_names)) {
                    if (kind != .text) {
                        return self.failNode(node, markup.text_size_element_message);
                    }
                } else if (!markup.nameInList(expression.literal, &markup.known_control_size_value_names)) {
                    return self.failNode(node, markup.size_value_message);
                }
            }
            // Splits take exactly two static pane children (the divider
            // sits between fixed panes). Mirrors the validator and the
            // compiled engine's compile error.
            if (kind == .split) {
                var pane_count: usize = 0;
                for (inner.children) |child| {
                    switch (child.kind) {
                        .element, .use_block => pane_count += 1,
                        else => return self.failNode(child, markup.split_children_message),
                    }
                }
                if (pane_count != 2) return self.failNode(node, markup.split_children_message);
            }
            // The image leaf's static shape, mirroring the validator and
            // the compiled engine's compile error. Without its id binding
            // the leaf can never draw - statically dead markup, refused
            // here too so markup that skipped validation (hot reload)
            // fails the build instead of silently rendering nothing. And
            // it takes no children at all (icon's leaf policy): checked
            // on the ORIGINAL node, so an extracted context-menu still
            // counts as a child exactly like the validator's raw-node
            // check.
            if (kind == .image) {
                if (node.attr("image") == null) {
                    return self.failNode(node, markup.image_missing_image_message);
                }
                if (node.children.len > 0) {
                    return self.failNode(node, markup.image_children_message);
                }
            }
            // The terminal leaf's static shape, the image policy exactly:
            // without its pty binding it can never attach a session, and
            // its widget has no child slots — both refused at build so
            // markup that skipped validation (hot reload) fails instead
            // of silently rendering an unbound surface or dropping the
            // child.
            if (kind == .terminal) {
                if (node.attr("pty") == null) {
                    return self.failNode(node, markup.terminal_missing_pty_message);
                }
                if (node.children.len > 0) {
                    return self.failNode(node, markup.terminal_children_message);
                }
            }
            // The a11y lint's error half: an unnamed interactive control
            // or a misused role ships a view a screen reader user cannot
            // operate, so it fails the build like any other markup
            // mistake. Mirrors the validator and the compiled engine's
            // compile error.
            if (markup.a11yNameError(node)) |message| {
                return self.failNode(node, message);
            }
            if (markup.a11yRoleError(node)) |message| {
                return self.failNode(node, message);
            }
            var options: Ui.ElementOptions = .{};
            try self.applyAttrs(scope, node, &options);
            // The extracted context-menu lowers through the ordinary
            // element path — its menu-items build like any element
            // (structure tags, interpolation, and message typing all
            // apply) — and the built nodes become the host's declared
            // items. An empty runtime result (every if false, an empty
            // for) simply declares no menu.
            if (context_menu_child) |menu_node| {
                var menu_children: std.ArrayListUnmanaged(Ui.Node) = .empty;
                try self.buildChildList(ui, scope, menu_node.children, &menu_children);
                options.context_menu = ui.contextMenuItemsFromNodes(menu_children.items);
            }

            if (kind == .icon) {
                // The shared icon value grammar, no children. Mirrors the
                // validator and the compiled engine: a built-in literal is
                // proven here (a typo can never rot), while app: names and
                // bound names ride the explicit icon channel and degrade
                // at draw time to the missing-icon fallback plus a Debug
                // warning naming the value.
                const name_attr = node.attrEntry("name") orelse return self.failNode(node, markup.icon_missing_name_message);
                if (inner.children.len > 0) return self.failNode(node, markup.icon_children_message);
                switch (markup.iconValueOf(name_attr.value, markup.icon_name_message)) {
                    .builtin => |name| {
                        var built = ui.el(kind, options, .{});
                        built.widget.text = name;
                        return built;
                    },
                    .app => |spelled| options.icon = spelled,
                    .binding => options.icon = try self.stringAttr(scope, node, name_attr, markup.icon_name_message),
                    .invalid => |message| return self.failNode(node, message),
                }
                return ui.el(kind, options, .{});
            }

            // The span paragraph: a text element with inline <span>
            // children lowers through Ui.paragraph, exactly like a
            // builder span paragraph. Mirrors the validator and the
            // compiled engine.
            if (kind == .text and markup.nodeHasSpanChildren(inner)) {
                return self.buildSpanParagraph(ui, scope, inner, options);
            }

            // The list-row composite: a text-taking element whose content
            // is element children instead of the text run flows those
            // children inside its own chrome (mixing text and elements is
            // a teaching error; the text path below would silently drop
            // the elements). Mirrors the validator and the compiled
            // engine.
            const composite_children = elementTakesChildren(kind) and markup.nodeHasElementContent(inner);
            if (composite_children) {
                for (inner.children) |child| {
                    if (child.kind == .text) return self.failNode(child, markup.text_or_children_content_message);
                }
            }
            if (elementTakesText(kind) and !composite_children) {
                var built = ui.el(kind, options, .{});
                // Element content wins when present; an empty element
                // keeps the already-resolved text= attribute in options.
                // Checkbox/radio joined this path when they became text
                // leaves, so replacing unconditionally would regress the
                // binding-friendly attribute that already worked.
                if (inner.children.len > 0) {
                    built.widget.text = try self.interpolatedText(ui, scope, inner);
                }
                // Avatars clip their runtime image to the avatar circle,
                // exactly like `Ui.avatar` (a no-op while the id is 0 and
                // the initials fallback renders).
                if (kind == .avatar) built.widget.image_fit = .cover;
                return built;
            }

            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, inner, &children);
            // Tab triggers ARE segmented controls: markup composes the
            // strip from `<button>` children (segmented-control is a
            // documented markup exclusion), and the engine lowers them to
            // the widget kind tab strips are built on — so the active
            // trigger lifts to the surface with a hairline exactly like
            // the Zig builder's tabs. Handlers ride the widget id, so
            // `selected=`/`on-press` bindings are untouched.
            if (kind == .tabs) lowerTabsTriggers(children.items);
            var built = ui.el(kind, options, @as([]const Ui.Node, children.items));
            // The extracted reactions run lands on the bubble widget's
            // chrome-text channel — the render pass draws it as the
            // docked pill — and the dock rides text_alignment (end is
            // the default: the trailing dock reactions conventionally
            // hang from). Interpolation applies to the run like any
            // text content.
            if (reactions_child) |pill_node| {
                built.widget.text = try self.interpolatedText(ui, scope, pill_node);
                built.widget.text_alignment = if (pill_node.attr("text-alignment")) |raw|
                    std.meta.stringToEnum(canvas.TextAlign, raw) orelse
                        return self.failNode(pill_node, markup.reactions_alignment_value_message)
                else
                    .end;
            }
            return built;
        }

        fn buildChildren(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            return self.buildChildList(ui, scope, node.children, out);
        }

        fn buildChildList(self: *Self, ui: *Ui, scope: *Scope, children: []const markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            var index: usize = 0;
            while (index < children.len) : (index += 1) {
                const child = children[index];
                switch (child.kind) {
                    .element => try out.append(ui.arena, try self.buildElement(ui, scope, child)),
                    .use_block => try out.append(ui.arena, try self.buildUse(ui, scope, child)),
                    .template_block => return self.failVoid(child, markup.template_top_level_message),
                    .import_block => return self.failVoid(child, markup.import_top_level_message),
                    .slot_block => try self.buildSlot(ui, scope, child, out),
                    .for_block => {
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                            else_node = children[index + 1];
                            index += 1;
                        }
                        const item_count = try self.buildFor(ui, scope, child, out);
                        if (item_count == 0) {
                            if (else_node) |else_block| {
                                try self.buildChildren(ui, scope, else_block, out);
                            }
                        }
                    },
                    .if_block => {
                        const test_attr = child.attrEntry("test") orelse {
                            return self.failVoid(child, "if requires a test attribute");
                        };
                        const condition = try self.evalAttrExpression(scope, child, test_attr);
                        var else_node: ?markup.MarkupNode = null;
                        if (index + 1 < children.len and children[index + 1].kind == .else_block) {
                            else_node = children[index + 1];
                            index += 1;
                        }
                        if (condition.truthy()) {
                            try self.buildChildren(ui, scope, child, out);
                        } else if (else_node) |else_block| {
                            try self.buildChildren(ui, scope, else_block, out);
                        }
                    },
                    .else_block => return self.failVoid(child, markup.else_placement_message),
                    .text => return self.failVoid(child, "text content is only allowed inside text-bearing elements"),
                }
            }
        }

        /// `<slot/>` in a template body: build the use-site children (the
        /// slot capture) IN THE CONSUMER'S SCOPE, inline at the slot's
        /// position — the point of slots is that content sees the model
        /// paths and loop variables where the `<use>` was written. The
        /// consumer's scope state is restored around the content build
        /// (and the body's own entries saved, since the entries array is
        /// shared), so structural ids and bindings behave exactly as if
        /// the content were built at the use site and inserted here.
        fn buildSlot(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!void {
            if (node.attrs.len > 0) return self.failVoid(node, markup.slot_attrs_message);
            if (node.children.len > 0) return self.failVoid(node.children[0], markup.slot_children_message);
            const capture = scope.slotCapture() orelse {
                if (scope.template_ctx == null) {
                    return self.failVoid(node, markup.slot_outside_template_message);
                }
                // A use with no children: the slot renders empty.
                return;
            };
            if (capture.nodes.len == 0) return;
            var saved_entries: [max_scope_depth]ScopeEntry = undefined;
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            for (scope.entries[capture.len..saved_len], 0..) |entry, offset| {
                saved_entries[offset] = entry;
            }
            const saved_chain = scope.source_chain;
            scope.len = capture.len;
            scope.floor = capture.floor;
            scope.template_ctx = capture.template_ctx;
            scope.source_chain = capture.chain;
            defer {
                for (saved_entries[0 .. saved_len - capture.len], 0..) |entry, offset| {
                    scope.entries[capture.len + offset] = entry;
                }
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.template_ctx = saved_ctx;
                scope.source_chain = saved_chain;
            }
            try self.buildChildList(ui, scope, capture.nodes, out);
        }

        /// Expands a `for` block: per item, the whole body (one or more
        /// elements, `use` expansions, and nested `for`/`if`/`else`
        /// structure) is appended to `out`. Returns the item count so the
        /// caller can render a trailing `<else>` for the empty case.
        fn buildFor(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, out: *std.ArrayListUnmanaged(Ui.Node)) BuildError!usize {
            @setEvalBranchQuota(scan_quota);
            const each = node.attr("each") orelse return self.failVoid(node, "for requires an each attribute");
            const as_name = node.attr("as") orelse return self.failVoid(node, "for requires an as attribute");
            const key_field = node.attr("key");
            if (scope.len >= max_scope_depth) return self.failVoid(node, "for nesting is too deep");
            if (node.children.len == 0) return self.failVoid(node, markup.for_children_message);
            for (node.children) |child| {
                switch (child.kind) {
                    .element, .use_block, .for_block, .if_block, .else_block, .slot_block => {},
                    else => return self.failVoid(child, markup.for_children_message),
                }
            }

            inline for (item_types, 0..) |Item, type_index| {
                if (try self.iterateItems(ui, Item, type_index, scope, each)) |items| {
                    for (items) |*item| {
                        scope.entries[scope.len] = .{
                            .name = as_name,
                            .payload = .{ .item = .{ .type_index = type_index, .ptr = @ptrCast(item) } },
                        };
                        scope.len += 1;
                        defer scope.len -= 1;

                        const first_emitted = out.items.len;
                        try self.buildChildren(ui, scope, node, out);
                        if (key_field) |field| {
                            // The item key stamps every node this item
                            // emitted (unless the node claims its own
                            // identity); later slots get a slot-suffixed
                            // key so same-kind siblings stay distinct.
                            const base = try self.itemKey(Item, item, node, field);
                            for (out.items[first_emitted..], 0..) |*built, slot| {
                                if (built.key == null and built.global_key == null) {
                                    built.key = try canvas.forSlotKey(ui.arena, base, slot);
                                }
                            }
                        }
                    }
                    return items.len;
                }
            }
            return self.failVoid(node, "each does not name an iterable (a model slice, array, or fn - or a slice-valued template arg)");
        }

        /// Resolve `each` to a slice of Item: a slice-valued template arg
        /// in scope, or on the model a field, a public array declaration,
        /// or a public function (with or without arena).
        fn iterateItems(self: *Self, ui: *Ui, comptime Item: type, comptime type_index: usize, scope: *Scope, each: []const u8) BuildError!?[]const Item {
            @setEvalBranchQuota(scan_quota);
            _ = self;
            if (scope.lookup(each)) |entry| {
                switch (entry.payload) {
                    .slice => |slice_entry| {
                        if (slice_entry.type_index != type_index) return null;
                        const items: [*]const Item = @ptrCast(@alignCast(slice_entry.ptr));
                        return items[0..slice_entry.len];
                    },
                    // The name is shadowed by a non-iterable scope entry.
                    else => return null,
                }
            }
            const model = scope.model;
            inline for (@typeInfo(ModelT).@"struct".fields) |field| {
                if (comptime sliceElement(field.type) != null and sliceElement(field.type).? == Item) {
                    if (std.mem.eql(u8, field.name, each)) {
                        return asSlice(Item, &@field(model, field.name));
                    }
                }
            }
            inline for (@typeInfo(ModelT).@"struct".decls) |decl| {
                const DeclType = @TypeOf(@field(ModelT, decl.name));
                if (comptime sliceElement(DeclType) != null and sliceElement(DeclType).? == Item) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return asSlice(Item, &@field(ModelT, decl.name));
                    }
                }
                if (comptime isItemFn(DeclType, Item, false)) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return @field(ModelT, decl.name)(model);
                    }
                }
                if (comptime isItemFn(DeclType, Item, true)) {
                    if (std.mem.eql(u8, decl.name, each)) {
                        return @field(ModelT, decl.name)(model, ui.arena);
                    }
                }
            }
            return null;
        }

        // ------------------------------------------------------- markdown

        const Md = canvas.markdown.Markdown(MsgT);

        /// `<markdown source="{body}" on-link="open_url"
        /// on-details="toggle_details" details-expanded="{flags}" />`:
        /// a leaf that renders its source binding through
        /// `native_sdk.markdown.Markdown(Msg).view`. Only `source` is
        /// required; without `on-details`/`details-expanded` the details
        /// blocks render collapsed and inert (Md.view's null defaults).
        fn buildMarkdown(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.markdown_children_message);
            }
            var options: Md.Options = .{};
            var source_text: ?[]const u8 = null;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "source")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_source_message);
                    const value = try self.evalBinding(scope, node, typed.binding, true);
                    source_text = switch (value) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.markdown_source_message),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-link")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message or typed.message.payload.len != 0) {
                        return self.failNode(node, markup.markdown_on_link_message);
                    }
                    options.on_link = linkConstructor(typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_link_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-details")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message or typed.message.payload.len != 0) {
                        return self.failNode(node, markup.markdown_on_details_message);
                    }
                    options.on_details = detailsConstructor(typed.message.tag) orelse {
                        return self.failNode(node, markup.markdown_on_details_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "details-expanded")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_details_expanded_message);
                    options.details_expanded = try self.boolItems(ui, scope, node, typed.binding);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "images")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.markdown_images_message);
                    options.images = try self.markdownImageItems(ui, scope, node, typed.binding);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "issue-link-base")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed == .equals or typed == .invalid) {
                        return self.failNode(node, markup.markdown_issue_link_base_message);
                    }
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.markdown_issue_link_base_message),
                    };
                    if (text.len > 0) options.issue_link_base = text;
                    continue;
                }
                return self.failNode(node, markup.markdown_attr_message);
            }
            const source_value = source_text orelse return self.failNode(node, markup.markdown_source_message);
            return Md.view(ui, source_value, options);
        }

        // ----------------------------------------------------------- code

        fn buildCode(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len != 0) return self.failNode(node.children[0], markup.code_children_message);
            var options: Ui.CodeOptions = .{};
            var source_text: ?[]const u8 = null;
            var added_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            var removed_lines_storage: [canvas.code.max_diff_lines]usize = undefined;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "source")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.code_source_message);
                    source_text = switch (try self.evalBinding(scope, node, typed.binding, true)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_source_message),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "language")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failNode(node, markup.code_language_message);
                    if (!canvas.code.isLanguageName(typed.literal)) return self.failNode(node, markup.code_language_message);
                    options.language = canvas.code.languageFromName(typed.literal);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "line-numbers")) {
                    options.line_numbers = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "added-lines")) {
                    const typed = markup.parseAttrExpression(attribute.value) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    const spec = if (typed == .literal)
                        typed.literal
                    else switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_diff_lines_message),
                    };
                    options.added_lines = canvas.code.parseLineNumberSpec(spec, &added_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "removed-lines")) {
                    const typed = markup.parseAttrExpression(attribute.value) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    const spec = if (typed == .literal)
                        typed.literal
                    else switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .string => |text| text,
                        else => return self.failNode(node, markup.code_diff_lines_message),
                    };
                    options.removed_lines = canvas.code.parseLineNumberSpec(spec, &removed_lines_storage) orelse
                        return self.failNode(node, markup.code_diff_lines_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "editable")) {
                    options.editable = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-input")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .message) {
                        return self.failNode(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
                    }
                    options.on_input = inputConstructor(typed.message.tag) orelse {
                        return self.failNode(node, "on-input tag must carry a TextInputEvent payload");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "wrap")) {
                    options.wrap = try self.codeFlagAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "min-width")) {
                    options.min_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.code_attr_message);
            }
            return ui.code(options, source_text orelse return self.failNode(node, markup.code_source_message));
        }

        fn codeFlagAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!bool {
            if (attribute.value.len == 0) return true;
            return (try self.evalAttrExpression(scope, node, attribute)).truthy();
        }

        // ------------------------------------------------ stepper/timeline

        /// `<stepper active="{stage_index}"><step>Work</step>...</stepper>`:
        /// the composite stage stepper. Steps are text leaves; their
        /// completed/active/pending states derive from position against
        /// the active index, mirroring `Ui.stepper`.
        fn buildStepper(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.StepperOptions = .{};
            var has_active = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "active")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.active = switch (value) {
                        .integer => |int| if (int < 0) 0 else @intCast(int),
                        else => return self.failNode(node, markup.stepper_active_message),
                    };
                    has_active = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.stepper_attr_message);
            }
            if (!has_active) return self.failNode(node, markup.stepper_active_message);

            const is_slotted = node.children.len == 1 and node.children[0].kind == .slot_block;
            const capture = if (is_slotted) scope.slotCapture() else null;
            if (is_slotted and capture == null) return self.failNode(node.children[0], markup.slot_outside_template_message);
            const step_nodes = if (capture) |captured| captured.nodes else node.children;
            const steps = try ui.arena.alloc(Ui.StepperStep, step_nodes.len);
            if (capture) |captured| {
                // Slot content is authored at the use site. Temporarily
                // restore that consumer scope so interpolated step labels
                // see the same loop variables as a direct stepper.
                var saved_entries: [max_scope_depth]ScopeEntry = undefined;
                const saved_len = scope.len;
                const saved_floor = scope.floor;
                const saved_ctx = scope.template_ctx;
                for (scope.entries[captured.len..saved_len], 0..) |entry, offset| saved_entries[offset] = entry;
                scope.len = captured.len;
                scope.floor = captured.floor;
                scope.template_ctx = captured.template_ctx;
                defer {
                    for (saved_entries[0 .. saved_len - captured.len], 0..) |entry, offset| scope.entries[captured.len + offset] = entry;
                    scope.len = saved_len;
                    scope.floor = saved_floor;
                    scope.template_ctx = saved_ctx;
                }
                for (step_nodes, 0..) |child, index| {
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) return self.failNode(child, markup.stepper_children_message);
                    for (child.attrs) |attribute| if (!std.mem.eql(u8, attribute.name, "kind")) return self.failNode(child, markup.step_attr_message);
                    steps[index] = .{ .label = try self.interpolatedText(ui, scope, child) };
                }
            } else {
                for (step_nodes, 0..) |child, index| {
                    if (child.kind != .element or !std.mem.eql(u8, child.name, "step")) {
                        return self.failNode(child, markup.stepper_children_message);
                    }
                    for (child.attrs) |attribute| {
                        if (!std.mem.eql(u8, attribute.name, "kind")) {
                            return self.failNode(child, markup.step_attr_message);
                        }
                    }
                    steps[index] = .{ .label = try self.interpolatedText(ui, scope, child) };
                }
            }
            return ui.stepper(options, steps);
        }

        /// `<input-group>` — the composer-grade grouped input: exactly
        /// one textarea child (built through the ordinary element path,
        /// so its text/placeholder/on-input/autofocus behave like any
        /// textarea) plus an optional input-group-actions row, lowered
        /// through `Ui.inputGroup` so the chrome-dissolve and
        /// focus-within treatment match Zig-built groups.
        fn buildInputGroup(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "min-width")) {
                    options.min_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.input_group_attr_message);
            }
            // The child shape is static (mirrors the validator): the
            // textarea first, then at most one actions row. Conditional
            // content belongs INSIDE the actions row.
            var entry: ?Ui.Node = null;
            var actions: ?Ui.Node = null;
            for (node.children) |child| {
                if (child.kind != .element) return self.failNode(child, markup.input_group_children_message);
                if (std.mem.eql(u8, child.name, "textarea")) {
                    if (entry != null or actions != null) return self.failNode(child, markup.input_group_children_message);
                    entry = try self.buildElement(ui, scope, child);
                    continue;
                }
                if (std.mem.eql(u8, child.name, "input-group-actions")) {
                    if (entry == null) return self.failNode(child, markup.input_group_textarea_message);
                    if (actions != null) return self.failNode(child, markup.input_group_children_message);
                    actions = try self.buildInputGroupActions(ui, scope, child);
                    continue;
                }
                return self.failNode(child, markup.input_group_children_message);
            }
            const entry_node = entry orelse return self.failNode(node, markup.input_group_textarea_message);
            return ui.inputGroup(options, entry_node, actions);
        }

        /// `<input-group-actions>` — the group's accessory row; children
        /// build through the ordinary pass (structure tags work) and
        /// lower through `Ui.inputGroupActions`.
        fn buildInputGroupActions(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.InputGroupActionsOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "gap")) {
                    options.gap = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.input_group_actions_attr_message);
            }
            for (node.children) |child| {
                if (child.kind == .text) return self.failNode(child, markup.input_group_actions_children_message);
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            return ui.inputGroupActions(options, @as([]const Ui.Node, children.items));
        }

        /// `<timeline gap="4">` — a list container whose children are
        /// timeline-item elements (structure tags work); mirrors
        /// `Ui.timeline`.
        fn buildTimeline(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.TimelineOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "gap")) {
                    options.gap = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.timeline_attr_message);
            }
            var children: std.ArrayListUnmanaged(Ui.Node) = .empty;
            try self.buildChildren(ui, scope, node, &children);
            return ui.timeline(options, @as([]const Ui.Node, children.items));
        }

        /// `<timeline-item title="{entry.title}" description="..."
        /// meta="..." variant="primary" on-press="open_step:{entry.slot}"/>`:
        /// one composite ledger item; mirrors `Ui.timelineItem`.
        fn buildTimelineItem(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, forwarded_press: ?MsgT) BuildError!Ui.Node {
            if (node.children.len != 0) {
                return self.failNode(node.children[0], markup.timeline_item_children_message);
            }
            var options: Ui.TimelineItemOptions = .{ .title = "" };
            var has_title = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "title")) {
                    options.title = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    has_title = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "description")) {
                    options.description = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "meta")) {
                    options.meta = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "indicator")) {
                    options.indicator = try self.stringAttr(scope, node, attribute, markup.timeline_item_text_attr_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    // Vector icon indicator: the shared icon value grammar,
                    // like every icon attribute.
                    switch (markup.iconValueOf(attribute.value, markup.button_icon_message)) {
                        .builtin, .app => |name| options.icon = name,
                        .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                        .invalid => |message| return self.failVoid(node, message),
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "variant")) {
                    const text = try self.stringAttr(scope, node, attribute, "expected an option name");
                    options.variant = std.meta.stringToEnum(canvas.WidgetVariant, text) orelse {
                        return self.failNode(node, "unknown option value");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "connector")) {
                    options.connector = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "selected")) {
                    options.selected = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "on-press")) {
                    // Reuse the full message-attr machinery (payload
                    // bindings included) through a scratch options value.
                    var scratch: Ui.ElementOptions = .{};
                    try self.applyMessageAttr(scope, node, &scratch, attribute);
                    options.on_press = scratch.on_press;
                    continue;
                }
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.timeline_item_press_only_message);
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.timeline_item_attr_message);
            }
            if (!has_title) return self.failNode(node, markup.timeline_item_title_message);
            if (forwarded_press) |msg| options.on_press = msg;
            return ui.timelineItem(options);
        }

        // ---------------------------------------------------------- chart

        /// `<chart y-min="0" grid-lines="4"><series kind="area"
        /// values="{cpuHistory}" color="accent"/></chart>`: the
        /// data-visualization composite, lowered through `Ui.chart` so
        /// markup charts get the same downsampling, semantics summary, and
        /// invalidation as Zig-built ones. Series values bind model
        /// iterables of f32 through the SAME resolution set as `for each`
        /// (slice-valued template args included); the series set itself is
        /// static — the data varies, the plot shape does not.
        fn buildChart(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            var options: Ui.ChartOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.chart_display_only_message);
                }
                if (std.mem.eql(u8, attribute.name, "y-min")) {
                    options.y_min = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "y-max")) {
                    options.y_max = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grid-lines")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.grid_lines = switch (value) {
                        .integer => |int| if (int < 0 or int > std.math.maxInt(u8))
                            return self.failNode(node, "expected a non-negative whole number")
                        else
                            @intCast(int),
                        else => return self.failNode(node, "expected a whole number"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "baseline")) {
                    options.baseline = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "x-labels")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failNode(node, markup.chart_x_labels_message);
                    options.x_labels = try self.stringItems(ui, scope, node, typed.binding, markup.chart_x_labels_message);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "y-labels")) {
                    options.y_labels = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "hover-details")) {
                    options.hover_details = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "stroke-width")) {
                    options.stroke_width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "padding")) {
                    options.padding = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.semantics.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                return self.failNode(node, markup.chart_attr_message);
            }
            if (node.children.len == 0) return self.failNode(node, markup.chart_series_required_message);
            const series = try ui.arena.alloc(canvas.ChartSeries, node.children.len);
            for (node.children, 0..) |child, index| {
                if (child.kind != .element or !std.mem.eql(u8, child.name, "series")) {
                    return self.failNode(child, markup.chart_children_message);
                }
                series[index] = try self.buildSeries(ui, scope, child);
            }
            return ui.chart(options, series);
        }

        // ---------------------------------------------------------- video

        /// `<video src="assets/clips/intro.mp4" controls autoplay/>`:
        /// the video playback composite, lowered through `Ui.video` so
        /// markup videos get the same playback surface, house chrome,
        /// and declaration recording as Zig-built ones. A leaf with a
        /// closed attribute set; flags accept bare presence (the
        /// boolean-attribute convention), literals, and bindings.
        fn buildVideo(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            if (node.children.len > 0) {
                return self.failNode(node.children[0], markup.video_children_message);
            }
            var options: Ui.VideoOptions = .{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.eql(u8, attribute.name, "src")) {
                    options.src = try self.stringAttr(scope, node, attribute, markup.video_src_message);
                    continue;
                }
                if (markup.videoFlagAttrName(attribute.name)) {
                    const value = try self.videoFlagAttr(scope, node, attribute);
                    if (std.mem.eql(u8, attribute.name, "controls")) {
                        options.controls = value;
                    } else if (std.mem.eql(u8, attribute.name, "autoplay")) {
                        options.autoplay = value;
                    } else if (std.mem.eql(u8, attribute.name, "loop")) {
                        options.loop = value;
                    } else {
                        options.muted = value;
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "width")) {
                    options.width = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "height")) {
                    options.height = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "grow")) {
                    options.grow = try self.floatAttr(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    options.label = try self.stringAttr(scope, node, attribute, "label expects text");
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                return self.failNode(node, markup.video_attr_message);
            }
            return ui.video(options);
        }

        /// One video flag's value: bare presence declares true, a
        /// valued flag evaluates truthy like every other flag attr.
        fn videoFlagAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!bool {
            if (attribute.value.len == 0) return true;
            return (try self.evalAttrExpression(scope, node, attribute)).truthy();
        }

        fn buildSeries(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.ChartSeries {
            if (node.children.len != 0) {
                return self.failVoid(node.children[0], markup.series_children_message);
            }
            var series = canvas.ChartSeries{};
            var has_values = false;
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) {
                    // Closed literal vocabulary: area is the markup
                    // spelling of a filled line; band stays with the
                    // builder (it needs a paired lower edge).
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failVoid(node, markup.series_kind_message);
                    if (std.mem.eql(u8, typed.literal, "line")) {
                        series.kind = .line;
                    } else if (std.mem.eql(u8, typed.literal, "area")) {
                        series.kind = .line;
                        series.fill = true;
                    } else if (std.mem.eql(u8, typed.literal, "bar")) {
                        series.kind = .bar;
                    } else {
                        return self.failVoid(node, markup.series_kind_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "values")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .binding) return self.failVoid(node, markup.series_values_message);
                    series.values = try self.f32Items(ui, scope, node, typed.binding);
                    has_values = true;
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "color")) {
                    const typed = markup.attrTyped(attribute);
                    if (typed != .literal) return self.failVoid(node, markup.series_color_message);
                    series.color = std.meta.stringToEnum(canvas.ChartSeriesColor, typed.literal) orelse {
                        return self.failVoid(node, markup.series_color_message);
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    series.label = try self.stringAttr(scope, node, attribute, markup.series_label_message);
                    continue;
                }
                return self.failVoid(node, markup.series_attr_message);
            }
            if (!has_values) return self.failVoid(node, markup.series_values_message);
            return series;
        }

        /// Resolve a series `values` binding to an f32 slice through the
        /// same sources `for each` accepts (scope slice args shadow model
        /// fields, pub decls, and fns). f64 iterables resolve too, copied
        /// down into the build arena per sample: the chart pipeline is
        /// f32, but transpiled TS cores carry every number array as f64
        /// (the subset's one float class), and refusing them would leave
        /// markup charts unreachable from a TS model.
        fn f32Items(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const f32 {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == f32)) {
                    if (try self.iterateItems(ui, f32, type_index, scope, path)) |items| {
                        return items;
                    }
                }
                if (comptime (Item == f64)) {
                    if (try self.iterateItems(ui, f64, type_index, scope, path)) |items| {
                        const narrowed = ui.arena.alloc(f32, items.len) catch {
                            return self.failText(node, markup.series_values_message);
                        };
                        for (narrowed, items) |*slot, value| slot.* = @floatCast(value);
                        return narrowed;
                    }
                }
            }
            return self.failText(node, markup.series_values_message);
        }

        fn stringAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, message: []const u8) BuildError![]const u8 {
            const value = try self.evalAttrExpression(scope, node, attribute);
            return switch (value) {
                .string => |text| text,
                else => self.failValue(node, message),
            };
        }

        fn floatAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!f32 {
            const value = try self.evalAttrExpression(scope, node, attribute);
            return switch (value) {
                .float => |float| float,
                .integer => |int| @floatFromInt(int),
                else => self.failValue(node, "expected a number"),
            };
        }

        /// Msg constructor for markdown link presses: the tag must name a
        /// `[]const u8` variant (mirrors `Ui.linkMsg`).
        fn linkConstructor(tag: []const u8) ?Ui.LinkMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == []const u8) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.linkMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        /// Msg constructor for markdown details toggles: the tag must name
        /// a `usize` variant (mirrors `Markdown(Msg).detailsMsg`).
        fn detailsConstructor(tag: []const u8) ?*const fn (index: usize) MsgT {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == usize) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Md.detailsMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                }
            }
            return null;
        }

        /// Resolve a string-list binding (chart `x-labels`) to a string
        /// slice through the same sources `for each` accepts (scope slice
        /// args shadow model fields, pub decls, and fns).
        fn stringItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8, message: []const u8) BuildError![]const []const u8 {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == []const u8)) {
                    if (try self.iterateItems(ui, []const u8, type_index, scope, path)) |items| {
                        return items;
                    }
                }
            }
            return self.failText(node, message);
        }

        /// Resolve a `details-expanded` binding to a bool slice through the
        /// same sources `for each` accepts (scope slice args shadow model
        /// fields, pub decls, and fns).
        fn boolItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const bool {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == bool)) {
                    if (try self.iterateItems(ui, bool, type_index, scope, path)) |items| {
                        return items;
                    }
                }
            }
            return self.failText(node, markup.markdown_details_expanded_message);
        }

        /// Resolve Markdown's registered source-to-image mapping through the
        /// same bounded iterable reflection used by `for each`.
        fn markdownImageItems(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, path: []const u8) BuildError![]const canvas.markdown.ResolvedImage {
            @setEvalBranchQuota(scan_quota);
            inline for (item_types, 0..) |Item, type_index| {
                if (comptime (Item == canvas.markdown.ResolvedImage)) {
                    if (try self.iterateItems(ui, Item, type_index, scope, path)) |items| {
                        return items;
                    }
                }
            }
            return self.failText(node, markup.markdown_images_message);
        }

        // ------------------------------------------------------ templates

        /// A hard cap on template expansion nesting. Legit documents are
        /// bounded structurally (see `Scope.template_ctx`); the cap turns
        /// a hostile unvalidated document into an error, never a hang.
        const max_use_depth = 128;

        /// Build a `<use>` site: evaluate the template args against the
        /// use-site scope, push them (plus the slot capture when the use
        /// has children) as scope entries, and build the template's single
        /// element child in place — structural ids hash through the parent
        /// chain at the expansion site, exactly as if the body were
        /// written inline.
        fn buildUse(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!Ui.Node {
            @setEvalBranchQuota(scan_quota);
            const template_name = node.attr("template") orelse {
                return self.failNode(node, markup.use_template_attr_message);
            };
            const template_index = self.document.templateIndex(template_name) orelse {
                return self.failNode(node, markup.use_undefined_template_message);
            };
            const template_node = self.document.templates[template_index];
            // The validator's define-before-use rule, enforced again at
            // build time: it is what makes expansion terminate, so an
            // unvalidated document must not slip past it.
            if (scope.template_ctx) |ctx_index| {
                if (template_index >= ctx_index) {
                    return self.failNode(node, markup.use_earlier_template_message);
                }
            }
            if (scope.use_depth >= max_use_depth) {
                return self.failNode(node, "template expansion nests too deeply");
            }
            if (template_node.children.len != 1 or template_node.children[0].kind != .element) {
                return self.failNode(template_node, markup.template_one_child_message);
            }
            if (markup.templateSecondSlot(template_node.children[0])) |second| {
                return self.failNode(second, markup.template_one_slot_message);
            }
            if (node.children.len != 0 and markup.templateSlot(template_node) == null) {
                return self.failNode(node.children[0], markup.use_children_without_slot_message);
            }

            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "template")) continue;
                if (std.mem.eql(u8, attribute.name, "on-press")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    return self.failNode(node, markup.use_forwarded_event_message);
                }
                if (!markup.templateDeclaresArg(template_node, attribute.name)) {
                    return self.failNode(node, markup.use_extra_arg_message);
                }
            }

            const forwarded_press = if (node.attrEntry("on-press")) |attribute| blk: {
                var scratch: Ui.ElementOptions = .{};
                try self.applyMessageAttr(scope, node, &scratch, attribute);
                break :blk scratch.on_press;
            } else null;

            // Evaluate every arg against the pristine use-site scope before
            // any entry is pushed, so args cannot see each other.
            const saved_len = scope.len;
            const saved_floor = scope.floor;
            const saved_ctx = scope.template_ctx;
            var arg_count: usize = 0;
            var args = markup.templateArgs(template_node);
            while (args.next()) |token| {
                const arg = markup.parseTemplateArg(token);
                if (saved_len + arg_count >= max_scope_depth) {
                    return self.failNode(node, "template args nest too deep");
                }
                const payload: ScopeEntry.Payload = if (node.attrEntry(arg.name)) |arg_attr|
                    try self.argPayload(ui, scope, node, arg_attr)
                else if (arg.default) |default| blk: {
                    // Defaults are literals only — a default cannot see
                    // any scope (validator and compiled-engine parity).
                    if (std.mem.indexOfScalar(u8, default, '{') != null) {
                        return self.failNode(template_node, markup.template_default_literal_message);
                    }
                    // Quotes are not string delimiters in a default; they
                    // would render verbatim (validator parity).
                    if (default.len > 0 and (default[0] == '\'' or default[0] == '"')) {
                        return self.failNode(template_node, markup.template_default_quoted_message);
                    }
                    break :blk .{ .value = literalValue(default) };
                } else return self.failNode(node, markup.use_missing_arg_message);
                scope.entries[saved_len + arg_count] = .{
                    .name = arg.name,
                    .payload = payload,
                    .defaulted = node.attrEntry(arg.name) == null and arg.default != null,
                };
                arg_count += 1;
            }
            // The slot capture: the use-site children plus the scope state
            // to build them under, consumed by the body's <slot/>.
            if (saved_len + arg_count >= max_scope_depth) {
                return self.failNode(node, "template args nest too deep");
            }
            scope.entries[saved_len + arg_count] = .{
                .name = "",
                .payload = .{ .slot = .{
                    .nodes = node.children,
                    .len = saved_len,
                    .floor = saved_floor,
                    .template_ctx = saved_ctx,
                    .chain = scope.source_chain,
                } },
            };
            arg_count += 1;

            scope.len = saved_len + arg_count;
            scope.floor = saved_len;
            scope.use_depth += 1;
            scope.template_ctx = template_index;
            // Provenance: the template body's nodes report this use site
            // (appended to any outer chain) alongside their definition
            // site, so "jump to its markup" can offer both.
            const saved_chain = scope.source_chain;
            if (ui.provenance_sink != null) {
                const chain = try ui.arena.alloc(ui_provenance.UseSite, saved_chain.len + 1);
                @memcpy(chain[0..saved_chain.len], saved_chain);
                chain[saved_chain.len] = .{
                    .src_path = node.src_path,
                    .span = node.span,
                    .line = node.line,
                    .column = node.column,
                };
                scope.source_chain = chain;
            }
            defer {
                scope.len = saved_len;
                scope.floor = saved_floor;
                scope.use_depth -= 1;
                scope.template_ctx = saved_ctx;
                scope.source_chain = saved_chain;
            }
            return self.buildElementForwardedPress(ui, scope, template_node.children[0], forwarded_press);
        }

        /// A template arg's scope payload: a `{binding}` naming an iterable
        /// (in scope or on the model, the same resolution set as
        /// `for each`) binds as a slice; anything else evaluates to a
        /// `Value` at the use site.
        fn argPayload(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!ScopeEntry.Payload {
            @setEvalBranchQuota(scan_quota);
            const typed = markup.attrTyped(attribute);
            if (typed == .invalid) {
                return self.failPayload(node, markup.invalid_expression_message);
            }
            if (typed == .binding) {
                const path = typed.binding;
                if (scope.lookup(pathHead(path))) |entry| {
                    if (entry.payload == .slice and pathTail(path) == null) {
                        // Re-pass a slice arg to a nested use.
                        return entry.payload;
                    }
                } else {
                    inline for (item_types, 0..) |Item, type_index| {
                        // Strings stay scalars: a binding producing
                        // []const u8 (a field, zero-arg fn, or arena fn)
                        // binds as a value arg, never as an iterable of
                        // bytes.
                        if (comptime (Item != u8)) {
                            if (try self.iterateItems(ui, Item, type_index, scope, path)) |items| {
                                return .{ .slice = .{
                                    .type_index = type_index,
                                    .ptr = @ptrCast(items.ptr),
                                    .len = items.len,
                                } };
                            }
                        }
                    }
                }
            }
            return .{ .value = try self.evalUnclassifiedExpression(scope, node, attribute) };
        }

        fn failPayload(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn itemKey(self: *Self, comptime Item: type, item: *const Item, node: markup.MarkupNode, field: []const u8) BuildError!canvas.UiKey {
            @setEvalBranchQuota(scan_quota);
            // Keys stay identity-stable data: fields and zero-arg methods
            // only, never arena-computed values.
            const value = resolveOn(Item, item, field, null) orelse {
                return self.failKey(node, "key does not name a field on the item");
            };
            return switch (value) {
                // Keys are identity, not quantities: a negative integer
                // id (an i64 database id, a -1 sentinel) is a distinct,
                // legitimate identity, so it maps bijectively into the
                // u64 key space instead of trapping in a signed cast.
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                .string => |text| canvas.uiKey(text),
                else => self.failKey(node, "key fields must be integers or strings"),
            };
        }

        // ---------------------------------------------------- attributes

        fn applyAttrs(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            try self.applyImageSourceAttrs(scope, node, options);
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "kind")) continue;
                if (std.mem.startsWith(u8, attribute.name, "on-")) {
                    try self.applyMessageAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "key")) {
                    options.key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "global-key")) {
                    options.global_key = try self.attrKey(scope, node, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "role")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "role expects a role name"),
                    };
                    options.semantics.role = std.meta.stringToEnum(canvas.WidgetRole, text) orelse {
                        return self.failVoid(node, "unknown role");
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "label")) {
                    const value = try self.evalAttrExpression(scope, node, attribute);
                    options.semantics.label = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "label expects text"),
                    };
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "image")) {
                    try self.applyImageAttr(scope, node, options, attribute);
                    continue;
                }
                if (markup.imageSourceAttrName(attribute.name)) continue;
                if (std.mem.eql(u8, attribute.name, "surface")) {
                    try self.applySurfaceAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "pty")) {
                    try self.applyPtyAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "scrollback") and !std.mem.eql(u8, node.name, "terminal")) {
                    // Terminal-scoped (the validator's rule, enforced
                    // here too for unvalidated paths): anywhere else the
                    // option would be silently inert data.
                    return self.failVoid(node, markup.scrollback_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "text") and std.mem.eql(u8, node.name, "terminal")) {
                    // The terminal's text channel is runtime-owned (the
                    // live screen); an authored value would clobber it
                    // and rename the control every frame.
                    return self.failVoid(node, markup.terminal_text_attr_message);
                }
                if (markup.videoFlagAttrName(attribute.name)) {
                    // The video element's flags, video-scoped (its own
                    // build consumed them): anywhere else they would be
                    // silently inert. Mirrors the validator and the
                    // compiled engine.
                    return self.failVoid(node, markup.video_flag_element_message);
                }
                if (std.mem.eql(u8, attribute.name, "name")) {
                    // Consumed by the icon branch in buildElement.
                    if (!std.mem.eql(u8, node.name, "icon")) {
                        return self.failVoid(node, markup.icon_name_element_message);
                    }
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "icon")) {
                    try self.applyButtonIconAttr(scope, node, options, attribute);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor")) {
                    try self.applyAnchorAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-alignment")) {
                    try self.applyAnchorAlignmentAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "anchor-offset")) {
                    try self.applyAnchorOffsetAttr(node, options, attribute.value);
                    continue;
                }
                if (std.mem.eql(u8, attribute.name, "quiet-hover")) {
                    try self.applyQuietHoverAttr(scope, node, options, attribute);
                    continue;
                }
                if (try self.applyStyleTokenAttr(node, options, attribute)) continue;
                if (!try self.applyOptionAttr(scope, node, options, attribute)) {
                    return self.failVoid(node, "unknown attribute for this element");
                }
            }
        }

        /// Style token references (`background="surface"`, `radius="md"`):
        /// literal token names only, validated against the token FieldEnums
        /// and resolved by the builder's `finalizeWithTokens`.
        fn applyStyleTokenAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!bool {
            inline for (color_style_attr_fields) |entry| {
                if (std.mem.eql(u8, attribute.name, entry.markup)) {
                    const literal = try self.styleTokenLiteral(node, attribute);
                    @field(options.style_tokens, entry.zig) = std.meta.stringToEnum(canvas.ColorTokenName, literal) orelse {
                        return self.failVoid(node, markup.unknown_color_token_message);
                    };
                    return true;
                }
            }
            if (std.mem.eql(u8, attribute.name, "radius")) {
                const literal = try self.styleTokenLiteral(node, attribute);
                options.style_tokens.radius = std.meta.stringToEnum(canvas.RadiusTokenName, literal) orelse {
                    return self.failVoid(node, markup.unknown_radius_token_message);
                };
                return true;
            }
            return false;
        }

        fn styleTokenLiteral(self: *Self, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError![]const u8 {
            return switch (markup.attrTyped(attribute)) {
                .literal => |text| text,
                else => self.failPayload(node, markup.style_token_literal_message),
            };
        }

        /// `image="{binding}"` on avatar and image: one binding
        /// producing a `u64` `canvas.ImageId` the app registered at
        /// runtime (`Cmd.imageLoad`, `fx.loadImage`,
        /// `fx.registerImageBytes`) — the id is model data, never a
        /// markup literal, and 0 draws nothing (an avatar keeps its
        /// initials fallback). Image-backed buttons remain a separate
        /// asset-lifecycle proposal.
        fn applyImageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                return self.failVoid(node, markup.image_binding_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.image_binding_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field (`image: i64 = -1`) can
            // deliver a negative — the teaching failure, never a trap.
            options.image = switch (value) {
                .integer => |int| if (int < 0)
                    return self.failVoid(node, markup.image_binding_message)
                else
                    @intCast(int),
                else => return self.failVoid(node, markup.image_binding_message),
            };
        }

        /// The four `source-*` attributes form one optional source
        /// rectangle in decoded-image pixel coordinates. Build it before
        /// the scalar attribute walk so declaration order carries no
        /// meaning; repeat the validator's shape checks for hot-reloaded
        /// documents that reached the interpreter without validation.
        fn applyImageSourceAttrs(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions) BuildError!void {
            var any = false;
            for (markup.image_source_attr_names) |name| {
                if (node.attr(name) != null) any = true;
            }
            if (!any) return;
            if (!std.mem.eql(u8, node.name, "avatar") and !std.mem.eql(u8, node.name, "image")) {
                return self.failVoid(node, markup.image_source_element_message);
            }
            if (node.attr("image") == null) return self.failVoid(node, markup.image_source_binding_message);
            for (markup.image_source_attr_names) |name| {
                if (node.attr(name) == null) return self.failVoid(node, markup.image_source_complete_message);
            }
            options.image_src = .{
                .x = try self.floatAttr(scope, node, node.attrEntry("source-x").?),
                .y = try self.floatAttr(scope, node, node.attrEntry("source-y").?),
                .width = try self.floatAttr(scope, node, node.attrEntry("source-width").?),
                .height = try self.floatAttr(scope, node, node.attrEntry("source-height").?),
            };
        }

        /// `surface="{binding}"` on media-surface: the model-owned u64
        /// surface id a producer targets — media-surface-only,
        /// binding-only, integer-valued (the runtime-image-id grammar
        /// exactly). The id rides `options.image` into
        /// `Widget.image_id`, the media surface's surface-id channel.
        fn applySurfaceAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "media-surface")) {
                return self.failVoid(node, markup.media_surface_surface_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.media_surface_surface_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field (`surface: i64 = -1`) can
            // deliver a negative — the teaching failure, never a trap.
            options.image = switch (value) {
                .integer => |int| if (int < 0)
                    return self.failVoid(node, markup.media_surface_surface_message)
                else
                    @intCast(int),
                else => return self.failVoid(node, markup.media_surface_surface_message),
            };
        }

        /// `pty="{binding}"` on terminal: the model-owned u64 pty effect
        /// key whose session the terminal renders — terminal-only,
        /// binding-only, integer-valued (the media-surface `surface`
        /// grammar exactly). The key rides `options.pty` into
        /// `Widget.terminal.pty`.
        fn applyPtyAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!std.mem.eql(u8, node.name, "terminal")) {
                return self.failVoid(node, markup.terminal_pty_element_message);
            }
            const typed = markup.attrTyped(attribute);
            if (typed != .binding) return self.failVoid(node, markup.terminal_pty_message);
            const value = try self.evalBinding(scope, node, typed.binding, true);
            // Range-checked before the u64 cast: expression values are
            // i64, so a signed model field can deliver a negative — the
            // teaching failure, never a trap.
            options.pty = switch (value) {
                .integer => |int| if (int < 0)
                    return self.failVoid(node, markup.terminal_pty_message)
                else
                    @intCast(int),
                else => return self.failVoid(node, markup.terminal_pty_message),
            };
        }

        /// `icon="save"` on button, toggle-button, list-item, or
        /// menu-item: the same icon value grammar as `<icon name>` — a
        /// built-in literal can never rot silently, app:<name> and one
        /// {binding} defer to the registered set and the model — drawn
        /// inside the element so icon + label are one hit target with one
        /// tint. Mirrors the validator and the compiled engine.
        fn applyButtonIconAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!markup.iconAttrElement(node.name)) {
                return self.failVoid(node, markup.button_icon_element_message);
            }
            switch (markup.iconValueOf(attribute.value, markup.button_icon_message)) {
                .builtin, .app => |name| options.icon = name,
                .binding => options.icon = try self.stringAttr(scope, node, attribute, markup.button_icon_message),
                .invalid => |message| return self.failVoid(node, message),
            }
        }

        /// `anchor="below|above"` on dropdown-menu: anchored floating
        /// placement — the surface floats against its parent's frame in
        /// the late window-level pass instead of the parent's flow.
        /// Literal placements only, mirroring the validator and the
        /// compiled engine's comptime resolution.
        fn applyAnchorAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            options.anchor = std.meta.stringToEnum(canvas.WidgetAnchorPlacement, raw) orelse {
                return self.failVoid(node, markup.anchor_value_message);
            };
        }

        fn applyAnchorAlignmentAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            if (node.attr("anchor") == null) return self.failVoid(node, markup.anchor_dependent_attr_message);
            options.anchor_alignment = std.meta.stringToEnum(canvas.WidgetAnchorAlignment, raw) orelse {
                return self.failVoid(node, markup.anchor_alignment_value_message);
            };
        }

        fn applyAnchorOffsetAttr(self: *Self, node: markup.MarkupNode, options: *Ui.ElementOptions, raw: []const u8) BuildError!void {
            if (!markup.anchorElement(node.name)) {
                return self.failVoid(node, markup.anchor_element_message);
            }
            if (node.attr("anchor") == null) return self.failVoid(node, markup.anchor_dependent_attr_message);
            options.anchor_offset = std.fmt.parseFloat(f32, raw) catch {
                return self.failVoid(node, markup.anchor_offset_value_message);
            };
        }

        /// `quiet-hover="true"` on a hit-target element: the quiet-surface
        /// knob (`WidgetStyle.quiet_hover`) for image-forward content
        /// tiles — silences ONLY the hover wash; press/selection fills,
        /// the focus ring, cursor intent, and hit testing keep their own
        /// channels. Applied to `options.style`, so no flat option field
        /// backs it (mirrors the validator and the compiled engine).
        fn applyQuietHoverAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            if (!markup.hitTargetElement(node.name)) {
                return self.failVoid(node, markup.quiet_hover_element_message);
            }
            const value = try self.evalAttrExpression(scope, node, attribute);
            options.style.quiet_hover = value.truthy();
        }

        fn applyOptionAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!bool {
            inline for (attr_names) |name| {
                if (std.mem.eql(u8, attribute.name, name.markup)) {
                    try self.setOptionField(scope, node, options, name.zig, attribute);
                    return true;
                }
            }
            return false;
        }

        fn setOptionField(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, comptime field: []const u8, attribute: markup.MarkupAttr) BuildError!void {
            const FieldType = @TypeOf(@field(options, field));
            const value = try self.evalAttrExpression(scope, node, attribute);
            switch (@typeInfo(FieldType)) {
                .float => @field(options, field) = switch (value) {
                    .float => |float| float,
                    .integer => |int| @floatFromInt(int),
                    else => return self.failVoid(node, "expected a number"),
                },
                .bool => @field(options, field) = value.truthy(),
                .optional => |optional| switch (@typeInfo(optional.child)) {
                    .bool => @field(options, field) = value.truthy(),
                    .float => @field(options, field) = switch (value) {
                        .float => |float| float,
                        .integer => |int| @floatFromInt(int),
                        else => return self.failVoid(node, "expected a number"),
                    },
                    else => return self.failVoid(node, "attribute is not settable from markup"),
                },
                // Range-checked against the FIELD's own integer type
                // before the cast (the grid-lines teaching, generalized):
                // expression values are i64, so a literal or model
                // binding can deliver 2147483648 to the i32
                // tooltip-delay — an unchecked @intCast TRAPPED on it
                // instead of failing the build. The field type is the
                // honest upper bound: no semantic millisecond cap is
                // invented on top of it, matching resize-duration, whose
                // only bound is likewise its u32.
                .int => @field(options, field) = switch (value) {
                    .integer => |int| if (int < 0 or int > std.math.maxInt(FieldType))
                        return self.failVoid(node, "expected a non-negative whole number")
                    else
                        @intCast(int),
                    else => return self.failVoid(node, "expected a whole number"),
                },
                .@"enum" => {
                    const text = switch (value) {
                        .string => |text| text,
                        else => return self.failVoid(node, "expected an option name"),
                    };
                    @field(options, field) = std.meta.stringToEnum(FieldType, text) orelse {
                        return self.failVoid(node, "unknown option value");
                    };
                },
                .pointer => @field(options, field) = switch (value) {
                    .string => |text| text,
                    else => return self.failVoid(node, "expected text"),
                },
                else => return self.failVoid(node, "attribute is not settable from markup"),
            }
        }

        fn attrKey(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!?canvas.UiKey {
            const omitted_default = switch (markup.attrTyped(attribute)) {
                .binding => |path| if (scope.lookup(pathHead(path))) |entry|
                    entry.defaulted and pathTail(path) == null
                else
                    false,
                else => false,
            };
            const value = try self.evalAttrExpression(scope, node, attribute);
            return switch (value) {
                // Bijective like itemKey: a negative integer key is a
                // distinct identity, never a trap.
                .integer => |int| canvas.uiKey(@as(u64, @bitCast(int))),
                // Empty defaults are the template-language spelling for an
                // omitted optional key. This lets ejected templates forward
                // key/global-key without changing unkeyed identity.
                .string => |text| if (text.len == 0 and omitted_default) null else canvas.uiKey(text),
                else => self.failKey(node, "keys must be integers or strings"),
            };
        }

        fn applyMessageAttr(self: *Self, scope: *Scope, node: markup.MarkupNode, options: *Ui.ElementOptions, attribute: markup.MarkupAttr) BuildError!void {
            const typed = markup.attrTyped(attribute);
            if (typed != .message) {
                return self.failVoid(node, "invalid message expression: on-* takes a Msg tag (\"add\") or tag with one binding payload (\"toggle:{item.id}\")");
            }
            const expression = typed.message;
            const event = attribute.name[3..];
            if (std.mem.eql(u8, event, "input")) {
                options.on_input = inputConstructor(expression.tag) orelse {
                    return self.failVoid(node, "on-input tag must carry a TextInputEvent payload");
                };
                return;
            }
            if (std.mem.eql(u8, event, "scroll")) {
                if (!std.mem.eql(u8, node.name, "scroll")) {
                    return self.failVoid(node, markup.on_scroll_element_message);
                }
                options.on_scroll = scrollConstructor(expression.tag) orelse {
                    // The retired one-axis record gets the migration
                    // teaching (it names the new per-axis fields) instead
                    // of the generic payload rejection.
                    if (legacyScrollTag(expression.tag)) {
                        return self.failVoid(node, markup.on_scroll_legacy_payload_message);
                    }
                    return self.failVoid(node, markup.on_scroll_payload_message);
                };
                return;
            }
            if (std.mem.eql(u8, event, "terminal")) {
                if (!std.mem.eql(u8, node.name, "terminal")) {
                    return self.failVoid(node, markup.on_terminal_element_message);
                }
                // Bare tag only: the runtime supplies the TerminalState,
                // so an authored payload would be silently discarded.
                if (expression.payload.len > 0) return self.failVoid(node, markup.on_terminal_payload_message);
                options.on_terminal = terminalConstructor(expression.tag) orelse {
                    return self.failVoid(node, markup.on_terminal_payload_message);
                };
                return;
            }
            if (std.mem.eql(u8, event, "resize")) {
                if (!std.mem.eql(u8, node.name, "split")) {
                    return self.failVoid(node, markup.on_resize_element_message);
                }
                options.on_resize = resizeConstructor(expression.tag) orelse {
                    return self.failVoid(node, markup.on_resize_payload_message);
                };
                return;
            }
            if (std.mem.eql(u8, event, "drag")) {
                options.on_drag = try self.constructDragMessage(scope, node, expression);
                return;
            }
            // The value-payload change event: a slider's `on-change` with a
            // bare tag naming a value-carrying arm dispatches the APPLIED
            // value through the `on_value` constructor (the `on-resize`
            // fraction mechanism) instead of a static Msg. Void arms keep
            // the static form below, so `on-change="volume_changed"` on a
            // slider still means "something changed" when the arm carries
            // nothing.
            if (std.mem.eql(u8, event, "change") and std.mem.eql(u8, node.name, "slider") and expression.payload.len == 0) {
                if (valueConstructor(expression.tag)) |make| {
                    options.on_value = make;
                    return;
                }
            }
            const msg = try self.constructMessage(scope, node, expression);
            if (std.mem.eql(u8, event, "press")) {
                options.on_press = msg;
            } else if (std.mem.eql(u8, event, "double-press")) {
                options.on_double_press = msg;
            } else if (std.mem.eql(u8, event, "toggle")) {
                options.on_toggle = msg;
            } else if (std.mem.eql(u8, event, "change")) {
                options.on_change = msg;
            } else if (std.mem.eql(u8, event, "submit")) {
                options.on_submit = msg;
            } else if (std.mem.eql(u8, event, "dismiss")) {
                // Only dismissible surfaces are ever dismissed by the
                // runtime; anywhere else the Msg could never fire.
                if (!markup.dismissEventElement(node.name)) {
                    return self.failVoid(node, markup.on_dismiss_element_message);
                }
                options.on_dismiss = msg;
            } else if (std.mem.eql(u8, event, "hold")) {
                // Press family: like on-press, a bound hold makes any
                // element pressable.
                options.on_hold = msg;
            } else if (std.mem.eql(u8, event, "hover-enter")) {
                // Hover family: binding either edge makes any element
                // hover-hittable (never pressable), so both are legal
                // everywhere like the press family.
                options.on_hover_enter = msg;
            } else if (std.mem.eql(u8, event, "hover-leave")) {
                options.on_hover_leave = msg;
            } else if (std.mem.eql(u8, event, "reach-end")) {
                // The approach-end signal (infinite-scroll fetch) is
                // emitted for scroll containers only.
                if (!std.mem.eql(u8, node.name, "scroll")) {
                    return self.failVoid(node, markup.on_reach_end_element_message);
                }
                options.on_reach_end = msg;
            } else {
                return self.failVoid(node, "unknown event attribute");
            }
        }

        fn constructMessage(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, expression.tag)) {
                    if (field.type == void) {
                        if (expression.payload.len > 0) {
                            return self.failMsg(node, "message does not take a payload");
                        }
                        return @unionInit(MsgT, field.name, {});
                    }
                    if (expression.payload.len == 0) {
                        return self.failMsg(node, "message requires a payload");
                    }
                    const value = try self.evalBinding(scope, node, expression.payload, true);
                    return @unionInit(MsgT, field.name, try self.coerce(field.type, node, value));
                }
            }
            return self.failMsg(node, "unknown message tag");
        }

        fn constructDragMessage(self: *Self, scope: *Scope, node: markup.MarkupNode, expression: markup.MessageExpression) BuildError!MsgT {
            if (expression.payload.len == 0) return self.failMsg(node, markup.on_drag_payload_message);
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (std.mem.eql(u8, field.name, expression.tag)) {
                    if (comptime !reflect.declaredWidgetDragDropRecord(field.type)) return self.failMsg(node, markup.on_drag_payload_message);
                    const value = try self.evalBinding(scope, node, expression.payload, true);
                    var payload: field.type = std.mem.zeroes(field.type);
                    payload.sourceId = try self.coerce(@FieldType(field.type, "sourceId"), node, value);
                    return @unionInit(MsgT, field.name, payload);
                }
            }
            return self.failMsg(node, markup.on_drag_payload_message);
        }

        fn coerce(self: *Self, comptime T: type, node: markup.MarkupNode, value: Value) BuildError!T {
            return switch (@typeInfo(T)) {
                // Range-checked against the payload's own integer type
                // before the cast (the option-attribute pattern): a
                // binding's i64 can deliver a negative to an unsigned
                // payload or overflow a small one — the teaching
                // failure, never a trap. Signed payloads keep their
                // negative range (minInt is the honest lower bound).
                .int => switch (value) {
                    .integer => |int| if (int < std.math.minInt(T) or int > std.math.maxInt(T))
                        self.failCoerce(T, node)
                    else
                        @intCast(int),
                    else => self.failCoerce(T, node),
                },
                .float => switch (value) {
                    .float => |float| @floatCast(float),
                    .integer => |int| @floatFromInt(int),
                    else => self.failCoerce(T, node),
                },
                .@"enum" => switch (value) {
                    .string => |text| std.meta.stringToEnum(T, text) orelse self.failCoerce(T, node),
                    else => self.failCoerce(T, node),
                },
                .pointer => switch (value) {
                    .string => |text| text,
                    else => self.failCoerce(T, node),
                },
                .bool => value.truthy(),
                else => self.failCoerce(T, node),
            };
        }

        fn failCoerce(self: *Self, comptime T: type, node: markup.MarkupNode) BuildError {
            _ = T;
            return self.failVoid(node, "payload type does not match the message");
        }

        fn inputConstructor(tag: []const u8) ?Ui.InputMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.TextInputEvent) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.inputMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (comptime reflect.declaredTextInputUnion(field.type)) {
                    // A declared mirror of the event union (transpiled
                    // cores): translated at dispatch, same handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedInputMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        fn scrollConstructor(tag: []const u8) ?Ui.ScrollMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.ScrollState) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.scrollMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (comptime reflect.declaredScrollStateRecord(field.type)) {
                    // A declared mirror of the scroll-state record
                    // (transpiled cores): translated at dispatch, same
                    // handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedScrollMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        fn terminalConstructor(tag: []const u8) ?Ui.TerminalMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == canvas.TerminalState) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.terminalMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (comptime reflect.declaredTerminalStateRecord(field.type)) {
                    // A declared mirror of the terminal-state record
                    // (transpiled cores): translated at dispatch, same
                    // handler shape.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedTerminalMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        /// Whether `tag` names an arm carrying the RETIRED one-axis
        /// scroll record — recognized only so the on-scroll rejection
        /// can teach the two-axis migration by field name.
        fn legacyScrollTag(tag: []const u8) bool {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (comptime reflect.declaredLegacyScrollStateRecord(field.type)) {
                    if (std.mem.eql(u8, field.name, tag)) return true;
                }
            }
            return false;
        }

        fn resizeConstructor(tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                if (field.type == f32) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name));
                    }
                } else if (field.type == f64) {
                    // A declared one-number float arm (transpiled cores,
                    // where f32 cannot be spelled): the fraction widens
                    // exactly at dispatch. Integer arms stay excluded —
                    // a 0..1 fraction rounded into an integer would be
                    // silently useless data.
                    if (std.mem.eql(u8, field.name, tag)) {
                        return Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type);
                    }
                }
            }
            return null;
        }

        /// The slider `on-change` value form: an arm carrying the applied
        /// 0..1 fraction as `f32` (the canvas-native shape) or the
        /// transpiled one-number float arm (`f64`, widened exactly).
        fn valueConstructor(tag: []const u8) ?Ui.ValueMsgFn {
            @setEvalBranchQuota(scan_quota);
            inline for (@typeInfo(MsgT).@"union".fields) |field| {
                const class = comptime reflect.valueArmClass(field.type);
                if (comptime class != null) {
                    if (std.mem.eql(u8, field.name, tag)) {
                        return switch (comptime class.?) {
                            .identity => Ui.valueMsg(@field(std.meta.Tag(MsgT), field.name)),
                            .float => Ui.translatedValueMsg(@field(std.meta.Tag(MsgT), field.name), field.type),
                        };
                    }
                }
            }
            return null;
        }

        // --------------------------------------------------- expressions

        /// Evaluate an attribute's TYPED value: the canonicalized form
        /// classified (and its expression tree parsed) once at document
        /// level, not per frame per use — the typed-document pass's whole
        /// point for the interpreter.
        fn evalAttributeExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr, attribute_aware: bool) BuildError!Value {
            return switch (markup.attrTyped(attribute)) {
                .literal => |text| if (attribute_aware)
                    literalValueForAttribute(text, attribute.name)
                else
                    literalValue(text),
                .binding => |path| try self.evalBinding(scope, node, path, true),
                // Arena-computed bindings are excluded from equality on
                // purpose: comparing freshly formatted strings is a smell —
                // compare the source fields, or bind a bool-returning fn.
                .equals => |sides| .{ .boolean = Value.eql(
                    try self.evalBinding(scope, node, sides.left, false),
                    try self.evalBinding(scope, node, sides.right, false),
                ) },
                .expression => |form| try self.evalExpressionForm(scope, node, form),
                .message, .invalid => self.failValue(node, markup.invalid_expression_message),
            };
        }

        fn evalAttrExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!Value {
            return self.evalAttributeExpression(scope, node, attribute, true);
        }

        fn evalUnclassifiedExpression(self: *Self, scope: *Scope, node: markup.MarkupNode, attribute: markup.MarkupAttr) BuildError!Value {
            return self.evalAttributeExpression(scope, node, attribute, false);
        }

        /// A typed expression: use the pre-parsed tree when the pass
        /// stamped one; a missing tree means the text does not parse (or
        /// the document was never canonicalized), and the re-parse
        /// surfaces the exact teaching diagnostic.
        fn evalExpressionForm(self: *Self, scope: *Scope, node: markup.MarkupNode, form: markup.TypedExprRef) BuildError!Value {
            if (form.tree) |tree| return self.evalParsedTree(scope, node, tree);
            return self.evalExpressionTree(scope, node, form.inner);
        }

        /// Evaluate a full `{expression}`: parse it (bounded, allocation-
        /// free), resolve every binding node through the ordinary scope
        /// chain, and hand the values to the shared evaluator — the same
        /// code the compiled engine runs, so results match bit for bit.
        /// Parse, type, and value failures (division by zero, overflow)
        /// become build diagnostics carrying the evaluator's teaching
        /// message.
        fn evalExpressionTree(self: *Self, scope: *Scope, node: markup.MarkupNode, inner: []const u8) BuildError!Value {
            var tree: markup.expr.ExprTree = .{};
            var diagnostic: markup.expr.Diagnostic = .{};
            if (!markup.expr.parse(inner, &tree, &diagnostic)) {
                return self.failValue(node, diagnostic.message);
            }
            return self.evalParsedTree(scope, node, &tree);
        }

        fn evalParsedTree(self: *Self, scope: *Scope, node: markup.MarkupNode, tree: *const markup.expr.ExprTree) BuildError!Value {
            var values: [markup.expr.max_expression_nodes]Value = undefined;
            for (tree.nodes[0..tree.len], 0..) |expr_node, index| {
                if (expr_node.kind != .binding) continue;
                // Comparison operands reject arena-computed scalars, the
                // same teaching rule as `{a == b}`.
                values[index] = try self.evalBinding(scope, node, expr_node.text, !expr_node.comparison_operand);
            }
            return switch (try markup.expr.eval(tree, &values, scope.arena)) {
                .value => |value| value,
                .fail => |message| self.failValue(node, message),
            };
        }

        /// Resolve a binding path to a `Value`. `allow_arena` gates the
        /// arena-taking scalar fn form (allowed everywhere a scalar binding
        /// is — text interpolation, attribute values, message payloads —
        /// except inside `{a == b}` equality).
        fn evalBinding(self: *Self, scope: *Scope, node: markup.MarkupNode, path: []const u8, allow_arena: bool) BuildError!Value {
            @setEvalBranchQuota(scan_quota);
            const head = pathHead(path);
            const arena: ?std.mem.Allocator = if (allow_arena) scope.arena else null;
            if (scope.lookup(head)) |entry| {
                switch (entry.payload) {
                    .item => |item_entry| {
                        inline for (item_types, 0..) |Item, type_index| {
                            if (item_entry.type_index == type_index) {
                                const item: *const Item = @ptrCast(@alignCast(item_entry.ptr));
                                if (pathTail(path)) |tail| {
                                    if (resolveOn(Item, item, tail, arena)) |value| return value;
                                    if (!allow_arena and resolveOn(Item, item, tail, scope.arena) != null) {
                                        return self.failValue(node, markup.arena_scalar_equality_message);
                                    }
                                    return self.failValue(node, "binding does not name a field on the loop item");
                                }
                                return valueOf(Item, item.*) orelse self.failValue(node, "loop items of this type cannot be used as values");
                            }
                        }
                        unreachable;
                    },
                    .value => |value| {
                        if (pathTail(path) != null) {
                            return self.failValue(node, "template arg values have no fields");
                        }
                        return value;
                    },
                    .slice => return self.failValue(node, "slice-valued template args are only usable with for each"),
                    // Slot captures carry an empty name, which no binding
                    // head can equal.
                    .slot => unreachable,
                }
            }
            if (resolveOn(ModelT, scope.model, path, arena)) |value| return value;
            if (!allow_arena and resolveOn(ModelT, scope.model, path, scope.arena) != null) {
                return self.failValue(node, markup.arena_scalar_equality_message);
            }
            if (fieldIsTextBuffer(ModelT, head)) {
                return self.failValue(node, markup.binding_text_buffer_message);
            }
            return self.failValue(node, "binding does not name a model field");
        }

        // ------------------------------------------------ span paragraphs

        /// A `<text>` with inline `<span>` children: the span paragraph.
        /// Each content child lowers to one `canvas.TextSpan` — plain runs
        /// (single-space separators the parser spliced included) keep the
        /// paragraph style, span children carry their own weight, mono,
        /// italic, and foreground — and the list lowers through
        /// `Ui.paragraph`, so byte rebasing, span-aware wrapping, and
        /// semantics match a builder span paragraph exactly: the widget
        /// announces as ONE text run (spans are visual, never semantic
        /// children). Mirrors the validator and the compiled engine.
        fn buildSpanParagraph(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, options: Ui.ElementOptions) BuildError!Ui.Node {
            // A span paragraph always word-wraps (builder parity), so the
            // single-line policies are dead data here. Mirrors the
            // validator and the compiled engine's compile error.
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "wrap") or std.mem.eql(u8, attribute.name, "overflow")) {
                    return self.failNode(node, markup.span_paragraph_wrap_message);
                }
            }
            const spans = try ui.arena.alloc(canvas.TextSpan, node.children.len);
            var len: usize = 0;
            for (node.children) |child| {
                if (child.kind == .text) {
                    spans[len] = .{ .text = try self.runText(ui, scope, node, child) };
                    len += 1;
                    continue;
                }
                if (!markup.nodeIsSpan(child)) return self.failNode(child, markup.text_inline_children_message);
                spans[len] = try self.buildSpan(ui, scope, child);
                len += 1;
            }
            return ui.paragraph(options, spans[0..len]);
        }

        /// One `<span>`: the shared shape check (closed attribute set,
        /// exactly one run, no nesting), then the style channels resolved
        /// against the scope — weight, scale, and the flags take bindings
        /// like any option attribute, foreground stays a literal token
        /// name. A bound scale is held to the same positive-finite bound
        /// the validator pins for literals: the engine draws anything
        /// else at the base size, and a silently dead binding is worse
        /// than a diagnostic.
        fn buildSpan(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError!canvas.TextSpan {
            if (markup.spanShapeError(node)) |info| {
                self.diagnostic = .{ .line = info.line, .column = info.column, .message = info.message, .path = info.path };
                return error.MarkupBuild;
            }
            var span = canvas.TextSpan{};
            for (node.attrs) |attribute| {
                if (std.mem.eql(u8, attribute.name, "weight")) {
                    const text = try self.stringAttr(scope, node, attribute, markup.span_weight_value_message);
                    span.weight = std.meta.stringToEnum(canvas.TextSpanWeight, text) orelse {
                        return self.failValue(node, markup.span_weight_value_message);
                    };
                } else if (std.mem.eql(u8, attribute.name, "scale")) {
                    const multiplier = switch (try self.evalAttrExpression(scope, node, attribute)) {
                        .float => |float| float,
                        .integer => |int| @as(f32, @floatFromInt(int)),
                        else => return self.failValue(node, markup.span_scale_value_message),
                    };
                    if (!std.math.isFinite(multiplier) or multiplier <= 0) {
                        return self.failValue(node, markup.span_scale_value_message);
                    }
                    span.scale = multiplier;
                } else if (std.mem.eql(u8, attribute.name, "mono")) {
                    span.monospace = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                } else if (std.mem.eql(u8, attribute.name, "italic")) {
                    span.italic = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                } else if (std.mem.eql(u8, attribute.name, "underline")) {
                    span.underline = (try self.evalAttrExpression(scope, node, attribute)).truthy();
                } else if (std.mem.eql(u8, attribute.name, "foreground")) {
                    span.color = std.meta.stringToEnum(canvas.TextSpanColor, attribute.value) orelse {
                        return self.failValue(node, markup.unknown_color_token_message);
                    };
                }
                // spanShapeError already rejected every other name.
            }
            span.text = try self.runText(ui, scope, node, node.children[0]);
            return span;
        }

        fn interpolatedText(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode) BuildError![]const u8 {
            if (node.children.len > 1) return self.failText(node, "text elements take a single run of text");
            for (node.children) |child| {
                if (child.kind != .text) {
                    // A span here sits inside a single-style label, not a
                    // paragraph — teach the <text> home instead of the
                    // generic message.
                    if (markup.nodeIsSpan(child)) return self.failText(child, markup.span_text_only_message);
                    return self.failText(node, "text elements may only contain text");
                }
                return self.runText(ui, scope, node, child);
            }
            return "";
        }

        /// Interpolate ONE text run (`{...}` bindings and expressions)
        /// into the build arena: the shared body behind plain text leaves
        /// and every span-paragraph run. `node` positions diagnostics.
        fn runText(self: *Self, ui: *Ui, scope: *Scope, node: markup.MarkupNode, run: markup.MarkupNode) BuildError![]const u8 {
            const source = run.text;
            const segments = run.typed_text;
            if (std.mem.indexOfScalar(u8, source, '{') == null) return source;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            if (segments) |typed_segments| {
                // The canonicalized fast path: the run was split (and its
                // expressions parsed) once at document level.
                for (typed_segments) |segment| {
                    switch (segment) {
                        .literal => |text| try out.appendSlice(ui.arena, text),
                        .binding => |path| try appendValue(&out, ui.arena, try self.evalBinding(scope, node, path, true)),
                        .expression => |form| try appendValue(&out, ui.arena, try self.evalExpressionForm(scope, node, form)),
                        .unterminated => return self.failText(node, "unterminated interpolation"),
                    }
                }
                return out.items;
            }
            var rest = source;
            while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
                try out.appendSlice(ui.arena, rest[0..open]);
                const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse {
                    return self.failText(node, "unterminated interpolation");
                };
                const inner = std.mem.trim(u8, rest[open + 1 .. close], " ");
                const value = if (markup.isBindingPath(inner))
                    try self.evalBinding(scope, node, inner, true)
                else
                    try self.evalExpressionTree(scope, node, inner);
                try appendValue(&out, ui.arena, value);
                rest = rest[close + 1 ..];
            }
            try out.appendSlice(ui.arena, rest);
            return out.items;
        }

        // -------------------------------------------------- diagnostics

        fn failNode(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError!Ui.Node {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failVoid(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failValue(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failText(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failMsg(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn failKey(self: *Self, node: markup.MarkupNode, message: []const u8) BuildError {
            self.setDiagnostic(node, message);
            return error.MarkupBuild;
        }

        fn setDiagnostic(self: *Self, node: markup.MarkupNode, message: []const u8) void {
            self.diagnostic = .{ .line = node.line, .column = node.column, .message = message, .path = node.src_path };
        }
    };
}

// ----------------------------------------------------------- reflection

/// Markup attribute name → `Ui.ElementOptions` field, derived from the
/// registry (ui_schema.zig). Shared with the comptime-compiled path so
/// both engines accept exactly the same attributes; the registry is the
/// single statement of the mapping.
pub const AttrName = markup.schema.NamePair;

pub const attr_names: []const AttrName = &markup.schema.option_field_pairs;

/// Markup color style attribute → `StyleTokenRefs` field, derived from
/// the registry's style-color group. Shared with the comptime-compiled
/// path; held consistent with the token structs by a conformance test.
pub const color_style_attr_fields: []const AttrName = &markup.schema.color_style_field_pairs;

/// Model/Msg reflection predicates shared with the compiled engine and
/// the model-contract describe step (see ui_markup_reflect.zig — one
/// definition of what markup can bind, three consumers).
const reflect = @import("ui_markup_reflect.zig");
pub const typeScanQuota = reflect.typeScanQuota;
pub const Pointee = reflect.Pointee;
pub const declaredTextInputUnion = reflect.declaredTextInputUnion;
pub const declaredScrollStateRecord = reflect.declaredScrollStateRecord;
pub const declaredTerminalStateRecord = reflect.declaredTerminalStateRecord;
pub const declaredLegacyScrollStateRecord = reflect.declaredLegacyScrollStateRecord;
pub const declaredWidgetDragDropRecord = reflect.declaredWidgetDragDropRecord;
pub const valueArmClass = reflect.valueArmClass;
pub const sliceElement = reflect.sliceElement;
pub const isItemFn = reflect.isItemFn;
pub const isArenaScalarFn = reflect.isArenaScalarFn;

fn collectItemTypes(comptime Model: type) []const type {
    comptime {
        @setEvalBranchQuota(typeScanQuota(Model));
        var types: []const type = &.{};
        for (@typeInfo(Model).@"struct".fields) |field| {
            if (sliceElement(field.type)) |Element| {
                types = appendUniqueType(types, Element);
            }
        }
        for (@typeInfo(Model).@"struct".decls) |decl| {
            const DeclType = @TypeOf(@field(Model, decl.name));
            if (sliceElement(DeclType)) |Element| {
                types = appendUniqueType(types, Element);
            }
            switch (@typeInfo(DeclType)) {
                .@"fn" => |info| {
                    if (info.return_type) |Return| {
                        if (sliceElement(Return)) |Element| {
                            types = appendUniqueType(types, Element);
                        }
                    }
                },
                else => {},
            }
        }
        return types;
    }
}

fn appendUniqueType(comptime types: []const type, comptime T: type) []const type {
    for (types) |existing| {
        if (existing == T) return types;
    }
    return types ++ &[_]type{T};
}

pub fn asSlice(comptime Item: type, value: anytype) []const Item {
    const T = @TypeOf(value.*);
    return switch (@typeInfo(T)) {
        .array => value[0..],
        .pointer => value.*,
        else => @compileError("not a slice"),
    };
}

/// Resolve a dotted path on a value: struct fields, zero-arg methods,
/// arena-taking methods (`fn (*const T, std.mem.Allocator) V`, skipped
/// when `arena` is null), and bounded model conventions (a
/// `field_count`-style pair is the author's job; the resolver only follows
/// what exists).
fn resolveOn(comptime T: type, value: *const T, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    @setEvalBranchQuota(comptime typeScanQuota(T));
    const head = pathHead(path);
    const tail = pathTail(path);
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (std.mem.eql(u8, field.name, head)) {
                    if (tail) |rest| {
                        return resolveNested(field.type, &@field(value, field.name), rest, arena);
                    }
                    return valueOf(field.type, @field(value, field.name));
                }
            }
            inline for (@typeInfo(T).@"struct".decls) |decl| {
                const DeclType = @TypeOf(@field(T, decl.name));
                switch (@typeInfo(DeclType)) {
                    .@"fn" => |info| {
                        if (info.params.len == 1 and info.return_type != null and info.params[0].type == *const T) {
                            if (std.mem.eql(u8, decl.name, head) and tail == null) {
                                return valueOf(info.return_type.?, @field(T, decl.name)(value));
                            }
                        }
                        if (comptime isArenaScalarFn(T, DeclType)) {
                            if (std.mem.eql(u8, decl.name, head) and tail == null) {
                                const allocator = arena orelse return null;
                                return valueOf(info.return_type.?, @field(T, decl.name)(value, allocator));
                            }
                        }
                    },
                    else => {},
                }
            }
            return null;
        },
        // Single-item const pointers are transparent (`reflect.Pointee`):
        // a `*const Row` loop item or shared model node binds like the
        // struct it points at.
        .pointer => |info| {
            if (info.size == .one and info.is_const) {
                return resolveOn(info.child, value.*, path, arena);
            }
            return null;
        },
        else => return null,
    }
}

/// True when `head` names a struct field whose type is a
/// `canvas.TextBuffer(N)` editor. Such a field is the EDIT MODEL, not
/// bindable text, so both engines and the contract checker turn the
/// generic missing-binding failure into a teaching message pointing at
/// the buffer's text() accessor. Comptime-callable (the compiled engine
/// runs it inside its comptime binding resolution).
pub fn fieldIsTextBuffer(comptime T: type, head: []const u8) bool {
    @setEvalBranchQuota(comptime typeScanQuota(T));
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const is_buffer = comptime (std.mem.indexOf(u8, @typeName(field.type), "TextBuffer(") != null);
        if (is_buffer and std.mem.eql(u8, field.name, head)) return true;
    }
    return false;
}

fn resolveNested(comptime T: type, ptr: anytype, path: []const u8, arena: ?std.mem.Allocator) ?Value {
    return switch (@typeInfo(T)) {
        .@"struct" => resolveOn(T, ptr, path, arena),
        // The `reflect.Pointee` transparency: traverse through a
        // single-item const pointer field into the struct it shares.
        .pointer => |info| if (info.size == .one and info.is_const)
            resolveNested(info.child, ptr.*, path, arena)
        else
            null,
        else => null,
    };
}

pub fn valueOf(comptime T: type, value: T) ?Value {
    return switch (@typeInfo(T)) {
        .bool => .{ .boolean = value },
        .int => .{ .integer = @intCast(value) },
        .float => .{ .float = @floatCast(value) },
        .@"enum" => .{ .string = @tagName(value) },
        .comptime_int => .{ .integer = value },
        .pointer => |info| if (info.size == .slice and info.child == u8) .{ .string = value } else null,
        .array => |info| if (info.child == u8) null else null,
        .optional => if (value) |inner| valueOf(@TypeOf(inner), inner) else .{ .boolean = false },
        else => null,
    };
}

pub const literalValue = reflect.literalValue;
pub const literalValueForAttribute = reflect.literalValueForAttribute;

/// Display-text formatting for interpolation and `++` concatenation:
/// defined once in the expression core so both engines (and the evaluator
/// itself) format identically, floats included.
pub const appendValue = markup.expr.appendValue;

pub fn pathHead(path: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return path;
    return path[0..dot];
}

pub fn pathTail(path: []const u8) ?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse return null;
    return path[dot + 1 ..];
}

// -------------------------------------------------------------- elements

/// One registry element resolved onto the engine's `WidgetKind`, computed
/// ONCE at comptime — resolving per lookup would re-run the enum scan per
/// element per call site and blow the comptime quota (the registry's
/// comptime-cost mitigation is single-pass derivation).
pub const ElementKindEntry = struct { name: []const u8, kind: canvas.WidgetKind, takes_text: bool, takes_children: bool };

fn widgetKindByName(comptime name: []const u8) canvas.WidgetKind {
    comptime {
        for (@typeInfo(canvas.WidgetKind).@"enum".fields) |field| {
            if (std.mem.eql(u8, field.name, name)) return @enumFromInt(field.value);
        }
        @compileError("registry element names an unknown widget kind: " ++ name);
    }
}

/// The registry's plain elements with their kinds resolved: the one
/// name→kind table both engines dispatch through. A registry entry naming
/// a kind that does not exist is a compile error, so the mapping cannot
/// rot.
pub const element_kind_table = blk: {
    @setEvalBranchQuota(400_000);
    var count: usize = 0;
    for (markup.schema.elements) |entry| {
        if (entry.widget_kind.len > 0) count += 1;
    }
    var entries: [count]ElementKindEntry = undefined;
    var index: usize = 0;
    for (markup.schema.elements) |entry| {
        if (entry.widget_kind.len == 0) continue;
        entries[index] = .{
            .name = entry.name,
            .kind = widgetKindByName(entry.widget_kind),
            .takes_text = entry.takes_text,
            .takes_children = entry.takes_children,
        };
        index += 1;
    }
    break :blk entries;
};

pub fn elementKind(name: []const u8) ?canvas.WidgetKind {
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.kind;
    }
    return null;
}

/// Tab triggers ARE segmented controls: markup composes the strip from
/// `<button>` children (segmented-control is a documented markup
/// exclusion), and both engines lower them to the widget kind the
/// engine's tab strips are built on, so the active trigger lifts to the
/// surface with a hairline exactly like the Zig builder's tabs.
/// Handlers ride the widget id, so bindings are untouched; toggle-button
/// children keep their kind (their on-toggle contract is different).
pub fn lowerTabsTriggers(children: anytype) void {
    for (children) |*child| {
        if (child.widget.kind == .button) child.widget.kind = .segmented_control;
    }
}

pub fn elementTakesText(kind: canvas.WidgetKind) bool {
    // The registry's takes-text predicate projected onto widget kinds
    // (both engines and the validator's text-leaf list read the same
    // registry fact).
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (entry.takes_text and entry.kind == kind) return true;
    }
    return false;
}

pub fn elementTakesChildren(kind: canvas.WidgetKind) bool {
    // The registry's takes-children predicate projected onto widget
    // kinds: text-taking elements that ALSO accept element children in
    // place of the text run (the list-row composite).
    @setEvalBranchQuota(20_000);
    for (&element_kind_table) |entry| {
        if (entry.takes_children and entry.kind == kind) return true;
    }
    return false;
}
