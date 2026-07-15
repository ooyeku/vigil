//! Runtime-owned timer service.
//!
//! One scheduler thread drives every timeout, interval, and delayed send from
//! a min-heap of deadlines, replacing the thread-per-timer model of
//! `vigil.Timer` and the detached thread spawned by `Timer.sendAfter`. The
//! scheduler parks on a condition until the earliest deadline (or a schedule
//! change) and fires due work in deadline order.

const std = @import("std");
const compat = @import("compat.zig");
const messages = @import("messages.zig");
const Message = messages.Message;
const ProcessMailbox = messages.ProcessMailbox;

/// Value snapshot of timer-service state.
pub const TimerServiceSnapshot = struct {
    /// Whether the scheduler thread is running.
    running: bool,
    /// Timers currently scheduled (including cancelled entries not yet
    /// reaped).
    pending: usize,
    /// Callbacks and delayed sends fired over the service lifetime.
    fired: u64,
    /// Timers cancelled over the service lifetime.
    cancelled: u64,
};

/// Min-heap timer scheduler running on a single owned thread.
///
/// Create with `init`, call `start()` once, and `deinit()` when finished.
/// The service address must remain stable between `start()` and `deinit()`;
/// heap-allocate it or store it in a struct that never moves.
pub const TimerService = struct {
    /// Allocator for heap storage and delayed-send contexts.
    allocator: std.mem.Allocator,
    /// Pending timers ordered by deadline.
    heap: Heap,
    /// Ids cancelled before firing; reaped lazily when popped.
    cancelled_ids: std.AutoHashMapUnmanaged(u64, void),
    /// Id assigned to the next scheduled timer.
    next_id: u64,
    /// Lifetime fired counter.
    fired: u64,
    /// Lifetime cancelled counter.
    cancelled: u64,
    /// Scheduler thread handle.
    thread: ?std.Thread,
    /// True while the scheduler should keep running.
    running: bool,
    /// Protects all service state.
    mutex: compat.Mutex,
    /// Wakes the scheduler when the schedule changes or the service stops.
    changed: compat.Condition,

    const Action = union(enum) {
        /// Run a plain callback.
        callback: *const fn () void,
        /// Send an owned message to a mailbox.
        send: struct {
            mailbox: *ProcessMailbox,
            message: Message,
        },
    };

    const Entry = struct {
        deadline_ms: i64,
        id: u64,
        interval_ms: ?u32,
        action: Action,
    };

    const Heap = std.PriorityQueue(Entry, void, compareEntries);

    fn compareEntries(_: void, a: Entry, b: Entry) std.math.Order {
        const by_deadline = std.math.order(a.deadline_ms, b.deadline_ms);
        if (by_deadline != .eq) return by_deadline;
        return std.math.order(a.id, b.id);
    }

    /// Initialize a stopped timer service.
    pub fn init(allocator: std.mem.Allocator) TimerService {
        return .{
            .allocator = allocator,
            .heap = Heap.initContext({}),
            .cancelled_ids = .empty,
            .next_id = 1,
            .fired = 0,
            .cancelled = 0,
            .thread = null,
            .running = false,
            .mutex = .{},
            .changed = .{},
        };
    }

    /// Start the scheduler thread. Returns `error.AlreadyRunning` when
    /// started twice.
    pub fn start(self: *TimerService) !void {
        self.mutex.lock();
        if (self.running or self.thread != null) {
            self.mutex.unlock();
            return error.AlreadyRunning;
        }
        self.running = true;
        self.thread = std.Thread.spawn(.{}, schedulerLoop, .{self}) catch |err| {
            self.running = false;
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
    }

    /// Stop the scheduler thread and discard pending timers.
    ///
    /// Pending callbacks never fire; pending delayed sends are released
    /// without delivery. Safe to call when already stopped.
    pub fn stop(self: *TimerService) void {
        self.mutex.lock();
        self.running = false;
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock();
        self.changed.broadcast();

        if (thread) |handle| handle.join();

        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.heap.pop()) |entry| {
            switch (entry.action) {
                .callback => {},
                .send => |delivery| delivery.message.deinit(),
            }
        }
        self.cancelled_ids.clearRetainingCapacity();
    }

    /// Stop the scheduler and release all storage.
    pub fn deinit(self: *TimerService) void {
        self.stop();
        self.heap.deinit(self.allocator);
        self.cancelled_ids.deinit(self.allocator);
    }

    /// Run `callback` once after `delay_ms`. Returns a cancellation id.
    pub fn setTimeout(self: *TimerService, delay_ms: u32, callback: *const fn () void) !u64 {
        return try self.schedule(delay_ms, null, .{ .callback = callback });
    }

    /// Run `callback` every `interval_ms` until cancelled. Returns a
    /// cancellation id. Zero-length intervals are rejected.
    pub fn setInterval(self: *TimerService, interval_ms: u32, callback: *const fn () void) !u64 {
        if (interval_ms == 0) return error.InvalidInterval;
        return try self.schedule(interval_ms, interval_ms, .{ .callback = callback });
    }

    /// Deliver `msg` to `mailbox` after `delay_ms` without spawning a thread.
    ///
    /// Takes ownership of `msg` on success; on scheduling failure the message
    /// is released before returning. Returns a cancellation id; cancelling
    /// releases the undelivered message.
    pub fn sendAfter(
        self: *TimerService,
        delay_ms: u32,
        mailbox: *ProcessMailbox,
        msg: Message,
    ) !u64 {
        return self.schedule(delay_ms, null, .{ .send = .{
            .mailbox = mailbox,
            .message = msg,
        } }) catch |err| {
            msg.deinit();
            return err;
        };
    }

    fn schedule(self: *TimerService, delay_ms: u32, interval_ms: ?u32, action: Action) !u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (!self.running) return error.NotRunning;

        const id = self.next_id;
        try self.heap.push(self.allocator, .{
            .deadline_ms = compat.monotonicMilliTimestamp() +| @as(i64, delay_ms),
            .id = id,
            .interval_ms = interval_ms,
            .action = action,
        });
        self.next_id += 1;
        self.changed.signal();
        return id;
    }

    /// Cancel a pending timer. Returns false when the id is not pending.
    ///
    /// A cancelled delayed send releases its message the next time the
    /// scheduler reaps the entry.
    pub fn cancel(self: *TimerService, id: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        var found = false;
        var it = self.heap.iterator();
        while (it.next()) |entry| {
            if (entry.id == id) {
                found = true;
                break;
            }
        }
        if (!found) return false;

        self.cancelled_ids.put(self.allocator, id, {}) catch return false;
        self.cancelled +|= 1;
        self.changed.signal();
        return true;
    }

    /// Return the number of scheduled timers, including cancelled entries
    /// that have not been reaped yet.
    pub fn pendingCount(self: *TimerService) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.heap.count();
    }

    /// Return a value snapshot of service state and lifetime counters.
    pub fn snapshot(self: *TimerService) TimerServiceSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .running = self.running,
            .pending = self.heap.count(),
            .fired = self.fired,
            .cancelled = self.cancelled,
        };
    }

    fn schedulerLoop(self: *TimerService) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.running) {
            const next = self.heap.peek() orelse {
                self.changed.wait(&self.mutex);
                continue;
            };

            // Reap cancelled entries before considering deadlines.
            if (self.cancelled_ids.remove(next.id)) {
                const entry = self.heap.pop().?;
                switch (entry.action) {
                    .callback => {},
                    .send => |delivery| delivery.message.deinit(),
                }
                continue;
            }

            const now_ms = compat.monotonicMilliTimestamp();
            if (next.deadline_ms > now_ms) {
                const wait_ns = @as(u64, @intCast(next.deadline_ms - now_ms)) * std.time.ns_per_ms;
                self.changed.timedWait(&self.mutex, wait_ns) catch {};
                continue;
            }

            var entry = self.heap.pop().?;
            self.fired +|= 1;

            // Re-arm intervals before releasing the lock so cancel() can
            // always find a scheduled entry for a live interval.
            if (entry.interval_ms) |interval| {
                entry.deadline_ms = now_ms +| @as(i64, interval);
                self.heap.push(self.allocator, entry) catch {};
            }

            // Fire outside the lock so callbacks may schedule or cancel.
            self.mutex.unlock();
            switch (entry.action) {
                .callback => |callback| callback(),
                .send => |delivery| delivery.mailbox.send(delivery.message) catch {},
            }
            self.mutex.lock();
        }
    }
};

var service_test_hits = std.atomic.Value(u32).init(0);

fn recordServiceHit() void {
    _ = service_test_hits.fetchAdd(1, .monotonic);
}

test "TimerService fires timeouts and delivers delayed sends from one thread" {
    service_test_hits.store(0, .release);
    const allocator = std.testing.allocator;

    var service = TimerService.init(allocator);
    defer service.deinit();
    try service.start();
    try std.testing.expectError(error.AlreadyRunning, service.start());

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();

    _ = try service.setTimeout(5, recordServiceHit);
    const msg = try Message.init(allocator, "delayed", "timer", "payload", null, .normal, null);
    _ = try service.sendAfter(5, &mailbox, msg);

    var delivered = mailbox.receiveWait(500) catch return error.ExpectedDelivery;
    defer delivered.deinit();
    try std.testing.expectEqualStrings("delayed", delivered.id);

    var waited_ms: u32 = 0;
    while (service_test_hits.load(.acquire) == 0 and waited_ms < 500) : (waited_ms += 5) {
        compat.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u32, 1), service_test_hits.load(.acquire));

    const state = service.snapshot();
    try std.testing.expect(state.running);
    try std.testing.expectEqual(@as(u64, 2), state.fired);
}

test "TimerService intervals repeat until cancelled" {
    service_test_hits.store(0, .release);
    const allocator = std.testing.allocator;

    var service = TimerService.init(allocator);
    defer service.deinit();
    try service.start();

    try std.testing.expectError(error.InvalidInterval, service.setInterval(0, recordServiceHit));

    const id = try service.setInterval(2, recordServiceHit);
    var waited_ms: u32 = 0;
    while (service_test_hits.load(.acquire) < 3 and waited_ms < 1000) : (waited_ms += 5) {
        compat.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(service_test_hits.load(.acquire) >= 3);

    try std.testing.expect(service.cancel(id));
    try std.testing.expect(!service.cancel(id + 100));

    // After the cancellation is reaped, the count stays fixed.
    compat.sleep(20 * std.time.ns_per_ms);
    const count_after_cancel = service_test_hits.load(.acquire);
    compat.sleep(20 * std.time.ns_per_ms);
    try std.testing.expectEqual(count_after_cancel, service_test_hits.load(.acquire));
}

test "TimerService cancel releases undelivered sends and stop discards pending work" {
    service_test_hits.store(0, .release);
    const allocator = std.testing.allocator;

    var service = TimerService.init(allocator);
    defer service.deinit();
    try service.start();

    var mailbox = ProcessMailbox.init(allocator, .{ .capacity = 4 });
    defer mailbox.deinit();

    const cancelled_msg = try Message.init(allocator, "never", "timer", null, null, .normal, null);
    const send_id = try service.sendAfter(60_000, &mailbox, cancelled_msg);
    try std.testing.expect(service.cancel(send_id));

    _ = try service.setTimeout(60_000, recordServiceHit);
    const stop_msg = try Message.init(allocator, "dropped", "timer", null, null, .normal, null);
    _ = try service.sendAfter(60_000, &mailbox, stop_msg);

    service.stop();
    try std.testing.expectEqual(@as(usize, 0), service.pendingCount());
    try std.testing.expectEqual(@as(u32, 0), service_test_hits.load(.acquire));
    try std.testing.expectError(messages.MessageError.EmptyMailbox, mailbox.receive());
    try std.testing.expectError(error.NotRunning, service.setTimeout(1, recordServiceHit));
}

test "TimerService schedules many timers without one thread each" {
    service_test_hits.store(0, .release);
    const allocator = std.testing.allocator;

    var service = TimerService.init(allocator);
    defer service.deinit();
    try service.start();

    for (0..64) |_| {
        _ = try service.setTimeout(1, recordServiceHit);
    }

    var waited_ms: u32 = 0;
    while (service_test_hits.load(.acquire) < 64 and waited_ms < 2000) : (waited_ms += 5) {
        compat.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(u32, 64), service_test_hits.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), service.pendingCount());
}
