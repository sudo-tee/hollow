pub const CellPoint = struct {
    row: usize = 0,
    col: usize = 0,
};

pub const Range = struct {
    start: CellPoint,
    end: CellPoint,
    block: bool = false,
};

pub fn normalize(anchor: CellPoint, head: CellPoint) ?Range {
    if (anchor.row == head.row and anchor.col == head.col) return null;
    if (lessThanOrEqual(anchor, head)) {
        return .{ .start = anchor, .end = head };
    }
    return .{ .start = head, .end = anchor };
}

pub fn normalizeBlock(anchor: CellPoint, head: CellPoint) ?Range {
    if (anchor.row == head.row and anchor.col == head.col) return null;
    return .{
        .start = .{
            .row = @min(anchor.row, head.row),
            .col = @min(anchor.col, head.col),
        },
        .end = .{
            .row = @max(anchor.row, head.row),
            .col = @max(anchor.col, head.col),
        },
        .block = true,
    };
}

pub fn rowIntersects(range: Range, row: usize) bool {
    return row >= range.start.row and row <= range.end.row;
}

pub fn cellSelected(range: Range, row: usize, col: usize) bool {
    if (!rowIntersects(range, row)) return false;
    if (range.block) {
        return col >= range.start.col and col <= range.end.col;
    }
    if (range.start.row == range.end.row) {
        return col >= range.start.col and col <= range.end.col;
    }
    if (row == range.start.row) return col >= range.start.col;
    if (row == range.end.row) return col <= range.end.col;
    return true;
}

fn lessThanOrEqual(a: CellPoint, b: CellPoint) bool {
    if (a.row < b.row) return true;
    if (a.row > b.row) return false;
    return a.col <= b.col;
}
