// trace paths
## process.zig
 
 - **start**
	- check is state = AlreadyRunning
	- define local context stuct ?
	- create wraper to execute function (thread safe w/ state change and cleanup)
	- handle error in seperate thread
	- set state to running and update stats

- **stop**
 - check for already stopped state
 - handle potential failed state
 - ensure thread completed its task
 - TODO: consider workaround for lock release while sleeping (process.zig[328-330])
 
   ```zig
   self.mutex.unlock();
   self.time.sleed(10 * std.time.ns_per_ms);  // is this necessary?
   self.mutex.lock();
    
   ```
 - set state to stopped and clear thread

- **isAlive**
 - return state validation

- **getState**
 - return state

 
