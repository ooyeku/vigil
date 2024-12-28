# Vigil - Process Supervision Library

A process supervision and management library for Zig, inspired by Erlang/OTP's supervisor model.

## Installation

Add Vigil to your `build.zig.zon`:

```zig
const vigil = .{
    .url = "https://github.com/ooyeku/vigil.git",
    .branch = "main",
    .hash = "e8ee9ac2b55ee2e3358269f8606d75a9ed703b88",
};
```

## Features

- Process lifecycle management with configurable restart strategies
- Flexiple child specification system
- Comprehensive error handling and recovery mechanisms
- Built-in support for distributed supervision and clustering
- Thread-safe operations with minimal overhead

## API Documentation

### Supervisor

The main supervision component that manages child processes.

#### Types

- `SupervisorOptions`: Configuration for supervisor behavior
- `RestartStrategy`: Defines how processes are restarted (.one_for_one, .one_for_all, .rest_for_one)

### Process

Represents a supervised process/thread.

#### Types

- `ChildSpec`: Specification for child processes
- `ProcessState`: Current state of a process (.initial, .running, .stopping, .stopped, .failed)

### Messages

Inter-process communication system.

#### Types

- `ProcessMailbox`: Thread-safe message queue
- `Message`: Communication unit between processes
- `Signal`: Pre-defined process signals

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

