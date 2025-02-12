const std = @import("std");

/// Errors that might occur during worker operation
pub const WorkerError = error{
    /// Task execution failed
    TaskFailed,
    /// Required resource is not available
    ResourceUnavailable,
    /// Health check failed
    HealthCheckFailed,
    /// Worker exceeded memory limit
    MemoryLimitExceeded,
};

/// Shared state for worker processes with thread-safe operations
pub const WorkerState = struct {
    /// Whether workers should continue running
    should_run: bool = true,
    /// Current memory usage in bytes
    memory_usage: usize = 0,
    /// Peak memory usage observed in bytes
    peak_memory_bytes: usize = 0,
    /// Current health status
    is_healthy: bool = true,
    /// Total number of processes created
    total_process_count: usize = 0,
    /// Currently active processes
    active_processes: usize = 0,
    /// Total number of process restarts
    total_restarts: usize = 0,
    /// Mutex for thread-safe operations
    mutex: std.Thread.Mutex = .{},

    /// Initialize a new worker state
    pub fn init() WorkerState {
        return .{};
    }

    /// Check if workers should continue running
    /// Returns: bool indicating if work should continue
    pub fn shouldRun(self: *WorkerState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.should_run and self.total_process_count < 1000;
    }

    /// Signal workers to stop
    pub fn signalStop(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.should_run = false;
    }

    /// Increment the total process count
    pub fn incrementProcessCount(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.total_process_count += 1;
    }

    /// Allocate memory for worker operation
    /// bytes: Amount of memory to allocate in bytes
    pub fn allocateMemory(self: *WorkerState, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.memory_usage += bytes;
        self.peak_memory_bytes = @max(self.peak_memory_bytes, self.memory_usage);
    }

    /// Free previously allocated memory
    /// bytes: Amount of memory to free in bytes
    pub fn freeMemory(self: *WorkerState, bytes: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (bytes <= self.memory_usage) {
            self.memory_usage -= bytes;
        } else {
            self.memory_usage = 0;
        }
    }

    /// Get current health status
    /// Returns: bool indicating if worker is healthy
    pub fn isHealthy(self: *WorkerState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_healthy;
    }

    /// Update worker health status
    /// healthy: New health status to set
    pub fn setHealth(self: *WorkerState, healthy: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_healthy = healthy;
    }

    /// Increment count of active processes
    pub fn incrementActiveProcesses(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_processes += 1;
    }

    /// Decrement count of active processes
    pub fn decrementActiveProcesses(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.active_processes > 0) {
            self.active_processes -= 1;
        }
    }

    /// Increment total restart count
    pub fn incrementRestarts(self: *WorkerState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.total_restarts += 1;
    }

    /// Get current worker metrics
    pub const Metrics = struct {
        memory_usage: usize,
        peak_memory: usize,
        active_processes: usize,
        total_processes: usize,
        total_restarts: usize,
        is_healthy: bool,
    };

    /// Get current worker metrics
    /// Returns: Metrics struct with current state
    pub fn getMetrics(self: *WorkerState) Metrics {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .memory_usage = self.memory_usage,
            .peak_memory = self.peak_memory_bytes,
            .active_processes = self.active_processes,
            .total_processes = self.total_process_count,
            .total_restarts = self.total_restarts,
            .is_healthy = self.is_healthy,
        };
    }
};

/// Health check function type
pub const HealthCheckFn = *const fn () bool;

/// Default health check implementations
pub const HealthChecks = struct {
    /// Check system health
    pub fn checkSystemHealth(state: *WorkerState) bool {
        return state.isHealthy();
    }

    /// Check business logic health
    pub fn checkBusinessHealth(state: *WorkerState) bool {
        return state.isHealthy();
    }

    /// Check background worker health
    pub fn checkBackgroundHealth(state: *WorkerState) bool {
        return state.isHealthy();
    }
};
