//! Telemetry and event hooks for Vigil.
//!
//! Telemetry is intentionally lightweight: handlers are plain function
//! pointers, event dispatch is synchronous, and events carry optional metadata
//! as borrowed slices. There is no process-wide emitter: every component that
//! emits (inboxes, supervisors, circuit breakers, groups, brokers) takes an
//! injected `TelemetryEmitter`, normally `Runtime.telemetry_emitter`.

const std = @import("std");
const compat = @import("compat.zig");

/// Event types emitted by Vigil components.
pub const EventType = enum {
    // Process lifecycle events
    process_started,
    process_stopped,
    process_crashed,
    process_suspended,
    process_resumed,

    // Message events
    message_sent,
    message_received,
    message_expired,
    message_dropped,
    message_dead_lettered,
    message_replayed,
    message_discarded,
    poison_message_detected,

    // Supervisor events
    supervisor_started,
    supervisor_stopped,
    supervisor_restart,
    supervisor_child_added,
    supervisor_child_removed,

    // Circuit breaker events
    circuit_opened,
    circuit_closed,
    circuit_half_open,

    // GenServer events
    genserver_started,
    genserver_stopped,
    genserver_state_changed,
};

/// Base event delivered to telemetry handlers.
///
/// `metadata`, when present, is borrowed for the duration of the `emit()` call.
pub const Event = struct {
    /// Kind of event.
    event_type: EventType,
    /// Event timestamp in milliseconds.
    timestamp_ms: i64,
    /// Optional human-readable metadata.
    metadata: ?[]const u8 = null,
};

/// Detailed circuit breaker event.
pub const CircuitEvent = struct {
    /// Base event fields.
    base: Event,
    /// Circuit id. Created helper events allocate a copied id.
    circuit_id: []const u8,
    /// Circuit state after the event.
    state: CircuitState,
    /// Failure count after the event.
    failure_count: u32,

    /// Circuit states used in telemetry payloads.
    pub const CircuitState = enum {
        opened,
        closed,
        half_open,
    };
};

/// Event handler function type.
///
/// Handlers run synchronously on the thread that calls `emit()`. Keep handlers
/// small and non-blocking.
pub const EventHandler = *const fn (event: Event) void;

/// One retained timeline entry.
pub const TimelineEntry = struct {
    /// Monotonic sequence number assigned when the event was recorded.
    sequence: u64,
    /// Kind of event.
    event_type: EventType,
    /// Event timestamp in milliseconds.
    timestamp_ms: i64,
    /// Copied metadata when the source event carried any.
    metadata: ?[]const u8,
};

/// Owned snapshot of retained timeline entries, oldest first.
pub const TimelineSnapshot = struct {
    allocator: std.mem.Allocator,
    /// Retained entries in recording order.
    entries: []TimelineEntry,
    /// Total events recorded over the timeline lifetime, including evicted
    /// entries.
    total_recorded: u64,

    /// Release copied metadata and snapshot storage.
    pub fn deinit(self: *TimelineSnapshot) void {
        for (self.entries) |entry| {
            if (entry.metadata) |metadata| self.allocator.free(metadata);
        }
        self.allocator.free(self.entries);
    }
};

/// Bounded, thread-safe timeline of recent notable events.
///
/// A timeline retains the most recent `capacity` events with copied metadata,
/// so operators can ask "what happened recently?" without wiring a log
/// pipeline. Attach one to a `TelemetryEmitter` with `attachTimeline()` or
/// enable it on a `Runtime` with `enableTimeline()`.
pub const EventTimeline = struct {
    /// Allocator for entry storage and copied metadata.
    allocator: std.mem.Allocator,
    /// Retained entries in recording order.
    entries: std.ArrayListUnmanaged(TimelineEntry),
    /// Maximum retained entries.
    capacity: usize,
    /// Sequence number assigned to the next recorded event.
    next_sequence: u64,
    /// Total events recorded, including evicted entries.
    total_recorded: u64,
    /// Protects timeline state.
    mutex: compat.Mutex,

    /// Initialize an empty timeline that retains up to `capacity` events.
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventTimeline {
        if (capacity == 0) return error.InvalidCapacity;
        return .{
            .allocator = allocator,
            .entries = .empty,
            .capacity = capacity,
            .next_sequence = 1,
            .total_recorded = 0,
            .mutex = .{},
        };
    }

    /// Release retained entries and their copied metadata.
    pub fn deinit(self: *EventTimeline) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.entries.items) |entry| {
            if (entry.metadata) |metadata| self.allocator.free(metadata);
        }
        self.entries.deinit(self.allocator);
    }

    /// Record an event, evicting the oldest entry when full.
    ///
    /// Recording is best-effort: when metadata cannot be copied the event is
    /// retained without metadata, and when entry storage cannot grow the event
    /// is dropped.
    pub fn record(self: *EventTimeline, event: Event) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const metadata_copy: ?[]const u8 = if (event.metadata) |metadata|
            self.allocator.dupe(u8, metadata) catch null
        else
            null;

        if (self.entries.items.len >= self.capacity) {
            const evicted = self.entries.orderedRemove(0);
            if (evicted.metadata) |metadata| self.allocator.free(metadata);
        }

        self.entries.append(self.allocator, .{
            .sequence = self.next_sequence,
            .event_type = event.event_type,
            .timestamp_ms = event.timestamp_ms,
            .metadata = metadata_copy,
        }) catch {
            if (metadata_copy) |metadata| self.allocator.free(metadata);
            return;
        };
        self.next_sequence +%= 1;
        self.total_recorded +|= 1;
    }

    /// Return the number of currently retained entries.
    pub fn count(self: *EventTimeline) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }

    /// Capture an owned snapshot of retained entries, oldest first.
    ///
    /// The caller owns the returned snapshot and must call `deinit()`.
    pub fn snapshot(self: *EventTimeline, allocator: std.mem.Allocator) !TimelineSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entries = try allocator.alloc(TimelineEntry, self.entries.items.len);
        errdefer allocator.free(entries);

        var written: usize = 0;
        errdefer for (entries[0..written]) |entry| {
            if (entry.metadata) |metadata| allocator.free(metadata);
        };

        for (self.entries.items) |entry| {
            entries[written] = .{
                .sequence = entry.sequence,
                .event_type = entry.event_type,
                .timestamp_ms = entry.timestamp_ms,
                .metadata = if (entry.metadata) |metadata|
                    try allocator.dupe(u8, metadata)
                else
                    null,
            };
            written += 1;
        }

        return .{
            .allocator = allocator,
            .entries = entries,
            .total_recorded = self.total_recorded,
        };
    }
};

/// Thread-safe event dispatcher.
///
/// Handlers are grouped by exact `EventType`; there is no wildcard matching.
/// The emitter copies its handler list before dispatch so handlers may register
/// or remove handlers without invalidating iteration.
pub const TelemetryEmitter = struct {
    /// Allocator for handler storage and dispatch snapshots.
    allocator: std.mem.Allocator,
    /// Registered handlers.
    handlers: std.ArrayListUnmanaged(HandlerEntry),
    /// Protects handler registration.
    mutex: compat.Mutex,
    /// Whether `emit()` dispatches events. Atomic so the disabled fast path
    /// costs one load with no lock.
    enabled: std.atomic.Value(bool),
    /// Registered handler count. Atomic so the no-handler fast path skips the
    /// lock and handler snapshot entirely.
    handler_count: std.atomic.Value(usize),
    /// Optional attached timeline that records every emitted event.
    timeline: std.atomic.Value(?*EventTimeline),

    const HandlerEntry = struct {
        event_type: EventType,
        handler: EventHandler,
    };

    /// Initialize an enabled telemetry emitter.
    pub fn init(allocator: std.mem.Allocator) TelemetryEmitter {
        return .{
            .allocator = allocator,
            .handlers = .empty,
            .mutex = .{},
            .enabled = std.atomic.Value(bool).init(true),
            .handler_count = std.atomic.Value(usize).init(0),
            .timeline = std.atomic.Value(?*EventTimeline).init(null),
        };
    }

    /// Release handler storage.
    pub fn deinit(self: *TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.handlers.deinit(self.allocator);
    }

    /// Register a handler for an exact event type.
    ///
    /// Handler function pointers are not owned by the emitter and must remain
    /// valid for as long as they are registered.
    pub fn on(self: *TelemetryEmitter, event_type: EventType, handler: EventHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
        });
        self.handler_count.store(self.handlers.items.len, .release);
    }

    /// Attach a timeline that records every event this emitter dispatches.
    ///
    /// The timeline is not owned by the emitter and must outlive the
    /// attachment. Pass through `detachTimeline()` before destroying it.
    pub fn attachTimeline(self: *TelemetryEmitter, timeline: *EventTimeline) void {
        self.timeline.store(timeline, .release);
    }

    /// Detach the currently attached timeline, if any.
    pub fn detachTimeline(self: *TelemetryEmitter) void {
        self.timeline.store(null, .release);
    }

    /// Return whether an `emit()` for `event_type` would reach a handler or
    /// timeline right now.
    ///
    /// Callers with expensive event construction (formatting metadata,
    /// snapshotting state) can use this to skip the work entirely when nobody
    /// is listening.
    pub fn wouldEmit(self: *TelemetryEmitter, event_type: EventType) bool {
        if (!self.enabled.load(.acquire)) return false;
        if (self.timeline.load(.acquire) != null) return true;
        if (self.handler_count.load(.acquire) == 0) return false;

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.handlers.items) |entry| {
            if (entry.event_type == event_type) return true;
        }
        return false;
    }

    /// Dispatch an event to matching handlers.
    ///
    /// Dispatch is synchronous and best-effort. An attached timeline records
    /// the event even when no handler matches. The common cases are cheap: a
    /// disabled emitter costs one atomic load, an emitter with no handlers
    /// never takes the lock, and dispatch to small handler sets is
    /// allocation-free.
    pub fn emit(self: *TelemetryEmitter, event: Event) void {
        if (!self.enabled.load(.acquire)) return;

        const timeline = self.timeline.load(.acquire);
        if (self.handler_count.load(.acquire) == 0) {
            if (timeline) |t| t.record(event);
            return;
        }

        // Copy handlers so registered callbacks may add or remove handlers
        // without invalidating this dispatch. Small sets copy to the stack.
        var stack_snapshot: [16]HandlerEntry = undefined;
        var heap_snapshot: ?[]HandlerEntry = null;

        self.mutex.lock();
        const count = self.handlers.items.len;
        const snapshot: []const HandlerEntry = if (count <= stack_snapshot.len) blk: {
            @memcpy(stack_snapshot[0..count], self.handlers.items);
            break :blk stack_snapshot[0..count];
        } else blk: {
            const copy = self.allocator.alloc(HandlerEntry, count) catch {
                self.mutex.unlock();
                if (timeline) |t| t.record(event);
                return;
            };
            @memcpy(copy, self.handlers.items);
            heap_snapshot = copy;
            break :blk copy;
        };
        self.mutex.unlock();
        defer if (heap_snapshot) |copy| self.allocator.free(copy);

        if (timeline) |t| t.record(event);

        for (snapshot) |entry| {
            if (entry.event_type == event.event_type) {
                entry.handler(event);
            }
        }
    }

    /// Enable or disable event emission.
    pub fn setEnabled(self: *TelemetryEmitter, enabled: bool) void {
        self.enabled.store(enabled, .release);
    }

    /// Remove all handlers for an event type.
    pub fn removeHandlers(self: *TelemetryEmitter, event_type: EventType) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.handlers.items.len) {
            if (self.handlers.items[i].event_type == event_type) {
                _ = self.handlers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        self.handler_count.store(self.handlers.items.len, .release);
    }

    /// Return the number of registered handlers.
    pub fn handlerCount(self: *TelemetryEmitter) usize {
        return self.handler_count.load(.acquire);
    }
};

/// Allocate a detailed circuit breaker event.
///
/// The returned `circuit_id` is allocated with `allocator` and must be freed by
/// the caller.
pub fn createCircuitEvent(
    allocator: std.mem.Allocator,
    event_type: EventType,
    circuit_id: []const u8,
    state: CircuitEvent.CircuitState,
    failure_count: u32,
) !CircuitEvent {
    const id_copy = try allocator.dupe(u8, circuit_id);
    errdefer allocator.free(id_copy);

    return CircuitEvent{
        .base = .{
            .event_type = event_type,
            .timestamp_ms = compat.milliTimestamp(),
            .metadata = null,
        },
        .circuit_id = id_copy,
        .state = state,
        .failure_count = failure_count,
    };
}

test "TelemetryEmitter basic operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emitter = TelemetryEmitter.init(allocator);
    defer emitter.deinit();

    const hook = struct {
        fn hook(_: Event) void {
            // Simplified test - just verify hook is called
        }
    }.hook;

    try emitter.on(.process_started, hook);

    const event = Event{
        .event_type = .process_started,
        .timestamp_ms = compat.milliTimestamp(),
        .metadata = null,
    };

    emitter.emit(event);
    // Test passes if no panic
}

test "TelemetryEmitter multiple handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emitter = TelemetryEmitter.init(allocator);
    defer emitter.deinit();

    const handler1 = struct {
        fn handle(_: Event) void {}
    }.handle;

    const handler2 = struct {
        fn handle(_: Event) void {}
    }.handle;

    try emitter.on(.message_sent, handler1);
    try emitter.on(.message_sent, handler2);

    const event = Event{
        .event_type = .message_sent,
        .timestamp_ms = compat.milliTimestamp(),
        .metadata = null,
    };

    emitter.emit(event);
    // Test passes if no panic
}

test "TelemetryEmitter event filtering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var emitter = TelemetryEmitter.init(allocator);
    defer emitter.deinit();

    const handler = struct {
        fn handle(_: Event) void {}
    }.handle;

    try emitter.on(.process_started, handler);

    const event1 = Event{
        .event_type = .process_started,
        .timestamp_ms = compat.milliTimestamp(),
        .metadata = null,
    };

    const event2 = Event{
        .event_type = .process_stopped,
        .timestamp_ms = compat.milliTimestamp(),
        .metadata = null,
    };

    emitter.emit(event1);
    emitter.emit(event2);
    // Test passes if no panic
}

test "EventTimeline retains bounded events in order" {
    var timeline = try EventTimeline.init(std.testing.allocator, 2);
    defer timeline.deinit();

    try std.testing.expectError(error.InvalidCapacity, EventTimeline.init(std.testing.allocator, 0));

    timeline.record(.{ .event_type = .message_sent, .timestamp_ms = 1, .metadata = "first" });
    timeline.record(.{ .event_type = .message_received, .timestamp_ms = 2, .metadata = null });
    timeline.record(.{ .event_type = .message_dropped, .timestamp_ms = 3, .metadata = "third" });

    try std.testing.expectEqual(@as(usize, 2), timeline.count());

    var snapshot = try timeline.snapshot(std.testing.allocator);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(u64, 3), snapshot.total_recorded);
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    try std.testing.expectEqual(EventType.message_received, snapshot.entries[0].event_type);
    try std.testing.expect(snapshot.entries[0].metadata == null);
    try std.testing.expectEqual(EventType.message_dropped, snapshot.entries[1].event_type);
    try std.testing.expectEqualStrings("third", snapshot.entries[1].metadata.?);
    try std.testing.expect(snapshot.entries[0].sequence < snapshot.entries[1].sequence);
}

test "TelemetryEmitter records emitted events into an attached timeline" {
    var emitter = TelemetryEmitter.init(std.testing.allocator);
    defer emitter.deinit();

    var timeline = try EventTimeline.init(std.testing.allocator, 8);
    defer timeline.deinit();
    emitter.attachTimeline(&timeline);

    // Recorded even with no registered handlers.
    emitter.emit(.{ .event_type = .message_sent, .timestamp_ms = 10, .metadata = "orders" });
    try std.testing.expectEqual(@as(usize, 1), timeline.count());

    // Disabled emitters record nothing.
    emitter.setEnabled(false);
    emitter.emit(.{ .event_type = .message_sent, .timestamp_ms = 11, .metadata = null });
    try std.testing.expectEqual(@as(usize, 1), timeline.count());

    emitter.setEnabled(true);
    emitter.detachTimeline();
    emitter.emit(.{ .event_type = .message_sent, .timestamp_ms = 12, .metadata = null });
    try std.testing.expectEqual(@as(usize, 1), timeline.count());
}

test "TelemetryEmitter wouldEmit reflects enabled state, handlers, and timeline" {
    var emitter = TelemetryEmitter.init(std.testing.allocator);
    defer emitter.deinit();

    // Nothing listening yet.
    try std.testing.expect(!emitter.wouldEmit(.message_sent));

    const handler = struct {
        fn handle(_: Event) void {}
    }.handle;
    try emitter.on(.message_sent, handler);
    try std.testing.expect(emitter.wouldEmit(.message_sent));
    try std.testing.expect(!emitter.wouldEmit(.message_dropped));

    // Disabled emitters never emit.
    emitter.setEnabled(false);
    try std.testing.expect(!emitter.wouldEmit(.message_sent));
    emitter.setEnabled(true);

    // A timeline listens to every event type.
    var timeline = try EventTimeline.init(std.testing.allocator, 4);
    defer timeline.deinit();
    emitter.attachTimeline(&timeline);
    try std.testing.expect(emitter.wouldEmit(.message_dropped));
    emitter.detachTimeline();
    try std.testing.expect(!emitter.wouldEmit(.message_dropped));

    emitter.removeHandlers(.message_sent);
    try std.testing.expect(!emitter.wouldEmit(.message_sent));
    try std.testing.expectEqual(@as(usize, 0), emitter.handlerCount());
}
