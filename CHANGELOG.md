# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-02-18

### Fixed
- **PubSub silent message drops**: `PubSubBroker.publish()` no longer silently swallows delivery failures. It now returns a `PublishResult` struct reporting `delivered` and `failed` counts, and emits `message_dropped` telemetry events for each failed delivery.
- **ProcessGroup broadcast silent drops**: `ProcessGroup.broadcast()` no longer silently swallows delivery failures. It now returns a `BroadcastResult` struct reporting `delivered` and `failed` counts, and emits `message_dropped` telemetry events for each failed delivery.
- **Request/Reply message loss**: `ReplyMailbox.waitForReply()` no longer discards messages with non-matching correlation IDs. Non-matching messages are now stashed in an internal buffer and re-queued to the inbox when the wait completes (on match, timeout, or error).
- **Wrong error for rate limiting**: `FlowControlledInbox.send()` now returns `MessageError.RateLimitExceeded` instead of the semantically incorrect `MessageError.MessageTooLarge` when a send is rejected by the rate limiter.
- **Inbox.close() race condition (TOCTOU)**: Replaced the unsafe 10ms sleep-and-hope strategy with an atomic reference count (`active_ops`). Every in-flight `send`, `recv`, and `recvTimeout` operation increments the count while accessing the mailbox. `close()` now spins until all in-flight operations have completed before deallocating, eliminating the use-after-free window.

### Added
- **`PublishResult` struct** (`pubsub.zig`): Reports `delivered` and `failed` counts from `PubSubBroker.publish()`.
- **`BroadcastResult` struct** (`process_group.zig`): Reports `delivered` and `failed` counts from `ProcessGroup.broadcast()`.
- **`MessageError.RateLimitExceeded`**: New error variant for rate limiter rejections.
- **`MessageError.DeliveryFailed`**: New error variant for subscriber delivery failures.
- **`deinitGlobal()` functions**: Added to `pubsub`, `shutdown`, and `telemetry` modules for safe teardown of global singleton state. Each function deinitializes resources under the module-level mutex and sets the global to `null`.
- **Safety documentation for `getGlobal()` functions**: All global accessor functions in `pubsub`, `shutdown`, and `telemetry` now document the pointer-lifetime contract — callers must ensure `deinitGlobal()` is only called during shutdown after all operations have completed.
- **`RateLimitExceeded` and `DeliveryFailed`** added to `VigilError` in `errors.zig`.

### Changed
- **`PubSubBroker.publish()` return type**: Changed from `!void` to `!PublishResult`.
- **Module-level `pubsub.publish()` return type**: Changed from `!void` to `!?PublishResult` (returns `null` when no global broker is initialized).
- **`ProcessGroup.broadcast()` return type**: Changed from `!void` to `!BroadcastResult`.
- **`ProcessGroup.count()` deprecated**: Aliased to `memberCount()` to remove the duplicate method.
- **Version bumped** from 1.0.1 to 1.1.0 in `build.zig.zon` and `vigil.getVersion()`.

## [1.0.1] - 2025-12-07

### Fixed
- **Memory Leak in Inbox.send()**: Fixed memory leak in `src/api/inbox.zig` where `Inbox.send()` was using `std.fmt.allocPrint()` to create dynamic message IDs that were never freed. Changed to use static string `"inbox_msg"` since `Message.init()` duplicates all strings internally.

## [1.0.0] 

### Added
- Initial release of Vigil, a high-performance actor system for Zig
- Core actor system with supervision trees
- Process mailboxes with priority queues and dead letter queues
- High-level inbox API for channel-like message passing
- Timer utilities for scheduling
- Registry for process discovery
- Flow control mechanisms with rate limiting and backpressure
- Comprehensive test suite and examples

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- N/A (initial release)
