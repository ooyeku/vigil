//! Growable ring buffer used by mailbox queues.
//!
//! The v2 mailbox previously used `std.ArrayList` with `orderedRemove(0)`,
//! which memmoves the whole queue on every receive. A ring buffer makes
//! pop-front O(1) while keeping indexed access for expiry sweeps.

const std = @import("std");

/// FIFO ring buffer with O(1) push-back/pop-front and indexed access.
///
/// Not thread-safe; callers synchronize externally (the mailbox holds its own
/// mutex). Storage grows by doubling and is never shrunk.
pub fn RingQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Backing storage; capacity is `storage.len`.
        storage: []T,
        /// Index of the logical front element.
        head: usize,
        /// Number of live elements.
        count: usize,

        /// An empty queue with no allocated storage.
        pub const empty: Self = .{ .storage = &.{}, .head = 0, .count = 0 };

        /// Free backing storage. Elements are not deinitialized.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.storage);
            self.* = empty;
        }

        /// Return the number of live elements.
        pub fn len(self: *const Self) usize {
            return self.count;
        }

        /// Return a pointer to the element at logical index `index`.
        ///
        /// Asserts `index < len()`.
        pub fn at(self: *const Self, index: usize) *T {
            std.debug.assert(index < self.count);
            return &self.storage[self.wrap(index)];
        }

        /// Append an element to the back, growing storage when full.
        pub fn pushBack(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            if (self.count == self.storage.len) {
                try self.grow(allocator);
            }
            self.storage[self.wrap(self.count)] = value;
            self.count += 1;
        }

        /// Remove and return the front element, or null when empty.
        pub fn popFront(self: *Self) ?T {
            if (self.count == 0) return null;
            const value = self.storage[self.head];
            self.head = if (self.head + 1 == self.storage.len) 0 else self.head + 1;
            self.count -= 1;
            if (self.count == 0) self.head = 0;
            return value;
        }

        /// Return a pointer to the front element without removing it.
        pub fn peekFront(self: *const Self) ?*T {
            if (self.count == 0) return null;
            return &self.storage[self.head];
        }

        /// Remove and return the element at logical index `index`, preserving
        /// order. Shifts whichever side of the queue is shorter.
        ///
        /// Asserts `index < len()`.
        pub fn removeAt(self: *Self, index: usize) T {
            std.debug.assert(index < self.count);
            const value = self.storage[self.wrap(index)];

            if (index < self.count - index - 1) {
                // Shift the front segment toward the back by one.
                var i = index;
                while (i > 0) : (i -= 1) {
                    self.storage[self.wrap(i)] = self.storage[self.wrap(i - 1)];
                }
                self.head = if (self.head + 1 == self.storage.len) 0 else self.head + 1;
            } else {
                // Shift the back segment toward the front by one.
                var i = index;
                while (i + 1 < self.count) : (i += 1) {
                    self.storage[self.wrap(i)] = self.storage[self.wrap(i + 1)];
                }
            }
            self.count -= 1;
            if (self.count == 0) self.head = 0;
            return value;
        }

        fn wrap(self: *const Self, logical: usize) usize {
            const offset = self.head + logical;
            return if (offset >= self.storage.len) offset - self.storage.len else offset;
        }

        fn grow(self: *Self, allocator: std.mem.Allocator) !void {
            const new_capacity = if (self.storage.len == 0) 8 else self.storage.len * 2;
            const new_storage = try allocator.alloc(T, new_capacity);

            for (0..self.count) |i| {
                new_storage[i] = self.storage[self.wrap(i)];
            }
            allocator.free(self.storage);
            self.storage = new_storage;
            self.head = 0;
        }
    };
}

test "RingQueue preserves FIFO order across growth and wraparound" {
    const allocator = std.testing.allocator;
    var queue = RingQueue(u32).empty;
    defer queue.deinit(allocator);

    // Interleave pushes and pops so head wraps repeatedly.
    var next: u32 = 0;
    var expected: u32 = 0;
    for (0..200) |round| {
        const pushes = (round % 5) + 1;
        for (0..pushes) |_| {
            try queue.pushBack(allocator, next);
            next += 1;
        }
        const pops = round % 3;
        for (0..pops) |_| {
            if (queue.popFront()) |value| {
                try std.testing.expectEqual(expected, value);
                expected += 1;
            }
        }
    }
    while (queue.popFront()) |value| {
        try std.testing.expectEqual(expected, value);
        expected += 1;
    }
    try std.testing.expectEqual(next, expected);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
    try std.testing.expect(queue.peekFront() == null);
}

test "RingQueue removeAt preserves order from either side" {
    const allocator = std.testing.allocator;
    var queue = RingQueue(u32).empty;
    defer queue.deinit(allocator);

    // Force a wrapped layout: fill, drain some, refill.
    for (0..8) |i| try queue.pushBack(allocator, @intCast(i));
    for (0..4) |_| _ = queue.popFront();
    for (8..14) |i| try queue.pushBack(allocator, @intCast(i));
    // Queue now holds 4..13 with head mid-storage.

    try std.testing.expectEqual(@as(u32, 5), queue.removeAt(1)); // near front
    try std.testing.expectEqual(@as(u32, 12), queue.removeAt(7)); // near back
    try std.testing.expectEqual(@as(u32, 8), queue.removeAt(3)); // middle

    const expected = [_]u32{ 4, 6, 7, 9, 10, 11, 13 };
    for (expected) |value| {
        try std.testing.expectEqual(value, queue.popFront().?);
    }
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "RingQueue at() indexes logically through wraparound" {
    const allocator = std.testing.allocator;
    var queue = RingQueue(u32).empty;
    defer queue.deinit(allocator);

    for (0..8) |i| try queue.pushBack(allocator, @intCast(i));
    for (0..6) |_| _ = queue.popFront();
    for (8..12) |i| try queue.pushBack(allocator, @intCast(i));

    const expected = [_]u32{ 6, 7, 8, 9, 10, 11 };
    try std.testing.expectEqual(expected.len, queue.len());
    for (expected, 0..) |value, i| {
        try std.testing.expectEqual(value, queue.at(i).*);
    }
}
