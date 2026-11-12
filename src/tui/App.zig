const std = @import("std");
const ascii = std.ascii;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Journal = @import("../Journal.zig");
const Model = @import("../Model.zig");
const dedup = @import("../dedup.zig");
const pstore = @import("../pstore.zig");
const ui = @import("../ui.zig");
const Term = @import("Term.zig");
const keys = @import("keys.zig");

const color = ui.color;
const Key = keys.Key;
const App = @This();

pub const View = enum { summary, notable, last, all };

const Mode = enum { main, detail, boots };

const Cursor = struct { sel: usize = 0, top: usize = 0 };

/// Header, tab bar and footer.
const chrome_rows = 3;

const priority_names = [_][]const u8{ "emerg", "alert", "crit", "err", "warning", "notice", "info", "debug" };

gpa: Allocator,
term: Term,
journal: Journal,
boots: []const Journal.Boot,
model: Model,
keep_noise: bool,
store: pstore.Status,
frame: Writer.Allocating,

mode: Mode = .main,
view: View = .summary,
cursors: std.EnumArray(View, Cursor) = .initFill(.{}),
search: std.ArrayList(u8) = .empty,
typing: bool = false,
/// Indices into the current view's items that match `search`.
visible: std.ArrayList(u32) = .empty,
detail: struct { center: usize = 0, top: ?usize = null, group: ?dedup.Group = null } = .{},
picker: Cursor = .{},
/// One-shot footer message, e.g. a failed boot load.
status: []const u8 = "",
size: Term.Size = .{ .rows = 24, .cols = 80 },

pub fn init(gpa: Allocator, term: Term, journal: Journal, boots: []const Journal.Boot, model: Model, keep_noise: bool, store: pstore.Status) App {
    return .{
        .gpa = gpa,
        .term = term,
        .journal = journal,
        .boots = boots,
        .model = model,
        .keep_noise = keep_noise,
        .store = store,
        .frame = .init(gpa),
    };
}

pub fn deinit(self: *App) void {
    self.search.deinit(self.gpa);
    self.visible.deinit(self.gpa);
    self.frame.deinit();
    self.model.deinit();
}

pub fn run(self: *App) !void {
    try self.refilter();
    var drawn: ?Term.Size = null;
    var buf: [64]u8 = undefined;
    while (true) {
        self.size = self.term.size();
        if (drawn == null or !std.meta.eql(drawn.?, self.size)) {
            try self.draw();
            drawn = self.size;
        }
        const input = try self.term.read(&buf, 200);
        if (input.len == 0) continue;
        var it: keys.Iterator = .{ .buf = input };
        while (it.next()) |k| {
            if (try self.handle(k)) return;
        }
        drawn = null;
    }
}

// Items of the list views.

fn itemCount(self: *const App, view: View) usize {
    const m = &self.model;
    return switch (view) {
        .summary => 0,
        .notable => m.notable.len,
        .all => m.all.len,
        .last => m.entries.len - m.tail,
    };
}

/// The entry an item points at (a group's first occurrence).
fn itemEntry(self: *const App, view: View, i: usize) usize {
    const m = &self.model;
    return switch (view) {
        .summary => unreachable,
        .notable => m.notable[i].first,
        .all => m.all[i].first,
        .last => m.tail + i,
    };
}

fn itemGroup(self: *const App, view: View, i: usize) ?dedup.Group {
    return switch (view) {
        .notable => self.model.notable[i],
        .all => self.model.all[i],
        .summary, .last => null,
    };
}

fn matches(self: *const App, view: View, i: usize) bool {
    const q = self.search.items;
    if (q.len == 0) return true;
    const idx = self.itemEntry(view, i);
    const e = &self.model.entries[idx];
    return ascii.findIgnoreCase(e.message, q) != null or
        ascii.findIgnoreCase(e.ident, q) != null or
        ascii.findIgnoreCase(e.unit, q) != null or
        ascii.findIgnoreCase(self.model.cats[idx].label(), q) != null;
}

fn refilter(self: *App) !void {
    self.visible.clearRetainingCapacity();
    for (0..self.itemCount(self.view)) |i| {
        if (self.matches(self.view, i)) try self.visible.append(self.gpa, @intCast(i));
    }
    const cur = self.cursors.getPtr(self.view);
    cur.sel = @min(cur.sel, self.visible.items.len -| 1);
}

// Input.

/// True to quit.
fn handle(self: *App, k: Key) !bool {
    if (k == .ctrl_c) return true;
    self.status = "";
    switch (self.mode) {
        .main => return self.handleMain(k),
        .detail => self.handleDetail(k),
        .boots => try self.handleBoots(k),
    }
    return false;
}

fn handleMain(self: *App, k: Key) !bool {
    if (self.typing) {
        switch (k) {
            .enter => self.typing = false,
            .esc => {
                self.typing = false;
                self.search.clearRetainingCapacity();
            },
            .backspace => _ = self.search.pop(),
            .ctrl_u => self.search.clearRetainingCapacity(),
            .char => |c| if (c >= 0x20) try self.search.append(self.gpa, c),
            else => {},
        }
        try self.refilter();
        return false;
    }

    const page = self.listRows();
    switch (k) {
        .char => |c| switch (c) {
            'q' => return true,
            '1'...'4' => try self.setView(@fromBackingInt(@intCast(c - '1'))),
            'l' => try self.cycleView(1),
            'h' => try self.cycleView(-1),
            'j' => self.move(1),
            'k' => self.move(-1),
            'g' => self.move(-std.math.maxInt(i32)),
            'G' => self.move(std.math.maxInt(i32)),
            '/' => {
                if (self.view == .summary) try self.setView(.notable);
                self.typing = true;
            },
            'b' => self.openPicker(),
            'n' => {
                self.keep_noise = !self.keep_noise;
                self.reload(Model.bootIndex(self.boots.len, self.model.offset).?);
                self.status = if (self.keep_noise) "noise shown" else "noise hidden";
            },
            else => {},
        },
        .tab, .right => try self.cycleView(1),
        .backtab, .left => try self.cycleView(-1),
        .down => self.move(1),
        .up => self.move(-1),
        .page_down => self.move(@intCast(page)),
        .page_up => self.move(-@as(i32, @intCast(page))),
        .ctrl_d => self.move(@intCast(page / 2)),
        .ctrl_u => self.move(-@as(i32, @intCast(page / 2))),
        .home => self.move(-std.math.maxInt(i32)),
        .end => self.move(std.math.maxInt(i32)),
        .enter => self.openDetail(),
        .esc => {
            self.search.clearRetainingCapacity();
            try self.refilter();
        },
        else => {},
    }
    return false;
}

fn handleDetail(self: *App, k: Key) void {
    const page: i64 = @intCast(self.contextRows());
    const delta: i64 = switch (k) {
        .esc, .enter, .backspace => {
            self.mode = .main;
            return;
        },
        .char => |c| switch (c) {
            'q', 'h' => {
                self.mode = .main;
                return;
            },
            'j' => 1,
            'k' => -1,
            'g' => std.math.minInt(i32),
            'G' => std.math.maxInt(i32),
            else => return,
        },
        .left => {
            self.mode = .main;
            return;
        },
        .down => 1,
        .up => -1,
        .page_down, .ctrl_d => page,
        .page_up, .ctrl_u => -page,
        .home => std.math.minInt(i32),
        .end => std.math.maxInt(i32),
        else => return,
    };
    const max: i64 = @intCast(self.model.entries.len -| self.contextRows());
    const top: i64 = @intCast(self.detailTop());
    self.detail.top = @intCast(std.math.clamp(top + delta, 0, max));
}

fn handleBoots(self: *App, k: Key) !void {
    const n = self.boots.len;
    switch (k) {
        .esc, .left => self.mode = .main,
        .char => |c| switch (c) {
            'q', 'b', 'h' => self.mode = .main,
            'j' => self.picker.sel = @min(self.picker.sel + 1, n - 1),
            'k' => self.picker.sel -|= 1,
            'g' => self.picker.sel = 0,
            'G' => self.picker.sel = n - 1,
            else => {},
        },
        .down => self.picker.sel = @min(self.picker.sel + 1, n - 1),
        .up => self.picker.sel -|= 1,
        .home => self.picker.sel = 0,
        .end => self.picker.sel = n - 1,
        .enter => {
            self.mode = .main;
            self.reload(n - 1 - self.picker.sel);
        },
        else => {},
    }
}

fn setView(self: *App, view: View) !void {
    self.view = view;
    try self.refilter();
}

fn cycleView(self: *App, delta: i32) !void {
    const n: i32 = @intCast(std.enums.values(View).len);
    try self.setView(@fromBackingInt(@intCast(@mod(@as(i32, @backingInt(self.view)) + delta, n))));
}

fn move(self: *App, delta: i32) void {
    if (self.view == .summary) return;
    const cur = self.cursors.getPtr(self.view);
    const len: i64 = @intCast(self.visible.items.len);
    if (len == 0) return;
    cur.sel = @intCast(std.math.clamp(@as(i64, @intCast(cur.sel)) + delta, 0, len - 1));
}

fn openDetail(self: *App) void {
    if (self.view == .summary or self.visible.items.len == 0) return;
    const i = self.visible.items[self.cursors.get(self.view).sel];
    self.detail = .{ .center = self.itemEntry(self.view, i), .group = self.itemGroup(self.view, i) };
    self.mode = .detail;
}

fn openPicker(self: *App) void {
    const loaded = Model.bootIndex(self.boots.len, self.model.offset) orelse 0;
    self.picker = .{ .sel = self.boots.len - 1 - loaded };
    self.mode = .boots;
}

fn reload(self: *App, index: usize) void {
    const m = Model.load(self.gpa, self.journal, self.boots, index, self.keep_noise) catch |err| {
        self.status = @errorName(err);
        return;
    };
    self.model.deinit();
    self.model = m;
    self.cursors = .initFill(.{});
    self.refilter() catch {};
}

// Drawing.

fn listRows(self: *const App) usize {
    return self.size.rows -| chrome_rows;
}

fn screenRows(self: *App, first: usize, end: usize) ui.Rows {
    return .{
        .w = &self.frame.writer,
        .width = self.size.cols,
        .colored = true,
        .screen = .{ .row = first, .end = @min(end, self.size.rows) },
    };
}

fn draw(self: *App) !void {
    self.frame.clearRetainingCapacity();
    const w = &self.frame.writer;
    try w.writeAll("\x1b[?2026h");
    try self.drawHeader();
    switch (self.mode) {
        .main => try self.drawMain(),
        .detail => try self.drawDetail(),
        .boots => try self.drawBoots(),
    }
    try self.drawFooter();
    try w.writeAll("\x1b[?2026l");
    self.term.write(self.frame.written());
}

fn drawHeader(self: *App) !void {
    const m = &self.model;
    var rows = self.screenRows(0, 1);
    const l = (try rows.next()) orelse return;
    try l.bg(color.base02);
    try l.fg(color.blue);
    try l.bold();
    try l.text(" silt ");
    try l.reset();
    try l.fg(color.base1);
    try l.print(" boot {d} · ", .{m.offset});
    try l.range(m.boot.first, m.boot.last);

    const kind = m.end.kind;
    const label = kind.label();
    // "● " + label + " " in columns ("●" is one).
    const badge = label.len + 3;
    try l.padTo(self.size.cols -| badge);
    try l.fg(if (kind == .running) color.blue else if (kind.clean()) color.green else color.red);
    try l.bold();
    try l.text("● ");
    try l.text(label);
    try l.fill();
    try rows.close();
}

fn drawMain(self: *App) !void {
    try self.drawTabs();
    switch (self.view) {
        .summary => {
            var rows = self.screenRows(2, self.size.rows -| 1);
            try ui.summary(&rows, &self.model, self.store);
            while (try rows.next()) |_| {}
            try rows.close();
        },
        else => try self.drawList(),
    }
}

fn drawTabs(self: *App) !void {
    var rows = self.screenRows(1, 2);
    const l = (try rows.next()) orelse return;
    const m = &self.model;
    var worst: ui.Category = .none;
    for (m.notable) |g| worst = @fromBackingInt(@intCast(@min(@backingInt(worst), @backingInt(g.cat))));
    for (std.enums.values(View)) |view| {
        const active = view == self.view;
        try l.text(" ");
        if (active) {
            try l.bg(color.base1);
            try l.fg(color.base03);
            try l.bold();
        } else {
            try l.fg(color.base0);
        }
        try l.text(" ");
        try l.text(switch (view) {
            .summary => "Summary",
            .notable => "Notable",
            .last => "Last 60s",
            .all => "All",
        });
        if (view != .summary) {
            if (!active and view == .notable and worst != .none) try l.fg(color.of(worst));
            try l.print(" {d}", .{self.itemCount(view)});
        }
        try l.text(" ");
        l.background = null;
        try l.reset();
    }
    if (self.search.items.len > 0 and !self.typing) {
        try l.text("   ");
        try l.fg(color.yellow);
        try l.print("filter: {s}", .{self.search.items});
    }
    try rows.close();
}

fn drawList(self: *App) !void {
    const avail = self.listRows();
    const cur = self.cursors.getPtr(self.view);
    const len = self.visible.items.len;
    if (cur.sel < cur.top) cur.top = cur.sel;
    if (cur.sel >= cur.top + avail) cur.top = cur.sel + 1 - avail;
    cur.top = @min(cur.top, len -| avail);

    var rows = self.screenRows(2, self.size.rows -| 1);
    if (len == 0) {
        _ = try rows.next();
        const l = (try rows.next()) orelse return;
        try l.text("  ");
        if (self.search.items.len > 0) {
            try l.fg(color.base0);
            try l.print("no matches for \"{s}\"", .{self.search.items});
        } else {
            try l.fg(color.green);
            try l.text(if (self.view == .notable) "nothing notable in this boot" else "nothing here");
        }
    }
    for (0..avail) |r| {
        const l = (try rows.next()) orelse break;
        const idx = cur.top + r;
        if (idx >= len) continue;
        const i = self.visible.items[idx];
        if (idx == cur.sel) try l.bg(color.base02);
        if (self.itemGroup(self.view, i)) |g| {
            try ui.groupRow(l, &self.model, g);
        } else {
            const e = self.itemEntry(self.view, i);
            try ui.entryRow(l, &self.model.entries[e], self.model.cats[e]);
        }
        if (idx == cur.sel) try l.fill();
    }
    try rows.close();
}

fn contextRows(self: *const App) usize {
    return self.size.rows -| (chrome_rows + 4 + self.messageLines());
}

fn messageLines(self: *const App) usize {
    const width = self.size.cols -| 4;
    if (width == 0) return 1;
    const cols = std.unicode.utf8CountCodepoints(self.model.entries[self.detail.center].message) catch
        self.model.entries[self.detail.center].message.len;
    return std.math.clamp(std.math.divCeil(usize, cols, width) catch 1, 1, 8);
}

fn detailTop(self: *const App) usize {
    return self.detail.top orelse self.detail.center -| self.contextRows() / 3;
}

fn drawDetail(self: *App) !void {
    const m = &self.model;
    const e = &m.entries[self.detail.center];
    const cat = m.cats[self.detail.center];
    var rows = self.screenRows(1, self.size.rows -| 1);

    // The full message, wrapped.
    const width = self.size.cols -| 4;
    var rest = e.message;
    for (0..self.messageLines()) |_| {
        const l = (try rows.next()) orelse return;
        try l.text("  ");
        try l.fg(color.priority(e.priority));
        try l.bold();
        const cut = codepointPrefix(rest, width);
        try l.text(rest[0..cut]);
        rest = rest[cut..];
    }

    var l = (try rows.next()) orelse return;
    try l.text("  ");
    try l.fg(color.base01);
    try l.date(e.usec);
    try l.text(" ");
    try l.clock(e.usec);
    try l.text(" · ");
    try l.fg(color.base0);
    try l.text(e.ident);
    if (e.unit.len > 0) {
        try l.fg(color.base01);
        try l.print(" ({s})", .{e.unit});
    }
    try l.fg(color.base01);
    try l.print(" · {s}", .{priority_names[e.priority]});
    if (cat != .none) {
        try l.text(" · ");
        try l.fg(color.of(cat));
        try l.text(cat.label());
    }
    if (self.detail.group) |g| if (g.count > 1) {
        try l.fg(color.yellow);
        try l.print(" · ×{d}, last at ", .{g.count});
        try l.clock(m.entries[g.last].usec);
    };

    _ = try rows.next();
    l = (try rows.next()) orelse return;
    try l.text("  ");
    try l.fg(color.base01);
    try l.text("context");

    const top = @min(self.detailTop(), m.entries.len -| self.contextRows());
    self.detail.top = top;
    var i = top;
    while (i < m.entries.len) : (i += 1) {
        l = (try rows.next()) orelse break;
        if (i == self.detail.center) try l.bg(color.base02);
        try ui.entryRow(l, &m.entries[i], m.cats[i]);
        if (i == self.detail.center) try l.fill();
    }
    while (try rows.next()) |_| {}
    try rows.close();
}

fn drawBoots(self: *App) !void {
    var rows = self.screenRows(1, self.size.rows -| 1);
    var l = (try rows.next()) orelse return;
    try l.text("  ");
    try l.fg(color.base1);
    try l.bold();
    try l.text("boots");
    try l.reset();
    try l.fg(color.base01);
    try l.text("  newest first; unclean = no \"Journal stopped\" at the end");

    const avail = self.size.rows -| (chrome_rows + 1);
    const p = &self.picker;
    if (p.sel < p.top) p.top = p.sel;
    if (p.sel >= p.top + avail) p.top = p.sel + 1 - avail;
    const n = self.boots.len;
    const loaded = Model.bootIndex(n, self.model.offset);
    for (p.top..n) |row| {
        l = (try rows.next()) orelse break;
        const index = n - 1 - row;
        const boot = &self.boots[index];
        if (row == p.sel) try l.bg(color.base02);
        try l.fg(color.blue);
        try l.text(if (loaded == index) " ● " else "   ");
        try l.fg(color.base1);
        var num: [16]u8 = undefined;
        try l.print("{s: >4}  ", .{std.fmt.bufPrint(&num, "{d}", .{-@as(i64, @intCast(row))}) catch "?"});
        try l.date(boot.first);
        try l.text("  ");
        try l.fg(color.base0);
        const start = l.used;
        try l.span(boot.last -| boot.first);
        try l.padTo(start + 9);
        if (index == n - 1) {
            try l.fg(color.blue);
            try l.text("running");
        } else if (boot.clean) {
            try l.fg(color.green);
            try l.text("clean");
        } else {
            try l.fg(color.red);
            try l.bold();
            try l.text("unclean");
        }
        if (row == p.sel) try l.fill();
    }
    while (try rows.next()) |_| {}
    try rows.close();
}

fn drawFooter(self: *App) !void {
    var rows = self.screenRows(self.size.rows -| 1, self.size.rows);
    const l = (try rows.next()) orelse return;
    try l.text(" ");
    if (self.typing) {
        try l.fg(color.yellow);
        try l.text("/");
        try l.fg(color.base1);
        try l.text(self.search.items);
        try l.fg(color.yellow);
        try l.text("▏");
        try l.fg(color.base01);
        try l.text("   enter keep · esc clear");
    } else if (self.status.len > 0) {
        try l.fg(color.yellow);
        try l.text(self.status);
    } else {
        try l.fg(color.base01);
        try l.text(switch (self.mode) {
            .main => "tab views · j/k move · enter details · / search · b boots · n noise · q quit",
            .detail => "j/k scroll · esc back",
            .boots => "j/k move · enter open · esc back",
        });
        if (self.mode == .main and self.view != .summary and self.visible.items.len > 0) {
            const pos = try std.fmt.allocPrint(self.gpa, "{d}/{d} ", .{ self.cursors.get(self.view).sel + 1, self.visible.items.len });
            defer self.gpa.free(pos);
            try l.padTo(self.size.cols -| pos.len);
            try l.text(pos);
        }
    }
    try rows.close();
}

/// The longest prefix of `s` that is at most `cols` codepoints, cut on a codepoint boundary.
fn codepointPrefix(s: []const u8, cols: usize) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < cols) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i = @min(s.len, i + len);
    }
    return i;
}

test codepointPrefix {
    try std.testing.expectEqual(3, codepointPrefix("abcdef", 3));
    try std.testing.expectEqual(4, codepointPrefix("a×b", 3));
    try std.testing.expectEqual(2, codepointPrefix("ab", 10));
}
