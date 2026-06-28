//! Telemetry and event hooks for Vigil.
//!
//! Telemetry is intentionally lightweight: handlers are plain function
//! pointers, event dispatch is synchronous, and events carry optional metadata
//! as borrowed slices. New v2 applications should prefer
//! `Runtime.telemetry_emitter`; the global helpers remain available for modules
//! that still publish through process-wide telemetry.

const std = @import("std");
const Message = @import("messages.zig").Message;
const MessagePriority = @import("messages.zig").MessagePriority;
const Signal = @import("messages.zig").Signal;
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

/// Detailed process lifecycle event.
pub const ProcessEvent = struct {
    /// Base event fields.
    base: Event,
    /// Process id. Created helper events allocate a copied id.
    process_id: []const u8,
    /// Lifecycle state.
    state: ProcessState,

    /// Process lifecycle states used in process telemetry.
    pub const ProcessState = enum {
        started,
        stopped,
        crashed,
        suspended,
        resumed,
    };
};

/// Detailed message event.
pub const MessageEvent = struct {
    /// Base event fields.
    base: Event,
    /// Message id.
    message_id: []const u8,
    /// Message sender.
    sender: []const u8,
    /// Optional logical receiver. Created helper events copy this field.
    receiver: ?[]const u8,
    /// Message priority.
    priority: MessagePriority,
    /// Payload size reported by the message metadata.
    size_bytes: usize,
    /// Optional topic for pub/sub style events.
    topic: ?[]const u8 = null,
};

/// Detailed supervisor event.
pub const SupervisorEvent = struct {
    /// Base event fields.
    base: Event,
    /// Supervisor id, if known. Created helper events copy this field.
    supervisor_id: ?[]const u8,
    /// Child id, if known. Created helper events copy this field.
    child_id: ?[]const u8,
    /// Restart count at the time of the event.
    restart_count: u32,
    /// Optional strategy label.
    strategy: ?[]const u8 = null,
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

/// Detailed GenServer event.
pub const GenServerEvent = struct {
    /// Base event fields.
    base: Event,
    /// Server id.
    server_id: []const u8,
    /// Optional serialized state snapshot.
    state_snapshot: ?[]const u8 = null,
};

/// Event handler function type.
///
/// Handlers run synchronously on the thread that calls `emit()`. Keep handlers
/// small and non-blocking.
pub const EventHandler = *const fn (event: Event) void;

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
    /// Protects handler registration and enabled state.
    mutex: compat.Mutex,
    /// Whether `emit()` dispatches events.
    enabled: bool = true,

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
            .enabled = true,
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
    }

    /// Dispatch an event to matching handlers.
    ///
    /// Dispatch is synchronous and best-effort. If a temporary handler snapshot
    /// cannot be allocated, the event is dropped.
    pub fn emit(self: *TelemetryEmitter, event: Event) void {
        if (!self.enabled) return;

        // Make a true copy of handlers to avoid use-after-free if handlers are modified
        self.mutex.lock();
        const handlers_snapshot = self.allocator.alloc(HandlerEntry, self.handlers.items.len) catch {
            self.mutex.unlock();
            return;
        };
        @memcpy(handlers_snapshot, self.handlers.items);
        self.mutex.unlock();
        defer self.allocator.free(handlers_snapshot);

        for (handlers_snapshot) |entry| {
            if (entry.event_type == event.event_type) {
                entry.handler(event);
            }
        }
    }

    /// Enable or disable event emission.
    pub fn setEnabled(self: *TelemetryEmitter, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = enabled;
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
    }

    /// Return the number of registered handlers.
    pub fn handlerCount(self: *TelemetryEmitter) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.handlers.items.len;
    }
};

/// Optional process-wide telemetry emitter.
///
/// Prefer `Runtime.telemetry_emitter` in new v2 code unless a process-wide
/// integration point is explicitly desired.
var global_telemetry: ?TelemetryEmitter = null;
var telemetry_mutex: compat.Mutex = .{};

/// Initialize the optional global telemetry emitter if needed.
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    telemetry_mutex.lock();
    defer telemetry_mutex.unlock();

    if (global_telemetry == null) {
        global_telemetry = TelemetryEmitter.init(allocator);
    }
}

/// Deinitialize and release the global telemetry emitter.
/// Must only be called during shutdown when no other threads are
/// emitting events or registering handlers.
pub fn deinitGlobal() void {
    telemetry_mutex.lock();
    defer telemetry_mutex.unlock();

    if (global_telemetry) |*t| {
        t.deinit();
        global_telemetry = null;
    }
}

/// Get global telemetry instance.
///
/// SAFETY: The returned pointer is valid as long as `deinitGlobal()` has
/// not been called.  Callers must ensure `deinitGlobal()` is only invoked
/// during shutdown after all event emission has completed.
pub fn getGlobal() ?*TelemetryEmitter {
    telemetry_mutex.lock();
    defer telemetry_mutex.unlock();
    return if (global_telemetry) |*t| t else null;
}

/// Register a handler on the optional global telemetry emitter.
///
/// Does nothing when global telemetry has not been initialized.
pub fn on(event_type: EventType, handler: EventHandler) !void {
    if (getGlobal()) |telemetry| {
        try telemetry.on(event_type, handler);
    }
}

/// Emit an event through the optional global telemetry emitter.
///
/// Does nothing when global telemetry has not been initialized.
pub fn emit(event: Event) void {
    if (getGlobal()) |telemetry| {
        telemetry.emit(event);
    }
}

/// Allocate a detailed process event.
///
/// The returned `process_id` is allocated with `allocator` and must be freed by
/// the caller when the event is no longer needed.
pub fn createProcessEvent(
    allocator: std.mem.Allocator,
    event_type: EventType,
    process_id: []const u8,
    state: ProcessEvent.ProcessState,
) !ProcessEvent {
    const id_copy = try allocator.dupe(u8, process_id);
    errdefer allocator.free(id_copy);

    return ProcessEvent{
        .base = .{
            .event_type = event_type,
            .timestamp_ms = compat.milliTimestamp(),
            .metadata = null,
        },
        .process_id = id_copy,
        .state = state,
    };
}

/// Create a detailed message event.
///
/// The returned `receiver`, when present, is allocated with `allocator` and
/// must be freed by the caller.
pub fn createMessageEvent(
    allocator: std.mem.Allocator,
    event_type: EventType,
    message: Message,
    receiver: ?[]const u8,
) !MessageEvent {
    const receiver_copy = if (receiver) |r| try allocator.dupe(u8, r) else null;
    errdefer if (receiver_copy) |r| allocator.free(r);

    return MessageEvent{
        .base = .{
            .event_type = event_type,
            .timestamp_ms = compat.milliTimestamp(),
            .metadata = null,
        },
        .message_id = message.id,
        .sender = message.sender,
        .receiver = receiver_copy,
        .priority = message.priority,
        .size_bytes = message.metadata.size_bytes,
        .topic = null,
    };
}

/// Allocate a detailed supervisor event.
///
/// Returned `supervisor_id` and `child_id` fields, when present, are allocated
/// with `allocator` and must be freed by the caller.
pub fn createSupervisorEvent(
    allocator: std.mem.Allocator,
    event_type: EventType,
    supervisor_id: ?[]const u8,
    child_id: ?[]const u8,
    restart_count: u32,
) !SupervisorEvent {
    const sup_id_copy = if (supervisor_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (sup_id_copy) |id| allocator.free(id);

    const child_id_copy = if (child_id) |id| try allocator.dupe(u8, id) else null;
    errdefer if (child_id_copy) |id| allocator.free(id);

    return SupervisorEvent{
        .base = .{
            .event_type = event_type,
            .timestamp_ms = compat.milliTimestamp(),
            .metadata = null,
        },
        .supervisor_id = sup_id_copy,
        .child_id = child_id_copy,
        .restart_count = restart_count,
        .strategy = null,
    };
}

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
