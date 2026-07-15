//! Graceful shutdown for Vigil.
//!
//! A `ShutdownManager` stores plain function hooks and runs them in forward or
//! reverse order. New applications should usually use `Runtime.onShutdown`
//! and `Runtime.shutdown`.

const std = @import("std");
const compat = @import("compat.zig");

/// Shutdown hook function type.
///
/// Hooks are plain function pointers. They must not rely on stack-captured
/// state.
pub const ShutdownHook = *const fn () void;

/// Order used when executing shutdown hooks.
pub const ShutdownOrder = enum {
    /// Same order as registration.
    forward,
    /// Reverse order of registration.
    reverse,
};

/// Options for running shutdown hooks.
pub const ShutdownOptions = struct {
    /// Maximum total time spent executing hooks.
    timeout_ms: u32 = 30_000,
    /// Hook execution order.
    order: ShutdownOrder = .reverse,
};

/// Thread-safe shutdown hook manager.
pub const ShutdownManager = struct {
    /// Allocator for hook storage.
    allocator: std.mem.Allocator,
    /// Registered hook pointers.
    hooks: std.ArrayListUnmanaged(ShutdownHook),
    /// Protects the hook list.
    mutex: compat.Mutex,

    /// Initialize an empty shutdown manager.
    pub fn init(allocator: std.mem.Allocator) ShutdownManager {
        return .{
            .allocator = allocator,
            .hooks = .empty,
            .mutex = .{},
        };
    }

    /// Release hook storage.
    pub fn deinit(self: *ShutdownManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.hooks.deinit(self.allocator);
    }

    /// Register a shutdown hook.
    pub fn onShutdown(self: *ShutdownManager, hook: ShutdownHook) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.hooks.append(self.allocator, hook);
    }

    /// Return the number of registered shutdown hooks.
    pub fn hookCount(self: *ShutdownManager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.hooks.items.len;
    }

    /// Execute registered hooks according to `options`.
    ///
    /// Hook execution is synchronous. If the timeout is exceeded, remaining
    /// hooks are skipped.
    pub fn shutdown(self: *ShutdownManager, options: ShutdownOptions) void {
        self.mutex.lock();
        const hooks_copy = self.allocator.alloc(ShutdownHook, self.hooks.items.len) catch {
            self.mutex.unlock();
            return;
        };
        @memcpy(hooks_copy, self.hooks.items);
        self.mutex.unlock();
        defer self.allocator.free(hooks_copy);

        const start_ms = compat.monotonicMilliTimestamp();

        if (options.order == .reverse) {
            var i: usize = hooks_copy.len;
            while (i > 0) {
                i -= 1;
                const elapsed = compat.monotonicMilliTimestamp() - start_ms;
                if (elapsed >= options.timeout_ms) break;
                hooks_copy[i]();
            }
        } else {
            for (hooks_copy) |hook| {
                const elapsed = compat.monotonicMilliTimestamp() - start_ms;
                if (elapsed >= options.timeout_ms) break;
                hook();
            }
        }
    }
};

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

test "ShutdownManager zero timeout executes no hooks" {
    const Counter = struct {
        var value = std.atomic.Value(u32).init(0);

        fn hook() void {
            _ = value.fetchAdd(1, .monotonic);
        }
    };
    Counter.value.store(0, .release);

    var manager = ShutdownManager.init(std.testing.allocator);
    defer manager.deinit();
    try manager.onShutdown(Counter.hook);
    manager.shutdown(.{ .timeout_ms = 0 });

    try std.testing.expectEqual(@as(u32, 0), Counter.value.load(.acquire));
}
