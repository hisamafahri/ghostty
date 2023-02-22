const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const options = @import("build_options");
const glfw = @import("glfw");
const macos = @import("macos");
const tracy = @import("tracy");
const internal_os = @import("os/main.zig");
const xev = @import("xev");
const fontconfig = @import("fontconfig");
const harfbuzz = @import("harfbuzz");
const renderer = @import("renderer.zig");
const xdg = @import("xdg.zig");
const apprt = @import("apprt.zig");

const App = @import("App.zig");
const cli_args = @import("cli_args.zig");
const Config = @import("config.zig").Config;
const Ghostty = @import("main_c.zig").Ghostty;

/// Global process state. This is initialized in main() for exe artifacts
/// and by ghostty_init() for lib artifacts. This should ONLY be used by
/// the C API. The Zig API should NOT use any global state and should
/// rely on allocators being passed in as parameters.
pub var state: GlobalState = undefined;

pub fn main() !void {
    state.init();
    defer state.deinit();
    const alloc = state.alloc;

    // Try reading our config
    var config = try Config.default(alloc);
    defer config.deinit();

    // If we have a configuration file in our home directory, parse that first.
    const cwd = std.fs.cwd();
    {
        const home_config_path = try xdg.config(alloc, .{ .subdir = "ghostty/config" });
        defer alloc.free(home_config_path);

        if (cwd.openFile(home_config_path, .{})) |file| {
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());
            try cli_args.parse(Config, alloc, &config, &iter);
        } else |err| switch (err) {
            error.FileNotFound => std.log.info(
                "homedir config not found, not loading path={s}",
                .{home_config_path},
            ),

            else => std.log.warn(
                "error reading homedir config file, not loading err={} path={s}",
                .{ err, home_config_path },
            ),
        }
    }

    // Parse the config from the CLI args
    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli_args.parse(Config, alloc, &config, &iter);
    }

    // Parse the config files that were added from our file and CLI args.
    // TODO(mitchellh): we should parse the files form the homedir first
    // TODO(mitchellh): support nesting (config-file in a config file)
    // TODO(mitchellh): detect cycles when nesting
    if (config.@"config-file".list.items.len > 0) {
        const len = config.@"config-file".list.items.len;
        for (config.@"config-file".list.items) |path| {
            var file = try cwd.openFile(path, .{});
            defer file.close();

            var buf_reader = std.io.bufferedReader(file.reader());
            var iter = cli_args.lineIterator(buf_reader.reader());

            try cli_args.parse(Config, alloc, &config, &iter);

            // We don't currently support adding more config files to load
            // from within a loaded config file. This can be supported
            // later.
            if (config.@"config-file".list.items.len > len)
                return error.ConfigFileInConfigFile;
        }
    }
    try config.finalize();
    std.log.debug("config={}", .{config});

    if (true) {
        // Create our app state
        var app = try App.create(alloc, &config);
        defer app.destroy();

        // Create our runtime app
        var app_runtime = try apprt.App.init(app, .{});
        defer app_runtime.terminate();

        // Create an initial window
        _ = try app_runtime.newWindow();

        // Run the GUI event loop
        try app_runtime.run();
        return;
    }

    // Run our app with a single initial window to start.
    var app = try App.create(alloc, .{}, &config);
    defer app.destroy();
    if (build_config.app_runtime == .gtk) {
        try app.runtime.newWindow();
        while (true) try app.runtime.wait();
        return;
    }
    _ = try app.newWindow(.{});
    try app.run();
}

// Required by tracy/tracy.zig to enable/disable tracy support.
pub fn tracy_enabled() bool {
    return options.tracy_enabled;
}

pub const std_options = struct {
    // Our log level is always at least info in every build mode.
    pub const log_level: std.log.Level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    };

    // The function std.log will call.
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Stuff we can do before the lock
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        // Lock so we are thread-safe
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();

        // On Mac, we use unified logging. To view this:
        //
        //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
        //
        if (builtin.os.tag == .macos) {
            // Convert our levels to Mac levels
            const mac_level: macos.os.LogType = switch (level) {
                .debug => .debug,
                .info => .info,
                .warn => .err,
                .err => .fault,
            };

            // Initialize a logger. This is slow to do on every operation
            // but we shouldn't be logging too much.
            const logger = macos.os.Log.create("com.mitchellh.ghostty", @tagName(scope));
            defer logger.release();
            logger.log(std.heap.c_allocator, mac_level, format, args);
        }

        // Always try default to send to stderr
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch return;
    }
};

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
pub const GlobalState = struct {
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    gpa: ?GPA,
    alloc: std.mem.Allocator,
    tracy: if (tracy.enabled) ?tracy.Allocator(null) else void,

    pub fn init(self: *GlobalState) void {
        // Output some debug information right away
        std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
        if (options.fontconfig) {
            std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
        }
        std.log.info("renderer={}", .{renderer.Renderer});
        std.log.info("libxev backend={}", .{xev.backend});

        // First things first, we fix our file descriptors
        internal_os.fixMaxFiles();

        // We need to make sure the process locale is set properly. Locale
        // affects a lot of behaviors in a shell.
        internal_os.ensureLocale();

        // Initialize ourself to nothing so we don't have any extra state.
        self.* = .{
            .gpa = null,
            .alloc = undefined,
            .tracy = undefined,
        };
        errdefer self.deinit();

        self.gpa = gpa: {
            // Use the libc allocator if it is available beacuse it is WAY
            // faster than GPA. We only do this in release modes so that we
            // can get easy memory leak detection in debug modes.
            if (builtin.link_libc) {
                if (switch (builtin.mode) {
                    .ReleaseSafe, .ReleaseFast => true,

                    // We also use it if we can detect we're running under
                    // Valgrind since Valgrind only instruments the C allocator
                    else => std.valgrind.runningOnValgrind() > 0,
                }) break :gpa null;
            }

            break :gpa GPA{};
        };

        self.alloc = alloc: {
            const base = if (self.gpa) |*value|
                value.allocator()
            else if (builtin.link_libc)
                std.heap.c_allocator
            else
                unreachable;

            // If we're tracing, wrap the allocator
            if (!tracy.enabled) break :alloc base;
            self.tracy = tracy.allocator(base, null);
            break :alloc self.tracy.?.allocator();
        };
    }

    /// Cleans up the global state. This doesn't _need_ to be called but
    /// doing so in dev modes will check for memory leaks.
    pub fn deinit(self: *GlobalState) void {
        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
        }

        if (tracy.enabled) {
            self.tracy = null;
        }
    }
};
test {
    _ = @import("Pty.zig");
    _ = @import("Command.zig");
    _ = @import("TempDir.zig");
    _ = @import("font/main.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");

    // Libraries
    _ = @import("segmented_pool.zig");
    _ = @import("terminal/main.zig");

    // TODO
    _ = @import("blocking_queue.zig");
    _ = @import("config.zig");
    _ = @import("homedir.zig");
    _ = @import("passwd.zig");
    _ = @import("xdg.zig");
    _ = @import("cli_args.zig");
    _ = @import("lru.zig");
}
