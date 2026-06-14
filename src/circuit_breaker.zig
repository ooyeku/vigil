//! Circuit breaker pattern for Vigil.
//!
//! Circuit breakers protect a caller from repeatedly invoking a dependency
//! that is already failing. After enough failures the breaker opens and future
//! calls fail fast with `error.CircuitOpen` until the reset timeout allows a
//! limited half-open probe.

const std = @import("std");
const telemetry = @import("telemetry.zig");
const compat = @import("compat.zig");

/// Public state of a circuit breaker.
pub const CircuitState = enum {
    /// Normal operation. Calls are allowed and failures are counted.
    closed,
    /// Failing fast. Calls return `error.CircuitOpen` until reset timeout.
    open,
    /// Limited probe mode after reset timeout.
    half_open,
};

/// Configuration for circuit breaker thresholds and recovery behavior.
pub const CircuitBreakerConfig = struct {
    /// Consecutive failures needed to open the circuit.
    failure_threshold: u32 = 5,
    /// Time to wait before allowing half-open probes.
    reset_timeout_ms: u32 = 30_000,
    /// Maximum calls allowed while half-open.
    half_open_requests: u32 = 3,
    /// Successful half-open calls needed to close the circuit.
    half_open_success_threshold: u32 = 2,
};

/// Thread-safe circuit breaker.
///
/// The breaker owns a copied `circuit_id` for telemetry metadata. Call
/// `deinit()` when finished. `callError()` is the best fit for fallible
/// `!void` operations; `call()` is for infallible functions returning a value.
pub const CircuitBreaker = struct {
    /// Thresholds and timing rules.
    config: CircuitBreakerConfig,
    /// Current state.
    state: CircuitState,
    /// Consecutive failure count while closed.
    failure_count: u32,
    /// Successful probe count while half-open.
    success_count: u32,
    /// Last failure timestamp in milliseconds.
    last_failure_time_ms: i64,
    /// Calls already admitted while half-open.
    half_open_request_count: u32,
    /// Protects breaker state.
    mutex: compat.Mutex,
    /// Stable id used in telemetry events.
    circuit_id: []const u8,
    /// Allocator for copied id and telemetry helpers.
    allocator: std.mem.Allocator,

    /// Initialize a new closed circuit breaker.
    pub fn init(allocator: std.mem.Allocator, circuit_id: []const u8, config: CircuitBreakerConfig) !CircuitBreaker {
        const id_copy = try allocator.dupe(u8, circuit_id);
        errdefer allocator.free(id_copy);

        return .{
            .config = config,
            .state = .closed,
            .failure_count = 0,
            .success_count = 0,
            .last_failure_time_ms = 0,
            .half_open_request_count = 0,
            .mutex = .{},
            .circuit_id = id_copy,
            .allocator = allocator,
        };
    }

    /// Release the copied circuit id.
    pub fn deinit(self: *CircuitBreaker) void {
        self.allocator.free(self.circuit_id);
    }

    /// Execute an infallible function with circuit breaker protection.
    ///
    /// Returns `error.CircuitOpen` if the breaker is open or half-open capacity
    /// has been exhausted. Successful calls close the breaker once the
    /// half-open success threshold is reached.
    pub fn call(self: *CircuitBreaker, comptime T: type, func: *const fn () T) !T {
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if circuit should transition from open to half-open
            if (self.state == .open) {
                const now_ms = compat.milliTimestamp();
                const elapsed = now_ms - self.last_failure_time_ms;
                if (elapsed >= self.config.reset_timeout_ms) {
                    self.state = .half_open;
                    self.half_open_request_count = 0;
                    self.success_count = 0;
                    self.emitEvent(.circuit_half_open);
                } else {
                    return error.CircuitOpen;
                }
            }

            // Check half-open limits
            if (self.state == .half_open) {
                if (self.half_open_request_count >= self.config.half_open_requests) {
                    return error.CircuitOpen;
                }
                self.half_open_request_count += 1;
            }
        }

        // Execute the function
        const result = func();

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Handle success
            if (self.state == .half_open) {
                self.success_count += 1;
                if (self.success_count >= self.config.half_open_success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.half_open_request_count = 0;
                    self.success_count = 0;
                    self.emitEvent(.circuit_closed);
                }
            } else if (self.state == .closed) {
                // Reset failure count on success
                self.failure_count = 0;
            }
        }

        return result;
    }

    /// Execute a fallible operation with circuit breaker protection.
    ///
    /// Failures returned by `func` are counted and then returned to the caller.
    /// Once the failure threshold is reached the breaker opens and subsequent
    /// calls return `error.CircuitOpen` until the reset timeout has elapsed.
    pub fn callError(self: *CircuitBreaker, func: *const fn () anyerror!void) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if circuit should transition from open to half-open
            if (self.state == .open) {
                const now_ms = compat.milliTimestamp();
                const elapsed = now_ms - self.last_failure_time_ms;
                if (elapsed >= self.config.reset_timeout_ms) {
                    self.state = .half_open;
                    self.half_open_request_count = 0;
                    self.success_count = 0;
                    self.emitEvent(.circuit_half_open);
                } else {
                    return error.CircuitOpen;
                }
            }

            // Check half-open limits
            if (self.state == .half_open) {
                if (self.half_open_request_count >= self.config.half_open_requests) {
                    return error.CircuitOpen;
                }
                self.half_open_request_count += 1;
            }
        }

        // Execute the function
        func() catch |err| {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                self.recordFailure();
            }
            return err;
        };

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Handle success
            if (self.state == .half_open) {
                self.success_count += 1;
                if (self.success_count >= self.config.half_open_success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.half_open_request_count = 0;
                    self.success_count = 0;
                    self.emitEvent(.circuit_closed);
                }
            } else if (self.state == .closed) {
                // Reset failure count on success
                self.failure_count = 0;
            }
        }
    }

    /// Record a failure
    fn recordFailure(self: *CircuitBreaker) void {
        self.failure_count += 1;
        self.last_failure_time_ms = compat.milliTimestamp();

        if (self.state == .half_open) {
            // Failure in half-open - go back to open
            self.state = .open;
            self.half_open_request_count = 0;
            self.success_count = 0;
            self.emitEvent(.circuit_opened);
        } else if (self.state == .closed and self.failure_count >= self.config.failure_threshold) {
            // Too many failures - open circuit
            self.state = .open;
            self.emitEvent(.circuit_opened);
        }
    }

    /// Return the current breaker state.
    pub fn getState(self: *CircuitBreaker) CircuitState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }

    /// Force the breaker open and emit telemetry if this is a transition.
    pub fn forceOpen(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .open) {
            self.state = .open;
            self.last_failure_time_ms = compat.milliTimestamp();
            self.emitEvent(.circuit_opened);
        }
    }

    /// Force the breaker closed and reset counters.
    pub fn forceClose(self: *CircuitBreaker) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .closed) {
            self.state = .closed;
            self.failure_count = 0;
            self.half_open_request_count = 0;
            self.success_count = 0;
            self.emitEvent(.circuit_closed);
        }
    }

    /// Return the current consecutive failure count.
    pub fn getFailureCount(self: *CircuitBreaker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure_count;
    }

    /// Emit telemetry event
    fn emitEvent(self: *CircuitBreaker, event_type: telemetry.EventType) void {
        if (telemetry.getGlobal()) |t| {
            const event = telemetry.createCircuitEvent(
                self.allocator,
                event_type,
                self.circuit_id,
                switch (self.state) {
                    .closed => .closed,
                    .open => .opened,
                    .half_open => .half_open,
                },
                self.failure_count,
            ) catch return;
            defer {
                if (event.base.metadata) |m| self.allocator.free(m);
                self.allocator.free(event.circuit_id);
            }
            t.emit(event.base);
        }
    }
};

/// Error returned when a protected call is rejected by an open circuit.
pub const CircuitBreakerError = error{
    /// The dependency is currently considered unavailable.
    CircuitOpen,
};

test "CircuitBreaker basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var breaker = try CircuitBreaker.init(allocator, "test", .{});
    defer breaker.deinit();

    try std.testing.expect(breaker.getState() == .closed);

    const successFn = struct {
        fn call() u32 {
            return 42;
        }
    }.call;

    const result = try breaker.call(u32, successFn);
    try std.testing.expect(result == 42);
}

test "CircuitBreaker failure threshold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var breaker = try CircuitBreaker.init(allocator, "test", .{
        .failure_threshold = 3,
        .reset_timeout_ms = 100,
    });
    defer breaker.deinit();

    const failFn = struct {
        fn call() anyerror!void {
            return error.TestError;
        }
    }.call;

    // Fail 3 times
    for (0..3) |_| {
        breaker.callError(failFn) catch {};
    }

    // Circuit should be open
    try std.testing.expect(breaker.getState() == .open);

    // Next call should fail fast
    try std.testing.expectError(error.CircuitOpen, breaker.callError(failFn));
}

test "CircuitBreaker half-open recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var breaker = try CircuitBreaker.init(allocator, "test", .{
        .failure_threshold = 2,
        .reset_timeout_ms = 10,
        .half_open_requests = 3,
        .half_open_success_threshold = 2,
    });
    defer breaker.deinit();

    const failFn = struct {
        fn call() anyerror!void {
            return error.TestError;
        }
    }.call;

    const successFn = struct {
        fn call() anyerror!void {}
    }.call;

    // Open circuit
    for (0..2) |_| {
        breaker.callError(failFn) catch {};
    }
    try std.testing.expect(breaker.getState() == .open);

    // Wait for reset timeout
    compat.sleep(20 * std.time.ns_per_ms);

    // First call transitions to half-open
    breaker.callError(successFn) catch {};
    try std.testing.expect(breaker.getState() == .half_open);

    // Success should close circuit
    breaker.callError(successFn) catch {};
    breaker.callError(successFn) catch {};
    try std.testing.expect(breaker.getState() == .closed);
}
