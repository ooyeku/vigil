//! Reliability policies for fallible operations.
//!
//! This module lets callers compose common production failure behavior around
//! an operation without scattering custom retry loops throughout an app. The
//! core helper, `execute()`, supports retry limits, fixed/exponential/jittered
//! backoff, synchronous timeout classification, fallback handlers, and optional
//! `CircuitBreaker` integration.
//!
//! Policies are intentionally explicit: callers provide a context pointer and
//! plain function pointers, so the common path is allocation-free and easy to
//! test. Timeout handling does not cancel a blocking function in the middle of
//! execution; it classifies the result when control returns to the policy.

const std = @import("std");
const CircuitBreaker = @import("circuit_breaker.zig").CircuitBreaker;
const compat = @import("compat.zig");

/// Final outcome category for a policy-protected operation.
pub const PolicyOutcome = enum {
    /// Operation completed without using fallback.
    success,
    /// Operation failed but another attempt remains.
    retry,
    /// Operation crossed its configured deadline.
    timeout,
    /// Fallback handler produced the returned value.
    fallback,
    /// Circuit breaker rejected the operation before it ran.
    circuit_open,
    /// Attempts were exhausted or fallback failed.
    permanent_failure,
};

/// Metadata returned for every terminal policy outcome.
pub const PolicyReport = struct {
    /// Final outcome represented by this report.
    outcome: PolicyOutcome,
    /// Number of times the protected operation was invoked.
    attempts: u32,
    /// Number of retry sleeps performed.
    retries: u32,
    /// Milliseconds measured by the policy clock from start to finish.
    elapsed_ms: i64,
    /// Last operation or fallback error, when one was observed.
    last_error: ?anyerror = null,
    /// Original failure category that caused a fallback result.
    fallback_from: ?PolicyOutcome = null,
};

/// Failure details passed into fallback handlers and returned by failures.
pub const PolicyFailure = struct {
    /// Failure category that triggered this value.
    outcome: PolicyOutcome,
    /// Number of operation attempts made before this failure.
    attempts: u32,
    /// Number of retry sleeps performed before this failure.
    retries: u32,
    /// Milliseconds measured by the policy clock.
    elapsed_ms: i64,
    /// Last operation or circuit error, when available.
    last_error: ?anyerror = null,

    /// Convert failure details into the common report shape.
    pub fn report(self: PolicyFailure) PolicyReport {
        return .{
            .outcome = self.outcome,
            .attempts = self.attempts,
            .retries = self.retries,
            .elapsed_ms = self.elapsed_ms,
            .last_error = self.last_error,
            .fallback_from = null,
        };
    }
};

/// Successful value plus policy metadata.
pub fn PolicySuccess(comptime T: type) type {
    return struct {
        /// Value returned by the operation or fallback handler.
        value: T,
        /// Metadata describing how the policy reached this value.
        report: PolicyReport,
    };
}

/// Typed terminal result for a policy-protected operation.
pub fn PolicyResult(comptime T: type) type {
    return union(enum) {
        /// The operation succeeded.
        success: PolicySuccess(T),
        /// The fallback handler succeeded after a failure condition.
        fallback: PolicySuccess(T),
        /// The operation crossed the configured timeout.
        timeout: PolicyFailure,
        /// A circuit breaker rejected the operation before it ran.
        circuit_open: PolicyFailure,
        /// Attempts were exhausted or fallback failed.
        permanent_failure: PolicyFailure,
    };
}

/// Exponential backoff configuration.
pub const ExponentialBackoff = struct {
    /// Delay after the first failed attempt.
    initial_ms: u32 = 10,
    /// Multiplier applied for each subsequent failed attempt.
    multiplier: u32 = 2,
    /// Maximum returned delay.
    max_ms: u32 = 1_000,
};

/// Deterministic jittered exponential backoff configuration.
pub const JitteredBackoff = struct {
    /// Base exponential backoff before jitter is applied.
    base: ExponentialBackoff = .{},
    /// Maximum extra jitter in milliseconds.
    jitter_ms: u32 = 0,
    /// Seed used to keep jitter deterministic in tests.
    seed: u64 = 0xa11c_e5eed,
};

/// Backoff strategy used between retry attempts.
pub const BackoffPolicy = union(enum) {
    /// Retry immediately.
    none,
    /// Sleep the same delay after each failed attempt.
    fixed_ms: u32,
    /// Increase delay after each failed attempt, capped by `max_ms`.
    exponential: ExponentialBackoff,
    /// Exponential delay plus deterministic positive jitter.
    jittered: JitteredBackoff,

    /// Return the delay after `failed_attempt` failures.
    ///
    /// Attempts are one-based: `delayMs(1)` is the delay after the first
    /// failed operation attempt.
    pub fn delayMs(self: BackoffPolicy, failed_attempt: u32) u32 {
        if (failed_attempt == 0) return 0;

        return switch (self) {
            .none => 0,
            .fixed_ms => |ms| ms,
            .exponential => |config| exponentialDelayMs(config, failed_attempt),
            .jittered => |config| blk: {
                const base = exponentialDelayMs(config.base, failed_attempt);
                const jitter = deterministicJitter(config.seed, failed_attempt, config.jitter_ms);
                const with_jitter = @as(u64, base) + @as(u64, jitter);
                break :blk @intCast(@min(with_jitter, config.base.max_ms));
            },
        };
    }
};

/// Retry policy for a protected operation.
pub const RetryPolicy = struct {
    /// Total attempts including the initial call. `1` means no retry.
    max_attempts: u32 = 1,
    /// Delay strategy used after each failed attempt that will be retried.
    backoff: BackoffPolicy = .none,

    /// Return true when another attempt should be made.
    pub fn shouldRetry(self: RetryPolicy, attempts_made: u32) bool {
        return attempts_made < @max(@as(u32, 1), self.max_attempts);
    }

    /// Return the backoff delay after `failed_attempt` failures.
    pub fn delayMs(self: RetryPolicy, failed_attempt: u32) u32 {
        return self.backoff.delayMs(failed_attempt);
    }
};

/// Options for `execute()`.
pub fn PolicyOptions(comptime Context: type, comptime T: type) type {
    return struct {
        /// Retry behavior for operation failures.
        retry: RetryPolicy = .{},
        /// Deadline in milliseconds. Synchronous work is not preempted; the
        /// deadline is checked before attempts, after attempts, and after
        /// retry sleeps.
        timeout_ms: ?u32 = null,
        /// Optional circuit breaker composed around every attempt.
        circuit_breaker: ?*CircuitBreaker = null,
        /// Optional fallback handler used for timeout, circuit-open, and
        /// permanent-failure outcomes.
        fallback: ?*const fn (*Context, PolicyFailure) anyerror!T = null,
        /// Clock hook for deterministic tests and simulated runtimes.
        clock: *const fn (*Context) i64 = defaultClock(Context),
        /// Sleep hook for deterministic tests and custom runtime schedulers.
        sleeper: *const fn (*Context, u64) void = defaultSleeper(Context),
    };
}

/// Execute an operation with retry, timeout, fallback, and optional
/// circuit-breaker composition.
pub fn execute(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    operation: *const fn (*Context) anyerror!T,
    options: PolicyOptions(Context, T),
) PolicyResult(T) {
    const start_ms = options.clock(context);
    var attempts: u32 = 0;
    var retries: u32 = 0;
    var last_error: ?anyerror = null;

    while (true) {
        if (timedOut(Context, T, context, options, start_ms)) {
            return finishFailure(Context, T, context, options, .timeout, attempts, retries, start_ms, last_error);
        }

        if (options.circuit_breaker) |breaker| {
            breaker.beforeCall() catch |err| {
                last_error = err;
                return finishFailure(Context, T, context, options, .circuit_open, attempts, retries, start_ms, last_error);
            };
        }

        attempts += 1;
        const value = operation(context) catch |err| {
            last_error = err;
            if (options.circuit_breaker) |breaker| {
                breaker.recordFailure();
            }

            if (timedOut(Context, T, context, options, start_ms)) {
                return finishFailure(Context, T, context, options, .timeout, attempts, retries, start_ms, last_error);
            }

            if (!options.retry.shouldRetry(attempts)) {
                return finishFailure(Context, T, context, options, .permanent_failure, attempts, retries, start_ms, last_error);
            }

            retries += 1;
            const delay_ms = options.retry.delayMs(attempts);
            if (delay_ms > 0) {
                options.sleeper(context, @as(u64, delay_ms) * std.time.ns_per_ms);
            }
            continue;
        };

        if (options.circuit_breaker) |breaker| {
            breaker.recordSuccess();
        }

        if (timedOut(Context, T, context, options, start_ms)) {
            return finishFailure(Context, T, context, options, .timeout, attempts, retries, start_ms, last_error);
        }

        return .{ .success = .{
            .value = value,
            .report = makeReport(Context, T, context, options, .success, attempts, retries, start_ms, last_error),
        } };
    }
}

fn defaultClock(comptime Context: type) *const fn (*Context) i64 {
    return struct {
        fn clock(_: *Context) i64 {
            return compat.milliTimestamp();
        }
    }.clock;
}

fn defaultSleeper(comptime Context: type) *const fn (*Context, u64) void {
    return struct {
        fn sleep(_: *Context, nanoseconds: u64) void {
            compat.sleep(nanoseconds);
        }
    }.sleep;
}

fn exponentialDelayMs(config: ExponentialBackoff, failed_attempt: u32) u32 {
    var delay: u64 = config.initial_ms;
    const multiplier = @max(@as(u32, 1), config.multiplier);
    var i: u32 = 1;
    while (i < failed_attempt) : (i += 1) {
        delay = @min(delay * multiplier, config.max_ms);
    }
    return @intCast(@min(delay, config.max_ms));
}

fn deterministicJitter(seed: u64, failed_attempt: u32, max_jitter_ms: u32) u32 {
    if (max_jitter_ms == 0) return 0;

    var x = seed ^ (@as(u64, failed_attempt) *% 0x9e37_79b9_7f4a_7c15);
    x ^= x >> 33;
    x *%= 0xff51_afd7_ed55_8ccd;
    x ^= x >> 33;
    x *%= 0xc4ce_b9fe_1a85_ec53;
    x ^= x >> 33;

    return @intCast(x % (@as(u64, max_jitter_ms) + 1));
}

fn timedOut(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    options: PolicyOptions(Context, T),
    start_ms: i64,
) bool {
    const limit = options.timeout_ms orelse return false;
    return elapsedMs(Context, T, context, options, start_ms) >= limit;
}

fn elapsedMs(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    options: PolicyOptions(Context, T),
    start_ms: i64,
) i64 {
    return @max(@as(i64, 0), options.clock(context) - start_ms);
}

fn makeReport(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    options: PolicyOptions(Context, T),
    outcome: PolicyOutcome,
    attempts: u32,
    retries: u32,
    start_ms: i64,
    last_error: ?anyerror,
) PolicyReport {
    return .{
        .outcome = outcome,
        .attempts = attempts,
        .retries = retries,
        .elapsed_ms = elapsedMs(Context, T, context, options, start_ms),
        .last_error = last_error,
    };
}

fn makeFailure(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    options: PolicyOptions(Context, T),
    outcome: PolicyOutcome,
    attempts: u32,
    retries: u32,
    start_ms: i64,
    last_error: ?anyerror,
) PolicyFailure {
    return .{
        .outcome = outcome,
        .attempts = attempts,
        .retries = retries,
        .elapsed_ms = elapsedMs(Context, T, context, options, start_ms),
        .last_error = last_error,
    };
}

fn finishFailure(
    comptime Context: type,
    comptime T: type,
    context: *Context,
    options: PolicyOptions(Context, T),
    outcome: PolicyOutcome,
    attempts: u32,
    retries: u32,
    start_ms: i64,
    last_error: ?anyerror,
) PolicyResult(T) {
    const failure = makeFailure(Context, T, context, options, outcome, attempts, retries, start_ms, last_error);

    if (options.fallback) |fallback| {
        const value = fallback(context, failure) catch |err| {
            const fallback_failure = makeFailure(Context, T, context, options, .permanent_failure, attempts, retries, start_ms, err);
            return .{ .permanent_failure = fallback_failure };
        };
        var report = makeReport(Context, T, context, options, .fallback, attempts, retries, start_ms, last_error);
        report.fallback_from = outcome;

        return .{ .fallback = .{
            .value = value,
            .report = report,
        } };
    }

    return switch (outcome) {
        .timeout => .{ .timeout = failure },
        .circuit_open => .{ .circuit_open = failure },
        else => .{ .permanent_failure = failure },
    };
}

test "BackoffPolicy returns fixed and capped exponential delays" {
    const fixed = BackoffPolicy{ .fixed_ms = 25 };
    try std.testing.expectEqual(@as(u32, 25), fixed.delayMs(1));
    try std.testing.expectEqual(@as(u32, 25), fixed.delayMs(8));

    const exponential = BackoffPolicy{ .exponential = .{
        .initial_ms = 10,
        .multiplier = 3,
        .max_ms = 80,
    } };

    try std.testing.expectEqual(@as(u32, 10), exponential.delayMs(1));
    try std.testing.expectEqual(@as(u32, 30), exponential.delayMs(2));
    try std.testing.expectEqual(@as(u32, 80), exponential.delayMs(4));
}

test "BackoffPolicy exponential delay saturates instead of overflowing" {
    const exponential = BackoffPolicy{ .exponential = .{
        .initial_ms = std.math.maxInt(u32),
        .multiplier = std.math.maxInt(u32),
        .max_ms = std.math.maxInt(u32),
    } };

    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), exponential.delayMs(16));
}

test "execute retries failed operation and reports attempts" {
    const Flaky = struct {
        attempts: u32 = 0,
        sleep_calls: u32 = 0,
        slept_ms: u32 = 0,
        now_ms: i64 = 0,

        fn operation(ctx: *@This()) anyerror!u32 {
            ctx.attempts += 1;
            if (ctx.attempts < 3) return error.TemporaryFailure;
            return 42;
        }

        fn clock(ctx: *@This()) i64 {
            return ctx.now_ms;
        }

        fn sleep(ctx: *@This(), nanoseconds: u64) void {
            ctx.sleep_calls += 1;
            const ms: u32 = @intCast(nanoseconds / std.time.ns_per_ms);
            ctx.slept_ms += ms;
            ctx.now_ms += ms;
        }
    };

    var ctx = Flaky{};
    const result = execute(Flaky, u32, &ctx, Flaky.operation, .{
        .retry = .{
            .max_attempts = 3,
            .backoff = .{ .fixed_ms = 5 },
        },
        .clock = Flaky.clock,
        .sleeper = Flaky.sleep,
    });

    switch (result) {
        .success => |success| {
            try std.testing.expectEqual(@as(u32, 42), success.value);
            try std.testing.expectEqual(@as(u32, 3), success.report.attempts);
            try std.testing.expectEqual(@as(u32, 2), success.report.retries);
            try std.testing.expectEqual(PolicyOutcome.success, success.report.outcome);
        },
        else => return error.ExpectedSuccess,
    }

    try std.testing.expectEqual(@as(u32, 3), ctx.attempts);
    try std.testing.expectEqual(@as(u32, 2), ctx.sleep_calls);
    try std.testing.expectEqual(@as(u32, 10), ctx.slept_ms);
}

test "execute reports timeout when synchronous operation exceeds deadline" {
    const Slow = struct {
        attempts: u32 = 0,
        now_ms: i64 = 0,

        fn operation(ctx: *@This()) anyerror!u32 {
            ctx.attempts += 1;
            ctx.now_ms += 15;
            return 99;
        }

        fn clock(ctx: *@This()) i64 {
            return ctx.now_ms;
        }

        fn sleep(_: *@This(), _: u64) void {}
    };

    var ctx = Slow{};
    const result = execute(Slow, u32, &ctx, Slow.operation, .{
        .timeout_ms = 10,
        .clock = Slow.clock,
        .sleeper = Slow.sleep,
    });

    switch (result) {
        .timeout => |failure| {
            try std.testing.expectEqual(@as(u32, 1), failure.attempts);
            try std.testing.expectEqual(PolicyOutcome.timeout, failure.outcome);
        },
        else => return error.ExpectedTimeout,
    }
}

test "execute uses fallback after retry exhaustion" {
    const Dependency = struct {
        attempts: u32 = 0,
        fallback_calls: u32 = 0,
        fallback_seen_outcome: ?PolicyOutcome = null,

        fn operation(ctx: *@This()) anyerror!u32 {
            ctx.attempts += 1;
            return error.DependencyUnavailable;
        }

        fn fallback(ctx: *@This(), failure: PolicyFailure) anyerror!u32 {
            ctx.fallback_calls += 1;
            ctx.fallback_seen_outcome = failure.outcome;
            return 7;
        }

        fn sleep(_: *@This(), _: u64) void {}
        fn clock(_: *@This()) i64 {
            return 0;
        }
    };

    var ctx = Dependency{};
    const result = execute(Dependency, u32, &ctx, Dependency.operation, .{
        .retry = .{ .max_attempts = 2 },
        .fallback = Dependency.fallback,
        .clock = Dependency.clock,
        .sleeper = Dependency.sleep,
    });

    switch (result) {
        .fallback => |fallback| {
            try std.testing.expectEqual(@as(u32, 7), fallback.value);
            try std.testing.expectEqual(@as(u32, 2), fallback.report.attempts);
            try std.testing.expectEqual(PolicyOutcome.fallback, fallback.report.outcome);
            try std.testing.expectEqual(PolicyOutcome.permanent_failure, fallback.report.fallback_from.?);
        },
        else => return error.ExpectedFallback,
    }

    try std.testing.expectEqual(@as(u32, 2), ctx.attempts);
    try std.testing.expectEqual(@as(u32, 1), ctx.fallback_calls);
    try std.testing.expectEqual(PolicyOutcome.permanent_failure, ctx.fallback_seen_outcome.?);
}

test "execute composes with circuit breaker and rejects while open" {
    const Failing = struct {
        attempts: u32 = 0,

        fn operation(ctx: *@This()) anyerror!void {
            ctx.attempts += 1;
            return error.UpstreamFailed;
        }

        fn sleep(_: *@This(), _: u64) void {}
        fn clock(_: *@This()) i64 {
            return 0;
        }
    };

    var breaker = try CircuitBreaker.init(std.testing.allocator, "upstream", .{
        .failure_threshold = 1,
        .reset_timeout_ms = 60_000,
    });
    defer breaker.deinit();

    var ctx = Failing{};
    const first = execute(Failing, void, &ctx, Failing.operation, .{
        .retry = .{ .max_attempts = 1 },
        .circuit_breaker = &breaker,
        .clock = Failing.clock,
        .sleeper = Failing.sleep,
    });
    try std.testing.expect(first == .permanent_failure);
    try std.testing.expectEqual(@as(u32, 1), ctx.attempts);

    const second = execute(Failing, void, &ctx, Failing.operation, .{
        .retry = .{ .max_attempts = 1 },
        .circuit_breaker = &breaker,
        .clock = Failing.clock,
        .sleeper = Failing.sleep,
    });

    switch (second) {
        .circuit_open => |failure| {
            try std.testing.expectEqual(@as(u32, 0), failure.attempts);
            try std.testing.expectEqual(PolicyOutcome.circuit_open, failure.outcome);
        },
        else => return error.ExpectedCircuitOpen,
    }
    try std.testing.expectEqual(@as(u32, 1), ctx.attempts);
}
