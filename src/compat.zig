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

test "Mutex basic lock/unlock" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();

    try std.testing.expect(m.tryLock());
    m.unlock();
}

/// Replacement for the removed `std.Thread.sleep`. Blocks the current thread
/// for `nanoseconds` nanoseconds using libc `nanosleep` or platform
/// equivalents.
pub fn sleep(nanoseconds: u64) void {
    const ns_per_s = std.time.ns_per_s;
    var req: std.posix.timespec = .{
        .sec = @intCast(nanoseconds / ns_per_s),
        .nsec = @intCast(nanoseconds % ns_per_s),
    };
    var rem: std.posix.timespec = undefined;
    while (std.c.nanosleep(&req, &rem) != 0) {
        req = rem;
    }
}

/// Replacement for the removed `std.time.nanoTimestamp`. Returns nanoseconds
/// since the Unix epoch using `CLOCK_REALTIME`.
pub fn nanoTimestamp() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
}

/// Replacement for the removed `std.time.milliTimestamp`.
pub fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
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
