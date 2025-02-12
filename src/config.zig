const std = @import("std");

/// Configuration for the Vigil process supervision system
pub const Config = struct {
    /// Demo configuration
    pub const Demo = struct {
        /// Number of iterations to run the demo
        iterations: usize = 100,
        /// Sleep duration between iterations in milliseconds
        sleep_duration_ms: u32 = 1,
        /// Demo duration in seconds
        duration_secs: u32 = 10,
        /// Status update interval in milliseconds
        status_update_ms: u32 = 50,
    };

    /// Worker configuration
    pub const Workers = struct {
        /// Number of background workers
        background_count: usize = 40,
        /// Number of business logic workers
        business_count: usize = 200,
        /// Worker sleep duration in milliseconds
        sleep_ms: u32 = 10,
        /// Minimum number of workers allowed
        min_count: usize = 20,
        /// Maximum number of workers allowed
        max_count: usize = 100,
    };

    /// Message passing configuration
    pub const Messaging = struct {
        /// Maximum mailbox capacity
        max_mailbox_capacity: usize = 1000,
        /// Message time-to-live in milliseconds
        message_ttl_ms: u32 = 5000,
        /// Broadcast interval in milliseconds
        broadcast_interval_ms: u32 = 50,
    };

    /// Health check configuration
    pub const Health = struct {
        /// Memory warning threshold in megabytes
        memory_warning_mb: usize = 10,
        /// Memory critical threshold in megabytes
        memory_critical_mb: usize = 100,
        /// Health check interval in milliseconds
        check_interval_ms: u32 = 10,
    };

    /// Dynamic scaling configuration
    pub const Scaling = struct {
        /// Interval between scale checks in milliseconds
        check_interval_ms: u32 = 50,
        /// High load threshold (0.0-1.0)
        load_threshold_high: f32 = 0.8,
        /// Low load threshold (0.0-1.0)
        load_threshold_low: f32 = 0.2,
    };

    demo: Demo = .{},
    workers: Workers = .{},
    messaging: Messaging = .{},
    health: Health = .{},
    scaling: Scaling = .{},

    /// Create a new configuration with default values
    pub fn init() Config {
        return .{};
    }

    /// Create a configuration optimized for development
    pub fn development() Config {
        return .{
            .demo = .{
                .iterations = 50,
                .sleep_duration_ms = 10,
            },
            .workers = .{
                .background_count = 10,
                .business_count = 50,
            },
            .health = .{
                .check_interval_ms = 100,
            },
        };
    }

    /// Create a configuration optimized for production
    pub fn production() Config {
        return .{
            .workers = .{
                .background_count = 100,
                .business_count = 500,
                .min_count = 50,
                .max_count = 200,
            },
            .messaging = .{
                .max_mailbox_capacity = 10000,
                .message_ttl_ms = 30000,
            },
            .health = .{
                .memory_warning_mb = 100,
                .memory_critical_mb = 1000,
                .check_interval_ms = 1000,
            },
        };
    }
};
