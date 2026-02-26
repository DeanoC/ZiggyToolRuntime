const std = @import("std");
const registry_mod = @import("tool_registry.zig");

pub const DEFAULT_MAX_OUTPUT_BYTES: usize = 1024 * 1024;
pub const DEFAULT_MAX_FILE_READ_BYTES: usize = 1024 * 1024;
const workspace_root_env = "SPIDERWEB_WORKSPACE_ROOT";

pub const RemoteToolExecutorFn = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
) registry_mod.ToolExecutionResult;

threadlocal var remote_tool_executor_ctx: ?*anyopaque = null;
threadlocal var remote_tool_executor_fn: ?RemoteToolExecutorFn = null;

pub fn setRemoteToolExecutor(ctx: ?*anyopaque, exec_fn: ?RemoteToolExecutorFn) void {
    remote_tool_executor_ctx = ctx;
    remote_tool_executor_fn = exec_fn;
}

const PathMode = enum {
    read_or_list,
    write,
};

fn fail(allocator: std.mem.Allocator, code: registry_mod.ToolErrorCode, msg: []const u8) registry_mod.ToolExecutionResult {
    const owned = allocator.dupe(u8, msg) catch return .{ .failure = .{
        .code = .execution_failed,
        .message = allocator.dupe(u8, "out of memory") catch @panic("out of memory while reporting error"),
    } };
    return .{ .failure = .{ .code = code, .message = owned } };
}

fn parseBool(args: std.json.ObjectMap, name: []const u8, default: bool) !bool {
    const value = args.get(name) orelse return default;
    if (value != .bool) return error.InvalidType;
    return value.bool;
}

fn parseUsize(args: std.json.ObjectMap, name: []const u8, default: usize) !usize {
    const value = args.get(name) orelse return default;
    if (value != .integer or value.integer < 0) return error.InvalidType;
    return @as(usize, @intCast(value.integer));
}

fn requiredString(args: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = args.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn optionalString(args: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = args.get(name) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn maybeExecuteRemote(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args: std.json.ObjectMap,
) ?registry_mod.ToolExecutionResult {
    const exec_fn = remote_tool_executor_fn orelse return null;
    const ctx = remote_tool_executor_ctx orelse return null;

    const args_json = std.json.Stringify.valueAlloc(
        allocator,
        std.json.Value{ .object = args },
        .{
            .emit_null_optional_fields = true,
            .whitespace = .minified,
        },
    ) catch return fail(allocator, .execution_failed, "failed to serialize tool arguments");
    defer allocator.free(args_json);

    return exec_fn(ctx, allocator, tool_name, args_json);
}

fn isWithinWorkspace(workspace: []const u8, target: []const u8) bool {
    if (std.mem.eql(u8, workspace, target)) return true;
    if (!std.mem.startsWith(u8, target, workspace)) return false;
    if (target.len <= workspace.len) return false;
    return target[workspace.len] == std.fs.path.sep;
}

fn getWorkspaceRootRealpath(allocator: std.mem.Allocator) ![]u8 {
    const configured_root = std.process.getEnvVarOwned(allocator, workspace_root_env) catch null;
    defer if (configured_root) |value| allocator.free(value);

    const cwd = std.fs.cwd();
    if (configured_root) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) {
            if (std.fs.path.isAbsolute(trimmed)) {
                return std.fs.realpathAlloc(allocator, trimmed);
            }
            const joined = try std.fs.path.join(allocator, &.{ ".", trimmed });
            defer allocator.free(joined);
            return cwd.realpathAlloc(allocator, joined);
        }
    }
    return cwd.realpathAlloc(allocator, ".");
}

fn resolveAbsolutePathInWorkspace(
    allocator: std.mem.Allocator,
    workspace_real: []const u8,
    relative_path: []const u8,
) ![]u8 {
    if (std.mem.eql(u8, relative_path, ".")) {
        return allocator.dupe(u8, workspace_real);
    }
    return std.fs.path.join(allocator, &.{ workspace_real, relative_path });
}

fn ensureAbsoluteParentDir(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (std.fs.path.isAbsolute(parent)) {
        var root = try std.fs.openDirAbsolute("/", .{});
        defer root.close();
        const rel_parent = std.mem.trimLeft(u8, parent, "/");
        if (rel_parent.len == 0) return;
        try root.makePath(rel_parent);
        return;
    }
    try std.fs.cwd().makePath(parent);
}

fn validatePathOwned(allocator: std.mem.Allocator, path: []const u8, mode: PathMode) ?[]u8 {
    if (path.len == 0) return allocator.dupe(u8, "path cannot be empty") catch null;
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, "absolute paths are not allowed") catch null;
    if (path[0] == '~') return allocator.dupe(u8, "home directory references are not allowed") catch null;

    const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| {
        return std.fmt.allocPrint(allocator, "failed to resolve workspace path: {s}", .{@errorName(err)}) catch null;
    };
    defer allocator.free(workspace_real);

    var candidate = switch (mode) {
        .read_or_list => path,
        .write => std.fs.path.dirname(path) orelse ".",
    };

    while (true) {
        const candidate_abs = resolveAbsolutePathInWorkspace(allocator, workspace_real, candidate) catch {
            return allocator.dupe(u8, "failed to resolve candidate path") catch null;
        };
        defer allocator.free(candidate_abs);

        const resolved = std.fs.realpathAlloc(allocator, candidate_abs) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                if (std.mem.eql(u8, candidate, ".")) {
                    return std.fmt.allocPrint(allocator, "failed to resolve path: {s}", .{@errorName(err)}) catch null;
                }
                candidate = std.fs.path.dirname(candidate) orelse ".";
                continue;
            },
            else => {
                return std.fmt.allocPrint(allocator, "failed to resolve path: {s}", .{@errorName(err)}) catch null;
            },
        };
        defer allocator.free(resolved);

        if (!isWithinWorkspace(workspace_real, resolved)) {
            return allocator.dupe(u8, "path resolves outside workspace") catch null;
        }
        return null;
    }
}

fn appendJsonEscaped(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    for (value) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => if (c < 0x20) {
                try out.writer(allocator).print("\\u00{x:0>2}", .{c});
            } else {
                try out.append(allocator, c);
            },
        }
    }
}

fn utf8SafePrefix(value: []const u8) []const u8 {
    if (std.unicode.utf8ValidateSlice(value)) return value;
    return value[0..longestValidUtf8PrefixLen(value)];
}

fn longestValidUtf8PrefixLen(value: []const u8) usize {
    var i: usize = 0;
    while (i < value.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(value[i]) catch break;
        const next = i + @as(usize, @intCast(seq_len));
        if (next > value.len) break;
        _ = std.unicode.utf8Decode(value[i..next]) catch break;
        i = next;
    }
    return i;
}

fn shellQuoteSingle(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayListUnmanaged(u8){};
    errdefer out.deinit(allocator);

    try out.append(allocator, '\'');
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

pub const BuiltinTools = struct {
    pub fn registerAll(registry: *registry_mod.ToolRegistry) !void {
        try registry.registerWorldTool(
            "file_read",
            "Read file contents",
            &[_]registry_mod.ToolParam{
                .{ .name = "path", .param_type = .string, .description = "Path to file", .required = true },
                .{ .name = "max_bytes", .param_type = .integer, .description = "Maximum bytes to read", .required = false },
            },
            fileRead,
        );
        try registry.registerWorldTool(
            "file_write",
            "Write file contents",
            &[_]registry_mod.ToolParam{
                .{ .name = "path", .param_type = .string, .description = "Path to file", .required = true },
                .{ .name = "content", .param_type = .string, .description = "File content", .required = true },
                .{ .name = "append", .param_type = .boolean, .description = "Append instead of overwrite", .required = false },
                .{ .name = "create_parents", .param_type = .boolean, .description = "Create parent folders", .required = false },
            },
            fileWrite,
        );
        try registry.registerWorldTool(
            "file_list",
            "List directory contents",
            &[_]registry_mod.ToolParam{
                .{ .name = "path", .param_type = .string, .description = "Directory path", .required = false },
                .{ .name = "recursive", .param_type = .boolean, .description = "Walk recursively", .required = false },
                .{ .name = "max_entries", .param_type = .integer, .description = "Maximum entries to return", .required = false },
            },
            fileList,
        );
        try registry.registerWorldTool(
            "search_code",
            "Search code using ripgrep",
            &[_]registry_mod.ToolParam{
                .{ .name = "query", .param_type = .string, .description = "Search query", .required = true },
                .{ .name = "path", .param_type = .string, .description = "Search path", .required = false },
                .{ .name = "case_sensitive", .param_type = .boolean, .description = "Enable case-sensitive search", .required = false },
                .{ .name = "max_results", .param_type = .integer, .description = "Maximum match lines", .required = false },
            },
            searchCode,
        );
        try registry.registerWorldTool(
            "shell_exec",
            "Execute a shell command",
            &[_]registry_mod.ToolParam{
                .{ .name = "command", .param_type = .string, .description = "Command line to execute", .required = true },
                .{ .name = "timeout_ms", .param_type = .integer, .description = "Timeout in milliseconds", .required = false },
                .{ .name = "cwd", .param_type = .string, .description = "Working directory", .required = false },
            },
            shellExec,
        );
    }

    pub fn fileRead(allocator: std.mem.Allocator, args: std.json.ObjectMap) registry_mod.ToolExecutionResult {
        if (maybeExecuteRemote(allocator, "file_read", args)) |remote| return remote;

        const path = requiredString(args, "path") orelse return fail(allocator, .invalid_params, "missing required parameter: path");
        if (validatePathOwned(allocator, path, .read_or_list)) |msg| {
            return .{ .failure = .{ .code = .permission_denied, .message = msg } };
        }

        const max_bytes = parseUsize(args, "max_bytes", DEFAULT_MAX_FILE_READ_BYTES) catch {
            return fail(allocator, .invalid_params, "max_bytes must be a non-negative integer");
        };
        const effective_max = @min(max_bytes, 8 * 1024 * 1024);

        const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(workspace_real);
        const absolute_path = resolveAbsolutePathInWorkspace(allocator, workspace_real, path) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(absolute_path);

        var file = std.fs.openFileAbsolute(absolute_path, .{}) catch |err| {
            return fail(allocator, .execution_failed, @errorName(err));
        };
        defer file.close();

        const file_size = file.getEndPos() catch 0;

        const content_buffer = allocator.alloc(u8, effective_max) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(content_buffer);
        const content_len = file.readAll(content_buffer) catch |err| {
            return fail(allocator, .execution_failed, @errorName(err));
        };
        const raw_content = content_buffer[0..content_len];
        const truncated = file_size > content_len;
        const content = if (truncated) utf8SafePrefix(raw_content) else raw_content;

        var payload = std.ArrayListUnmanaged(u8){};
        errdefer payload.deinit(allocator);

        payload.appendSlice(allocator, "{\"path\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, path) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"bytes\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.writer(allocator).print("{d}", .{content.len}) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, ",\"truncated\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, if (truncated) "true" else "false") catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, ",\"content\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, content) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\"}") catch return fail(allocator, .execution_failed, "out of memory");

        return .{ .success = .{ .payload_json = payload.toOwnedSlice(allocator) catch return fail(allocator, .execution_failed, "out of memory") } };
    }

    pub fn fileWrite(allocator: std.mem.Allocator, args: std.json.ObjectMap) registry_mod.ToolExecutionResult {
        if (maybeExecuteRemote(allocator, "file_write", args)) |remote| return remote;

        const path = requiredString(args, "path") orelse return fail(allocator, .invalid_params, "missing required parameter: path");
        const content = requiredString(args, "content") orelse return fail(allocator, .invalid_params, "missing required parameter: content");
        if (validatePathOwned(allocator, path, .write)) |msg| {
            return .{ .failure = .{ .code = .permission_denied, .message = msg } };
        }

        const append = parseBool(args, "append", false) catch return fail(allocator, .invalid_params, "append must be boolean");
        const create_parents = parseBool(args, "create_parents", true) catch return fail(allocator, .invalid_params, "create_parents must be boolean");

        const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(workspace_real);
        const absolute_path = resolveAbsolutePathInWorkspace(allocator, workspace_real, path) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(absolute_path);

        if (create_parents) {
            ensureAbsoluteParentDir(absolute_path) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        }

        if (append) {
            var file = std.fs.createFileAbsolute(absolute_path, .{ .truncate = false }) catch |err| return fail(allocator, .execution_failed, @errorName(err));
            defer file.close();
            file.seekFromEnd(0) catch |err| return fail(allocator, .execution_failed, @errorName(err));
            file.writeAll(content) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        } else {
            var file = std.fs.createFileAbsolute(absolute_path, .{ .truncate = true }) catch |err| return fail(allocator, .execution_failed, @errorName(err));
            defer file.close();
            file.writeAll(content) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        }

        var payload = std.ArrayListUnmanaged(u8){};
        errdefer payload.deinit(allocator);
        payload.appendSlice(allocator, "{\"path\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, path) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"bytes_written\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.writer(allocator).print("{d}", .{content.len}) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, ",\"append\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, if (append) "true" else "false") catch return fail(allocator, .execution_failed, "out of memory");
        payload.append(allocator, '}') catch return fail(allocator, .execution_failed, "out of memory");

        return .{ .success = .{ .payload_json = payload.toOwnedSlice(allocator) catch return fail(allocator, .execution_failed, "out of memory") } };
    }

    pub fn fileList(allocator: std.mem.Allocator, args: std.json.ObjectMap) registry_mod.ToolExecutionResult {
        if (maybeExecuteRemote(allocator, "file_list", args)) |remote| return remote;

        const path = optionalString(args, "path") orelse ".";
        if (validatePathOwned(allocator, path, .read_or_list)) |msg| {
            return .{ .failure = .{ .code = .permission_denied, .message = msg } };
        }
        const recursive = parseBool(args, "recursive", false) catch return fail(allocator, .invalid_params, "recursive must be boolean");
        const max_entries = parseUsize(args, "max_entries", 500) catch return fail(allocator, .invalid_params, "max_entries must be integer");
        const effective_max = @min(max_entries, 5000);
        const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(workspace_real);
        const absolute_path = resolveAbsolutePathInWorkspace(allocator, workspace_real, path) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(absolute_path);

        const listing_result = if (recursive)
            std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{
                    "find",
                    absolute_path,
                    "-mindepth",
                    "1",
                    "-printf",
                    "%y\t%P\n",
                },
                .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
            }) catch |err| return fail(allocator, .execution_failed, @errorName(err))
        else
            std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{
                    "find",
                    absolute_path,
                    "-mindepth",
                    "1",
                    "-maxdepth",
                    "1",
                    "-printf",
                    "%y\t%f\n",
                },
                .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
            }) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(listing_result.stdout);
        defer allocator.free(listing_result.stderr);

        var payload = std.ArrayListUnmanaged(u8){};
        errdefer payload.deinit(allocator);

        payload.appendSlice(allocator, "{\"path\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, path) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"entries\":[") catch return fail(allocator, .execution_failed, "out of memory");

        var first = true;
        var count: usize = 0;
        var truncated = false;
        var lines = std.mem.splitScalar(u8, listing_result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const delim = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            if (delim + 1 >= line.len) continue;

            if (count >= effective_max) {
                truncated = true;
                break;
            }

            const kind = findEntryKind(line[0]);
            const name = line[delim + 1 ..];
            if (name.len == 0) continue;

            if (!first) payload.append(allocator, ',') catch return fail(allocator, .execution_failed, "out of memory");
            first = false;
            count += 1;

            payload.appendSlice(allocator, "{\"name\":\"") catch return fail(allocator, .execution_failed, "out of memory");
            appendJsonEscaped(allocator, &payload, name) catch return fail(allocator, .execution_failed, "out of memory");
            payload.appendSlice(allocator, "\",\"type\":\"") catch return fail(allocator, .execution_failed, "out of memory");
            payload.appendSlice(allocator, kind) catch return fail(allocator, .execution_failed, "out of memory");
            payload.appendSlice(allocator, "\"}") catch return fail(allocator, .execution_failed, "out of memory");
        }

        const listing_failed = switch (listing_result.term) {
            .Exited => |code| code != 0,
            else => true,
        };
        if (listing_failed) truncated = true;

        payload.appendSlice(allocator, "],\"truncated\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, if (truncated) "true" else "false") catch return fail(allocator, .execution_failed, "out of memory");
        if (listing_failed) {
            const trimmed_stderr = std.mem.trim(u8, listing_result.stderr, " \t\r\n");
            if (trimmed_stderr.len > 0) {
                const capped = trimmed_stderr[0..@min(trimmed_stderr.len, 512)];
                payload.appendSlice(allocator, ",\"error\":\"") catch return fail(allocator, .execution_failed, "out of memory");
                appendJsonEscaped(allocator, &payload, capped) catch return fail(allocator, .execution_failed, "out of memory");
                payload.appendSlice(allocator, "\"") catch return fail(allocator, .execution_failed, "out of memory");
            }
        }
        payload.append(allocator, '}') catch return fail(allocator, .execution_failed, "out of memory");

        return .{ .success = .{ .payload_json = payload.toOwnedSlice(allocator) catch return fail(allocator, .execution_failed, "out of memory") } };
    }

    fn findEntryKind(raw: u8) []const u8 {
        return switch (raw) {
            'f' => "file",
            'd' => "directory",
            'l' => "symlink",
            else => "other",
        };
    }

    pub fn searchCode(allocator: std.mem.Allocator, args: std.json.ObjectMap) registry_mod.ToolExecutionResult {
        if (maybeExecuteRemote(allocator, "search_code", args)) |remote| return remote;

        const query = requiredString(args, "query") orelse return fail(allocator, .invalid_params, "missing required parameter: query");
        const path = optionalString(args, "path") orelse ".";
        if (validatePathOwned(allocator, path, .read_or_list)) |msg| {
            return .{ .failure = .{ .code = .permission_denied, .message = msg } };
        }
        const case_sensitive = parseBool(args, "case_sensitive", false) catch return fail(allocator, .invalid_params, "case_sensitive must be boolean");
        const max_results = parseUsize(args, "max_results", 200) catch return fail(allocator, .invalid_params, "max_results must be integer");
        const effective_max_results = @min(max_results, 5000);
        const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(workspace_real);
        const absolute_path = resolveAbsolutePathInWorkspace(allocator, workspace_real, path) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(absolute_path);

        const rg_case_flag = if (case_sensitive) "--case-sensitive" else "-i";
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "rg", "-n", rg_case_flag, "--color=never", "-m", "5000", "-e", query, "--", absolute_path },
            .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
        }) catch {
            const grep_case_flag = if (case_sensitive) "" else "-i";
            const grep_argv = if (grep_case_flag.len == 0)
                &[_][]const u8{ "grep", "-rn", "--color=never", "-m", "5000", "-e", query, "--", absolute_path }
            else
                &[_][]const u8{ "grep", "-rn", "--color=never", grep_case_flag, "-m", "5000", "-e", query, "--", absolute_path };

            const grep_result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = grep_argv,
                .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
            }) catch |grep_err| return fail(allocator, .execution_failed, @errorName(grep_err));
            defer allocator.free(grep_result.stderr);

            if (grep_result.term.Exited != 0 and grep_result.term.Exited != 1) {
                allocator.free(grep_result.stdout);
                return fail(allocator, .execution_failed, "grep command failed");
            }

            return buildSearchPayload(allocator, path, query, grep_result.stdout, effective_max_results);
        };
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0 and result.term.Exited != 1) {
            allocator.free(result.stdout);
            return fail(allocator, .execution_failed, "rg command failed");
        }

        return buildSearchPayload(allocator, path, query, result.stdout, effective_max_results);
    }

    fn buildSearchPayload(
        allocator: std.mem.Allocator,
        path: []const u8,
        query: []const u8,
        raw_output: []u8,
        max_results: usize,
    ) registry_mod.ToolExecutionResult {
        defer allocator.free(raw_output);

        var payload = std.ArrayListUnmanaged(u8){};
        errdefer payload.deinit(allocator);

        payload.appendSlice(allocator, "{\"path\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, path) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"query\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, query) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"matches\":[") catch return fail(allocator, .execution_failed, "out of memory");

        var lines = std.mem.splitScalar(u8, raw_output, '\n');
        var count: usize = 0;
        var first = true;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (count >= max_results) break;
            if (!first) payload.append(allocator, ',') catch return fail(allocator, .execution_failed, "out of memory");
            first = false;
            count += 1;

            payload.appendSlice(allocator, "\"") catch return fail(allocator, .execution_failed, "out of memory");
            appendJsonEscaped(allocator, &payload, line) catch return fail(allocator, .execution_failed, "out of memory");
            payload.appendSlice(allocator, "\"") catch return fail(allocator, .execution_failed, "out of memory");
        }

        payload.appendSlice(allocator, "],\"count\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.writer(allocator).print("{d}", .{count}) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, ",\"truncated\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, if (lines.next() != null) "true" else "false") catch return fail(allocator, .execution_failed, "out of memory");
        payload.append(allocator, '}') catch return fail(allocator, .execution_failed, "out of memory");

        return .{ .success = .{ .payload_json = payload.toOwnedSlice(allocator) catch return fail(allocator, .execution_failed, "out of memory") } };
    }

    pub fn shellExec(allocator: std.mem.Allocator, args: std.json.ObjectMap) registry_mod.ToolExecutionResult {
        if (maybeExecuteRemote(allocator, "shell_exec", args)) |remote| return remote;

        const command = requiredString(args, "command") orelse return fail(allocator, .invalid_params, "missing required parameter: command");
        const timeout_ms = parseUsize(args, "timeout_ms", 30_000) catch return fail(allocator, .invalid_params, "timeout_ms must be integer");
        const bounded_timeout_ms = @min(timeout_ms, 300_000);
        const cwd = optionalString(args, "cwd");
        const workspace_real = getWorkspaceRootRealpath(allocator) catch |err| return fail(allocator, .execution_failed, @errorName(err));
        defer allocator.free(workspace_real);

        const timeout_sec = @max(@divTrunc(bounded_timeout_ms + 999, 1000), 1);
        const timeout_str = std.fmt.allocPrint(allocator, "{d}", .{timeout_sec}) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(timeout_str);

        const workspace_quoted = shellQuoteSingle(allocator, workspace_real) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(workspace_quoted);
        const wrapped_command = if (cwd) |cwd_value| blk: {
            if (validatePathOwned(allocator, cwd_value, .read_or_list)) |msg| {
                return .{ .failure = .{ .code = .permission_denied, .message = msg } };
            }
            const cwd_quoted = shellQuoteSingle(allocator, cwd_value) catch return fail(allocator, .execution_failed, "out of memory");
            defer allocator.free(cwd_quoted);
            break :blk std.fmt.allocPrint(
                allocator,
                "cd {s} && cd {s} && {s}",
                .{ workspace_quoted, cwd_quoted, command },
            ) catch return fail(allocator, .execution_failed, "out of memory");
        } else std.fmt.allocPrint(
            allocator,
            "cd {s} && {s}",
            .{ workspace_quoted, command },
        ) catch return fail(allocator, .execution_failed, "out of memory");
        defer allocator.free(wrapped_command);

        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "timeout", timeout_str, "bash", "-lc", wrapped_command },
            .max_output_bytes = DEFAULT_MAX_OUTPUT_BYTES,
        }) catch |err| return fail(allocator, .execution_failed, @errorName(err));

        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code: i32 = switch (result.term) {
            .Exited => |code| @intCast(code),
            .Signal => |sig| @intCast(sig),
            .Stopped => |sig| @intCast(sig),
            .Unknown => |code| @intCast(code),
        };

        if (exit_code == 124) {
            return fail(allocator, .timeout, "command timed out");
        }

        var payload = std.ArrayListUnmanaged(u8){};
        errdefer payload.deinit(allocator);

        payload.appendSlice(allocator, "{\"exit_code\":") catch return fail(allocator, .execution_failed, "out of memory");
        payload.writer(allocator).print("{d}", .{exit_code}) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, ",\"stdout\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, result.stdout) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\",\"stderr\":\"") catch return fail(allocator, .execution_failed, "out of memory");
        appendJsonEscaped(allocator, &payload, result.stderr) catch return fail(allocator, .execution_failed, "out of memory");
        payload.appendSlice(allocator, "\"}") catch return fail(allocator, .execution_failed, "out of memory");

        return .{ .success = .{ .payload_json = payload.toOwnedSlice(allocator) catch return fail(allocator, .execution_failed, "out of memory") } };
    }
};

fn inTempCwd(allocator: std.mem.Allocator, body: *const fn (std.mem.Allocator, []const u8) anyerror!void) !void {
    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);

    const temp_dir = try std.fmt.allocPrint(allocator, ".tmp-tool-tests-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(temp_dir);
    defer std.fs.cwd().deleteTree(temp_dir) catch {};

    try std.fs.cwd().makePath(temp_dir);
    const target_cwd = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ original_cwd, temp_dir });
    defer allocator.free(target_cwd);

    try std.process.changeCurDir(target_cwd);
    defer std.process.changeCurDir(original_cwd) catch {};

    try body(allocator, target_cwd);
}

fn testFileWriteReadImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    var write_parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        "{\"path\":\"nested/a.txt\",\"content\":\"hello\",\"create_parents\":true}",
        .{},
    );
    defer write_parsed.deinit();

    var write_result = BuiltinTools.fileWrite(allocator, write_parsed.value.object);
    defer write_result.deinit(allocator);
    try std.testing.expect(write_result == .success);

    var read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"nested/a.txt\"}", .{});
    defer read_parsed.deinit();

    var read_result = BuiltinTools.fileRead(allocator, read_parsed.value.object);
    defer read_result.deinit(allocator);

    try std.testing.expect(read_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"content\":\"hello\"") != null);
}

test "tool_executor: file_write then file_read roundtrip" {
    try inTempCwd(std.testing.allocator, testFileWriteReadImpl);
}

fn testFileReadMaxBytesImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = "big.txt", .data = "abcdefghij" });

    var read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"big.txt\",\"max_bytes\":4}", .{});
    defer read_parsed.deinit();

    var read_result = BuiltinTools.fileRead(allocator, read_parsed.value.object);
    defer read_result.deinit(allocator);

    try std.testing.expect(read_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"bytes\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"content\":\"abcd\"") != null);
}

test "tool_executor: file_read max_bytes returns partial content" {
    try inTempCwd(std.testing.allocator, testFileReadMaxBytesImpl);
}

fn testFileReadMaxBytesUtf8BoundaryImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = "utf8.txt", .data = "abc\xe2\x82\xacdef" });

    var read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\"utf8.txt\",\"max_bytes\":5}", .{});
    defer read_parsed.deinit();

    var read_result = BuiltinTools.fileRead(allocator, read_parsed.value.object);
    defer read_result.deinit(allocator);

    try std.testing.expect(read_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"bytes\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_result.success.payload_json, "\"content\":\"abc\"") != null);

    var payload_parsed = try std.json.parseFromSlice(std.json.Value, allocator, read_result.success.payload_json, .{});
    defer payload_parsed.deinit();
    try std.testing.expect(payload_parsed.value == .object);
}

test "tool_executor: file_read max_bytes keeps truncated output utf8-safe" {
    try inTempCwd(std.testing.allocator, testFileReadMaxBytesUtf8BoundaryImpl);
}

fn testFileListImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = "one.txt", .data = "1" });
    try std.fs.cwd().writeFile(.{ .sub_path = "two.txt", .data = "2" });
    try std.fs.cwd().writeFile(.{ .sub_path = "three.txt", .data = "3" });

    var list_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"path\":\".\",\"max_entries\":2}", .{});
    defer list_parsed.deinit();

    var list_result = BuiltinTools.fileList(allocator, list_parsed.value.object);
    defer list_result.deinit(allocator);

    try std.testing.expect(list_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, list_result.success.payload_json, "\"truncated\":true") != null);
}

test "tool_executor: file_list honors max_entries truncation" {
    try inTempCwd(std.testing.allocator, testFileListImpl);
}

fn testSearchCodeImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    try std.fs.cwd().makePath("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/sample.zig", .data = "const token = \"needle\";\n" });

    var search_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"query\":\"needle\",\"path\":\"src\"}", .{});
    defer search_parsed.deinit();

    var search_result = BuiltinTools.searchCode(allocator, search_parsed.value.object);
    defer search_result.deinit(allocator);

    try std.testing.expect(search_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, search_result.success.payload_json, "needle") != null);
}

test "tool_executor: search_code returns matching lines" {
    try inTempCwd(std.testing.allocator, testSearchCodeImpl);
}

fn testShellCwdImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    try std.fs.cwd().makePath("workdir/sub");

    var shell_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"command\":\"pwd\",\"cwd\":\"workdir/sub\"}", .{});
    defer shell_parsed.deinit();

    var shell_result = BuiltinTools.shellExec(allocator, shell_parsed.value.object);
    defer shell_result.deinit(allocator);

    try std.testing.expect(shell_result == .success);
    try std.testing.expect(std.mem.indexOf(u8, shell_result.success.payload_json, "\"exit_code\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, shell_result.success.payload_json, "workdir/sub") != null);
}

test "tool_executor: shell_exec supports cwd" {
    try inTempCwd(std.testing.allocator, testShellCwdImpl);
}

fn testShellTimeoutImpl(allocator: std.mem.Allocator, _: []const u8) !void {
    var timeout_parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"command\":\"sleep 2\",\"timeout_ms\":100}", .{});
    defer timeout_parsed.deinit();

    var timeout_result = BuiltinTools.shellExec(allocator, timeout_parsed.value.object);
    defer timeout_result.deinit(allocator);

    try std.testing.expect(timeout_result == .failure);
    try std.testing.expectEqual(registry_mod.ToolErrorCode.timeout, timeout_result.failure.code);
}

test "tool_executor: shell_exec returns timeout" {
    try inTempCwd(std.testing.allocator, testShellTimeoutImpl);
}
