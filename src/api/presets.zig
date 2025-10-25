//! High-level configuration presets for Vigil 0.3.0+
//! Pre-configured settings for different deployment scenarios.

pub const Preset = enum {
    development,
    production,
    high_availability,
    testing,
};

pub const PresetConfig = struct {
    max_restarts: u32,
    max_seconds: u32,
    health_check_interval_ms: u32,
    shutdown_timeout_ms: u32,
    mailbox_capacity: usize,
    enable_monitoring: bool,
    enable_verbose_logging: bool,

    pub fn get(preset: Preset) PresetConfig {
        return switch (preset) {
            .development => .{
                .max_restarts = 10,
                .max_seconds = 5,
                .health_check_interval_ms = 1000,
                .shutdown_timeout_ms = 5000,
                .mailbox_capacity = 100,
                .enable_monitoring = true,
                .enable_verbose_logging = true,
            },
            .production => .{
                .max_restarts = 3,
                .max_seconds = 60,
                .health_check_interval_ms = 5000,
                .shutdown_timeout_ms = 30000,
                .mailbox_capacity = 1000,
                .enable_monitoring = true,
                .enable_verbose_logging = false,
            },
            .high_availability => .{
                .max_restarts = 5,
                .max_seconds = 30,
                .health_check_interval_ms = 2000,
                .shutdown_timeout_ms = 20000,
                .mailbox_capacity = 5000,
                .enable_monitoring = true,
                .enable_verbose_logging = false,
            },
            .testing => .{
                .max_restarts = 1,
                .max_seconds = 10,
                .health_check_interval_ms = 100,
                .shutdown_timeout_ms = 1000,
                .mailbox_capacity = 50,
                .enable_monitoring = false,
                .enable_verbose_logging = true,
            },
        };
    }
};

test "Presets development configuration" {
    const config = PresetConfig.get(.development);

    try @import("std").testing.expect(config.max_restarts == 10);
    try @import("std").testing.expect(config.max_seconds == 5);
    try @import("std").testing.expect(config.health_check_interval_ms == 1000);
    try @import("std").testing.expect(config.enable_monitoring == true);
    try @import("std").testing.expect(config.enable_verbose_logging == true);
}

test "Presets production configuration" {
    const config = PresetConfig.get(.production);

    try @import("std").testing.expect(config.max_restarts == 3);
    try @import("std").testing.expect(config.max_seconds == 60);
    try @import("std").testing.expect(config.health_check_interval_ms == 5000);
    try @import("std").testing.expect(config.enable_monitoring == true);
    try @import("std").testing.expect(config.enable_verbose_logging == false);
}

test "Presets high availability configuration" {
    const config = PresetConfig.get(.high_availability);

    try @import("std").testing.expect(config.max_restarts == 5);
    try @import("std").testing.expect(config.max_seconds == 30);
    try @import("std").testing.expect(config.health_check_interval_ms == 2000);
}

test "Presets testing configuration" {
    const config = PresetConfig.get(.testing);

    try @import("std").testing.expect(config.max_restarts == 1);
    try @import("std").testing.expect(config.max_seconds == 10);
    try @import("std").testing.expect(config.health_check_interval_ms == 100);
    try @import("std").testing.expect(config.enable_monitoring == false);
    try @import("std").testing.expect(config.enable_verbose_logging == true);
}
