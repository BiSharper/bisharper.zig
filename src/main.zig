const std = @import("std");
const bisharper = @import("bisharper.zig");

pub fn main() !void {
    //
    // // stdout is for the actual output of your application, for example if you
    // // are implementing gzip, then only the compressed bytes should be sent to
    // // stdout, not any debugging messages.
    // const stdout_file = std.io.getStdOut().writer();
    // var bw = std.io.bufferedWriter(stdout_file);
    // const stdout = bw.writer();
    //
    // try stdout.print("All your {s} are belong to us.\n", .{bisharper.hi});
    //
    // try bw.flush(); // don't forget to flush!
}
