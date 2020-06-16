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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");
const util = @import("util.zig");

const Box = @import("Box.zig");
const Log = @import("log.zig").Log;
const Output = @import("Output.zig");
const Root = @import("Root.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XdgToplevel = @import("XdgToplevel.zig");
const XwaylandView = if (build_options.xwayland)
    @import("XwaylandView.zig")
else
    @import("VoidView.zig");

const Impl = union(enum) {
    xdg_toplevel: XdgToplevel,
    xwayland_view: XwaylandView,
};

const SavedBuffer = struct {
    wlr_buffer: *c.wlr_buffer,
    box: Box,
    transform: c.wl_output_transform,
};

/// The implementation of this view
impl: Impl,

/// The output this view is currently associated with
output: *Output,

/// This is non-null exactly when the view is mapped
wlr_surface: ?*c.wlr_surface,

/// If the view is floating or not
floating: bool,

/// True if the view is currently focused by at least one seat
focused: bool,

/// The current output-relative coordinates and dimensions of the view. The
/// surface itself may have other dimensions which are stored in the
/// surface_box member.
current_box: Box,

/// Pending dimensions of the view during a transaction
pending_box: ?Box,

/// The currently commited geometry of the surface. The x/y may be negative if
/// for example the client has decided to draw CSD shadows a la GTK.
surface_box: Box,

/// The geometry the view's surface had when the transaction started and
/// buffers were saved.
saved_surface_box: Box,

/// These are what we render while a transaction is in progress
saved_buffers: std.ArrayList(SavedBuffer),

/// The dimensions the view would have taken if we didn't force it to tile
natural_width: u32,
natural_height: u32,

current_tags: u32,
pending_tags: ?u32,

pending_serial: ?u32,

pub fn init(self: *Self, output: *Output, tags: u32, surface: var) void {
    self.output = output;

    self.wlr_surface = null;

    self.focused = false;

    self.current_box = Box{
        .x = 0,
        .y = 0,
        .height = 0,
        .width = 0,
    };
    self.pending_box = null;

    self.current_tags = tags;
    self.pending_tags = null;

    self.pending_serial = null;

    self.saved_buffers = std.ArrayList(SavedBuffer).init(util.allocator);

    if (@TypeOf(surface) == *c.wlr_xdg_surface) {
        self.impl = .{ .xdg_toplevel = undefined };
        self.impl.xdg_toplevel.init(self, surface);
    } else if (build_options.xwayland and @TypeOf(surface) == *c.wlr_xwayland_surface) {
        self.impl = .{ .xwayland_view = undefined };
        self.impl.xwayland_view.init(self, surface);
    } else unreachable;
}

pub fn deinit(self: Self) void {
    for (self.saved_buffers.items) |buffer| c.wlr_buffer_unref(buffer.wlr_buffer);
    self.saved_buffers.deinit();
}

pub fn needsConfigure(self: Self) bool {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.needsConfigure(),
        .xwayland_view => |xwayland_view| xwayland_view.needsConfigure(),
    };
}

pub fn configure(self: Self) void {
    if (self.pending_box) |pending_box| {
        switch (self.impl) {
            .xdg_toplevel => |xdg_toplevel| xdg_toplevel.configure(pending_box),
            .xwayland_view => |xwayland_view| xwayland_view.configure(pending_box),
        }
    } else {
        Log.Error.log("Configure called on a View with no pending box", .{});
    }
}

pub fn sendFrameDone(self: Self) void {
    var now: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);
    c.wlr_surface_send_frame_done(self.wlr_surface.?, &now);
}

pub fn dropSavedBuffers(self: *Self) void {
    for (self.saved_buffers.items) |buffer| c.wlr_buffer_unref(buffer.wlr_buffer);
    self.saved_buffers.items.len = 0;
}

pub fn saveBuffers(self: *Self) void {
    if (self.saved_buffers.items.len > 0) {
        Log.Error.log("view already has buffers saved, overwriting", .{});
        self.saved_buffers.items.len = 0;
    }

    self.saved_surface_box = self.surface_box;
    self.forEachSurface(saveBuffersIterator, &self.saved_buffers);
}

fn saveBuffersIterator(
    wlr_surface: ?*c.wlr_surface,
    surface_x: c_int,
    surface_y: c_int,
    data: ?*c_void,
) callconv(.C) void {
    const saved_buffers = util.voidCast(std.ArrayList(SavedBuffer), data.?);
    if (wlr_surface) |surface| {
        if (c.wlr_surface_has_buffer(surface)) {
            saved_buffers.append(.{
                .wlr_buffer = surface.buffer,
                .box = Box{
                    .x = surface_x,
                    .y = surface_y,
                    .width = @intCast(u32, surface.current.width),
                    .height = @intCast(u32, surface.current.height),
                },
                .transform = surface.current.transform,
            }) catch return;
            _ = c.wlr_buffer_ref(surface.buffer);
        }
    }
}

/// Set the focued bool and the active state of the view if it is a toplevel
pub fn setFocused(self: *Self, focused: bool) void {
    self.focused = focused;
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.setActivated(focused),
        .xwayland_view => |xwayland_view| xwayland_view.setActivated(focused),
    }
}

/// If true is passsed, make the view float. If false, return it to the tiled
/// layout.
pub fn setFloating(self: *Self, float: bool) void {
    if (float and !self.floating) {
        self.floating = true;
        self.pending_box = Box{
            .x = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.width) -
                @intCast(i32, self.natural_width), 2)),
            .y = std.math.max(0, @divTrunc(@intCast(i32, self.output.usable_box.height) -
                @intCast(i32, self.natural_height), 2)),
            .width = self.natural_width,
            .height = self.natural_height,
        };
    } else if (!float and self.floating) {
        self.floating = false;
    }
}

/// Move a view from one output to another, sending the required enter/leave
/// events.
pub fn sendToOutput(self: *Self, destination_output: *Output) void {
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);

    self.output.views.remove(node);
    destination_output.views.push(node);

    self.output.sendViewTags();
    destination_output.sendViewTags();

    c.wlr_surface_send_leave(self.wlr_surface, self.output.wlr_output);
    c.wlr_surface_send_enter(self.wlr_surface, destination_output.wlr_output);

    self.output = destination_output;
}

pub fn close(self: Self) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.close(),
        .xwayland_view => |xwayland_view| xwayland_view.close(),
    }
}

pub fn forEachSurface(
    self: Self,
    iterator: c.wlr_surface_iterator_func_t,
    user_data: ?*c_void,
) void {
    switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.forEachSurface(iterator, user_data),
        .xwayland_view => |xwayland_view| xwayland_view.forEachSurface(iterator, user_data),
    }
}

/// Return the surface at output coordinates ox, oy and set sx, sy to the
/// corresponding surface-relative coordinates, if there is a surface.
pub fn surfaceAt(self: Self, ox: f64, oy: f64, sx: *f64, sy: *f64) ?*c.wlr_surface {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.surfaceAt(ox, oy, sx, sy),
        .xwayland_view => |xwayland_view| xwayland_view.surfaceAt(ox, oy, sx, sy),
    };
}

/// Return the current title of the view. May be an empty string.
pub fn getTitle(self: Self) [*:0]const u8 {
    return switch (self.impl) {
        .xdg_toplevel => |xdg_toplevel| xdg_toplevel.getTitle(),
        .xwayland_view => |xwayland_view| xwayland_view.getTitle(),
    };
}

/// Called by the impl when the surface is ready to be displayed
pub fn map(self: *Self) void {
    const root = self.output.root;

    Log.Debug.log("View '{}' mapped", .{self.getTitle()});

    // Add the view to the stack of its output
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.push(node);

    // Focus the newly mapped view. Note: if a seat is focusing a different output
    // it will continue to do so.
    var it = root.server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) {
        seat_node.data.focus(self);
    }

    c.wlr_surface_send_enter(self.wlr_surface.?, self.output.wlr_output);

    self.output.sendViewTags();

    root.arrange();
}

/// Called by the impl when the surface will no longer be displayed
pub fn unmap(self: *Self) void {
    const root = self.output.root;

    Log.Debug.log("View '{}' unmapped", .{self.getTitle()});

    self.wlr_surface = null;

    // Inform all seats that the view has been unmapped so they can handle focus
    var it = root.server.input_manager.seats.first;
    while (it) |node| : (it = node.next) {
        const seat = &node.data;
        seat.handleViewUnmap(self);
    }

    // Remove the view from its output's stack
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    self.output.views.remove(node);

    self.output.sendViewTags();

    root.arrange();
}

/// Destory the view and free the ViewStack node holding it.
pub fn destroy(self: *const Self) void {
    self.deinit();
    const node = @fieldParentPtr(ViewStack(Self).Node, "view", self);
    util.allocator.destroy(node);
}
