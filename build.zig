const std = @import("std");

pub const WlScannerStep = struct {
    const Protocol = struct {
        xml: std.Build.LazyPath,
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
        const mod = b.createModule(.{
            .target = options.target,
            .optimize = options.optimize,
            .link_libc = true,
        });
        // Why not just linkSystemLibrary? Because if I do that then I get lld warnings like...
        // archive member '/lib64/libwayland-client.so' is neither ET_REL nor LLVM bitcode
        // ... that make the build system think the build failed, but it did not really fail.
        mod.addIncludePath(.{ .cwd_relative = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "wayland-client" }), &std.ascii.whitespace) });
        res.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "wayland-scanner",
                .owner = b,
                .makeFn = make,
            }),
            .queue = .{},
            .lib = b.addLibrary(.{
                .linkage = .static,
                .name = "wl-protocol-lib",
                .root_module = mod,
            }),
            .dest_path = .{ .step = &res.step },
            .gen_server_headers = options.server_headers,
            .client_header_suffix = options.client_header_suffix,
        };
        return res;
    }
    pub fn linkWith(self: *Self, mod: *std.Build.Module) void {
        mod.linkLibrary(self.lib);
        mod.addIncludePath(.{ .generated = .{ .file = &self.dest_path } });
    }

    pub fn addSystemProtocol(self: *Self, xml: []const u8) void {
        if (self.system_protocol_dir == null) {
            self.system_protocol_dir = std.mem.trim(u8, self.step.owner.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), &std.ascii.whitespace);
        }
        const path = self.step.owner.pathJoin(&.{ self.system_protocol_dir.?, xml });
        self.addProtocol(.{ .cwd_relative = path });
    }
    pub fn addProtocol(self: *Self, xml: std.Build.LazyPath) void {
        const node = self.step.owner.allocator.create(QueueType.Node) catch @panic("OOM");
        node.data = .{
            .xml = xml,
            .file = .{ .step = &self.step },
        };
        self.lib.addCSourceFile(.{ .file = .{ .generated = .{ .file = &node.data.file } }, .flags = &.{} });
        self.queue.prepend(node);
    }
    pub fn addSystemProtocols(self: *Self, xmls: []const []const u8) void {
        for (xmls) |x| {
            self.addSystemProtocol(x);
        }
    }
    pub fn addProtocols(self: *Self, xmls: []const std.Build.LazyPath) void {
        for (xmls) |x| {
            self.addProtocol(x);
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

    fn runScanner(self: *Self, protocol: std.Build.Cache.Path, gentype: WlScanGenType, output: []const u8) !void {
        var scannerprocess = std.process.Child.init(&.{ "wayland-scanner", gentype.toString(), protocol.sub_path, output }, self.step.owner.allocator);
        scannerprocess.cwd_dir = protocol.root_dir.handle;
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

    fn processProtocol(self: *Self, ally: std.mem.Allocator, protocol: std.Build.Cache.Path, gentype: WlScanGenType, dest: []const u8) !void {
        const protoname = std.fs.path.stem(protocol.sub_path);
        const filesuffix = switch (gentype) {
            .code => ".c",
            .clientheader => self.client_header_suffix,
            .serverheader => "-protocol.h",
        };
        const filename = try std.mem.concat(ally, u8, &.{ protoname, filesuffix });
        try self.runScanner(protocol, gentype, self.step.owner.pathJoin(&.{ dest, filename }));
    }

    pub fn process(self: *Self, protocol: std.Build.Cache.Path, dest: []const u8) !void {
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
        manifest.hash.addBytes("wlscan004");
        while (it) |node| : (it = node.next) {
            _ = try manifest.addFilePath(node.data.xml.getPath3(self.step.owner, step), null);
        }
        self.step.result_cached = try manifest.hit();
        const dest = try step.owner.cache_root.join(step.owner.allocator, &.{ "wl-gen", &manifest.final() });
        self.dest_path.path = dest;
        it = self.queue.first;
        var dest_dir = try std.fs.cwd().makeOpenPath(dest, .{});
        defer dest_dir.close();
        while (it) |node| : (it = node.next) {
            const path = node.data.xml.getPath3(self.step.owner, step);
            // Need to fix the generatedfiles for the c sources
            const name = std.fs.path.stem(path.sub_path);
            const namefile = try std.mem.concat(step.owner.allocator, u8, &.{ name, ".c" });
            node.data.file.path = step.owner.pathJoin(&.{ dest, namefile });
            if (!self.step.result_cached) {
                self.process(path, dest) catch |err| {
                    std.log.err("failed to process protocol {s}", .{path.sub_path});
                    return err;
                };
            }
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
