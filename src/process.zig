const std = @import("std");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const ProcessError = error{
    AlreadyRunning,
    StartFailed,
    ShutdownTimeout,
    OutOfMemory,
};

pub const ProcessState = enum {
    initial,
    running,
    stopping,
    stopped,
    failed,
};

pub const ChildSpec = struct {
    id: []const u8,
    start_fn: *const fn () void,
    restart_type: enum {
        permanent,
        transient,
        temporary,
    },
    shutdown_timeout_ms: u32,
};

pub const ChildProcess = struct {
    spec: ChildSpec,
    thread: ?Thread,
    mutex: Mutex,
    state: ProcessState,
    last_error: ?anyerror,

    pub fn init(spec: ChildSpec) ChildProcess {
        return .{
            .spec = spec,
            .thread = null,
            .mutex = Mutex{},
            .state = .initial,
            .last_error = null,
        };
    }

    pub fn start(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .running) return ProcessError.AlreadyRunning;

        const Context = struct {
            func: *const fn () void,
            process: *ChildProcess,
        };

        const wrapper = struct {
            fn wrap(ctx: *const Context) void {
                // Set initial state with mutex protection
                {
                    ctx.process.mutex.lock();
                    ctx.process.state = .running;
                    ctx.process.mutex.unlock();
                }

                // Run the function and ensure cleanup
                {
                    defer {
                        // Final state change and cleanup
                        const held = ctx.process.mutex.tryLock();
                        if (held) {
                            ctx.process.state = .stopped;
                            ctx.process.thread = null;
                            ctx.process.mutex.unlock();
                        }
                        std.heap.page_allocator.destroy(ctx);
                    }

                    // Run the actual function
                    nosuspend {
                        (ctx.func)();
                    }
                }
            }
        };

        // Allocate context that will be freed by the wrapper
        const context = try std.heap.page_allocator.create(Context);
        errdefer std.heap.page_allocator.destroy(context);

        context.* = .{
            .func = self.spec.start_fn,
            .process = self,
        };

        // Spawn thread with error handling
        self.thread = Thread.spawn(.{}, wrapper.wrap, .{context}) catch {
            std.heap.page_allocator.destroy(context);
            self.state = .failed;
            return ProcessError.StartFailed;
        };

        self.state = .running;
    }

    pub fn stop(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Allow stopping from any state except stopped
        if (self.state == .stopped) return;

        // Handle failed state
        if (self.state == .failed) {
            if (self.thread) |thread| {
                thread.detach();
                self.thread = null;
            }
            return;
        }

        self.state = .stopping;

        if (self.thread) |thread| {
            const start_time = std.time.milliTimestamp();

            while (true) {
                const elapsed = std.time.milliTimestamp() - start_time;
                if (elapsed > self.spec.shutdown_timeout_ms) {
                    thread.detach();
                    self.thread = null;
                    self.state = .failed;
                    return ProcessError.ShutdownTimeout;
                }

                // Check if thread has finished
                if (self.state == .stopped) {
                    thread.detach();
                    self.thread = null;
                    return;
                }

                // Release lock while sleeping
                self.mutex.unlock();
                std.time.sleep(10 * std.time.ns_per_ms);
                self.mutex.lock();
            }
        }

        self.state = .stopped;
        self.thread = null;
    }

    pub fn isAlive(self: *ChildProcess) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .running;
    }

    pub fn getState(self: *ChildProcess) ProcessState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
};

test "ChildProcess basic lifecycle" {
    const spec = ChildSpec{
        .id = "test_basic",
        .start_fn = struct {
            fn testFn() void {
                // Simple function that just sleeps briefly
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(spec);
    defer _ = process.stop() catch {};

    // Test initial state
    try std.testing.expectEqual(ProcessState.initial, process.getState());
    try std.testing.expect(!process.isAlive());

    // Test starting
    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());
    try std.testing.expect(process.isAlive());

    // Test double start should fail
    try std.testing.expectError(ProcessError.AlreadyRunning, process.start());

    // Wait for process to complete
    std.time.sleep(20 * std.time.ns_per_ms);

    // Test stopping
    try process.stop();
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(!process.isAlive());
}

test "ChildProcess timeout handling" {
    const spec = ChildSpec{
        .id = "test_timeout",
        .start_fn = struct {
            fn testFn() void {
                // Function that runs longer than timeout
                while (true) {
                    std.time.sleep(10 * std.time.ns_per_ms);
                }
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 50, // Short timeout for testing
    };

    var process = ChildProcess.init(spec);
    defer _ = process.stop() catch {};

    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());

    // Try to stop - should timeout
    try std.testing.expectError(ProcessError.ShutdownTimeout, process.stop());
    try std.testing.expectEqual(ProcessState.failed, process.getState());
}

test "ChildProcess error handling" {
    const spec = ChildSpec{
        .id = "test_error",
        .start_fn = struct {
            fn testFn() void {
                // Function that exits quickly
                std.time.sleep(5 * std.time.ns_per_ms);
            }
        }.testFn,
        .restart_type = .permanent,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(spec);
    errdefer _ = process.stop() catch {}; // Use errdefer for cleanup

    // Test failed start
    var bad_process = ChildProcess.init(spec);
    bad_process.state = .running; // Force into running state
    try std.testing.expectError(ProcessError.AlreadyRunning, bad_process.start());

    // Test normal process
    try process.start();
    try std.testing.expect(process.last_error == null);
    try std.testing.expect(process.thread != null);

    // Wait for completion and verify cleanup
    std.time.sleep(50 * std.time.ns_per_ms); // Increased wait time to ensure completion
    try process.stop();

    // Add a small delay after stop to ensure cleanup completes
    std.time.sleep(10 * std.time.ns_per_ms);

    // Verify final state
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(process.thread == null);
}

test "ChildProcess state transitions" {
    const spec = ChildSpec{
        .id = "test_states",
        .start_fn = struct {
            fn testFn() void {
                std.time.sleep(10 * std.time.ns_per_ms); // Reduced sleep time
            }
        }.testFn,
        .restart_type = .temporary,
        .shutdown_timeout_ms = 100,
    };

    var process = ChildProcess.init(spec);
    defer _ = process.stop() catch {};

    // Test state progression
    try std.testing.expectEqual(ProcessState.initial, process.getState());
    try process.start();
    try std.testing.expectEqual(ProcessState.running, process.getState());

    // Let it run a bit
    std.time.sleep(20 * std.time.ns_per_ms); // Increased wait time

    // Stop and verify final state
    try process.stop();
    try std.testing.expectEqual(ProcessState.stopped, process.getState());
    try std.testing.expect(!process.isAlive());
}
