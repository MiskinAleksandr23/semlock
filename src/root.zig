pub const ConflictGraphLockV1 = @import("semantic_lock_v1.zig").ConflictGraphLock;
pub const ConflictGraphLockV2 = @import("semantic_lock_v2.zig").ConflictGraphLock;

pub threadlocal var slot_id: usize = 0;
