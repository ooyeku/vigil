const std = @import("std");
const Allocator = std.mem.Allocator;
const vigil = @import("vigil.zig");

pub const SupervisorTree = struct {
    allocator: Allocator,
    main: vigil.Supervisor,
    children: std.ArrayList(vigil.Supervisor),

    pub fn init(allocator: Allocator, main_supervisor: vigil.Supervisor) SupervisorTree {
        return .{
            .allocator = allocator,
            .main = main_supervisor,
            .children = std.ArrayList(vigil.Supervisor).init(allocator),
        };
    }

    pub fn deinit(self: *SupervisorTree) void {
        self.children.deinit();
    }

    pub fn addChild(self: *SupervisorTree, child: vigil.Supervisor) !void {
        try self.children.append(child);
    }
};

test "initialize supervisor tree" {
    const v = @import("vigil.zig");

    const allocator = std.testing.allocator;
    const options = v.SupervisorOptions{
        .strategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };
    const supervisor_1 = v.Supervisor.init(allocator, options);
    const supervisor_2 = v.Supervisor.init(allocator, options);
    const supervisor_3 = v.Supervisor.init(allocator, options);

    var sup_tree = SupervisorTree.init(allocator, supervisor_1);
    defer sup_tree.deinit();
    try sup_tree.addChild(supervisor_2);
    try sup_tree.addChild(supervisor_3);

    try std.testing.expect(sup_tree.children.items.len == 2);
}
