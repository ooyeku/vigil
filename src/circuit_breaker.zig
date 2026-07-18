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

/// Value snapshot of circuit-breaker state.
pub const CircuitBreakerSnapshot = struct {
    /// Borrowed circuit id. Valid while the breaker remains alive.
    circuit_id: []const u8,
    /// Current circuit state.
    state: CircuitState,
    /// Consecutive failure count while closed.
    failure_count: u32,
    /// Successful probe count while half-open.
    success_count: u32,
    /// Last failure timestamp in milliseconds.
    last_failure_time_ms: i64,
    /// Calls already admitted while half-open.
    half_open_request_count: u32,
    /// Timestamp of the most recent state transition in milliseconds, or zero
    /// when the breaker has never left its initial closed state.
    last_transition_time_ms: i64,
    /// Number of times the breaker has transitioned to open.
    open_transitions: u32,
    /// Total failures recorded over the breaker lifetime.
    total_failures: u64,
    /// Total successes recorded over the breaker lifetime.
    total_successes: u64,
    /// Breaker thresholds and timing rules.
    config: CircuitBreakerConfig,
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
    /// Monotonic failure time used for reset deadlines.
    last_failure_monotonic_ms: i64,
    /// Calls already admitted while half-open.
    half_open_request_count: u32,
    /// Wall-clock timestamp of the most recent state transition.
    last_transition_time_ms: i64,
    /// Lifetime count of transitions to the open state.
    open_transitions: u32,
    /// Lifetime failure count across all states.
    total_failures: u64,
    /// Lifetime success count across all states.
    total_successes: u64,
    /// Protects breaker state.
    mutex: compat.Mutex,
    /// Stable id used in telemetry events.
    circuit_id: []const u8,
    /// Optional emitter for state-transition events.
    telemetry_emitter: ?*telemetry.TelemetryEmitter,
    /// Allocator for copied id and telemetry helpers.
    allocator: std.mem.Allocator,

    /// Initialize a new closed circuit breaker.
    pub fn init(allocator: std.mem.Allocator, circuit_id: []const u8, config: CircuitBreakerConfig) !CircuitBreaker {
        if (config.failure_threshold == 0 or
            config.half_open_requests == 0 or
            config.half_open_success_threshold == 0 or
            config.half_open_success_threshold > config.half_open_requests)
        {
            return error.InvalidConfiguration;
        }

        const id_copy = try allocator.dupe(u8, circuit_id);
        errdefer allocator.free(id_copy);

        return .{
            .config = config,
            .state = .closed,
            .failure_count = 0,
            .success_count = 0,
            .last_failure_time_ms = 0,
            .last_failure_monotonic_ms = 0,
            .half_open_request_count = 0,
            .last_transition_time_ms = 0,
            .open_transitions = 0,
            .total_failures = 0,
            .total_successes = 0,
            .mutex = .{},
            .circuit_id = id_copy,
            .telemetry_emitter = null,
            .allocator = allocator,
        };
    }

    /// Attach an emitter for circuit state-transition events.
    ///
    /// The emitter is not owned and must outlive the attachment.
    pub fn setTelemetryEmitter(self: *CircuitBreaker, emitter: ?*telemetry.TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.telemetry_emitter = emitter;
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
        try self.beforeCall();
        const result = func();
        self.recordSuccess();
        return result;
    }

    /// Execute a fallible operation with circuit breaker protection.
    ///
    /// Failures returned by `func` are counted and then returned to the caller.
    /// Once the failure threshold is reached the breaker opens and subsequent
    /// calls return `error.CircuitOpen` until the reset timeout has elapsed.
    pub fn callError(self: *CircuitBreaker, func: *const fn () anyerror!void) !void {
        try self.beforeCall();
        func() catch |err| {
            self.recordFailure();
            return err;
        };

        self.recordSuccess();
    }

    /// Reserve permission for one protected operation.
    ///
    /// Reliability policies use this when they need to compose circuit-breaker
    /// protection around operations that return values or use custom retry
    /// logic. Pair every successful reservation with either `recordSuccess()`
    /// or `recordFailure()`.
    pub fn beforeCall(self: *CircuitBreaker) CircuitBreakerError!void {
        self.mutex.lock();
        var transition: ?TelemetryTransition = null;

        if (self.state == .open) {
            const now_ms = compat.monotonicMilliTimestamp();
            const elapsed = now_ms - self.last_failure_monotonic_ms;
            if (elapsed >= self.config.reset_timeout_ms) {
                self.state = .half_open;
                self.half_open_request_count = 0;
                self.success_count = 0;
                transition = self.telemetryTransitionLocked(.circuit_half_open);
            } else {
                self.mutex.unlock();
                return error.CircuitOpen;
            }
        }

        if (self.state == .half_open) {
            if (self.half_open_request_count >= self.config.half_open_requests) {
                self.mutex.unlock();
                if (transition) |event| self.emitEvent(event);
                return error.CircuitOpen;
            }
            self.half_open_request_count +|= 1;
        }
        self.mutex.unlock();
        if (transition) |event| self.emitEvent(event);
    }

    /// Record a successful protected operation.
    pub fn recordSuccess(self: *CircuitBreaker) void {
        self.mutex.lock();
        var transition: ?TelemetryTransition = null;
        self.total_successes +|= 1;

        if (self.state == .half_open) {
            self.success_count +|= 1;
            if (self.success_count >= self.config.half_open_success_threshold) {
                self.state = .closed;
                self.failure_count = 0;
                self.half_open_request_count = 0;
                self.success_count = 0;
                transition = self.telemetryTransitionLocked(.circuit_closed);
            }
        } else if (self.state == .closed) {
            self.failure_count = 0;
        }
        self.mutex.unlock();
        if (transition) |event| self.emitEvent(event);
    }

    /// Record a failed protected operation.
    pub fn recordFailure(self: *CircuitBreaker) void {
        self.mutex.lock();
        const transition = self.recordFailureLocked();
        self.mutex.unlock();
        if (transition) |event| self.emitEvent(event);
    }

    fn recordFailureLocked(self: *CircuitBreaker) ?TelemetryTransition {
        self.failure_count +|= 1;
        self.total_failures +|= 1;
        self.last_failure_time_ms = compat.milliTimestamp();
        self.last_failure_monotonic_ms = compat.monotonicMilliTimestamp();

        if (self.state == .half_open) {
            // Failure in half-open - go back to open
            self.state = .open;
            self.half_open_request_count = 0;
            self.success_count = 0;
            return self.telemetryTransitionLocked(.circuit_opened);
        } else if (self.state == .closed and self.failure_count >= self.config.failure_threshold) {
            // Too many failures - open circuit
            self.state = .open;
            return self.telemetryTransitionLocked(.circuit_opened);
        }
        return null;
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
        var transition: ?TelemetryTransition = null;

        if (self.state != .open) {
            self.state = .open;
            self.last_failure_time_ms = compat.milliTimestamp();
            self.last_failure_monotonic_ms = compat.monotonicMilliTimestamp();
            transition = self.telemetryTransitionLocked(.circuit_opened);
        }
        self.mutex.unlock();
        if (transition) |event| self.emitEvent(event);
    }

    /// Force the breaker closed and reset counters.
    pub fn forceClose(self: *CircuitBreaker) void {
        self.mutex.lock();
        var transition: ?TelemetryTransition = null;

        if (self.state != .closed) {
            self.state = .closed;
            self.failure_count = 0;
            self.half_open_request_count = 0;
            self.success_count = 0;
            transition = self.telemetryTransitionLocked(.circuit_closed);
        }
        self.mutex.unlock();
        if (transition) |event| self.emitEvent(event);
    }

    /// Return the current consecutive failure count.
    pub fn getFailureCount(self: *CircuitBreaker) u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failure_count;
    }

    /// Return a value snapshot of breaker state and counters.
    pub fn snapshot(self: *CircuitBreaker) CircuitBreakerSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .circuit_id = self.circuit_id,
            .state = self.state,
            .failure_count = self.failure_count,
            .success_count = self.success_count,
            .last_failure_time_ms = self.last_failure_time_ms,
            .half_open_request_count = self.half_open_request_count,
            .last_transition_time_ms = self.last_transition_time_ms,
            .open_transitions = self.open_transitions,
            .total_failures = self.total_failures,
            .total_successes = self.total_successes,
            .config = self.config,
        };
    }

    const TelemetryTransition = struct {
        event_type: telemetry.EventType,
        state: CircuitState,
        failure_count: u32,
    };

    /// Record diagnostics for a state transition and build its telemetry
    /// payload. Every state change must flow through this helper.
    fn telemetryTransitionLocked(self: *CircuitBreaker, event_type: telemetry.EventType) TelemetryTransition {
        self.last_transition_time_ms = compat.milliTimestamp();
        if (self.state == .open) self.open_transitions +|= 1;
        return .{
            .event_type = event_type,
            .state = self.state,
            .failure_count = self.failure_count,
        };
    }

    /// Emit telemetry after releasing the breaker mutex so handlers may safely
    /// inspect or update this breaker.
    fn emitEvent(self: *CircuitBreaker, transition: TelemetryTransition) void {
        if (self.telemetry_emitter) |t| {
            const event = telemetry.createCircuitEvent(
                self.allocator,
                transition.event_type,
                self.circuit_id,
                switch (transition.state) {
                    .closed => .closed,
                    .open => .opened,
                    .half_open => .half_open,
                },
                transition.failure_count,
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

test "CircuitBreaker snapshot reports state and counters" {
    const allocator = std.testing.allocator;

    var breaker = try CircuitBreaker.init(allocator, "payments", .{
        .failure_threshold = 2,
        .reset_timeout_ms = 100,
    });
    defer breaker.deinit();

    const failFn = struct {
        fn call() anyerror!void {
            return error.TestError;
        }
    }.call;

    breaker.callError(failFn) catch {};
    const snapshot = breaker.snapshot();

    try std.testing.expectEqualStrings("payments", snapshot.circuit_id);
    try std.testing.expectEqual(CircuitState.closed, snapshot.state);
    try std.testing.expectEqual(@as(u32, 1), snapshot.failure_count);
    try std.testing.expectEqual(@as(u32, 0), snapshot.success_count);
    try std.testing.expectEqual(@as(u32, 2), snapshot.config.failure_threshold);
}

test "CircuitBreaker rejects configurations that cannot recover" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.InvalidConfiguration, CircuitBreaker.init(allocator, "zero-failures", .{
        .failure_threshold = 0,
    }));
    try std.testing.expectError(error.InvalidConfiguration, CircuitBreaker.init(allocator, "zero-probes", .{
        .half_open_requests = 0,
    }));
    try std.testing.expectError(error.InvalidConfiguration, CircuitBreaker.init(allocator, "impossible-recovery", .{
        .half_open_requests = 1,
        .half_open_success_threshold = 2,
    }));
}

test "CircuitBreaker telemetry handlers may inspect the emitting breaker" {
    const allocator = std.testing.allocator;
    var emitter = telemetry.TelemetryEmitter.init(allocator);
    defer emitter.deinit();

    var breaker = try CircuitBreaker.init(allocator, "reentrant", .{
        .failure_threshold = 1,
    });
    defer breaker.deinit();
    breaker.setTelemetryEmitter(&emitter);

    const Recorder = struct {
        var target: ?*CircuitBreaker = null;
        var calls = std.atomic.Value(u32).init(0);

        fn handle(_: telemetry.Event) void {
            _ = target.?.getState();
            _ = calls.fetchAdd(1, .monotonic);
        }
    };
    Recorder.target = &breaker;
    Recorder.calls.store(0, .release);
    try emitter.on(.circuit_opened, Recorder.handle);

    breaker.recordFailure();
    try std.testing.expectEqual(CircuitState.open, breaker.getState());
    try std.testing.expectEqual(@as(u32, 1), Recorder.calls.load(.acquire));
}

test "CircuitBreaker diagnostics track transitions and lifetime counters" {
    const allocator = std.testing.allocator;

    var breaker = try CircuitBreaker.init(allocator, "diagnostics", .{
        .failure_threshold = 2,
        .reset_timeout_ms = 60_000,
    });
    defer breaker.deinit();

    const initial = breaker.snapshot();
    try std.testing.expectEqual(@as(i64, 0), initial.last_transition_time_ms);
    try std.testing.expectEqual(@as(u32, 0), initial.open_transitions);

    breaker.recordSuccess();
    breaker.recordFailure();
    breaker.recordFailure();

    const opened = breaker.snapshot();
    try std.testing.expectEqual(CircuitState.open, opened.state);
    try std.testing.expectEqual(@as(u32, 1), opened.open_transitions);
    try std.testing.expectEqual(@as(u64, 2), opened.total_failures);
    try std.testing.expectEqual(@as(u64, 1), opened.total_successes);
    try std.testing.expect(opened.last_transition_time_ms > 0);

    breaker.forceClose();
    breaker.forceOpen();
    const reopened = breaker.snapshot();
    try std.testing.expectEqual(@as(u32, 2), reopened.open_transitions);
    try std.testing.expect(reopened.last_transition_time_ms >= opened.last_transition_time_ms);
}
