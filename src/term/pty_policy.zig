//! Shared PTY work limits; pane API aliases and terminal polling use one source.
pub const parse_chunk_bytes: usize = 128 * 1024;
pub const pressure_parse_chunk_bytes: usize = 384 * 1024;
pub const hard_byte_limit: usize = 2 * 1024 * 1024;
pub const deferred_output_limit: usize = 4 * 1024 * 1024;
