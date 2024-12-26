const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const Process = @import("process.zig");

pub const RestartStrategy = enum {
    one_for_one,
    one_for_all,
    rest_for_one,
};

pub const SupervisorOptions = struct {
    stategy: RestartStrategy,
    max_restarts: u32,
    max_seconds: u32,
};


pub const Supervisor = struct {
    allocator: Allocator,
    children: std.ArrayList(Process.ChildProcess),
    options: SupervisorOptions,
    restart_count: u32,
    last_restart_time: i64,
    mutex: Mutex,

    pub fn init(allocator: Allocator, options: SupervisorOptions) Supervisor {
        return .{
            .allocator = allocator,
            .children = std.ArrayList(Process.ChildProcess).init(allocator),
            .options = options,
            .restart_count = 0,
            .last_restart_time = 0,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.stopChildren();
        self.children.deinit();
    }

    pub fn addChild(self: *Supervisor, spec: Process.ChildSpec) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const child = Process.ChildProcess.init(spec);
        try self.children.append(child);
    }

    pub fn start(self: *Supervisor) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            try child.start();
        }
    }

    pub fn stopChildren(self: *Supervisor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.children.items) |*child| {
            child.stop() catch {};
        }
    }

    fn handleChildFailure(self: *Supervisor, failed_child: *Process.ChildProcess) !void {
        const current_time = std.time.milliTimestamp();
        const time_diff = current_time - self.last_restart_time;

        // Reset restart count if enough time has passed
        if (time_diff > self.options.max_seconds * 1000) {
            self.restart_count = 0;
        }

        self.restart_count += 1;
        if (self.restart_count > self.options.max_restarts) {
            // too many restarts, escaleate to parent supervisor or crash
            return error.TooManyRestarts;
        }

        self.last_restart_time = current_time;

        switch (self.options.stategy) {
            .one_for_one => {
                try failed_child.start();
            },
            .one_for_all => {
                self.stopChildren();
                try self.start();
            },
            .rest_for_one => {
                var found_failed = false;
                for (self.children.items) |*child| {
                    if (&child == &failed_child) {
                        found_failed = true;
                    }
                    if (found_failed) {
                        child.stop();
                        try child.start();
                    }
                }
            },
        }
    }

    // Monitor thread function that checks child processes
    fn monitorChildren(self: *Supervisor) !void {
        while (true) {
            self.mutex.lock();
            for (self.children.items) |*child| {
                if (!child.is_alive and child.spec.restart_type != .temporary) {
                    try self.handleChildFailure(child);
                }
            }
            self.mutex.unlock();
            std.time.sleep(100 * std.time.ns_per_ms);
        }
    }
};

fn testWorkerProcess() void {
    while (true) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }
}

test "supervisor basic operations" {
    const allocator = std.testing.allocator;

    const options = SupervisorOptions{
        .stategy = .one_for_one,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = Supervisor.init(allocator, options);
    defer supervisor.deinit();

    try supervisor.addChild(.{
        .id = "test1",
        .start_fn = &testWorkerProcess,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.start();

    try std.testing.expect(supervisor.children.items.len == 1);
}

test "supervisor restart strategies" {
    const allocator = std.testing.allocator;

    const options = SupervisorOptions{
        .stategy = .one_for_all,
        .max_restarts = 3,
        .max_seconds = 5,
    };

    var supervisor = Supervisor.init(allocator, options);
    defer supervisor.deinit();

    try supervisor.addChild(.{
        .id = "test1",
        .start_fn = &testWorkerProcess,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.addChild(.{
        .id = "test2",
        .start_fn = &testWorkerProcess,
        .restart_type = .transient,
        .shutdown_timeout_ms = 1000,
    });

    try supervisor.start();
    try std.testing.expect(supervisor.children.items.len == 2);

    supervisor.stopChildren();
    try std.testing.expect(!supervisor.children.items[0].is_alive);
    try std.testing.expect(!supervisor.children.items[1].is_alive);
}
