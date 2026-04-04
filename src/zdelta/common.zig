pub const DeltaSpan = struct {
    offset: u32,
    len: u32,
};

pub const DeltaOp = union(enum) {
    insert: DeltaSpan,
    delete: u32,
    equal: u32,
};
