const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const STACK_CAPACITY = 1024;

const alloc = std.heap.page_allocator;
var coros: ArrayList(*Context) = ArrayList(*Context).init(alloc);
var garbage: ArrayList(*Context) = ArrayList(*Context).init(alloc);
var curr: usize = 0;

const Context = struct {
    rsp: usize = 0,
    stack: [STACK_CAPACITY / 8]usize = undefined,
    completed: bool = true,

    const Self = @This();

    fn init(self: *Self, func: *fn () void) void {
        @memset(&self.stack, 0);

        self.stack[self.stack.len - 1] = @intFromPtr(&finish);
        self.stack[self.stack.len - 7] = @intFromPtr(func);
        self.rsp = @intFromPtr(&self.stack) + STACK_CAPACITY - (8 * 8);
        self.completed = false;
    }
};

fn init() void {
    const ctx = alloc.create(Context) catch unreachable;
    coros.append(ctx) catch unreachable;
}

fn deinit() void {
    coros.deinit();
    garbage.deinit();
}

fn create(func: fn () void) void {
    const ctx = alloc.create(Context) catch unreachable;
    ctx.init(@constCast(&func));
    coros.append(ctx) catch unreachable;
}

fn next() usize {
    curr += 1;
    if (curr >= coros.items.len) {
        curr = 0;
    }
    return curr;
}

fn run() void {
    while (coros.items.len > 1) {
        yeild();
        while (garbage.items.len > 0) {
            const ctx = garbage.pop();
            alloc.destroy(ctx);
        }
    }
}

inline fn yeild() void {
    asm volatile (
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ push %rbx
    );

    yeild_intern(false);
}

fn yeild_intern(only_restore: bool) void {
    if (!only_restore) {
        var ctx: *Context = coros.items[curr];
        ctx.rsp = asm volatile (""
            : [ret] "={rbp}" (-> usize),
        );
    }

    const idx = next();
    var ctx = coros.items[idx];
    if (ctx.completed) {
        ctx = coros.items[0];
    }

    asm volatile (
        \\ pop %rbp
        \\ pop %r10
        \\ pop %rbx
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ push %r10
        \\ ret
        :
        : [rsp] "{rsp}" (ctx.rsp),
    );
}

fn finish() void {
    const ctx = coros.swapRemove(curr);
    garbage.append(ctx) catch unreachable;
    yeild_intern(true);
}

fn print(arg: []const u8) void {
    const SYS_WRITE: usize = 1;
    const STDOUT_FILENO: usize = 1;

    _ = asm volatile ("syscall"
        : [ret] "={rax}" (-> usize),
        : [SYS_WRITE] "{rax}" (SYS_WRITE),
          [STDOUT_FILENO] "{rdi}" (STDOUT_FILENO),
          [data] "{rsi}" (arg.ptr),
          [len] "{rdx}" (arg.len),
        : "rcx", "r11"
    );
}

fn counter(len: usize) void {
    for (0..len) |i| {
        const v: [2]u8 = .{ @as(u8, @truncate(i + 48)), '\n' };
        print(&v);
        yeild();
    }
}

pub fn main() !void {
    init();
    defer deinit();

    create(struct {
        fn f() void {
            counter(10);
        }
    }.f);
    create(struct {
        fn f() void {
            counter(6);
        }
    }.f);
    create(struct {
        fn f() void {
            counter(12);
        }
    }.f);
    run();
}
