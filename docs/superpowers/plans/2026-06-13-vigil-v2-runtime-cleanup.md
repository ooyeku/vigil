# Vigil v2 Runtime Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Vigil 2.0.0 as a cohesive actor runtime for Zig with a clean public API, real builder behavior, first-class GenServer lifecycle, owned runtime state, documented timer/distribution contracts, and no stale 0.2 compatibility helpers on the root module.

**Architecture:** Add a `Runtime` owner for registry, telemetry, shutdown, and convenience construction while preserving low-level modules for advanced callers. Use the 2.0.0 breaking-change window to remove obsolete root exports, align docs with implemented APIs, wire previously inert builder options, and place distribution behind a small versioned protocol layer.

**Tech Stack:** Zig 0.16.0, `std.testing`, `std.Thread`, existing Vigil modules, existing `compat` layer, no new dependencies.

---

## One-Sitting Execution Rules

- Work on a dedicated branch: `codex/v2-runtime-cleanup`.
- Keep the tree compiling after every task.
- Commit after every task so rollback points are crisp.
- Do the public API cleanup before new feature work so v2 does not accidentally preserve stale entry points.
- Use `zig build test` as the main gate and `zig build` as the package/example gate.
- Finish by updating version, changelog, README, and API docs in the same sitting.

## Target File Structure

- Create `src/runtime.zig`: owned runtime facade for registry, telemetry, shutdown, inbox creation, supervisor creation, and app shutdown.
- Create `src/distributed_protocol.zig`: parser/formatter for the distributed registry wire protocol.
- Modify `src/vigil.zig`: export `Runtime`, `RuntimeOptions`, `runtime`; remove root exports for obsolete compatibility helpers; remove `global_registry`.
- Modify `src/genserver.zig`: replace global-registry registration with explicit registry registration; add thread-owned start helper.
- Modify `src/api/server_sugar.zig`: replace misleading `start()` with explicit `init()` and `spawn()` handle API.
- Modify `src/api/inbox.zig`: make `InboxBuilder.withRateLimit()` and `withBackpressure()` affect the built inbox.
- Modify `src/api/flow_control.zig`: expose helper methods needed by built-in inbox flow control; preserve `FlowControlledInbox` as a compatibility wrapper over the same behavior.
- Modify `src/supervisor.zig` and `src/api/supervisor_builder.zig`: wire crash handlers and telemetry into runtime restart/control paths.
- Modify `src/timer.zig`: add instance timer API matching docs: `init`, `deinit`, `setTimeout`, `setInterval`, `cancel`, while preserving `sendAfter`.
- Modify `src/distributed_registry.zig`: use `distributed_protocol`, add protocol versioning and unregister support.
- Delete `src/compat_0_2.zig`: remove obsolete 0.2 helper API from source.
- Modify `build.zig`: keep `vigil/legacy`; add doc/example compile tests if created as separate files.
- Modify `README.md`, `docs/api.md`, `CHANGELOG.md`, `build.zig.zon`: v2 docs, examples, version, and migration notes.

---

### Task 0: Branch, Baseline, and Safety Net

**Files:**
- Read: `build.zig`
- Read: `src/vigil.zig`
- Read: `docs/api.md`

- [ ] **Step 1: Create the v2 branch**

Run:

```bash
git checkout -b codex/v2-runtime-cleanup
```

Expected: branch switches to `codex/v2-runtime-cleanup`.

- [ ] **Step 2: Verify the baseline**

Run:

```bash
zig build test
zig build
```

Expected: both commands exit `0`.

- [ ] **Step 3: Commit baseline marker only if branch creation changed no files**

Run:

```bash
git status --short
```

Expected: no tracked file changes before implementation begins.

---

### Task 1: Remove Obsolete Root Compatibility API

**Files:**
- Modify: `src/vigil.zig`
- Modify: `src/genserver.zig`
- Delete: `src/compat_0_2.zig`
- Modify: `README.md`
- Modify: `docs/api.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add failing public-surface tests in `src/vigil.zig`**

Add this test near the bottom of `src/vigil.zig`, before the final `test { std.testing.refAllDecls(@This()); }` block:

```zig
test "v2 root module excludes obsolete 0.2 compatibility helpers" {
    try std.testing.expect(!@hasDecl(@This(), "createMailbox"));
    try std.testing.expect(!@hasDecl(@This(), "createSupervisor"));
    try std.testing.expect(!@hasDecl(@This(), "createSupervisionTree"));
    try std.testing.expect(!@hasDecl(@This(), "createResponse"));
    try std.testing.expect(!@hasDecl(@This(), "addWorkerGroup"));
    try std.testing.expect(!@hasDecl(@This(), "broadcast"));
    try std.testing.expect(!@hasDecl(@This(), "global_registry"));
}
```

- [ ] **Step 2: Run the public-surface test and verify it fails**

Run:

```bash
zig build test
```

Expected: FAIL because the old helper declarations still exist on `vigil`.

- [ ] **Step 3: Remove old exports from `src/vigil.zig`**

Remove these declarations from `src/vigil.zig`:

```zig
/// Global registry instance (optional)
pub var global_registry: ?*Registry = null;

// Additional legacy exports for backward compatibility
pub const SupervisorOptions = legacy.SupervisorOptions;
pub const SupervisorTree = legacy.SupervisorTree;
pub const ChildSpec = legacy.ChildSpec;
pub const createMailbox = compat_0_2.createMailbox;
pub const createSupervisor = compat_0_2.createSupervisor;
pub const createSupervisionTree = compat_0_2.createSupervisionTree;
pub const broadcast = compat_0_2.broadcast;
pub const createResponse = compat_0_2.createResponse;
pub const addWorkerGroup = compat_0_2.addWorkerGroup;

const compat_0_2 = @import("compat_0_2.zig");
```

Keep explicit advanced types that are part of the current v2 surface:

```zig
pub const Supervisor = supervisor_builder.Supervisor;
pub const RestartStrategy = supervisor_builder.RestartStrategy;
pub const ProcessPriority = supervisor_builder.ProcessPriority;
pub const GenServer = legacy.GenServer;
pub const ProcessMailbox = legacy.ProcessMailbox;
pub const Registry = @import("registry.zig").Registry;
pub const Timer = @import("timer.zig").Timer;
```

- [ ] **Step 4: Delete the obsolete compatibility file**

Run:

```bash
rm src/compat_0_2.zig
```

Expected: the file is gone and no source imports it.

- [ ] **Step 5: Replace global registry registration in `src/genserver.zig`**

Replace the existing `register(self: *Self, name: []const u8)` method with:

```zig
/// Register the GenServer with an explicit registry.
pub fn register(self: *Self, registry: *vigil.Registry, name: []const u8) !void {
    try registry.register(name, self.mailbox);
}
```

- [ ] **Step 6: Run tests and fix direct old API references**

Run:

```bash
rg -n "compat_0_2|createMailbox|createSupervisor|createSupervisionTree|createResponse|addWorkerGroup|global_registry" src README.md docs/api.md CHANGELOG.md
zig build test
```

Expected: `rg` only shows migration/changelog text after docs are updated; `zig build test` exits `0`.

- [ ] **Step 7: Update docs to state v2 cleanup**

In `README.md` and `docs/api.md`, document:

```markdown
Vigil 2.0.0 removes the old 0.2 compatibility helpers from the root `vigil` module. Code that needs the historical low-level types should import `vigil/legacy` explicitly. New code should use `vigil.Runtime`, `vigil.app`, `vigil.supervisor`, `vigil.inbox`, and `vigil.GenServer`.
```

- [ ] **Step 8: Commit**

Run:

```bash
git add src/vigil.zig src/genserver.zig README.md docs/api.md CHANGELOG.md
git add -u src/compat_0_2.zig
git commit -m "refactor!: remove obsolete root compatibility APIs"
```

Expected: commit succeeds.

---

### Task 2: Add Owned Runtime Facade

**Files:**
- Create: `src/runtime.zig`
- Modify: `src/vigil.zig`
- Modify: `src/api/app_builder.zig`
- Modify: `README.md`
- Modify: `docs/api.md`

- [ ] **Step 1: Write failing runtime tests in `src/runtime.zig`**

Create `src/runtime.zig` with these tests first:

```zig
const std = @import("std");
const Registry = @import("registry.zig").Registry;
const telemetry = @import("telemetry.zig");
const shutdown = @import("shutdown.zig");
const inbox_api = @import("api/inbox.zig");
const supervisor_builder = @import("api/supervisor_builder.zig");

test "Runtime initializes owned services" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    try std.testing.expect(rt.isRunning());
    try std.testing.expect(rt.whereis("missing") == null);
}

test "Runtime creates and closes inboxes" {
    var rt = try Runtime.init(std.testing.allocator, .{});
    defer rt.deinit();

    var ib = try rt.inbox(.{ .capacity = 4 });
    defer ib.close();

    try ib.send("hello");
    var msg = try ib.recvTimeout(50) orelse return error.ExpectedMessage;
    defer msg.deinit();
    try std.testing.expectEqualStrings("hello", msg.payload.?);
}
```

- [ ] **Step 2: Run runtime tests and verify they fail to compile**

Run:

```bash
zig test src/runtime.zig
```

Expected: FAIL because `Runtime` is not defined.

- [ ] **Step 3: Implement `Runtime` in `src/runtime.zig`**

Use this structure:

```zig
pub const RuntimeOptions = struct {
    telemetry_enabled: bool = true,
    shutdown_enabled: bool = true,
};

pub const InboxOptions = struct {
    capacity: usize = 100,
    priority_queues: bool = true,
    dead_letter: bool = true,
    default_ttl_ms: ?u32 = 30_000,
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    registry: Registry,
    telemetry_emitter: telemetry.TelemetryEmitter,
    shutdown_manager: shutdown.ShutdownManager,
    options: RuntimeOptions,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
        return .{
            .allocator = allocator,
            .registry = Registry.init(allocator),
            .telemetry_emitter = telemetry.TelemetryEmitter.init(allocator),
            .shutdown_manager = shutdown.ShutdownManager.init(allocator),
            .options = options,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.running.store(false, .release);
        self.shutdown_manager.deinit();
        self.telemetry_emitter.deinit();
        self.registry.deinit();
    }

    pub fn isRunning(self: *Runtime) bool {
        return self.running.load(.acquire);
    }

    pub fn inbox(self: *Runtime, options: InboxOptions) !*inbox_api.Inbox {
        return try inbox_api.inboxBuilder(self.allocator)
            .capacity(options.capacity)
            .priorityQueues(options.priority_queues)
            .deadLetter(options.dead_letter)
            .defaultTTL(options.default_ttl_ms orelse 0)
            .build();
    }

    pub fn supervisor(self: *Runtime) supervisor_builder.SupervisorBuilder {
        return supervisor_builder.supervisor(self.allocator)
            .withTelemetry(self.options.telemetry_enabled);
    }

    pub fn register(self: *Runtime, name: []const u8, mailbox: *@import("messages.zig").ProcessMailbox) !void {
        try self.registry.register(name, mailbox);
    }

    pub fn whereis(self: *Runtime, name: []const u8) ?*@import("messages.zig").ProcessMailbox {
        return self.registry.whereis(name);
    }

    pub fn onShutdown(self: *Runtime, hook: shutdown.ShutdownHook) !void {
        try self.shutdown_manager.onShutdown(hook);
    }

    pub fn shutdown(self: *Runtime) void {
        self.running.store(false, .release);
        self.shutdown_manager.shutdown(.{});
    }
};

pub fn runtime(allocator: std.mem.Allocator, options: RuntimeOptions) !Runtime {
    return Runtime.init(allocator, options);
}
```

- [ ] **Step 4: Export runtime from `src/vigil.zig`**

Add:

```zig
pub const runtime_api = @import("runtime.zig");
pub const Runtime = runtime_api.Runtime;
pub const RuntimeOptions = runtime_api.RuntimeOptions;
pub const runtime = runtime_api.runtime;
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/runtime.zig src/vigil.zig README.md docs/api.md
git commit -m "feat: add owned runtime facade"
```

Expected: commit succeeds.

---

### Task 3: Make Inbox Builder Flow Control Real

**Files:**
- Modify: `src/api/inbox.zig`
- Modify: `src/api/flow_control.zig`
- Modify: `README.md`
- Modify: `docs/api.md`

- [ ] **Step 1: Add failing tests to `src/api/inbox.zig`**

Add:

```zig
test "InboxBuilder applies rate limiting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ib = try inboxBuilder(allocator)
        .withRateLimit(.{ .max_per_second = 1 })
        .build();
    defer ib.close();

    try ib.send("first");
    try std.testing.expectError(MessageError.RateLimitExceeded, ib.send("second"));
}

test "InboxBuilder applies return_error backpressure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ib = try inboxBuilder(allocator)
        .capacity(1)
        .withBackpressure(.{
            .strategy = .return_error,
            .high_watermark = 1,
            .low_watermark = 0,
        })
        .build();
    defer ib.close();

    try ib.send("first");
    try std.testing.expectError(MessageError.MailboxFull, ib.send("second"));
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because the builder stores flow-control config but does not apply it.

- [ ] **Step 3: Add optional flow-control fields to `Inbox`**

Add fields:

```zig
rate_limiter: ?flow_control.RateLimiter,
backpressure_config: ?flow_control.BackpressureConfig,
```

Initialize them in `Inbox.init()`:

```zig
.rate_limiter = null,
.backpressure_config = null,
```

Initialize them in `InboxBuilder.build()`:

```zig
.rate_limiter = if (self.rate_limit_config) |config| flow_control.RateLimiter.init(config.max_per_second) else null,
.backpressure_config = self.backpressure_config,
```

- [ ] **Step 4: Route `Inbox.send()` through built-in flow control**

At the start of `Inbox.send()` after the closed re-check, add:

```zig
if (self.rate_limiter) |*limiter| {
    if (!limiter.allow()) {
        return MessageError.RateLimitExceeded;
    }
}

if (self.backpressure_config) |config| {
    const inbox_stats = self.stats();
    const current_count = inbox_stats.messages_received - inbox_stats.messages_sent;
    if (current_count >= config.high_watermark) {
        switch (config.strategy) {
            .drop_oldest => {
                if (self.mailbox.receive()) |old| {
                    var owned_old = old;
                    owned_old.deinit();
                } else |_| {}
            },
            .drop_newest => return,
            .block => {
                while (true) {
                    const current_stats = self.stats();
                    const current = current_stats.messages_received - current_stats.messages_sent;
                    if (current < config.low_watermark) break;
                    compat.sleep(10 * std.time.ns_per_ms);
                }
            },
            .return_error => return MessageError.MailboxFull,
        }
    }
}
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/api/inbox.zig src/api/flow_control.zig README.md docs/api.md
git commit -m "fix!: apply inbox builder flow control"
```

Expected: commit succeeds.

---

### Task 4: Wire Supervisor Crash Handlers and Telemetry

**Files:**
- Modify: `src/supervisor.zig`
- Modify: `src/api/supervisor_builder.zig`
- Modify: `src/telemetry.zig`
- Modify: `docs/api.md`

- [ ] **Step 1: Add failing tests in `src/api/supervisor_builder.zig`**

Add:

```zig
var test_crash_count = std.atomic.Value(u32).init(0);

fn testCrashHandler(_: []const u8) void {
    _ = test_crash_count.fetchAdd(1, .monotonic);
}

test "SupervisorBuilder wires crash handler" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    test_crash_count.store(0, .release);

    var builder = supervisor(allocator);
    _ = builder.onCrash(testCrashHandler);
    var sup = builder.build();
    defer sup.deinit();

    sup.notifyChildCrashForTest("worker_a");

    try std.testing.expectEqual(@as(u32, 1), test_crash_count.load(.acquire));
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `notifyChildCrashForTest` and stored crash handler behavior do not exist.

- [ ] **Step 3: Add handler and telemetry fields to `SupervisorOptions` and `Supervisor`**

In `src/supervisor.zig`, add:

```zig
pub const CrashHandler = *const fn (child_id: []const u8) void;
```

Extend `SupervisorOptions`:

```zig
crash_handler: ?CrashHandler = null,
enable_telemetry: bool = false,
```

Add helper to `Supervisor`:

```zig
fn notifyChildCrash(self: *Supervisor, child_id: []const u8) void {
    if (self.options.crash_handler) |handler| {
        handler(child_id);
    }
    if (self.options.enable_telemetry) {
        @import("telemetry.zig").emit(.{
            .event_type = .process_crashed,
            .timestamp_ms = compat.milliTimestamp(),
            .metadata = child_id,
        });
    }
}

pub fn notifyChildCrashForTest(self: *Supervisor, child_id: []const u8) void {
    self.notifyChildCrash(child_id);
}
```

Call `notifyChildCrash(child.spec.id)` before restart handling in the monitor path where a child is detected as stopped/crashed.

- [ ] **Step 4: Pass builder fields into `Supervisor.init()`**

In `src/api/supervisor_builder.zig`, make both `build()` paths pass:

```zig
.crash_handler = self.crash_handler,
.enable_telemetry = self.enable_telemetry,
```

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/supervisor.zig src/api/supervisor_builder.zig src/telemetry.zig docs/api.md
git commit -m "feat: wire supervisor crash hooks and telemetry"
```

Expected: commit succeeds.

---

### Task 5: Fix GenServer Lifecycle and Server Sugar

**Files:**
- Modify: `src/genserver.zig`
- Modify: `src/api/server_sugar.zig`
- Modify: `docs/api.md`
- Modify: `README.md`

- [ ] **Step 1: Add failing lifecycle test in `src/api/server_sugar.zig`**

Add:

```zig
test "server sugar spawn runs message loop and joins cleanly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Server = server(TestState, TestHandlers);
    var handle = try Server.spawn(allocator, .{});
    defer handle.deinit();

    try handle.cast("increment");
    compat.sleep(20 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 1), handle.ptr.state.counter);

    handle.stop();
    handle.join();
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because `spawn`, `handle.ptr`, `join`, and `deinit` do not exist.

- [ ] **Step 3: Add explicit thread handle to server sugar**

In `src/api/server_sugar.zig`, make `server()` return a type with:

```zig
pub const Handle = struct {
    ptr: *Self,
    thread: ?std.Thread,

    pub fn cast(self: *Handle, payload: []const u8) !void {
        try Self.castPayload(self.ptr, payload);
    }

    pub fn call(self: *Handle, payload: []const u8, options: CallOptions) !Message {
        return try Self.callPayload(self.ptr, payload, options);
    }

    pub fn stop(self: *Handle) void {
        self.ptr.stop();
    }

    pub fn join(self: *Handle) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Handle) void {
        self.join();
        self.ptr.deinit();
    }
};
```

Expose:

```zig
pub fn init(allocator: std.mem.Allocator, initial_state: StateType) !*Self {
    return try Self.init(allocator, Handlers.handle, Handlers.init, Handlers.terminate, initial_state);
}

pub fn spawn(allocator: std.mem.Allocator, initial_state: StateType) !Handle {
    const ptr = try init(allocator, initial_state);
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Self) void {
            s.start() catch {};
        }
    }.run, .{ptr});
    return .{ .ptr = ptr, .thread = thread };
}
```

Move the old payload helpers to names that do not shadow `GenServer.cast` and `GenServer.call`:

```zig
pub fn castPayload(self: *Self, payload: []const u8) !void {
    const id = try std.fmt.allocPrint(self.allocator, "cast_{d}", .{compat.milliTimestamp()});
    defer self.allocator.free(id);

    var message = try Message.init(
        self.allocator,
        id,
        "anonymous",
        payload,
        null,
        .normal,
        null,
    );
    errdefer message.deinit();

    try self.cast(message);
}

pub fn callPayload(self: *Self, payload: []const u8, options: CallOptions) !Message {
    const id = try std.fmt.allocPrint(self.allocator, "call_{d}", .{compat.milliTimestamp()});
    defer self.allocator.free(id);

    var message = try Message.init(
        self.allocator,
        id,
        "anonymous",
        payload,
        null,
        .normal,
        null,
    );
    defer message.deinit();

    return try self.call(&message, options.timeout);
}
```

- [ ] **Step 4: Update existing server sugar tests**

Replace old `Server.start` calls with `Server.init` when the test only checks initialization. Use `Server.spawn` when the test expects message processing.

- [ ] **Step 5: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add src/genserver.zig src/api/server_sugar.zig README.md docs/api.md
git commit -m "fix!: make server sugar lifecycle explicit"
```

Expected: commit succeeds.

---

### Task 6: Implement Documented Timer Instance API

**Files:**
- Modify: `src/timer.zig`
- Modify: `docs/api.md`
- Modify: `README.md`

- [ ] **Step 1: Add failing timer tests in `src/timer.zig`**

Add:

```zig
var timer_test_count = std.atomic.Value(u32).init(0);

fn incrementTimerTestCount() void {
    _ = timer_test_count.fetchAdd(1, .monotonic);
}

test "Timer setTimeout runs callback" {
    timer_test_count.store(0, .release);

    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    try timer.setTimeout(10, incrementTimerTestCount);
    compat.sleep(40 * std.time.ns_per_ms);

    try std.testing.expectEqual(@as(u32, 1), timer_test_count.load(.acquire));
}

test "Timer cancel stops interval" {
    timer_test_count.store(0, .release);

    var timer = Timer.init(std.testing.allocator);
    defer timer.deinit();

    try timer.setInterval(5, incrementTimerTestCount);
    compat.sleep(20 * std.time.ns_per_ms);
    timer.cancel();

    const count_after_cancel = timer_test_count.load(.acquire);
    compat.sleep(20 * std.time.ns_per_ms);

    try std.testing.expectEqual(count_after_cancel, timer_test_count.load(.acquire));
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```bash
zig build test
```

Expected: FAIL because the instance timer API does not exist.

- [ ] **Step 3: Implement timer state**

Change `Timer` to:

```zig
pub const TimerCallback = *const fn () void;

pub const Timer = struct {
    allocator: std.mem.Allocator,
    cancelled: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) Timer {
        return .{
            .allocator = allocator,
            .cancelled = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    pub fn deinit(self: *Timer) void {
        self.cancel();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn cancel(self: *Timer) void {
        self.cancelled.store(true, .release);
    }

    pub fn setTimeout(self: *Timer, delay_ms: u32, callback: TimerCallback) !void {
        self.cancelled.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, timeoutLoop, .{ self, delay_ms, callback });
    }

    pub fn setInterval(self: *Timer, interval_ms: u32, callback: TimerCallback) !void {
        self.cancelled.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, intervalLoop, .{ self, interval_ms, callback });
    }

    fn timeoutLoop(self: *Timer, delay_ms: u32, callback: TimerCallback) void {
        compat.sleep(@as(u64, delay_ms) * std.time.ns_per_ms);
        if (!self.cancelled.load(.acquire)) callback();
    }

    fn intervalLoop(self: *Timer, interval_ms: u32, callback: TimerCallback) void {
        while (!self.cancelled.load(.acquire)) {
            compat.sleep(@as(u64, interval_ms) * std.time.ns_per_ms);
            if (!self.cancelled.load(.acquire)) callback();
        }
    }

    /// Schedule a message to be sent after a delay.
    /// Spawns a detached thread to handle the timing.
    /// The message is owned by the timer until sent.
    pub fn sendAfter(
        allocator: std.mem.Allocator,
        delay_ms: u32,
        mailbox: *ProcessMailbox,
        msg: Message,
    ) !void {
        const Context = struct {
            delay: u32,
            mailbox: *ProcessMailbox,
            msg: Message,
            allocator: std.mem.Allocator,
        };

        const context = try allocator.create(Context);
        context.* = .{
            .delay = delay_ms,
            .mailbox = mailbox,
            .msg = msg,
            .allocator = allocator,
        };

        const thread_fn = struct {
            fn run(ctx: *Context) void {
                defer ctx.allocator.destroy(ctx);

                compat.sleep(@as(u64, ctx.delay) * std.time.ns_per_ms);

                ctx.mailbox.send(ctx.msg) catch {
                    ctx.msg.deinit();
                };
            }
        }.run;

        const thread = try std.Thread.spawn(.{}, thread_fn, .{context});
        thread.detach();
    }
};
```

Keep the existing `sendAfter` body inside the struct.

- [ ] **Step 4: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 5: Commit**

Run:

```bash
git add src/timer.zig README.md docs/api.md
git commit -m "feat: add documented timer instance API"
```

Expected: commit succeeds.

---

### Task 7: Add Versioned Distributed Registry Protocol

**Files:**
- Create: `src/distributed_protocol.zig`
- Modify: `src/distributed_registry.zig`
- Modify: `src/vigil.zig`
- Modify: `docs/api.md`

- [ ] **Step 1: Write protocol parser tests**

Create `src/distributed_protocol.zig`:

```zig
const std = @import("std");

pub const ProtocolError = error{ InvalidFrame, UnsupportedVersion };

pub const Command = union(enum) {
    hello: NodeIdentity,
    heart,
    where: []const u8,
    reg: []const u8,
    unreg: []const u8,
};

pub const NodeIdentity = struct {
    node_id: []const u8,
    port: u16,
};

test "distributed protocol parses v2 frames" {
    try std.testing.expectEqual(Command.heart, try parse("VIGIL/2 HEART"));

    const where_cmd = try parse("VIGIL/2 WHERE service_a");
    try std.testing.expectEqualStrings("service_a", where_cmd.where);

    const unreg_cmd = try parse("VIGIL/2 UNREG service_a");
    try std.testing.expectEqualStrings("service_a", unreg_cmd.unreg);
}
```

- [ ] **Step 2: Run protocol test and verify failure**

Run:

```bash
zig test src/distributed_protocol.zig
```

Expected: FAIL because `parse` is not defined.

- [ ] **Step 3: Implement parser and formatter**

Add:

```zig
pub const version_prefix = "VIGIL/2 ";

pub fn parse(line: []const u8) ProtocolError!Command {
    if (!std.mem.startsWith(u8, line, version_prefix)) return error.UnsupportedVersion;
    const body = line[version_prefix.len..];

    if (std.mem.eql(u8, body, "HEART")) return .heart;
    if (std.mem.startsWith(u8, body, "WHERE ")) return .{ .where = body["WHERE ".len..] };
    if (std.mem.startsWith(u8, body, "REG ")) return .{ .reg = body["REG ".len..] };
    if (std.mem.startsWith(u8, body, "UNREG ")) return .{ .unreg = body["UNREG ".len..] };
    if (std.mem.startsWith(u8, body, "HELLO ")) {
        var parts = std.mem.splitScalar(u8, body["HELLO ".len..], ' ');
        const node_id = parts.next() orelse return error.InvalidFrame;
        const port_text = parts.next() orelse return error.InvalidFrame;
        const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidFrame;
        return .{ .hello = .{ .node_id = node_id, .port = port } };
    }
    return error.InvalidFrame;
}

pub fn writeFrame(buffer: []u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.bufPrint(buffer, "VIGIL/2 " ++ fmt ++ "\n", args);
}
```

- [ ] **Step 4: Update `distributed_registry.zig` to use v2 frames**

Replace frame writes:

```zig
_ = stream.write("HEART\n") catch {
    node.is_alive = false;
    return;
};
```

with:

```zig
var frame_buf: [128]u8 = undefined;
const frame = protocol.writeFrame(&frame_buf, "HEART", .{}) catch return;
_ = stream.write(frame) catch {
    node.is_alive = false;
    return;
};
```

Replace `WHERE`, `REG`, and incoming command parsing with `protocol.parse(line)`.

Handle `UNREG`:

```zig
.unreg => |name| {
    self.remote_registrations.remove(name);
    Protocol.sendFrame(stream, "OK\n");
},
```

- [ ] **Step 5: Export protocol module**

In `src/vigil.zig`, add:

```zig
pub const distributed_protocol = @import("distributed_protocol.zig");
```

- [ ] **Step 6: Run tests**

Run:

```bash
zig build test
```

Expected: PASS.

- [ ] **Step 7: Commit**

Run:

```bash
git add src/distributed_protocol.zig src/distributed_registry.zig src/vigil.zig docs/api.md
git commit -m "feat: version distributed registry protocol"
```

Expected: commit succeeds.

---

### Task 8: Promote Runtime-First Docs and Compile-Checked Examples

**Files:**
- Modify: `README.md`
- Modify: `docs/api.md`
- Modify: `src/example.zig`
- Modify: `examples/vigilant_server/src/main.zig`

- [ ] **Step 1: Update README quick start to use v2 APIs**

Replace `std.Thread.sleep` in README examples with:

```zig
vigil.compat.sleep(100 * std.time.ns_per_ms);
```

Add runtime example:

```zig
var rt = try vigil.runtime(allocator, .{});
defer rt.deinit();

var inbox = try rt.inbox(.{ .capacity = 128 });
defer inbox.close();
```

- [ ] **Step 2: Update API docs for removed old APIs**

Remove references to root-level `createMailbox`, `createSupervisor`, `createSupervisionTree`, `createResponse`, and root-level `broadcast`.

Add migration text:

```markdown
### Migrating from pre-2.0 root helpers

Vigil 2.0 removes the 0.2 compatibility helpers from `@import("vigil")`. Use `vigil.inboxBuilder`, `vigil.supervisor`, `vigil.Runtime`, or explicit `@import("vigil/legacy")` low-level types.
```

- [ ] **Step 3: Update `src/example.zig` banner**

Replace:

```zig
std.debug.print("\n=== Vigil v1.0.0 Example ===\n", .{});
```

with:

```zig
std.debug.print("\n=== Vigil v2.0.0 Example ===\n", .{});
```

- [ ] **Step 4: Run docs consistency search**

Run:

```bash
rg -n "v1\\.0\\.0|createMailbox|createSupervisor|createSupervisionTree|createResponse|addWorkerGroup|global_registry|std\\.Thread\\.sleep|Timer\\.init" README.md docs/api.md src/example.zig
```

Expected: only intentional `Timer.init` docs remain; old compatibility helpers and stale version banner are absent.

- [ ] **Step 5: Build examples**

Run:

```bash
zig build
```

Expected: PASS.

- [ ] **Step 6: Commit**

Run:

```bash
git add README.md docs/api.md src/example.zig examples/vigilant_server/src/main.zig
git commit -m "docs: refresh public v2 examples"
```

Expected: commit succeeds.

---

### Task 9: Version, Changelog, and Final Verification

**Files:**
- Modify: `build.zig.zon`
- Modify: `src/vigil.zig`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Update version declarations**

In `build.zig.zon`:

```zig
.version = "2.0.0",
```

In `src/vigil.zig`:

```zig
pub fn getVersion() struct { major: u32, minor: u32, patch: u32 } {
    return .{
        .major = 2,
        .minor = 0,
        .patch = 0,
    };
}
```

- [ ] **Step 2: Add changelog section**

Add at the top of `CHANGELOG.md`:

```markdown
## [2.0.0] - 2026-06-13

### Added
- Owned `Runtime` facade for registry, telemetry, shutdown, inbox creation, and supervisor creation.
- Explicit server sugar lifecycle with `init` and `spawn` handle APIs.
- Documented timer instance API with timeout, interval, cancellation, and cleanup.
- Versioned distributed registry protocol frames under `VIGIL/2`.

### Changed
- `InboxBuilder.withRateLimit()` and `withBackpressure()` now affect built inboxes.
- `SupervisorBuilder.onCrash()` and `withTelemetry()` now wire into supervisor behavior.
- GenServer registration now takes an explicit registry instead of using root global state.
- README and API docs now use runtime-first v2 examples.

### Removed
- Removed obsolete 0.2 compatibility helper exports from the root `vigil` module.
- Removed `src/compat_0_2.zig`.
- Removed root-level `global_registry`.
```

- [ ] **Step 3: Run full verification**

Run:

```bash
zig fmt src build.zig
zig build test
zig build
rg -n "compat_0_2|global_registry|createMailbox|createSupervisor|createSupervisionTree|createResponse|addWorkerGroup|Vigil v1" src README.md docs/api.md CHANGELOG.md
```

Expected:

- `zig fmt` exits `0`.
- `zig build test` exits `0`.
- `zig build` exits `0`.
- `rg` shows only changelog or migration mentions for removed APIs, not active public exports or examples.

- [ ] **Step 4: Inspect public exports**

Run:

```bash
sed -n '1,180p' src/vigil.zig
```

Expected:

- `Runtime`, `RuntimeOptions`, and `runtime` are exported.
- 0.2 helper names are not exported.
- `compat_0_2` is not imported.

- [ ] **Step 5: Commit final version changes**

Run:

```bash
git add build.zig.zon src/vigil.zig CHANGELOG.md README.md docs/api.md
git commit -m "chore!: release vigil 2.0.0"
```

Expected: commit succeeds.

---

## Self-Review Checklist

- Public API cleanup is covered by Task 1 and verified again in Task 9.
- Runtime ownership is covered by Task 2.
- Builder honesty is covered by Tasks 3 and 4.
- GenServer lifecycle is covered by Task 5.
- Timer docs/API drift is covered by Task 6.
- Distribution is covered by Task 7.
- Docs, examples, changelog, and version are covered by Tasks 8 and 9.
- No task depends on hidden state from a previous task except committed code.
- Every task has a compile or test command and an expected result.
