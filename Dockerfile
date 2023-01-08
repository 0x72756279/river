FROM ubuntu:22.04

RUN apt-get update && apt-get upgrade

RUN apt-get install \
    libseat-dev libevdev-dev libinput-dev libxkbcommon-dev mesa-common-dev \
    meson libpixman-1-dev libegl-dev libgbm-dev libgles-dev hwdata libxcb-util-dev \
    libxcb-image0-dev libxcb-render-util0-dev xwayland libxcb-dri3-dev libxcb-present-dev \
    seatd tar wget git xz-utils cmake libexpat1-dev libxml2-dev liblzma-dev libxcb-xinput-dev -y


WORKDIR /

RUN git clone https://gitlab.freedesktop.org/wayland/wayland.git
WORKDIR wayland
RUN git checkout 1.21.0
RUN meson setup build -Ddocumentation=false -Dtests=false --prefix /usr
RUN ninja -C build install

WORKDIR /

RUN wget -nv https://dri.freedesktop.org/libdrm/libdrm-2.4.114.tar.xz
RUN tar -xvf libdrm-2.4.114.tar.xz 1>/dev/null
WORKDIR libdrm-2.4.114
RUN mkdir build
WORKDIR build
RUN meson --prefix=/usr \
      --buildtype=release   \
      -Dudev=true           \
      -Dvalgrind=disabled
RUN ninja install

WORKDIR /
RUN wget -nv https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.27/downloads/wayland-protocols-1.27.tar.xz
RUN tar -xvf wayland-protocols-1.27.tar.xz
WORKDIR wayland-protocols-1.27
RUN mkdir build
WORKDIR build
RUN meson --prefix=/usr --buildtype=release
RUN ninja install

WORKDIR /

RUN git clone https://gitlab.freedesktop.org/wlroots/wlroots.git
WORKDIR wlroots
RUN git checkout 0.16.0
RUN git clone https://git.sr.ht/~kennylevinsen/seatd subprojects/seatd
RUN meson setup build --auto-features=auto -Drenderers=gles2 -Dexamples=false \
            -Dwerror=false -Db_ndebug=false --prefix /usr
RUN ninja -C build/ install

WORKDIR /

# install zig
RUN wget -nv https://ziglang.org/download/0.9.1/zig-linux-x86_64-0.9.1.tar.xz
# Remove a lot of useless lines from tar output.
RUN tar -xvf zig-linux-x86_64-0.9.1.tar.xz 1>/dev/null
RUN mv zig-linux-x86_64-0.9.1/zig /usr/bin/
RUN mv zig-linux-x86_64-0.9.1/lib /usr/lib/zig
