const Lock = @import("../sync/lock.zig").Lock;
const OsAutoResetEvent = @import("../sync/auto_reset_event/os.zig").OsAutoResetEvent;
const ZapLock = Lock(OsAutoResetEvent);

pub const Mutex = struct {
    pub const NAME = "zap.Lock";

    inner: ZapLock,

    pub fn init(self: *Mutex) void {
        self.inner = ZapLock.init();
    }

    pub fn deinit(self: *Mutex) void {
        self.inner.deinit();
    }

    pub fn acquire(self: *Mutex) void {
        self.inner.acquire();
    }

    pub fn release(self: *Mutex) void {
        self.inner.release();
    }
};