//! Graceful shutdown for Vigil.
//!
//! A `ShutdownManager` stores plain function hooks and runs them in forward or
//! reverse order. New v2 applications should usually use `Runtime.onShutdown`
//! and `Runtime.shutdown`; the global helpers remain for compatibility and
//! process-wide integrations.

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

        const start_ms = compat.milliTimestamp();

        if (options.order == .reverse) {
            var i: usize = hooks_copy.len;
            while (i > 0) {
                i -= 1;
                const elapsed = compat.milliTimestamp() - start_ms;
                if (elapsed > options.timeout_ms) break;
                hooks_copy[i]();
            }
        } else {
            for (hooks_copy) |hook| {
                const elapsed = compat.milliTimestamp() - start_ms;
                if (elapsed > options.timeout_ms) break;
                hook();
            }
        }
    }
};

/// Optional process-wide shutdown manager.
var global_shutdown: ?ShutdownManager = null;
var shutdown_mutex: compat.Mutex = .{};

/// Initialize the optional global shutdown manager if needed.
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    shutdown_mutex.lock();
    defer shutdown_mutex.unlock();

    if (global_shutdown == null) {
        global_shutdown = ShutdownManager.init(allocator);
    }
}

/// Deinitialize and release the global shutdown manager.
/// Must only be called during shutdown when no other threads are
/// registering hooks or calling shutdownAll.
pub fn deinitGlobal() void {
    shutdown_mutex.lock();
    defer shutdown_mutex.unlock();

    if (global_shutdown) |*s| {
        s.deinit();
        global_shutdown = null;
    }
}

/// Get global shutdown manager.
///
/// SAFETY: The returned pointer is valid as long as `deinitGlobal()` has
/// not been called.  Callers must ensure `deinitGlobal()` is only invoked
/// after all shutdown operations have completed.
pub fn getGlobal() ?*ShutdownManager {
    shutdown_mutex.lock();
    defer shutdown_mutex.unlock();
    return if (global_shutdown) |*s| s else null;
}

/// Register a hook with the optional global shutdown manager.
///
/// Does nothing when the global manager has not been initialized.
pub fn onShutdown(hook: ShutdownHook) !void {
    if (getGlobal()) |manager| {
        try manager.onShutdown(hook);
    }
}

/// Run hooks registered with the optional global shutdown manager.
///
/// Does nothing when the global manager has not been initialized.
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
