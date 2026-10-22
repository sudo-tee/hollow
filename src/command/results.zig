//! Structural result contracts. Snapshot objects allow additive fields.
const std = @import("std");

pub const Frame = struct { x: usize, y: usize, width: usize, height: usize };
pub const Size = struct { rows: usize, cols: usize, width: usize, height: usize };
pub const Pane = struct {
    id: usize,
    pid: usize,
    domain: []const u8,
    cwd: []const u8,
    title: []const u8,
    foreground_process: []const u8,
    tags: []const []const u8,
    is_focused: bool,
    is_floating: bool,
    is_maximized: bool,
    frame: Frame,
    size: Size,
};
pub const Tab = struct { id: usize, title: []const u8, index: usize, is_active: bool, panes: []const Pane, pane: ?Pane };
pub const Workspace = struct { id: usize, index: usize, name: []const u8, domain: ?[]const u8, is_active: bool };
pub const TreeWorkspace = struct { id: usize, index: usize, name: []const u8, domain: ?[]const u8, is_active: bool, tabs: []const Tab };
pub const Domain = struct { name: []const u8, is_active: bool, is_default: bool, shell: ?[]const u8 = null, default_cwd: ?[]const u8 = null };
pub const Revision = struct { revision: u64 };
pub const Screenshot = struct { path: []const u8, width: usize, height: usize };
const Point = struct { row: usize, col: usize };
const Cursor = struct { position: ?Point, visible: bool, blinking: bool, password_input: bool, wide_tail: bool, style: []const u8 };
const Line = struct { row: usize, text: []const u8 };
pub const Screen = struct { revision: u64, pane_id: usize, rows: usize, cols: usize, coordinate_base: usize, active_screen: []const u8, cursor: Cursor, lines: []const Line };
const Bounds = struct { x: f64, y: f64, width: f64, height: f64 };
const Node = struct { id: []const u8, name: []const u8, surface: []const u8, role: []const u8, bounds: Bounds, actions: []const []const u8 };
pub const UiNodes = struct { revision: u64, generation: u64, valid: bool, truncated: bool, nodes: []const Node };
pub const Method = struct {
    name: []const u8,
    description: []const u8,
    input_schema: std.json.Value,
    output_schema: std.json.Value,
    completion: []const u8,
    transports: []const []const u8,
    validation_notes: []const u8,
    request_example: std.json.Value,
};

/// Unlike inputs, output snapshots deliberately permit additive fields.
pub fn schema(comptime T: type, writer: *std.Io.Writer) anyerror!void {
    if (T == std.json.Value) {
        try writer.writeAll("{}");
        return;
    }
    switch (@typeInfo(T)) {
        .void => try writer.writeAll("{\"type\":\"null\"}"),
        .bool => try writer.writeAll("{\"type\":\"boolean\"}"),
        .int => try writer.writeAll("{\"type\":\"integer\",\"minimum\":0}"),
        .float => try writer.writeAll("{\"type\":\"number\"}"),
        .optional => |info| {
            try writer.writeAll("{\"anyOf\":[");
            try schema(info.child, writer);
            try writer.writeAll(",{\"type\":\"null\"}]}");
        },
        .pointer => |info| {
            if (info.child == u8) try writer.writeAll("{\"type\":\"string\"}") else {
                try writer.writeAll("{\"type\":\"array\",\"items\":");
                try schema(info.child, writer);
                try writer.writeByte('}');
            }
        },
        .@"struct" => |info| {
            try writer.writeAll("{\"type\":\"object\",\"properties\":{");
            inline for (info.fields, 0..) |field, i| {
                if (i != 0) try writer.writeByte(',');
                try std.json.Stringify.value(field.name, .{}, writer);
                try writer.writeByte(':');
                try schema(field.type, writer);
            }
            try writer.writeAll("},\"required\":[");
            var first = true;
            inline for (info.fields) |field| {
                if (field.default_value_ptr == null) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try std.json.Stringify.value(field.name, .{}, writer);
                }
            }
            try writer.writeAll("]}");
        },
        else => @compileError("Unsupported result type " ++ @typeName(T)),
    }
}
