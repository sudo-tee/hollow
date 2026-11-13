//! Owner-side process-tree lifetime. Assign the child while it is suspended:
//! otherwise it can create descendants before joining the job.
const std = @import("std");
const windows = std.os.windows;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: windows.DWORD = 0x00002000;
const JobObjectExtendedLimitInformation: windows.DWORD = 9;

const BasicLimits = extern struct {
    process_user_time: i64 = 0,
    job_user_time: i64 = 0,
    flags: windows.DWORD = 0,
    minimum_working_set: usize = 0,
    maximum_working_set: usize = 0,
    active_processes: windows.DWORD = 0,
    affinity: usize = 0,
    priority: windows.DWORD = 0,
    scheduling: windows.DWORD = 0,
};

const IoCounters = extern struct {
    read_operations: u64 = 0,
    write_operations: u64 = 0,
    other_operations: u64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    other_bytes: u64 = 0,
};

const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io: IoCounters = .{},
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

extern "kernel32" fn CreateJobObjectW(?*windows.SECURITY_ATTRIBUTES, ?windows.LPCWSTR) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(windows.HANDLE, windows.DWORD, *const anyopaque, windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn AssignProcessToJobObject(windows.HANDLE, windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) windows.BOOL;

pub const Job = struct {
    handle: ?windows.HANDLE,

    pub fn create() !Job {
        // Unnamed and noninheritable: only the owner keeps this handle alive.
        const handle = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
        errdefer _ = CloseHandle(handle);
        const limits: ExtendedLimits = .{ .basic = .{ .flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE } };
        if (SetInformationJobObject(handle, JobObjectExtendedLimitInformation, &limits, @sizeOf(ExtendedLimits)) == .FALSE)
            return error.SetJobLimitsFailed;
        return .{ .handle = handle };
    }

    pub fn assign(self: *const Job, process: windows.HANDLE) !void {
        const handle = self.handle orelse return error.JobClosed;
        if (AssignProcessToJobObject(handle, process) == .FALSE) return error.AssignJobFailed;
    }

    /// Explicit owner-side pane destruction, never GUI-view detach.
    pub fn close(self: *Job) void {
        const handle = self.handle orelse return;
        self.handle = null;
        _ = CloseHandle(handle);
    }
};

test "owner job assignment fails closed and close is idempotent" {
    var job = try Job.create();
    defer job.close();
    // INVALID_HANDLE_VALUE is also the current-process pseudo handle here.
    // Use a non-pseudo invalid handle so this test never assigns itself.
    const invalid: windows.HANDLE = @ptrFromInt(1);
    try std.testing.expectError(error.AssignJobFailed, job.assign(invalid));
    job.close();
    try std.testing.expect(job.handle == null);
    try std.testing.expectError(error.JobClosed, job.assign(invalid));
    job.close();
}
