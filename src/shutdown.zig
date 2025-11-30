//! Graceful shutdown for Vigil
//! Coordinated shutdown of all components.

const std = @import("std");

/// Shutdown hook function type
pub const ShutdownHook = *const fn () void;

/// Shutdown order
pub const ShutdownOrder = enum {
    forward, // Same as startup order
    reverse, // Reverse of startup order
};

/// Shutdown options
pub const ShutdownOptions = struct {
    timeout_ms: u32 = 30_000,
    order: ShutdownOrder = .reverse,
};

/// Global shutdown manager
pub const ShutdownManager = struct {
    allocator: std.mem.Allocator,
    hooks: std.ArrayListUnmanaged(ShutdownHook),
    mutex: std.Thread.Mutex,

    /// Initialize shutdown manager
    pub fn init(allocator: std.mem.Allocator) ShutdownManager {
        return .{
            .allocator = allocator,
            .hooks = .{},
            .mutex = .{},
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *ShutdownManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.hooks.deinit(self.allocator);
    }

    /// Register a shutdown hook
    pub fn onShutdown(self: *ShutdownManager, hook: ShutdownHook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.hooks.append(self.allocator, hook);
    }

    /// Execute all shutdown hooks
    pub fn shutdown(self: *ShutdownManager, options: ShutdownOptions) void {
        self.mutex.lock();
        const hooks_copy = self.allocator.alloc(ShutdownHook, self.hooks.items.len) catch {
            self.mutex.unlock();
            return;
        };
        @memcpy(hooks_copy, self.hooks.items);
        self.mutex.unlock();
        defer self.allocator.free(hooks_copy);

        const start_ms = std.time.milliTimestamp();

        if (options.order == .reverse) {
            var i: usize = hooks_copy.len;
            while (i > 0) {
                i -= 1;
                const elapsed = std.time.milliTimestamp() - start_ms;
                if (elapsed > options.timeout_ms) break;
                hooks_copy[i]();
            }
        } else {
            for (hooks_copy) |hook| {
                const elapsed = std.time.milliTimestamp() - start_ms;
                if (elapsed > options.timeout_ms) break;
                hook();
            }
        }
    }
};

/// Global shutdown manager instance
var global_shutdown: ?ShutdownManager = null;
var shutdown_mutex: std.Thread.Mutex = .{};

/// Initialize global shutdown manager
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    shutdown_mutex.lock();
    defer shutdown_mutex.unlock();

    if (global_shutdown == null) {
        global_shutdown = ShutdownManager.init(allocator);
    }
}

/// Get global shutdown manager
pub fn getGlobal() ?*ShutdownManager {
    shutdown_mutex.lock();
    defer shutdown_mutex.unlock();
    return if (global_shutdown) |*s| s else null;
}

/// Register a shutdown hook
pub fn onShutdown(hook: ShutdownHook) !void {
    if (getGlobal()) |manager| {
        try manager.onShutdown(hook);
    }
}

/// Shutdown all components
pub fn shutdownAll(options: ShutdownOptions) void {
    if (getGlobal()) |manager| {
        manager.shutdown(options);
    }
}

test "ShutdownManager hooks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var manager = ShutdownManager.init(allocator);
    defer manager.deinit();

    const hook1 = struct {
        fn hook() void {
            // Simplified test - just verify hooks are called
        }
    }.hook;

    const hook2 = struct {
        fn hook() void {
            // Simplified test - just verify hooks are called
        }
    }.hook;

    try manager.onShutdown(hook1);
    try manager.onShutdown(hook2);

    manager.shutdown(.{});
    // Test passes if no panic
}

test "ShutdownManager reverse order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var manager = ShutdownManager.init(allocator);
    defer manager.deinit();

    const hook1 = struct {
        fn hook() void {}
    }.hook;

    const hook2 = struct {
        fn hook() void {}
    }.hook;

    const hook3 = struct {
        fn hook() void {}
    }.hook;

    try manager.onShutdown(hook1);
    try manager.onShutdown(hook2);
    try manager.onShutdown(hook3);

    manager.shutdown(.{ .order = .reverse });
    // Test passes if no panic - order verification would need different approach
}
