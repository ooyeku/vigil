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
/// Each checkpoint is stored as `{base_path}/{id}.checkpoint`. The id is used
/// as a path component, so callers should pass ids that are safe for the local
/// filesystem.
pub const FileCheckpointer = struct {
    /// Allocator for copied base path and temporary file paths.
    allocator: Allocator,
    /// Base directory for checkpoint files.
    base_path: []const u8,

    /// Initialize a file checkpointer and create `base_path` if needed.
    pub fn init(allocator: Allocator, base_path: []const u8) !FileCheckpointer {
        const path_copy = try allocator.dupe(u8, base_path);
        errdefer allocator.free(path_copy);

        // Ensure directory exists
        std.fs.cwd().makePath(base_path) catch {};

        return .{
            .allocator = allocator,
            .base_path = path_copy,
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
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id });
        defer self.allocator.free(file_path);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        try file.writeAll(state);
    }

    fn loadImpl(context: *anyopaque, id: []const u8, allocator: Allocator) !?[]u8 {
        const self: *FileCheckpointer = @ptrCast(@alignCast(context));
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id });
        defer self.allocator.free(file_path);

        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        const stat = try file.stat();
        const buffer = try allocator.alloc(u8, @as(usize, @intCast(stat.size)));
        errdefer allocator.free(buffer);

        const bytes_read = try file.readAll(buffer);
        return buffer[0..bytes_read];
    }

    fn deleteImpl(context: *anyopaque, id: []const u8) void {
        const self: *FileCheckpointer = @ptrCast(@alignCast(context));
        const file_path = std.fmt.allocPrint(self.allocator, "{s}/{s}.checkpoint", .{ self.base_path, id }) catch return;
        defer self.allocator.free(file_path);

        std.fs.cwd().deleteFile(file_path) catch {};
    }

    const file_vtable = Checkpointer.VTable{
        .save = saveImpl,
        .load = loadImpl,
        .delete = deleteImpl,
    };
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
        const id_copy = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(id_copy);

        const state_copy = try self.allocator.dupe(u8, state);
        errdefer self.allocator.free(state_copy);

        // Remove old checkpoint if exists
        if (self.checkpoints.fetchRemove(id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }

        try self.checkpoints.put(id_copy, state_copy);
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
