const std = @import("std");
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Allocator = std.mem.Allocator;

pub const ProcessError = error{
    AlreadyRunning,
    StartFailed,
    ShutdownTimeout,
};

pub const ProcessState = enum {
    initial,
    running,
    stopping,
    stopped,
    failed,
};

pub const ChildSpec = struct {
    id: []const u8,
    start_fn: *const fn () void,
    restart_type: enum {
        permanent,
        transient,
        temporary,
    },
    shutdown_timeout_ms: u32,
};

pub const ChildProcess = struct {
    spec: ChildSpec,
    thread: ?Thread,
    mutex: Mutex,
    state: ProcessState,
    last_error: ?anyerror,

    pub fn init(spec: ChildSpec) ChildProcess {
        return .{
            .spec = spec,
            .thread = null,
            .mutex = Mutex{},
            .state = .initial,
            .last_error = null,
        };
    }

    pub fn start(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .running) return ProcessError.AlreadyRunning;

        const Context = struct {
            func: *const fn () void,
            process: *ChildProcess,
        };

        const wrapper = struct {
            fn wrap(ctx: Context) void {
                ctx.process.mutex.lock();
                ctx.process.state = .running;
                ctx.process.mutex.unlock();

                (ctx.func)() catch |err| {
                    ctx.process.mutex.lock();
                    ctx.process.state = .failed;
                    ctx.process.last_error = err;
                    ctx.process.mutex.unlock();
                };
            }
        };

        self.thread = Thread.spawn(.{}, wrapper.wrap, .{
            .func = self.spec.start_fn,
            .process = self,
        }) catch {
            self.state = .failed;
            return ProcessError.StartFailed;
        };

        self.state = .running;
    }

    pub fn stop(self: *ChildProcess) ProcessError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .running) return;

        self.state = .stopping;

        if (self.thread) |thread| {
            // Start timeout timer
            const start_time = std.time.milliTimestamp();

            while (self.state == .stopping) {
                const elapsed = std.time.milliTimestamp() - start_time;
                if (elapsed > self.spec.shutdown_timeout_ms) {
                    self.state = .failed;
                    return ProcessError.ShutdownTimeout;
                }
                std.time.sleep(10 * std.time.ns_per_ms);
            }

            self.thread = null;
            thread.detach();
            self.state = .stopped;
        }
    }

    pub fn isAlive(self: *ChildProcess) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .running;
    }

    pub fn getState(self: *ChildProcess) ProcessState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state;
    }
};
