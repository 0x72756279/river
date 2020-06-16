// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");

const c = @import("c.zig");
const command = @import("command.zig");
const util = @import("util.zig");

const Log = @import("log.zig").Log;
const Seat = @import("Seat.zig");
const Server = @import("Server.zig");

const protocol_version = 1;

const implementation = c.struct_zriver_control_v1_interface{
    .destroy = destroy,
    .add_argument = addArgument,
    .run_command = runCommand,
};

wl_global: *c.wl_global,

args_map: std.AutoHashMap(u32, std.ArrayList([]const u8)),

listen_display_destroy: c.wl_listener,

pub fn init(self: *Self, server: *Server) !void {
    self.wl_global = c.wl_global_create(
        server.wl_display,
        &c.zriver_control_v1_interface,
        protocol_version,
        self,
        bind,
    ) orelse return error.CantCreateWlGlobal;

    self.args_map = std.AutoHashMap(u32, std.ArrayList([]const u8)).init(util.allocator);

    self.listen_display_destroy.notify = handleDisplayDestroy;
    c.wl_display_add_destroy_listener(server.wl_display, &self.listen_display_destroy);
}

fn handleDisplayDestroy(wl_listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_display_destroy", wl_listener.?);
    c.wl_global_destroy(self.wl_global);
    self.args_map.deinit();
}

/// Called when a client binds our global
fn bind(wl_client: ?*c.wl_client, data: ?*c_void, version: u32, id: u32) callconv(.C) void {
    const self = util.voidCast(Self, data.?);
    const wl_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_control_v1_interface,
        @intCast(c_int, version),
        id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        return;
    };
    self.args_map.putNoClobber(id, std.ArrayList([]const u8).init(util.allocator)) catch {
        c.wl_resource_destroy(wl_resource);
        c.wl_client_post_no_memory(wl_client);
        return;
    };
    c.wl_resource_set_implementation(wl_resource, &implementation, self, handleResourceDestroy);
}

/// Remove the resource from the hash map and free all stored args
fn handleResourceDestroy(wl_resource: ?*c.wl_resource) callconv(.C) void {
    const self = util.voidCast(Self, c.wl_resource_get_user_data(wl_resource).?);
    const id = c.wl_resource_get_id(wl_resource);
    const list = self.args_map.remove(id).?.value;
    for (list.items) |arg| list.allocator.free(arg);
    list.deinit();
}

fn destroy(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource) callconv(.C) void {
    c.wl_resource_destroy(wl_resource);
}

fn addArgument(wl_client: ?*c.wl_client, wl_resource: ?*c.wl_resource, arg: ?[*:0]const u8) callconv(.C) void {
    const self = util.voidCast(Self, c.wl_resource_get_user_data(wl_resource).?);
    const id = c.wl_resource_get_id(wl_resource);

    const owned_slice = std.mem.dupe(util.allocator, u8, std.mem.span(arg.?)) catch {
        c.wl_client_post_no_memory(wl_client);
        return;
    };

    self.args_map.get(id).?.value.append(owned_slice) catch {
        c.wl_client_post_no_memory(wl_client);
        util.allocator.free(owned_slice);
        return;
    };
}

fn runCommand(
    wl_client: ?*c.wl_client,
    wl_resource: ?*c.wl_resource,
    seat_wl_resource: ?*c.wl_resource,
    callback_id: u32,
) callconv(.C) void {
    const self = util.voidCast(Self, c.wl_resource_get_user_data(wl_resource).?);
    // This can be null if the seat is inert, in which case we ignore the request
    const wlr_seat_client = c.wlr_seat_client_from_resource(seat_wl_resource) orelse return;
    const seat = util.voidCast(Seat, wlr_seat_client.*.seat.*.data.?);

    const callback_resource = c.wl_resource_create(
        wl_client,
        &c.zriver_command_callback_v1_interface,
        protocol_version,
        callback_id,
    ) orelse {
        c.wl_client_post_no_memory(wl_client);
        return;
    };
    c.wl_resource_set_implementation(callback_resource, null, null, null);

    const args = self.args_map.get(c.wl_resource_get_id(wl_resource)).?.value.items;

    var failure_message: []const u8 = undefined;
    command.run(util.allocator, seat, args, &failure_message) catch |err| {
        if (err == command.Error.CommandFailed) {
            defer util.allocator.free(failure_message);
            const out = std.cstr.addNullByte(util.allocator, failure_message) catch {
                c.zriver_command_callback_v1_send_failure(callback_resource, "out of memory");
                return;
            };
            defer util.allocator.free(out);
            c.zriver_command_callback_v1_send_failure(callback_resource, out);
        } else {
            c.zriver_command_callback_v1_send_failure(
                callback_resource,
                switch (err) {
                    command.Error.NoCommand => "no command given",
                    command.Error.UnknownCommand => "unknown command",
                    command.Error.UnknownOption => "unknown option",
                    command.Error.NotEnoughArguments => "not enough arguments",
                    command.Error.TooManyArguments => "too many arguments",
                    command.Error.Overflow => "value out of bounds",
                    command.Error.InvalidCharacter => "invalid character in argument",
                    command.Error.InvalidDirection => "invalid direction. Must be 'next' or 'previous'",
                    command.Error.InvalidRgba => "invalid color format, must be #RRGGBB or #RRGGBBAA",
                    command.Error.OutOfMemory => "out of memory",
                    command.Error.CommandFailed => unreachable,
                },
            );
        }
        return;
    };
    c.zriver_command_callback_v1_send_success(callback_resource, "");
}
