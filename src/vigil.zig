const std = @import("std");
pub const Supervisor = @import("supervisor.zig").Supervisor;
pub const SupervisorOptions = @import("supervisor.zig").SupervisorOptions;
pub const Process = @import("process.zig").ChildProcess;
pub const ChildSpec = @import("process.zig").ChildSpec;
pub const ProcessMailbox = @import("messages.zig").ProcessMailbox;

test "vigil" {
    _ = @import("process.zig");
    _ = @import("messages.zig");
    _ = @import("supervisor.zig");
}
