const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

const web3 = @import("web3.zig");

/// Implements encoding data to the RLP standard as per the specification
/// Reference: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
/// Note: RLP only defines the container format and now how values are encoded within it.
/// To encode higher-order data structures as an Ethereum node expects, use RlpEncoder instead.
pub const RlpBaseEncoder = struct {
    pub fn writeString(value: []const u8, writer: anytype) !void {
        if (value.len == 1 and value[0] < 0x80) {
            try writer.writeByte(value[0]);
        } else {
            try encodeLength(value.len, 0x80, writer);
            _ = try writer.write(value);
        }
    }

    pub fn writeList(value: []const u8, writer: anytype) !void {
        try encodeLength(value.len, 0xc0, writer);
        _ = try writer.write(value);
    }

    fn encodeLength(length: usize, offset: u8, writer: anytype) !void {
        if (length < 56) {
            try writer.writeByte(@as(u8, @intCast(length)) + offset);
        } else {
            const swapped = if (native_endian == .Little) @byteSwap(length) else length;

            // const binary_length = try std.math.divCeil(u8, @as(u8, @intCast(std.math.log2(swapped))), 8);

            const ptr: [*]const u8 = @ptrCast(&swapped);
            const slice: []const u8 = ptr[0..@sizeOf(@TypeOf(length))];
            while (slice[0] == 0) {
                slice = slice[1..];
            }

            try writer.writeByte(@as(u8, @intCast(slice.len + offset + 55)));

            _ = try writer.write(slice);
        }
    }
};

/// Higher level RLP encoding which supports encoding arbitrary structures in RLP in the
/// format expected by an Ethereum node. i.e. Writes structs as lists in order of field
/// declaration and encodes ints in big endian format.
pub const RlpEncoder = struct {
    pub fn writeAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
        const buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
        errdefer buffer.deinit();

        try write(value, buffer.writer());

        return buffer.toOwnedSlice();
    }

    pub fn write(value: anytype, writer: anytype) !void {
        const T = @TypeOf(value);
        const TI = @typeInfo(T);

        switch (TI) {
            .Int, .ComptimeInt => {
                if (value == 0) {
                    return RlpBaseEncoder.writeString(&.{}, writer);
                }
                const buffer: [32]u8 = undefined;
                std.mem.writeIntBig(u256, &buffer, value);
                const slice: []u8 = &buffer;
                while (slice[0] == 0) {
                    slice = slice[1..];
                }
                return RlpBaseEncoder.writeString(slice, writer);
            },
            .Struct => |struct_t| {
                const gpa = std.heap.GeneralPurposeAllocator(.{}){};
                const allocator = gpa.allocator();

                const temp_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
                errdefer temp_buffer.deinit();

                const temp_writer = temp_buffer.writer();

                inline for (struct_t.fields) |field| {
                    try write(@field(value, field.name), temp_writer);
                }

                const slice = try temp_buffer.toOwnedSlice();
                defer allocator.free(slice);

                return RlpBaseEncoder.writeList(slice, writer);
            },
            .Pointer => |ptr_t| {
                switch (ptr_t.size) {
                    .One => {
                        const CTI = @typeInfo(ptr_t.child);
                        if (CTI == .Array) {
                            const slice: []const CTI.Array.child = &(value.*);
                            return write(slice, writer);
                        } else {
                            return write(value.*, writer);
                        }
                    },
                    .Many => {
                        const slice = std.mem.span(value);
                        return write(slice, writer);
                    },
                    .Slice => {
                        if (ptr_t.child == u8) {
                            return RlpBaseEncoder.writeString(value, writer);
                        } else {
                            const gpa = std.heap.GeneralPurposeAllocator(.{}){};
                            const allocator = gpa.allocator();

                            const temp_buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
                            errdefer temp_buffer.deinit();

                            const temp_writer = temp_buffer.writer();

                            for (value) |child| {
                                try write(child, temp_writer);
                            }

                            const slice = try temp_buffer.toOwnedSlice();
                            defer allocator.free(slice);

                            return RlpBaseEncoder.writeList(slice, writer);
                        }
                    },
                    .C => @compileError("Cannot RLP encode C pointer"),
                }
            },
            .Array => |array_t| {
                const slice: []const array_t.child = &value;
                return write(slice, writer);
            },
            .Optional => |opt_t| {
                _ = opt_t;
                if (value != null) {
                    return write(value.?, writer);
                }
            },
            else => @compileError("Cannot RLP encode " ++ @typeName(T)),
        }
    }
};

test "rlp encoding" {
    const allocator = std.testing.allocator;
    const assert = std.debug.assert;
    const hex: [1024]u8 = undefined;

    const buffer = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer buffer.deinit();

    {
        buffer.items.len = 0;
        const writer = buffer.writer();

        try RlpEncoder.write(.{ 1024, 1024 }, writer);

        const bytes = try std.fmt.hexToBytes(&hex, "c6820400820400");
        assert(std.mem.eql(u8, bytes, buffer.items));
    }

    {
        buffer.items.len = 0;
        const writer = buffer.writer();

        try RlpEncoder.write(.{ "dog", "cat" }, writer);

        const bytes = try std.fmt.hexToBytes(&hex, "c883646f6783636174");
        assert(std.mem.eql(u8, bytes, buffer.items));
    }

    {
        buffer.items.len = 0;
        const writer = buffer.writer();

        try RlpEncoder.write(0, writer);

        const bytes = try std.fmt.hexToBytes(&hex, "80");
        assert(std.mem.eql(u8, bytes, buffer.items));
    }

    {
        buffer.items.len = 0;
        const writer = buffer.writer();

        try RlpEncoder.write(.{}, writer);

        const bytes = try std.fmt.hexToBytes(&hex, "c0");
        assert(std.mem.eql(u8, bytes, buffer.items));
    }

    {
        buffer.items.len = 0;
        const writer = buffer.writer();

        try RlpEncoder.write(.{"123456789012345678901234567890123456789012345678901234567890"}, writer);

        const bytes = try std.fmt.hexToBytes(&hex, "f83eb83c313233343536373839303132333435363738393031323334353637383930313233343536373839303132333435363738393031323334353637383930");
        assert(std.mem.eql(u8, bytes, buffer.items));
    }
}
