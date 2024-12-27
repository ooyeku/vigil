# Vigil - (WIP)

A process supervision and management library for Zig, inspired by Erlang/OTP's supervisor model.

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

[Add your chosen license]

