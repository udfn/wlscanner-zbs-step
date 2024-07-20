const std = @import("std");

pub const WlScannerStep = struct {
    const Protocol = struct {
        xml: []const u8,
        system: bool,
        file: std.Build.GeneratedFile,
    };
    const WlScannerStepOptions = struct {
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
        server_headers: bool = false,
        client_header_suffix: []const u8 = "-client-protocol.h",
    };
    const QueueType = std.SinglyLinkedList(Protocol);
    step: std.Build.Step,
    queue: QueueType,
    lib: *std.Build.Step.Compile,
    dest_path: std.Build.GeneratedFile,
    gen_server_headers: bool,
    client_header_suffix: []const u8,
    system_protocol_dir: ?[]const u8 = null,
    const Self = @This();
    pub fn create(b: *std.Build, options: WlScannerStepOptions) !*Self {
        const res = try b.allocator.create(Self);
        res.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "wayland-scanner",
                .owner = b,
                .makeFn = make,
            }),
            .queue = .{},
            .lib = b.addStaticLibrary(.{
                .name = "wayland-protocol-lib",
                .target = options.target,
                .optimize = options.optimize,
            }),
            .dest_path = .{ .step = &res.step },
            .gen_server_headers = options.server_headers,
            .client_header_suffix = options.client_header_suffix,
        };
        // Smarten this up, perhaps..
        res.lib.linkSystemLibrary("wayland-client");
        return res;
    }
    pub fn linkWith(self: *Self, lib: *std.Build.Step.Compile) void {
        lib.linkLibrary(self.lib);
        lib.addIncludePath(.{ .generated = .{ .file = &self.dest_path } });
    }
    pub fn addProtocol(self: *Self, xml: []const u8, system: bool) void {
        const real_xml = blk: {
            if (system) {
                if (self.system_protocol_dir == null) {
                    self.system_protocol_dir = std.mem.trim(u8, self.step.owner.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), &std.ascii.whitespace);
                }
                break :blk self.step.owner.pathJoin(&.{ self.system_protocol_dir.?, xml });
            } else {
                break :blk xml;
            }
        };
        const node = self.step.owner.allocator.create(QueueType.Node) catch @panic("OOM");
        node.data = .{
            .xml = real_xml,
            .file = .{ .step = &self.step },
            .system = system,
        };
        self.lib.addCSourceFile(.{ .file = .{ .generated = .{ .file = &node.data.file } }, .flags = &.{} });
        self.queue.prepend(node);
    }
    pub fn addProtocolFromPath(self: *Self, base: []const u8, xml: []const u8) void {
        self.addProtocol(self.step.owner.pathJoin(&.{ base, xml }), false);
    }
    pub fn addSystemProtocols(self: *Self, xmls: []const []const u8) void {
        for (xmls) |x| {
            self.addProtocol(x, true);
        }
    }
    pub fn addProtocolsFromPath(self: *Self, base: []const u8, xmls: []const []const u8) void {
        for (xmls) |x| {
            self.addProtocolFromPath(base, x);
        }
    }

    const WlScanGenType = enum {
        code,
        clientheader,
        serverheader,
        pub fn toString(self: WlScanGenType) []const u8 {
            switch (self) {
                .code => return "private-code",
                .clientheader => return "client-header",
                .serverheader => return "server-header",
            }
        }
    };

    fn runScanner(self: *Self, protocol: []const u8, gentype: WlScanGenType, output: []const u8, dest: std.fs.Dir) !void {
        var scannerprocess = std.process.Child.init(&.{ "wayland-scanner", gentype.toString(), protocol, output }, self.step.owner.allocator);
        scannerprocess.cwd_dir = dest;
        const ret = try scannerprocess.spawnAndWait();
        switch (ret) {
            .Exited => |val| {
                if (val == 0) {
                    return;
                }
            },
            else => {},
        }
        return error.WaylandScannerFailed;
    }

    fn processProtocol(self: *Self, ally: std.mem.Allocator, protocol: *QueueType.Node.Data, gentype: WlScanGenType, dest: std.fs.Dir) !void {
        const protoname = std.fs.path.stem(protocol.xml);
        const filesuffix = switch (gentype) {
            .code => ".c",
            .clientheader => self.client_header_suffix,
            .serverheader => "-protocol.h",
        };
        const filename = try std.mem.concat(ally, u8, &.{ protoname, filesuffix });
        try self.runScanner(protocol.xml, gentype, filename, dest);
    }

    pub fn process(self: *Self, protocol: *QueueType.Node.Data, dest: std.fs.Dir) !void {
        var buf: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(buf[0..]);
        const ally = fba.allocator();
        try self.processProtocol(ally, protocol, .code, dest);
        fba.reset();
        try self.processProtocol(ally, protocol, .clientheader, dest);
        if (self.gen_server_headers) {
            fba.reset();
            try self.processProtocol(ally, protocol, .serverheader, dest);
        }
    }

    pub fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *Self = @fieldParentPtr("step", step);
        if (self.queue.first == null) {
            return;
        }
        var it = self.queue.first;
        var manifest = step.owner.graph.cache.obtain();
        defer manifest.deinit();
        manifest.hash.addBytes("wlscan000");
        while (it) |node| : (it = node.next) {
            _ = try manifest.addFile(node.data.xml, null);
        }
        self.step.result_cached = try manifest.hit();
        const dest = try step.owner.cache_root.join(step.owner.allocator, &.{ "wl-gen", &manifest.final() });
        self.dest_path.path = dest;
        it = self.queue.first;
        var dest_dir = try std.fs.cwd().makeOpenPath(dest, .{});
        defer dest_dir.close();
        while (it) |node| : (it = node.next) {
            if (!self.step.result_cached) {
                self.process(&node.data, dest_dir) catch |err| {
                    std.log.err("failed to process protocol {s}", .{node.data.xml});
                    return err;
                };
            }
            // Need to fix the generatedfiles for the c sources
            const name = std.fs.path.stem(node.data.xml);
            const namefile = try std.mem.concat(step.owner.allocator, u8, &.{ name, ".c" });
            node.data.file.path = step.owner.pathJoin(&.{ dest, namefile });
        }
        if (!self.step.result_cached) {
            try manifest.writeManifest();
        }
    }
};

pub fn build(b: *std.Build) !void {
    // This space intentionally left blank
    // Maybe have tests here?
    _ = b;
}
