//! Unified error types for Vigil

/// Common Vigil errors
pub const VigilError = error{
    // Process errors
    ProcessNotFound,
    ProcessAlreadyRunning,
    ProcessStartFailed,
    ProcessStopFailed,

    // Supervisor errors
    SupervisorNotFound,
    ChildNotFound,
    TooManyRestarts,
    ShutdownTimeout,
    AlreadyMonitoring,

    // Message errors
    EmptyMailbox,
    MailboxFull,
    MessageExpired,
    MessageTooLarge,
    InvalidMessage,
    DeliveryTimeout,
    RateLimitExceeded,
    DeliveryFailed,

    // Registry errors
    AlreadyRegistered,
    NotRegistered,

    // Circuit breaker errors
    CircuitOpen,

    // General errors
    OutOfMemory,
    InvalidConfiguration,
    OperationTimeout,
    InvalidState,
};

