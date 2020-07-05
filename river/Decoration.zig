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
const util = @import("util.zig");

wlr_xdg_toplevel_decoration: *c.wlr_xdg_toplevel_decoration_v1,

listen_destroy: c.wl_listener,
listen_request_mode: c.wl_listener,

pub fn init(
    self: *Self,
    wlr_xdg_toplevel_decoration: *c.wlr_xdg_toplevel_decoration_v1,
) void {
    self.wlr_xdg_toplevel_decoration = wlr_xdg_toplevel_decoration;

    self.listen_destroy.notify = handleDestroy;
    c.wl_signal_add(&self.wlr_xdg_toplevel_decoration.events.destroy, &self.listen_destroy);

    self.listen_request_mode.notify = handleRequestMode;
    c.wl_signal_add(&self.wlr_xdg_toplevel_decoration.events.request_mode, &self.listen_request_mode);

    handleRequestMode(&self.listen_request_mode, self.wlr_xdg_toplevel_decoration);
}

fn handleDestroy(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_destroy", listener.?);
    util.gpa.destroy(self);
}

fn handleRequestMode(listener: ?*c.wl_listener, data: ?*c_void) callconv(.C) void {
    const self = @fieldParentPtr(Self, "listen_request_mode", listener.?);
    _ = c.wlr_xdg_toplevel_decoration_v1_set_mode(
        self.wlr_xdg_toplevel_decoration,
        .WLR_XDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE,
    );
}
