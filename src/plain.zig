const std = @import("std");
const Writer = std.Io.Writer;

const Model = @import("Model.zig");
const pstore = @import("pstore.zig");
const ui = @import("ui.zig");

/// The Last section is capped, the TUI shows all of it.
const tail_lines = 40;

pub const Options = struct {
    colored: bool,
    /// List only the notable events that are new in this boot.
    only_new: bool,
};

pub fn write(w: *Writer, m: *const Model, store: pstore.Status, options: Options) Writer.Error!void {
    var rows: ui.Rows = .{ .w = w, .width = std.math.maxInt(usize), .colored = options.colored };
    try ui.summary(&rows, m, store, false);

    if (options.only_new) {
        try heading(&rows, "new", m.new_notable);
        if (m.compared == 0) {
            const l = (try rows.next()).?;
            try l.fg(ui.color.base01);
            try l.text("  no earlier boots to compare with");
        }
        for (m.notable) |g| {
            if (g.new) try ui.groupRow((try rows.next()).?, m, g);
        }
    } else if (m.notable.len > 0) {
        try heading(&rows, "notable", m.notable.len);
        for (m.notable) |g| try ui.groupRow((try rows.next()).?, m, g);
    }

    const tail = m.entries.len - m.tail;
    if (tail > 0) {
        try heading(&rows, "last 60 s", tail);
        const start = m.entries.len - @min(tail, tail_lines);
        if (start > m.tail) {
            const l = (try rows.next()).?;
            try l.fg(ui.color.base01);
            try l.print("  … {d} earlier lines (see the TUI)", .{start - m.tail});
        }
        for (m.entries[start..], m.cats[start..]) |*e, cat| try ui.entryRow((try rows.next()).?, e, cat);
    }
    try rows.close();
    try w.flush();
}

fn heading(rows: *ui.Rows, name: []const u8, count: usize) Writer.Error!void {
    _ = try rows.next();
    const l = (try rows.next()).?;
    try l.text("  ");
    try l.bold();
    try l.fg(ui.color.base1);
    try l.text(name);
    try l.reset();
    try l.fg(ui.color.base01);
    try l.print("  {d}", .{count});
}
