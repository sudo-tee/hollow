//! Typed, non-owning one-to-one links over runtime Client.session and
//! Session.client fields. No registry or allocation; events remain runtime policy.
const std = @import("std");

/// Link both sides, retiring any previous links. Return the displaced client
/// so the runtime can notify it after the new ownership is already consistent.
pub fn link(client: anytype, session: anytype) @TypeOf(session.client) {
    if (client.session) |old| {
        if (old != session) _ = unlink(client, old);
    }
    const previous = session.client;
    if (previous) |other| {
        if (other != client and other.session == session) other.session = null;
    }
    session.client = client;
    client.session = session;
    return if (previous == client) null else previous;
}

/// A stale detach must neither clear a newer owner nor its delivery backlog.
/// Return whether this client actually owned this session.
pub fn unlink(client: anytype, session: anytype) bool {
    const owned = session.client == client;
    if (owned) session.client = null;
    if (client.session == session) client.session = null;
    return owned;
}

test "takeover and session switching preserve identity-checked links" {
    const Test = struct {
        const Session = struct { client: ?*Client = null };
        const Client = struct { session: ?*Session = null };
    };
    var first: Test.Client = .{};
    var second: Test.Client = .{};
    var old: Test.Session = .{};
    var next: Test.Session = .{};
    try std.testing.expect(link(&first, &old) == null);
    try std.testing.expect(link(&first, &old) == null);
    try std.testing.expect(link(&second, &old) == &first);
    try std.testing.expect(first.session == null);
    try std.testing.expect(!unlink(&first, &old));
    try std.testing.expect(old.client == &second);
    try std.testing.expect(link(&second, &next) == null);
    try std.testing.expect(old.client == null);
    try std.testing.expect(!unlink(&second, &old));
    try std.testing.expect(second.session == &next and next.client == &second);
    try std.testing.expect(unlink(&second, &next));
    try std.testing.expect(!unlink(&second, &next));
    try std.testing.expect(second.session == null and next.client == null);
}
