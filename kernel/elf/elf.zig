//! ELF loader facade.

pub const loader = @import("loader.zig");
pub const parse = @import("parse.zig");

pub fn selfTestStaticLoaderMarker() bool {
    return loader.selfTestStaticLoaderMarker();
}
