const std = @import("std");

pub const WlScannerStep = struct {
    const WlScannerStepOptions = struct {
        optimize: std.builtin.OptimizeMode,
        target: std.Build.ResolvedTarget,
        server_headers: bool = false,
        client_header_suffix: []const u8 = "-client-protocol.h",
    };
    lib: *std.Build.Step.Compile,
    gen_server_headers: bool,
    client_header_suffix: []const u8,
    system_protocol_dir: ?[]const u8 = null,
    wayland_scanner_exe: std.Build.LazyPath,
    pub fn create(b: *std.Build, options: WlScannerStepOptions) *WlScannerStep {
        const res = b.allocator.create(WlScannerStep) catch @panic("OOM");
        res.* = .{
            .lib = b.addLibrary(.{
                .linkage = .static,
                .name = "wl-protocol-lib",
                .root_module = b.createModule(.{
                    .target = options.target,
                    .optimize = options.optimize,
                    .link_libc = true,
                }),
            }),
            .gen_server_headers = options.server_headers,
            .client_header_suffix = options.client_header_suffix,
            .wayland_scanner_exe = b.findProgramLazy(.{ .names = &.{"wayland-scanner"} }),
        };
        // Why not just linkSystemLibrary? Because if I do that then I get lld warnings like...
        // archive member '/lib64/libwayland-client.so' is neither ET_REL nor LLVM bitcode
        // ... that make the build system think the build failed, but it did not really fail.
        res.lib.root_module.addIncludePath(.{ .cwd_relative = std.mem.trim(u8, b.run(&.{ "pkg-config", "--variable=includedir", "wayland-client" }), &std.ascii.whitespace) });
        return res;
    }

    pub fn linkWith(self: *WlScannerStep, mod: *std.Build.Module) void {
        mod.linkLibrary(self.lib);
    }

    pub fn addSystemProtocol(self: *WlScannerStep, xml: []const u8) void {
        if (self.system_protocol_dir == null) {
            self.system_protocol_dir = std.mem.trim(u8, self.lib.step.owner.run(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }), &std.ascii.whitespace);
        }
        const path = self.lib.step.owner.pathJoin(&.{ self.system_protocol_dir.?, xml });
        self.addProtocol(.{ .cwd_relative = path }, std.fs.path.stem(xml));
    }

    pub fn addProtocol(self: *WlScannerStep, xml: std.Build.LazyPath, name: []const u8) void {
        self.runScanner(xml, .code, name);
        if (self.gen_server_headers) {
            self.runScanner(xml, .serverheader, name);
        }
        self.runScanner(xml, .clientheader, name);
    }

    pub fn addSystemProtocols(self: *WlScannerStep, xmls: []const []const u8) void {
        for (xmls) |x| {
            self.addSystemProtocol(x);
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

    fn runScanner(self: *WlScannerStep, protocol: std.Build.LazyPath, gentype: WlScanGenType, protocol_name: []const u8) void {
        const run = self.lib.step.owner.addRunFile(self.wayland_scanner_exe);
        run.addArg(gentype.toString());
        run.addFileArg(protocol);
        var fba_buf: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
        const output_name = switch (gentype) {
            .code => std.mem.concat(fba.allocator(), u8, &.{ protocol_name, ".c" }) catch @panic("OOM"),
            .clientheader => std.mem.concat(fba.allocator(), u8, &.{ protocol_name, self.client_header_suffix }) catch @panic("OOM"),
            .serverheader => std.mem.concat(fba.allocator(), u8, &.{ protocol_name, "-protocol.h" }) catch @panic("OOM"),
        };
        const output_file = run.addOutputFileArg(output_name);
        if (gentype == .code) {
            self.lib.root_module.addCSourceFile(.{ .file = output_file, .flags = &.{} });
        } else {
            self.lib.installHeader(output_file, output_name);
        }
    }
};

pub fn build(b: *std.Build) !void {
    // This space intentionally left blank
    // Maybe have tests here?
    _ = b;
}
