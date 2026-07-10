//! Unified error types for Vigil.

/// Common errors used across high-level Vigil APIs.
pub const VigilError = error{
    /// A process id or name could not be found.
    ProcessNotFound,
    /// A process was started while already running.
    ProcessAlreadyRunning,
    /// A child process failed to start.
    ProcessStartFailed,
    /// A process failed to stop cleanly.
    ProcessStopFailed,

    /// A supervisor id or name could not be found.
    SupervisorNotFound,
    /// A supervisor child id could not be found.
    ChildNotFound,
    /// Restart intensity exceeded supervisor limits.
    TooManyRestarts,
    /// Graceful shutdown exceeded its timeout.
    ShutdownTimeout,
    /// Monitoring was started while already active.
    AlreadyMonitoring,

    /// A mailbox had no available messages.
    EmptyMailbox,
    /// A mailbox or inbox reached capacity.
    MailboxFull,
    /// A message exceeded its TTL.
    MessageExpired,
    /// A message exceeded the configured size limit.
    MessageTooLarge,
    /// A message was malformed for the requested operation.
    InvalidMessage,
    /// Delivery or request/reply waiting exceeded its timeout.
    DeliveryTimeout,
    /// A rate limiter rejected the operation.
    RateLimitExceeded,
    /// A message could not be delivered.
    DeliveryFailed,
    /// Dead-letter storage reached its configured capacity.
    DeadLetterFull,

    /// A registry name is already in use.
    AlreadyRegistered,
    /// A registry name is not present.
    NotRegistered,

    /// A circuit breaker is open and rejected the call.
    CircuitOpen,

    /// Allocation failed.
    OutOfMemory,
    /// Configuration values were invalid.
    InvalidConfiguration,
    /// A generic operation timeout occurred.
    OperationTimeout,
    /// The object is in the wrong state for the requested operation.
    InvalidState,
};
