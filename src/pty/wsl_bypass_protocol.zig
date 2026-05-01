pub const version: u8 = 1;

pub const FrameType = enum(u8) {
    hello = 1,
    input = 2,
    output = 3,
    resize = 4,
    exit = 5,
};

pub const hello_payload = [_]u8{ 'H', 'W', 'B', version };
