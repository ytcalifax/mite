const std = @import("std");
const win32 = @import("win32").everything;

const log = std.log.scoped(.pty);

pub const GridPos = struct {
    row: u16,
    col: u16,
};

pub const Error = struct {
    what: [:0]const u8,
    code: Code,

    pub fn setZig(self: *Error, what: [:0]const u8, code: anyerror) error{Error} {
        self.* = .{ .what = what, .code = .{ .zig = code } };
        return error.Error;
    }
    pub fn setWin32(self: *Error, what: [:0]const u8, code: win32.WIN32_ERROR) error{Error} {
        self.* = .{ .what = what, .code = .{ .win32 = code } };
        return error.Error;
    }
    pub fn setHresult(self: *Error, what: [:0]const u8, code: i32) error{Error} {
        self.* = .{ .what = what, .code = .{ .hresult = code } };
        return error.Error;
    }

    const Code = union(enum) {
        zig: anyerror,
        win32: win32.WIN32_ERROR,
        hresult: win32.HRESULT,
    };
};

pub const ReadPayload = struct {
    generation: u32,
    len: u32,
    data: [4096]u8,
};

const payload_pool_size = 256;

const PayloadPool = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    used: [payload_pool_size]bool = [_]bool{false} ** payload_pool_size,
    items: [payload_pool_size]ReadPayload = undefined,

    fn acquire(self: *PayloadPool) *ReadPayload {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            for (&self.used, 0..) |*used, i| {
                if (!used.*) {
                    used.* = true;
                    return &self.items[i];
                }
            }
            self.cond.wait(&self.mutex);
        }
    }

    fn release(self: *PayloadPool, payload: *ReadPayload) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (&self.items, 0..) |*item, i| {
            if (item == payload) {
                std.debug.assert(self.used[i]);
                self.used[i] = false;
                self.cond.signal();
                return;
            }
        }
        std.debug.panic("released payload outside PTY pool", .{});
    }
};

var payload_pool: PayloadPool = .{};

pub fn releaseReadPayload(payload: *ReadPayload) void {
    payload_pool.release(payload);
}

const PipePair = struct {
    read: win32.HANDLE,
    write: win32.HANDLE,

    fn closeRead(self: PipePair) void {
        win32.closeHandle(self.read);
    }

    fn closeWrite(self: PipePair) void {
        win32.closeHandle(self.write);
    }
};

pub const ChildProcess = struct {
    pty: ?Pty,
    job: win32.HANDLE,
    process_handle: win32.HANDLE,

    pub const Pty = struct {
        write: std.fs.File,
        hpcon: win32.HPCON,
        pub fn deinit(self: *Pty) void {
            _ = win32.ClosePseudoConsole(self.hpcon);
            win32.closeHandle(self.write.handle);
        }
        pub fn writeFlushAll(self: *const Pty, slice: []const u8) !void {
            try self.write.writeAll(slice);
        }
    };

    pub fn startConPtyWin32(
        out_err: *Error,
        allocator: std.mem.Allocator,
        application_name: ?[*:0]const u16,
        command_line: ?[*:0]u16,
        hwnd: win32.HWND,
        hwnd_msg: u32,
        _: win32.LRESULT,
        generation: u32,
        cell_count: GridPos,
    ) error{Error}!ChildProcess {
        const input_pipe = try createPipe(out_err, "CreateInputPipe");
        var input_read_open = true;
        defer if (input_read_open) input_pipe.closeRead();
        errdefer input_pipe.closeWrite();

        const output_pipe = try createPipe(out_err, "CreateOutputPipe");
        var output_read_owned_by_thread = false;
        var output_write_open = true;
        errdefer if (!output_read_owned_by_thread) output_pipe.closeRead();
        errdefer if (output_write_open) output_pipe.closeWrite();

        try setInherit(out_err, input_pipe.write, false);
        try setInherit(out_err, output_pipe.read, false);

        const thread = std.Thread.spawn(
            .{},
            readConsoleThread,
            .{ hwnd, hwnd_msg, generation, output_pipe.read },
        ) catch |e| return out_err.setZig("CreateReadConsoleThread", e);
        thread.detach();
        output_read_owned_by_thread = true;

        var hpcon: win32.HPCON = undefined;
        {
            const hr = win32.CreatePseudoConsole(
                .{ .X = @intCast(cell_count.col), .Y = @intCast(cell_count.row) },
                input_pipe.read,
                output_pipe.write,
                0,
                @ptrCast(&hpcon),
            );
            input_pipe.closeRead();
            output_pipe.closeWrite();
            input_read_open = false;
            output_write_open = false;
            if (hr < 0) return out_err.setHresult("CreatePseudoConsole", hr);
        }
        errdefer _ = win32.ClosePseudoConsole(hpcon);

        var attr_list_size: usize = undefined;
        _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);

        const attr_list = allocator.alloc(
            u8,
            attr_list_size,
        ) catch return out_err.setZig("AllocProcAttrs", error.OutOfMemory);
        defer allocator.free(attr_list);

        if (0 == win32.InitializeProcThreadAttributeList(
            attr_list.ptr,
            1,
            0,
            &attr_list_size,
        )) return out_err.setWin32("InitProcAttrs", win32.GetLastError());
        defer win32.DeleteProcThreadAttributeList(attr_list.ptr);

        if (0 == win32.UpdateProcThreadAttribute(
            attr_list.ptr,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            hpcon,
            @sizeOf(@TypeOf(hpcon)),
            null,
            null,
        )) return out_err.setWin32("UpdateProcThreadAttribute", win32.GetLastError());

        var startup_info = win32.STARTUPINFOEXW{
            .StartupInfo = .{
                .cb = @sizeOf(win32.STARTUPINFOEXW),
                .hStdError = null,
                .hStdOutput = null,
                .hStdInput = null,
                .dwFlags = .{ .USESTDHANDLES = 1 },
                .lpReserved = null,
                .lpDesktop = null,
                .lpTitle = null,
                .dwX = 0,
                .dwY = 0,
                .dwXSize = 0,
                .dwYSize = 0,
                .dwXCountChars = 0,
                .dwYCountChars = 0,
                .dwFillAttribute = 0,
                .wShowWindow = 0,
                .cbReserved2 = 0,
                .lpReserved2 = null,
            },
            .lpAttributeList = attr_list.ptr,
        };

        _ = win32.SetEnvironmentVariableW(win32.L("TERM"), win32.L("xterm-256color"));
        _ = win32.SetEnvironmentVariableW(win32.L("NO_COLOR"), null);
        _ = win32.SetEnvironmentVariableW(win32.L("COLORTERM"), win32.L("truecolor"));

        var process_info: win32.PROCESS_INFORMATION = undefined;
        if (0 == win32.CreateProcessW(
            application_name,
            command_line,
            null,
            null,
            0,
            .{
                .CREATE_SUSPENDED = 1,
                .EXTENDED_STARTUPINFO_PRESENT = 1,
            },
            null,
            null,
            &startup_info.StartupInfo,
            &process_info,
        )) return out_err.setWin32("CreateProcess", win32.GetLastError());
        defer win32.closeHandle(process_info.hThread.?);
        errdefer win32.closeHandle(process_info.hProcess.?);

        const job = win32.CreateJobObjectW(null, null) orelse return out_err.setWin32(
            "CreateJobObject",
            win32.GetLastError(),
        );
        errdefer win32.closeHandle(job);

        {
            var info = std.mem.zeroes(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            _ = win32.SetInformationJobObject(
                job,
                win32.JobObjectExtendedLimitInformation,
                &info,
                @sizeOf(@TypeOf(info)),
            );
        }

        _ = win32.AssignProcessToJobObject(job, process_info.hProcess);

        const suspend_count = win32.ResumeThread(process_info.hThread);
        if (suspend_count == -1) return out_err.setWin32("ResumeThread", win32.GetLastError());

        return .{
            .pty = .{
                .write = .{ .handle = input_pipe.write },
                .hpcon = hpcon,
            },
            .job = job,
            .process_handle = process_info.hProcess.?,
        };
    }

    pub fn deinit(self: *ChildProcess, terminate: bool) void {
        if (terminate) _ = win32.TerminateProcess(self.process_handle, 0);
        if (self.pty) |*child_pty| {
            child_pty.deinit();
            self.pty = null;
        }
        win32.closeHandle(self.job);
        win32.closeHandle(self.process_handle);
    }

    pub fn resize(self: *const ChildProcess, out_err: *Error, size: GridPos) error{Error}!void {
        const pty = self.pty orelse return;
        const hr = win32.ResizePseudoConsole(
            pty.hpcon,
            .{ .X = @intCast(size.col), .Y = @intCast(size.row) },
        );
        if (hr < 0) return out_err.setHresult("ResizePseudoConsole", hr);
    }

    fn setInherit(out_err: *Error, handle: win32.HANDLE, enable: bool) error{Error}!void {
        if (0 == win32.SetHandleInformation(
            handle,
            @bitCast(win32.HANDLE_FLAGS{ .INHERIT = 1 }),
            .{ .INHERIT = if (enable) 1 else 0 },
        )) return out_err.setWin32(
            "SetHandleInformation",
            win32.GetLastError(),
        );
    }

    fn createPipe(out_err: *Error, what: [:0]const u8) error{Error}!PipePair {
        var security_attributes: win32.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
            .bInheritHandle = 1,
            .lpSecurityDescriptor = null,
        };

        var read: win32.HANDLE = undefined;
        var write: win32.HANDLE = undefined;
        if (0 == win32.CreatePipe(@ptrCast(&read), @ptrCast(&write), &security_attributes, 0)) {
            return out_err.setWin32(what, win32.GetLastError());
        }
        return .{ .read = read, .write = write };
    }

    fn readConsoleThread(
        hwnd: win32.HWND,
        hwnd_msg: u32,
        generation: u32,
        read: win32.HANDLE,
    ) void {
        defer win32.closeHandle(read);
        while (true) {
            const payload = payload_pool.acquire();
            payload.generation = generation;

            var read_len: u32 = undefined;
            if (0 == win32.ReadFile(
                read,
                &payload.data,
                payload.data.len,
                &read_len,
                null,
            )) {
                const err = win32.GetLastError();
                releaseReadPayload(payload);
                if (err == .ERROR_BROKEN_PIPE) break;
                log.err("ReadFile failed: {any}", .{err});
                break;
            }
            if (read_len == 0) {
                releaseReadPayload(payload);
                break;
            }
            payload.len = read_len;

            if (0 == win32.PostMessageW(
                hwnd,
                hwnd_msg,
                @intFromPtr(payload),
                0,
            )) {
                releaseReadPayload(payload);
                break;
            }
        }
    }
};
