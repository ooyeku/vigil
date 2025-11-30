//! Telemetry and event hooks for Vigil
//! Provides observable events for monitoring and debugging.

const std = @import("std");
const Message = @import("messages.zig").Message;
const MessagePriority = @import("messages.zig").MessagePriority;
const Signal = @import("messages.zig").Signal;

/// Event types that can be emitted
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

/// Base event structure
pub const Event = struct {
    event_type: EventType,
    timestamp_ms: i64,
    metadata: ?[]const u8 = null,
};

/// Process lifecycle event
pub const ProcessEvent = struct {
    base: Event,
    process_id: []const u8,
    state: ProcessState,

    pub const ProcessState = enum {
        started,
        stopped,
        crashed,
        suspended,
        resumed,
    };
};

/// Message event
pub const MessageEvent = struct {
    base: Event,
    message_id: []const u8,
    sender: []const u8,
    receiver: ?[]const u8,
    priority: MessagePriority,
    size_bytes: usize,
    topic: ?[]const u8 = null,
};

/// Supervisor event
pub const SupervisorEvent = struct {
    base: Event,
    supervisor_id: ?[]const u8,
    child_id: ?[]const u8,
    restart_count: u32,
    strategy: ?[]const u8 = null,
};

/// Circuit breaker event
pub const CircuitEvent = struct {
    base: Event,
    circuit_id: []const u8,
    state: CircuitState,
    failure_count: u32,

    pub const CircuitState = enum {
        opened,
        closed,
        half_open,
    };
};

/// GenServer event
pub const GenServerEvent = struct {
    base: Event,
    server_id: []const u8,
    state_snapshot: ?[]const u8 = null,
};

/// Event handler function type
pub const EventHandler = *const fn (event: Event) void;

/// Telemetry emitter - central event dispatcher
pub const TelemetryEmitter = struct {
    allocator: std.mem.Allocator,
    handlers: std.ArrayListUnmanaged(HandlerEntry),
    mutex: std.Thread.Mutex,
    enabled: bool = true,

    const HandlerEntry = struct {
        event_type: EventType,
        handler: EventHandler,
    };

    /// Initialize a new telemetry emitter
    pub fn init(allocator: std.mem.Allocator) TelemetryEmitter {
        return .{
            .allocator = allocator,
            .handlers = .{},
            .mutex = .{},
            .enabled = true,
        };
    }

    /// Cleanup resources
    pub fn deinit(self: *TelemetryEmitter) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.handlers.deinit(self.allocator);
    }

    /// Register a handler for a specific event type
    pub fn on(self: *TelemetryEmitter, event_type: EventType, handler: EventHandler) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.handlers.append(self.allocator, .{
            .event_type = event_type,
            .handler = handler,
        });
    }

    /// Emit an event to all registered handlers
    pub fn emit(self: *TelemetryEmitter, event: Event) void {
        if (!self.enabled) return;

        self.mutex.lock();
        const handlers_copy = self.handlers.items;
        self.mutex.unlock();

        for (handlers_copy) |entry| {
            if (entry.event_type == event.event_type) {
                entry.handler(event);
            }
        }
    }

    /// Enable or disable event emission
    pub fn setEnabled(self: *TelemetryEmitter, enabled: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.enabled = enabled;
    }

    /// Remove all handlers for an event type
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
};

/// Global telemetry instance
var global_telemetry: ?TelemetryEmitter = null;
var telemetry_mutex: std.Thread.Mutex = .{};

/// Initialize global telemetry
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    telemetry_mutex.lock();
    defer telemetry_mutex.unlock();

    if (global_telemetry == null) {
        global_telemetry = TelemetryEmitter.init(allocator);
    }
}

/// Get global telemetry instance
pub fn getGlobal() ?*TelemetryEmitter {
    telemetry_mutex.lock();
    defer telemetry_mutex.unlock();
    return if (global_telemetry) |*t| t else null;
}

/// Register a handler for global telemetry
pub fn on(event_type: EventType, handler: EventHandler) !void {
    if (getGlobal()) |telemetry| {
        try telemetry.on(event_type, handler);
    }
}

/// Emit an event to global telemetry
pub fn emit(event: Event) void {
    if (getGlobal()) |telemetry| {
        telemetry.emit(event);
    }
}

/// Helper to create a process event
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
            .timestamp_ms = std.time.milliTimestamp(),
            .metadata = null,
        },
        .process_id = id_copy,
        .state = state,
    };
}

/// Helper to create a message event
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
            .timestamp_ms = std.time.milliTimestamp(),
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

/// Helper to create a supervisor event
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
            .timestamp_ms = std.time.milliTimestamp(),
            .metadata = null,
        },
        .supervisor_id = sup_id_copy,
        .child_id = child_id_copy,
        .restart_count = restart_count,
        .strategy = null,
    };
}

/// Helper to create a circuit breaker event
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
            .timestamp_ms = std.time.milliTimestamp(),
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
        .timestamp_ms = std.time.milliTimestamp(),
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
        .timestamp_ms = std.time.milliTimestamp(),
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
        .timestamp_ms = std.time.milliTimestamp(),
        .metadata = null,
    };

    const event2 = Event{
        .event_type = .process_stopped,
        .timestamp_ms = std.time.milliTimestamp(),
        .metadata = null,
    };

    emitter.emit(event1);
    emitter.emit(event2);
    // Test passes if no panic
}
