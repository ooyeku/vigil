//! State checkpointing for Vigil.
//!
//! A `Checkpointer` is a small type-erased interface for saving and loading
//! serialized state by id. Implementations can store state in memory, on disk,
//! or in an application-provided backend.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Type-erased interface for checkpoint persistence.
///
/// `load()` returns a newly allocated copy of the stored bytes. The caller owns
/// that returned slice and must free it with the allocator passed to `load()`.
pub const Checkpointer = struct {
    /// Implementation function table.
    vtable: *const VTable,
    /// Implementation object pointer.
    context: *anyopaque,

    /// Function table used by `Checkpointer`.
    pub const VTable = struct {
        /// Save bytes under an id, replacing any previous value.
        save: *const fn (context: *anyopaque, id: []const u8, state: []const u8) anyerror!void,
        /// Load bytes by id, or null if no checkpoint exists.
        load: *const fn (context: *anyopaque, id: []const u8, allocator: Allocator) anyerror!?[]u8,
        /// Delete a checkpoint if it exists.
        delete: *const fn (context: *anyopaque, id: []const u8) void,
    };

    /// Save serialized state under `id`.
    pub fn save(self: Checkpointer, id: []const u8, state: []const u8) !void {
        try self.vtable.save(self.context, id, state);
    }

    /// Load serialized state by `id`.
    ///
    /// Returns null when no checkpoint exists. When non-null, the returned slice
    /// is allocated with `allocator` and must be freed by the caller.
    pub fn load(self: Checkpointer, id: []const u8, allocator: Allocator) !?[]u8 {
        return try self.vtable.load(self.context, id, allocator);
    }

    /// Delete stored state for `id`, ignoring missing entries.
    pub fn delete(self: Checkpointer, id: []const u8) void {
        self.vtable.delete(self.context, id);
    }
};

/// File-backed checkpointer.
///
/// Each checkpoint is stored as `{base_path}/{id}.checkpoint`. IDs must be a
/// single non-empty path component; separators and `.`/`..` are rejected.
pub const FileCheckpointer = struct {
    /// Allocator for copied base path and temporary file paths.
    allocator: Allocator,
    /// Base directory for checkpoint files.
    base_path: []const u8,
    /// I/O implementation used for filesystem operations.
    io: std.Io,

    /// Initialize a file checkpointer and create `base_path` if needed.
    pub fn init(allocator: Allocator, base_path: []const u8) !FileCheckpointer {
        return initWithIo(allocator, std.Io.Threaded.global_single_threaded.io(), base_path);
    }

    /// Initialize with an application-provided Zig I/O implementation.
    pub fn initWithIo(allocator: Allocator, io: std.Io, base_path: []const u8) !FileCheckpointer {
        const path_copy = try allocator.dupe(u8, base_path);
        errdefer allocator.free(path_copy);

        // Surface invalid or inaccessible paths during initialization instead
        // of deferring the failure until the first checkpoint write.
        try std.Io.Dir.cwd().createDirPath(io, base_path);

        return .{
            .allocator = allocator,
            .base_path = path_copy,
            .io = io,
        };
    }

    /// Release the copied base path.
    pub fn deinit(self: *FileCheckpointer) void {
        self.allocator.free(self.base_path);
    }

    /// Return the generic `Checkpointer` interface for this file backend.
    pub fn toCheckpointer(self: *FileCheckpointer) Checkpointer {
        return .{
            .vtable = &file_vtable,
            .context = self,
        };
    }

    fn saveImpl(context: *anyopaque, id: []const u8, state: []const u8) !void {
        const self: *FileCheckpointer = @ptrCast(@alignCast(context));
        if (!validFileId(id)) return error.InvalidCheckpointId;
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id });
        defer self.allocator.free(file_path);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{file_path});
        defer self.allocator.free(tmp_path);

        // Write to a temporary file and rename into place, so a crash
        // mid-write can never corrupt the previous good checkpoint.
        {
            const file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{});
            defer file.close(self.io);

            var buffer: [4096]u8 = undefined;
            var writer = file.writer(self.io, &buffer);
            try writer.interface.writeAll(state);
            try writer.interface.flush();
        }
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
        try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), file_path, self.io);
    }

    fn loadImpl(context: *anyopaque, id: []const u8, allocator: Allocator) !?[]u8 {
        const self: *FileCheckpointer = @ptrCast(@alignCast(context));
        if (!validFileId(id)) return error.InvalidCheckpointId;
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id });
        defer self.allocator.free(file_path);

        return std.Io.Dir.cwd().readFileAlloc(self.io, file_path, allocator, .unlimited) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
    }

    fn deleteImpl(context: *anyopaque, id: []const u8) void {
        const self: *FileCheckpointer = @ptrCast(@alignCast(context));
        if (!validFileId(id)) return;
        const file_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id }) catch return;
        defer self.allocator.free(file_path);

        std.Io.Dir.cwd().deleteFile(self.io, file_path) catch {};
    }

    const file_vtable = Checkpointer.VTable{
        .save = saveImpl,
        .load = loadImpl,
        .delete = deleteImpl,
    };

    fn validFileId(id: []const u8) bool {
        if (id.len == 0 or std.mem.eql(u8, id, ".") or std.mem.eql(u8, id, "..")) return false;
        return std.mem.indexOfAny(u8, id, "/\\\x00") == null;
    }
};

/// In-memory checkpointer.
///
/// This backend is useful for tests and examples. It owns copied ids and state
/// bytes, and it is not persistent across process restarts.
pub const MemoryCheckpointer = struct {
    /// Allocator for ids, state bytes, and hash map storage.
    allocator: Allocator,
    /// Stored checkpoints by id.
    checkpoints: std.StringHashMap([]const u8),

    /// Initialize an empty in-memory backend.
    pub fn init(allocator: Allocator) MemoryCheckpointer {
        return .{
            .allocator = allocator,
            .checkpoints = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Release all stored ids and state bytes.
    pub fn deinit(self: *MemoryCheckpointer) void {
        var it = self.checkpoints.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.checkpoints.deinit();
    }

    /// Return the generic `Checkpointer` interface for this memory backend.
    pub fn toCheckpointer(self: *MemoryCheckpointer) Checkpointer {
        return .{
            .vtable = &memory_vtable,
            .context = self,
        };
    }

    fn saveImpl(context: *anyopaque, id: []const u8, state: []const u8) !void {
        const self: *MemoryCheckpointer = @ptrCast(@alignCast(context));
        // Reserve map capacity before replacing an existing value so an OOM
        // cannot erase the last good checkpoint.
        try self.checkpoints.ensureUnusedCapacity(1);

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        const state_copy = try self.allocator.dupe(u8, state);
        errdefer self.allocator.free(state_copy);

        // Remove old checkpoint if exists
        if (self.checkpoints.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }

        self.checkpoints.putAssumeCapacityNoClobber(id_copy, state_copy);
    }

    fn loadImpl(context: *anyopaque, id: []const u8, allocator: Allocator) !?[]u8 {
        const self: *MemoryCheckpointer = @ptrCast(@alignCast(context));
        if (self.checkpoints.get(id)) |state| {
            const copy = try allocator.dupe(u8, state);
            return copy;
        }
        return null;
    }

    fn deleteImpl(context: *anyopaque, id: []const u8) void {
        const self: *MemoryCheckpointer = @ptrCast(@alignCast(context));
        if (self.checkpoints.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
    }

    const memory_vtable = Checkpointer.VTable{
        .save = saveImpl,
        .load = loadImpl,
        .delete = deleteImpl,
    };
};

test "MemoryCheckpointer save and load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var checkpointer = MemoryCheckpointer.init(allocator);
    defer checkpointer.deinit();

    const ckpt = checkpointer.toCheckpointer();
    try ckpt.save("test_id", "test_state");

    const loaded = try ckpt.load("test_id", allocator);
    try std.testing.expect(loaded != null);
    defer allocator.free(loaded.?);

    try std.testing.expectEqualSlices(u8, "test_state", loaded.?);
}

test "FileCheckpointer init reports a non-directory base path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const blocking_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}/not-a-directory",
        .{tmp.sub_path},
    );
    defer allocator.free(blocking_path);

    const file = try std.Io.Dir.cwd().createFile(std.testing.io, blocking_path, .{});
    file.close(std.testing.io);

    if (FileCheckpointer.initWithIo(allocator, std.testing.io, blocking_path)) |value| {
        var checkpointer = value;
        checkpointer.deinit();
        return error.ExpectedInitializationFailure;
    } else |_| {}
}

test "FileCheckpointer saves loads replaces and deletes state" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/checkpoints", .{tmp.sub_path});
    defer allocator.free(base_path);

    var checkpointer = try FileCheckpointer.initWithIo(allocator, std.testing.io, base_path);
    defer checkpointer.deinit();
    const ckpt = checkpointer.toCheckpointer();

    try ckpt.save("state", "first");
    var loaded = (try ckpt.load("state", allocator)).?;
    try std.testing.expectEqualStrings("first", loaded);
    allocator.free(loaded);

    try ckpt.save("state", "replacement");
    loaded = (try ckpt.load("state", allocator)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("replacement", loaded);

    ckpt.delete("state");
    try std.testing.expectEqual(@as(?[]u8, null), try ckpt.load("state", allocator));

    try std.testing.expectError(error.InvalidCheckpointId, ckpt.save("../escape", "bad"));
    try std.testing.expectError(error.InvalidCheckpointId, ckpt.load("nested/id", allocator));
    try std.testing.expectError(error.InvalidCheckpointId, ckpt.save("", "bad"));
}

test "MemoryCheckpointer preserves an existing value on replacement OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var checkpointer = MemoryCheckpointer.init(failing.allocator());
    defer checkpointer.deinit();
    const ckpt = checkpointer.toCheckpointer();
    try ckpt.save("id", "old");

    // Allow the replacement id copy, then fail the state copy.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, ckpt.save("id", "new"));

    const loaded = (try ckpt.load("id", std.testing.allocator)).?;
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("old", loaded);
}

/// Byte transform hook used for checkpoint compression or encryption.
pub const TransformFn = *const fn (allocator: Allocator, bytes: []const u8) anyerror![]u8;

/// Migration hook invoked when a loaded checkpoint carries an older version.
///
/// Receives the decoded payload and its stored version; returns migrated
/// bytes allocated with `allocator`.
pub const MigrateFn = *const fn (allocator: Allocator, from_version: u32, bytes: []const u8) anyerror![]u8;

/// Options for `CheckpointService`.
pub const CheckpointServiceOptions = struct {
    /// Skip persistence when the state is byte-identical to the last save
    /// for the same id.
    skip_unchanged: bool = true,
    /// Optional transform applied before persistence (compression hook).
    encode: ?TransformFn = null,
    /// Inverse transform applied after load.
    decode: ?TransformFn = null,
    /// Version stamped into every saved checkpoint.
    version: u32 = 1,
    /// Optional migration hook for checkpoints saved with older versions.
    /// Without one, loading a mismatched version fails with
    /// `error.CheckpointVersionMismatch`.
    migrate: ?MigrateFn = null,
};

/// Lifetime counters for a `CheckpointService`.
pub const CheckpointMetrics = struct {
    /// Checkpoints persisted to the backend.
    saves: u64,
    /// Saves skipped because the state was unchanged.
    skipped_unchanged: u64,
    /// Saves that failed in the backend or hooks.
    failures: u64,
    /// Payload bytes written to the backend.
    bytes_written: u64,
    /// Total backend save latency in milliseconds.
    total_save_latency_ms: u64,
    /// Async saves accepted but not yet persisted.
    pending: usize,
};

/// Versioned, metered checkpoint pipeline over any `Checkpointer` backend.
///
/// The service stamps a version header on every checkpoint, applies optional
/// encode/decode transforms (compression hooks), skips writes when state has
/// not changed, and can persist asynchronously on one background thread so
/// hot paths never wait on storage. Metrics report latency, size, and skip
/// counts.
///
/// Like `TimerService`, the service address must stay stable between
/// `start()` and `deinit()`.
pub const CheckpointService = struct {
    /// Allocator for queued states and dedup bookkeeping.
    allocator: Allocator,
    /// Persistence backend.
    backend: Checkpointer,
    /// Pipeline behavior.
    options: CheckpointServiceOptions,
    /// Hash of the last saved state per id, for unchanged-state skips.
    last_hashes: std.StringHashMapUnmanaged(u64),
    /// Pending async saves in submission order.
    queue: std.ArrayListUnmanaged(Pending),
    /// True while the worker owns a dequeued save.
    worker_busy: bool,
    /// Protects queue, hashes, and worker state.
    mutex: compat.Mutex,
    /// Signaled when the queue or lifecycle changes.
    changed: compat.Condition,
    /// Background writer thread.
    worker: ?std.Thread,
    /// True while the worker should keep running.
    running: bool,
    // Lifetime counters.
    saves: std.atomic.Value(u64),
    skipped: std.atomic.Value(u64),
    failures: std.atomic.Value(u64),
    bytes_written: std.atomic.Value(u64),
    total_save_latency_ms: std.atomic.Value(u64),

    const compat = @import("compat.zig");

    const Pending = struct {
        id: []u8,
        state: []u8,
    };

    const frame_magic = "VCK1";

    /// Initialize a stopped service over `backend`.
    pub fn init(allocator: Allocator, backend: Checkpointer, options: CheckpointServiceOptions) CheckpointService {
        return .{
            .allocator = allocator,
            .backend = backend,
            .options = options,
            .last_hashes = .empty,
            .queue = .empty,
            .worker_busy = false,
            .mutex = .{},
            .changed = .{},
            .worker = null,
            .running = false,
            .saves = std.atomic.Value(u64).init(0),
            .skipped = std.atomic.Value(u64).init(0),
            .failures = std.atomic.Value(u64).init(0),
            .bytes_written = std.atomic.Value(u64).init(0),
            .total_save_latency_ms = std.atomic.Value(u64).init(0),
        };
    }

    /// Start the background writer used by `saveAsync()`.
    pub fn start(self: *CheckpointService) !void {
        self.mutex.lock();
        if (self.running or self.worker != null) {
            self.mutex.unlock();
            return error.AlreadyRunning;
        }
        self.running = true;
        self.worker = std.Thread.spawn(.{}, workerLoop, .{self}) catch |err| {
            self.running = false;
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
    }

    /// Stop the writer, persisting any queued saves first, and release
    /// bookkeeping storage.
    pub fn deinit(self: *CheckpointService) void {
        self.mutex.lock();
        self.running = false;
        const worker = self.worker;
        self.worker = null;
        self.mutex.unlock();
        self.changed.broadcast();
        if (worker) |thread| thread.join();

        // Persist whatever remains so no accepted save is silently lost.
        while (true) {
            self.mutex.lock();
            const pending = if (self.queue.items.len > 0) self.dequeueLocked() else null;
            self.mutex.unlock();
            const item = pending orelse break;
            self.persist(item.id, item.state) catch {};
            self.allocator.free(item.id);
            self.allocator.free(item.state);
        }

        var it = self.last_hashes.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.last_hashes.deinit(self.allocator);
        self.queue.deinit(self.allocator);
    }

    /// Save synchronously through the full pipeline.
    pub fn save(self: *CheckpointService, id: []const u8, state: []const u8) !void {
        if (self.options.skip_unchanged and self.isUnchanged(id, state)) {
            _ = self.skipped.fetchAdd(1, .monotonic);
            return;
        }
        try self.persist(id, state);
    }

    /// Queue a save to be persisted by the background writer.
    ///
    /// The id and state are copied; the call never blocks on storage.
    /// Requires `start()`. Use `flush()` to wait for queued saves.
    pub fn saveAsync(self: *CheckpointService, id: []const u8, state: []const u8) !void {
        if (self.options.skip_unchanged and self.isUnchanged(id, state)) {
            _ = self.skipped.fetchAdd(1, .monotonic);
            return;
        }

        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);
        const state_copy = try self.allocator.dupe(u8, state);
        errdefer self.allocator.free(state_copy);

        self.mutex.lock();
        if (!self.running) {
            self.mutex.unlock();
            return error.NotRunning;
        }
        self.queue.append(self.allocator, .{ .id = id_copy, .state = state_copy }) catch |err| {
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
        self.changed.signal();
    }

    /// Block until every queued async save has been persisted.
    pub fn flush(self: *CheckpointService) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.queue.items.len > 0 or self.worker_busy) {
            self.changed.timedWait(&self.mutex, 50 * std.time.ns_per_ms) catch {};
        }
    }

    /// Load a checkpoint through version checking, migration, and decoding.
    ///
    /// Returns null when no checkpoint exists. Checkpoints written without a
    /// version header are treated as version 0. The caller owns the returned
    /// slice.
    pub fn load(self: *CheckpointService, id: []const u8, allocator: Allocator) !?[]u8 {
        const raw = (try self.backend.load(id, allocator)) orelse return null;
        defer allocator.free(raw);

        var version: u32 = 0;
        var payload: []const u8 = raw;
        if (raw.len >= frame_magic.len + 4 and std.mem.eql(u8, raw[0..frame_magic.len], frame_magic)) {
            version = std.mem.readInt(u32, raw[frame_magic.len..][0..4], .little);
            payload = raw[frame_magic.len + 4 ..];
        }

        const decoded: []u8 = if (self.options.decode) |decode|
            try decode(allocator, payload)
        else
            try allocator.dupe(u8, payload);

        if (version == self.options.version) return decoded;

        defer allocator.free(decoded);
        const migrate = self.options.migrate orelse return error.CheckpointVersionMismatch;
        return try migrate(allocator, version, decoded);
    }

    /// Return lifetime pipeline counters.
    pub fn metrics(self: *CheckpointService) CheckpointMetrics {
        self.mutex.lock();
        const pending = self.queue.items.len + @intFromBool(self.worker_busy);
        self.mutex.unlock();

        return .{
            .saves = self.saves.load(.monotonic),
            .skipped_unchanged = self.skipped.load(.monotonic),
            .failures = self.failures.load(.monotonic),
            .bytes_written = self.bytes_written.load(.monotonic),
            .total_save_latency_ms = self.total_save_latency_ms.load(.monotonic),
            .pending = pending,
        };
    }

    fn isUnchanged(self: *CheckpointService, id: []const u8, state: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, state);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.last_hashes.get(id)) |previous| {
            if (previous == hash) return true;
        }
        return false;
    }

    fn rememberHashLocked(self: *CheckpointService, id: []const u8, hash: u64) void {
        if (self.last_hashes.getPtr(id)) |slot| {
            slot.* = hash;
            return;
        }
        const id_copy = self.allocator.dupe(u8, id) catch return;
        self.last_hashes.put(self.allocator, id_copy, hash) catch {
            self.allocator.free(id_copy);
        };
    }

    fn persist(self: *CheckpointService, id: []const u8, state: []const u8) !void {
        const start_ms = compat.monotonicMilliTimestamp();

        const encoded: ?[]u8 = if (self.options.encode) |encode|
            try encode(self.allocator, state)
        else
            null;
        defer if (encoded) |bytes| self.allocator.free(bytes);
        const payload = encoded orelse state;

        const frame = try self.allocator.alloc(u8, frame_magic.len + 4 + payload.len);
        defer self.allocator.free(frame);
        @memcpy(frame[0..frame_magic.len], frame_magic);
        std.mem.writeInt(u32, frame[frame_magic.len..][0..4], self.options.version, .little);
        @memcpy(frame[frame_magic.len + 4 ..], payload);

        self.backend.save(id, frame) catch |err| {
            _ = self.failures.fetchAdd(1, .monotonic);
            return err;
        };

        const elapsed: u64 = @intCast(@max(0, compat.monotonicMilliTimestamp() - start_ms));
        _ = self.saves.fetchAdd(1, .monotonic);
        _ = self.bytes_written.fetchAdd(frame.len, .monotonic);
        _ = self.total_save_latency_ms.fetchAdd(elapsed, .monotonic);

        const hash = std.hash.Wyhash.hash(0, state);
        self.mutex.lock();
        self.rememberHashLocked(id, hash);
        self.mutex.unlock();
    }

    fn dequeueLocked(self: *CheckpointService) ?Pending {
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn workerLoop(self: *CheckpointService) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            if (self.dequeueLocked()) |item| {
                self.worker_busy = true;
                self.mutex.unlock();

                self.persist(item.id, item.state) catch {};
                self.allocator.free(item.id);
                self.allocator.free(item.state);

                self.mutex.lock();
                self.worker_busy = false;
                self.changed.broadcast();
                continue;
            }
            if (!self.running) return;
            self.changed.wait(&self.mutex);
        }
    }
};

fn testDoubleEncode(allocator: Allocator, bytes: []const u8) anyerror![]u8 {
    // Stand-in compression hook: prefix payloads with a marker.
    const out = try allocator.alloc(u8, bytes.len + 2);
    out[0] = 'Z';
    out[1] = ':';
    @memcpy(out[2..], bytes);
    return out;
}

fn testDoubleDecode(allocator: Allocator, bytes: []const u8) anyerror![]u8 {
    if (bytes.len < 2 or bytes[0] != 'Z' or bytes[1] != ':') return error.CorruptCheckpoint;
    return try allocator.dupe(u8, bytes[2..]);
}

fn testMigrateV0(allocator: Allocator, from_version: u32, bytes: []const u8) anyerror![]u8 {
    return std.fmt.allocPrint(allocator, "migrated-v{d}:{s}", .{ from_version, bytes });
}

test "CheckpointService round-trips with version header and skips unchanged saves" {
    const allocator = std.testing.allocator;
    var backend = MemoryCheckpointer.init(allocator);
    defer backend.deinit();

    var service = CheckpointService.init(allocator, backend.toCheckpointer(), .{ .version = 3 });
    defer service.deinit();

    try service.save("machine", "state-a");
    try service.save("machine", "state-a"); // unchanged: skipped
    try service.save("machine", "state-b");

    const loaded = (try service.load("machine", allocator)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("state-b", loaded);

    const stats = service.metrics();
    try std.testing.expectEqual(@as(u64, 2), stats.saves);
    try std.testing.expectEqual(@as(u64, 1), stats.skipped_unchanged);
    try std.testing.expectEqual(@as(u64, 0), stats.failures);
    try std.testing.expect(stats.bytes_written > 0);

    // The stored frame carries the magic + version header.
    const raw = (try backend.toCheckpointer().load("machine", allocator)).?;
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("VCK1", raw[0..4]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, raw[4..8], .little));
}

test "CheckpointService applies compression hooks on save and load" {
    const allocator = std.testing.allocator;
    var backend = MemoryCheckpointer.init(allocator);
    defer backend.deinit();

    var service = CheckpointService.init(allocator, backend.toCheckpointer(), .{
        .encode = testDoubleEncode,
        .decode = testDoubleDecode,
    });
    defer service.deinit();

    try service.save("compressed", "payload");
    const loaded = (try service.load("compressed", allocator)).?;
    defer allocator.free(loaded);
    try std.testing.expectEqualStrings("payload", loaded);

    // The persisted payload is the encoded form.
    const raw = (try backend.toCheckpointer().load("compressed", allocator)).?;
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("Z:payload", raw[8..]);
}

test "CheckpointService migrates old versions and rejects unknown ones" {
    const allocator = std.testing.allocator;
    var backend = MemoryCheckpointer.init(allocator);
    defer backend.deinit();

    // A legacy checkpoint written without any version header.
    try backend.toCheckpointer().save("legacy", "old-bytes");

    var strict = CheckpointService.init(allocator, backend.toCheckpointer(), .{ .version = 2 });
    defer strict.deinit();
    try std.testing.expectError(error.CheckpointVersionMismatch, strict.load("legacy", allocator));

    var migrating = CheckpointService.init(allocator, backend.toCheckpointer(), .{
        .version = 2,
        .migrate = testMigrateV0,
    });
    defer migrating.deinit();
    const migrated = (try migrating.load("legacy", allocator)).?;
    defer allocator.free(migrated);
    try std.testing.expectEqualStrings("migrated-v0:old-bytes", migrated);
}

test "CheckpointService persists async saves in order and drains on deinit" {
    const allocator = std.testing.allocator;
    var backend = MemoryCheckpointer.init(allocator);
    defer backend.deinit();

    var service = CheckpointService.init(allocator, backend.toCheckpointer(), .{});
    try service.start();
    try std.testing.expectError(error.AlreadyRunning, service.start());

    try service.saveAsync("async", "one");
    try service.saveAsync("async", "two");
    try service.saveAsync("async", "three");
    service.flush();

    const flushed = (try service.load("async", allocator)).?;
    try std.testing.expectEqualStrings("three", flushed);
    allocator.free(flushed);
    try std.testing.expectEqual(@as(usize, 0), service.metrics().pending);

    // Queued work accepted before deinit is persisted during deinit.
    try service.saveAsync("async", "final");
    service.deinit();

    var reader = CheckpointService.init(allocator, backend.toCheckpointer(), .{});
    defer reader.deinit();
    const final = (try reader.load("async", allocator)).?;
    defer allocator.free(final);
    try std.testing.expectEqualStrings("final", final);
}

test "CheckpointService saveAsync requires a running worker" {
    const allocator = std.testing.allocator;
    var backend = MemoryCheckpointer.init(allocator);
    defer backend.deinit();

    var service = CheckpointService.init(allocator, backend.toCheckpointer(), .{});
    defer service.deinit();
    try std.testing.expectError(error.NotRunning, service.saveAsync("id", "state"));
}
