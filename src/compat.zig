//! Zig 0.16 compatibility layer.
//!
//! Zig 0.16 moved the synchronous threading primitives (`Mutex`, `Condition`,
//! `ResetEvent`, etc.) off of `std.Thread` and into `std.Io`, where the new
//! variants require an `Io` instance on every `lock`/`unlock` call.
//!
//! This module exposes a thin `Mutex` that wraps `std.Io.Mutex` and drives it
//! with `std.Io.Threaded.mutexLock`/`mutexUnlock`, which go straight to the
//! futex and bypass the VTable. Semantics match the old `std.Thread.Mutex`.

const std = @import("std");

/// Drop-in replacement for the pre-0.16 `std.Thread.Mutex`.
///
/// Default-initialize with `.{}` in a struct field declaration. `lock`,
/// `unlock`, and `tryLock` have the same semantics as the old API.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        std.Io.Threaded.mutexLock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        std.Io.Threaded.mutexUnlock(&self.inner);
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// Minimal futex-style wait/wake on a 32-bit word.
///
/// Zig 0.16 moved futex access behind `std.Io`; this exposes the same
/// primitive directly on the OS so synchronization types here do not need an
/// `Io` instance. Waits may return spuriously — callers must re-check their
/// condition in a loop.
pub const futex = struct {
    /// Block until `ptr` no longer holds `expect`, a wake arrives, the
    /// optional timeout elapses, or a spurious wakeup occurs.
    pub fn wait(ptr: *const std.atomic.Value(u32), expect: u32, timeout_ns: ?u64) void {
        switch (@import("builtin").os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => {
                const flags: std.c.UL = .{ .op = .COMPARE_AND_WAIT, .NO_ERRNO = true };
                const timeout_us: u32 = if (timeout_ns) |ns|
                    @intCast(@min(@max((ns + std.time.ns_per_us - 1) / std.time.ns_per_us, 1), std.math.maxInt(u32)))
                else
                    0; // zero means wait forever
                _ = std.c.__ulock_wait(flags, &ptr.raw, expect, timeout_us);
            },
            .linux => {
                const linux = std.os.linux;
                var ts_buffer: linux.timespec = undefined;
                const ts: ?*const linux.timespec = if (timeout_ns) |ns| blk: {
                    ts_buffer = .{
                        .sec = @intCast(ns / std.time.ns_per_s),
                        .nsec = @intCast(ns % std.time.ns_per_s),
                    };
                    break :blk &ts_buffer;
                } else null;
                _ = linux.futex_4arg(&ptr.raw, .{ .cmd = .WAIT, .private = true }, expect, ts);
            },
            else => {
                // Portable fallback: bounded sleep-poll. Correct (callers
                // re-check in a loop) but not as responsive as a real futex.
                if (ptr.load(.acquire) != expect) return;
                const step_ns: u64 = 1 * std.time.ns_per_ms;
                sleep(if (timeout_ns) |ns| @min(ns, step_ns) else step_ns);
            },
        }
    }

    /// Wake up to `max_waiters` threads blocked in `wait()` on `ptr`.
    pub fn wake(ptr: *const std.atomic.Value(u32), max_waiters: u32) void {
        if (max_waiters == 0) return;
        switch (@import("builtin").os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => {
                const flags: std.c.UL = .{
                    .op = .COMPARE_AND_WAIT,
                    .NO_ERRNO = true,
                    .WAKE_ALL = max_waiters > 1,
                };
                while (true) {
                    const status = std.c.__ulock_wake(flags, &ptr.raw, 0);
                    if (status >= 0) return;
                    switch (@as(std.c.E, @enumFromInt(-status))) {
                        .INTR, .CANCELED => continue,
                        else => return,
                    }
                }
            },
            .linux => {
                const linux = std.os.linux;
                _ = linux.futex_3arg(
                    &ptr.raw,
                    .{ .cmd = .WAKE, .private = true },
                    @min(max_waiters, std.math.maxInt(i32)),
                );
            },
            else => {},
        }
    }
};

/// Drop-in replacement for the pre-0.16 `std.Thread.Condition`, integrated
/// with `compat.Mutex`.
///
/// The algorithm mirrors the standard library's futex-based condition
/// variable: a packed waiters/signals word plus an epoch word that waiters
/// sleep on. `timedWait` returns `error.Timeout` when no signal arrived
/// within the given duration.
pub const Condition = struct {
    /// Low 16 bits: waiter count. High 16 bits: undelivered signal count.
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Bumped on every signal/broadcast; waiters sleep on this word.
    epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    const one_waiter: u32 = 1;
    const one_signal: u32 = 1 << 16;

    fn waiters(state: u32) u32 {
        return state & 0xffff;
    }

    fn signals(state: u32) u32 {
        return state >> 16;
    }

    /// Atomically release `mutex` and wait for a signal. The mutex is
    /// re-acquired before returning.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.waitInner(mutex, null) catch unreachable;
    }

    /// Like `wait`, but gives up after `timeout_ns` nanoseconds.
    pub fn timedWait(self: *Condition, mutex: *Mutex, timeout_ns: u64) error{Timeout}!void {
        return self.waitInner(mutex, timeout_ns);
    }

    fn waitInner(self: *Condition, mutex: *Mutex, timeout_ns: ?u64) error{Timeout}!void {
        const deadline_ms: ?i64 = if (timeout_ns) |ns|
            monotonicMilliTimestamp() +| @as(i64, @intCast(@min(ns / std.time.ns_per_ms + 1, std.math.maxInt(i64))))
        else
            null;

        var epoch = self.epoch.load(.acquire);
        const prev_state = self.state.fetchAdd(one_waiter, .monotonic);
        std.debug.assert(waiters(prev_state) < 0xffff);

        mutex.unlock();
        defer mutex.lock();

        while (true) {
            const remaining_ns: ?u64 = if (deadline_ms) |deadline| blk: {
                const remaining_ms = deadline - monotonicMilliTimestamp();
                if (remaining_ms <= 0) break :blk 0;
                break :blk @as(u64, @intCast(remaining_ms)) * std.time.ns_per_ms;
            } else null;

            if (remaining_ns == null or remaining_ns.? > 0) {
                futex.wait(&self.epoch, epoch, remaining_ns);
            }
            epoch = self.epoch.load(.acquire);

            // Consume a pending signal if one is available, even after a
            // timeout, so no delivered signal is lost.
            var state = self.state.load(.monotonic);
            while (signals(state) > 0) {
                state = self.state.cmpxchgWeak(
                    state,
                    state - (one_waiter + one_signal),
                    .acquire,
                    .monotonic,
                ) orelse return;
            }

            if (deadline_ms) |deadline| {
                if (monotonicMilliTimestamp() >= deadline) {
                    _ = self.state.fetchSub(one_waiter, .monotonic);
                    return error.Timeout;
                }
            }
        }
    }

    /// Wake one waiting thread, if any.
    pub fn signal(self: *Condition) void {
        var state = self.state.load(.monotonic);
        while (waiters(state) > signals(state)) {
            state = self.state.cmpxchgWeak(
                state,
                state + one_signal,
                .release,
                .monotonic,
            ) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                futex.wake(&self.epoch, 1);
                return;
            };
        }
    }

    /// Wake every waiting thread.
    pub fn broadcast(self: *Condition) void {
        var state = self.state.load(.monotonic);
        while (waiters(state) > signals(state)) {
            const wake_count = waiters(state) - signals(state);
            state = self.state.cmpxchgWeak(
                state,
                (waiters(state) << 16) | waiters(state),
                .release,
                .monotonic,
            ) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                futex.wake(&self.epoch, wake_count);
                return;
            };
        }
    }
};

test "Mutex basic lock/unlock" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();

    try std.testing.expect(m.tryLock());
    m.unlock();
}

test "monotonic clock does not move backwards" {
    const before = monotonicMilliTimestamp();
    sleep(1 * std.time.ns_per_ms);
    const after = monotonicMilliTimestamp();
    try std.testing.expect(after >= before);
}

// Direct kernel32 externs. Zig 0.16 pared `std.os.windows.kernel32` down
// to a couple of functions (CreateProcessW etc.), so the time / Sleep
// surfaces aren't reachable through the stdlib anymore. Declaring them
// inline keeps the change self-contained and zero-dep.
const win32 = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *std.os.windows.FILETIME) callconv(.winapi) void;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
} else struct {};

/// Replacement for the removed `std.Thread.sleep`. Blocks the current thread
/// for `nanoseconds` nanoseconds using libc `nanosleep` (POSIX) or
/// `kernel32!Sleep` (Windows). Windows resolution is milliseconds; sub-ms
/// callers get a single ms wait so we never short-sleep.
pub fn sleep(nanoseconds: u64) void {
    if (@import("builtin").os.tag == .windows) {
        const ms_u64 = if (nanoseconds == 0)
            0
        else
            ((nanoseconds - 1) / std.time.ns_per_ms) + 1;
        const ms: u32 = @intCast(@min(ms_u64, std.math.maxInt(u32)));
        win32.Sleep(ms);
        return;
    }
    const ns_per_s = std.time.ns_per_s;
    var req: std.posix.timespec = .{
        .sec = @intCast(nanoseconds / ns_per_s),
        .nsec = @intCast(nanoseconds % ns_per_s),
    };
    var rem: std.posix.timespec = undefined;
    while (true) {
        switch (std.posix.errno(std.posix.system.nanosleep(&req, &rem))) {
            .INTR => req = rem,
            else => return,
        }
    }
}

/// Replacement for the removed `std.time.nanoTimestamp`. Returns nanoseconds
/// since the Unix epoch. POSIX uses `clock_gettime(CLOCK_REALTIME)`; Windows
/// reads a FILETIME (100-ns ticks since 1601-01-01) and shifts it onto the
/// Unix epoch.
pub fn nanoTimestamp() i128 {
    if (@import("builtin").os.tag == .windows) {
        var ft: std.os.windows.FILETIME = undefined;
        win32.GetSystemTimeAsFileTime(&ft);
        // Combine into a single 64-bit count of 100-ns intervals since
        // 1601-01-01, then shift the epoch to 1970-01-01 and scale up
        // to nanoseconds. 116444736000000000 = ticks between the two
        // epochs (369 years × 365.2425 days × 86400 × 10_000_000).
        const epoch_delta_100ns: i128 = 116444736000000000;
        const ticks_100ns: i128 =
            (@as(i128, ft.dwHighDateTime) << 32) | @as(i128, ft.dwLowDateTime);
        return (ticks_100ns - epoch_delta_100ns) * 100;
    }
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Replacement for the removed `std.time.milliTimestamp`.
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

/// Monotonic milliseconds suitable for measuring elapsed time and deadlines.
pub fn monotonicMilliTimestamp() i64 {
    if (@import("builtin").os.tag == .windows) {
        return @intCast(@min(win32.GetTickCount64(), std.math.maxInt(i64)));
    }

    var ts: std.posix.timespec = undefined;
    if (std.posix.errno(std.posix.system.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// Replacement for the removed `std.time.timestamp`.
pub fn timestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_s));
}

/// BSD-socket helpers. Zig 0.16 removed `std.posix.socket`/`connect`/`bind`/
/// `listen`/`accept` (networking moved under `std.Io.net`). Until callers can
/// accept an `Io` parameter, these thin wrappers around libc keep the old
/// surface available.
pub const sockets = struct {
    const posix = std.posix;

    pub const SocketError = error{SocketFailed};
    pub const ConnectError = error{ConnectFailed};
    pub const BindError = error{BindFailed};
    pub const ListenError = error{ListenFailed};
    pub const AcceptError = error{AcceptFailed} || posix.UnexpectedError;

    pub fn socket(domain: u32, sock_type: u32, protocol: u32) SocketError!posix.socket_t {
        const rc = std.c.socket(domain, sock_type, protocol);
        if (rc < 0) return error.SocketFailed;
        return rc;
    }

    pub fn connect(fd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) ConnectError!void {
        if (std.c.connect(fd, addr, len) != 0) return error.ConnectFailed;
    }

    pub fn bind(fd: posix.socket_t, addr: *const posix.sockaddr, len: posix.socklen_t) BindError!void {
        if (std.c.bind(fd, addr, len) != 0) return error.BindFailed;
    }

    pub fn listen(fd: posix.socket_t, backlog: u31) ListenError!void {
        if (std.c.listen(fd, backlog) != 0) return error.ListenFailed;
    }

    pub fn accept(fd: posix.socket_t, addr: ?*posix.sockaddr, len: ?*posix.socklen_t) AcceptError!posix.socket_t {
        const rc = std.c.accept(fd, addr, len);
        if (rc < 0) return error.AcceptFailed;
        return rc;
    }

    pub fn close(fd: posix.socket_t) void {
        _ = std.c.close(fd);
    }
};

/// Minimal networking shim covering the subset of `std.net` this library
/// used pre-0.16. Implemented directly on POSIX sockets so callers don't
/// need to thread an `Io` handle through the distributed registry.
pub const net = struct {
    pub const Address = std.posix.sockaddr;
    const posix = std.posix;

    /// IPv4 + port wrapper matching the old `std.net.Address` surface used
    /// in this project.
    pub const Ip4Address = extern struct {
        any: posix.sockaddr,
        in: posix.sockaddr.in,

        pub fn getOsSockLen(_: Ip4Address) posix.socklen_t {
            return @sizeOf(posix.sockaddr.in);
        }
    };

    pub const AddressError = error{InvalidAddress};

    /// Parse `a.b.c.d` + port into an address usable with posix.connect/bind.
    pub fn parseIp4(text: []const u8, port: u16) AddressError!Ip4Address {
        var octets: [4]u8 = undefined;
        var part_index: usize = 0;
        var cursor: usize = 0;
        while (cursor < text.len) : (part_index += 1) {
            if (part_index >= 4) return error.InvalidAddress;
            var end = cursor;
            while (end < text.len and text[end] != '.') : (end += 1) {}
            if (end == cursor) return error.InvalidAddress;
            octets[part_index] = std.fmt.parseInt(u8, text[cursor..end], 10) catch return error.InvalidAddress;
            cursor = if (end < text.len) end + 1 else end;
        }
        if (part_index != 4) return error.InvalidAddress;

        const addr_be: u32 =
            (@as(u32, octets[0]) << 24) |
            (@as(u32, octets[1]) << 16) |
            (@as(u32, octets[2]) << 8) |
            @as(u32, octets[3]);

        var sin: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
        sin.family = posix.AF.INET;
        sin.port = std.mem.nativeToBig(u16, port);
        sin.addr = std.mem.nativeToBig(u32, addr_be);

        var result: Ip4Address = undefined;
        result.in = sin;
        @memcpy(std.mem.asBytes(&result.any)[0..@sizeOf(posix.sockaddr.in)], std.mem.asBytes(&sin));
        return result;
    }

    /// Thin wrapper over a connected socket fd providing blocking read/write
    /// with the same surface the legacy `std.net.Stream` had.
    pub const Stream = struct {
        handle: posix.socket_t,

        pub const IoError = error{ReadFailed} || error{WriteFailed};

        pub fn write(self: Stream, data: []const u8) IoError!usize {
            const rc = std.c.write(self.handle, data.ptr, data.len);
            if (rc < 0) return error.WriteFailed;
            return @intCast(rc);
        }

        pub fn read(self: Stream, buffer: []u8) IoError!usize {
            const rc = std.c.read(self.handle, buffer.ptr, buffer.len);
            if (rc < 0) return error.ReadFailed;
            return @intCast(rc);
        }

        pub fn close(self: Stream) void {
            sockets.close(self.handle);
        }
    };

    /// Minimal accept loop wrapper matching the fields the project reads
    /// (`stream`, `listen_address`).
    pub const Server = struct {
        stream: Stream,
        listen_address: Ip4Address,

        pub const Connection = struct {
            stream: Stream,
            address: Ip4Address,
        };

        pub const AcceptError = error{ SocketNotListening, AcceptFailed } || posix.UnexpectedError;

        pub fn accept(self: *Server) AcceptError!Connection {
            var addr: posix.sockaddr.in = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            const fd = sockets.accept(self.stream.handle, @ptrCast(&addr), &addr_len) catch return error.AcceptFailed;
            var ip4: Ip4Address = undefined;
            ip4.in = addr;
            @memcpy(std.mem.asBytes(&ip4.any)[0..@sizeOf(posix.sockaddr.in)], std.mem.asBytes(&addr));
            return .{
                .stream = .{ .handle = fd },
                .address = ip4,
            };
        }
    };
};

test "Condition timedWait returns Timeout when nothing signals" {
    var mutex: Mutex = .{};
    var cond: Condition = .{};

    mutex.lock();
    defer mutex.unlock();

    const start = monotonicMilliTimestamp();
    try std.testing.expectError(error.Timeout, cond.timedWait(&mutex, 10 * std.time.ns_per_ms));
    try std.testing.expect(monotonicMilliTimestamp() - start >= 5);
}

test "Condition signal wakes a waiting thread" {
    const Shared = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,
        observed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn waiter(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.ready) {
                self.cond.wait(&self.mutex);
            }
            self.observed.store(true, .release);
        }
    };

    var shared = Shared{};
    const thread = try std.Thread.spawn(.{}, Shared.waiter, .{&shared});

    shared.mutex.lock();
    shared.ready = true;
    shared.mutex.unlock();
    shared.cond.signal();

    thread.join();
    try std.testing.expect(shared.observed.load(.acquire));
}

test "Condition broadcast wakes every waiting thread" {
    const Shared = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,
        woken: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn waiter(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.ready) {
                self.cond.wait(&self.mutex);
            }
            _ = self.woken.fetchAdd(1, .monotonic);
        }
    };

    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*slot| {
        slot.* = try std.Thread.spawn(.{}, Shared.waiter, .{&shared});
    }

    shared.mutex.lock();
    shared.ready = true;
    shared.mutex.unlock();
    shared.cond.broadcast();

    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u32, 4), shared.woken.load(.acquire));
}

test "Condition timedWait consumes a signal that arrives in time" {
    const Shared = struct {
        mutex: Mutex = .{},
        cond: Condition = .{},
        ready: bool = false,
        succeeded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn waiter(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.ready) {
                self.cond.timedWait(&self.mutex, 2 * std.time.ns_per_s) catch return;
            }
            self.succeeded.store(true, .release);
        }
    };

    var shared = Shared{};
    const thread = try std.Thread.spawn(.{}, Shared.waiter, .{&shared});

    sleep(5 * std.time.ns_per_ms);
    shared.mutex.lock();
    shared.ready = true;
    shared.mutex.unlock();
    shared.cond.signal();

    thread.join();
    try std.testing.expect(shared.succeeded.load(.acquire));
}
