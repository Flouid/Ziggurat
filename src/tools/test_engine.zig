const std = @import("std");
const debug = @import("debug");
const utils = @import("utils");
const RefEngine = @import("ref_engine").TextEngine;
const NewEngine = @import("engine").TextEngine;


// -------------------- TEST FIXTURE IMPLEMENTATION --------------------

const Location = struct {
    // wraps a starting index and length for a text operation
    at: usize,
    len: usize,
};

const OPType = enum { I, D };

const TextOp = struct {
    // wraps an insert or a delete as a struct
    loc: Location,
    text: []const u8,
    op: OPType,

    fn initInsert(loc: Location, text: []const u8) TextOp {
        return TextOp{ .loc = loc, .text = text, .op = .I };
    }

    fn initDelete(loc: Location) TextOp {
        return TextOp{ .loc = loc, .text = undefined, .op = .D };
    }

    pub fn format(self: TextOp, writer: anytype) !void {
        switch (self.op) {
            .I => try writer.print("I {d} {d} : {s}", .{ self.loc.at, self.loc.len, self.text}),
            .D => try writer.print("D {d} {d}", .{ self.loc.at, self.loc.len }),
        }
    }
};

const TestFixture = struct {
    // encapsulates and owns all of the data to represent a test fixture in memory.
    init_text: []const u8,
    ops: []const TextOp,
    final_text: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) TestFixture {
        return .{
            .init_text = &.{},
            .ops = &.{},
            .final_text = &.{},
            .arena = std.heap.ArenaAllocator.init(parent),
        };
    }

    pub fn allocator(self: *TestFixture) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *TestFixture) void {
        self.arena.deinit();
    }
};

// -------------------- TEST RUNNER IMPLEMENTATION --------------------

fn replayWithEngine(comptime Engine: type, alloc: std.mem.Allocator, init_text: []const u8, ops: []const TextOp) ![]const u8 {
    var editor = try Engine.init(alloc, init_text);
    defer editor.deinit();

    var timer = try std.time.Timer.start();
    for (ops, 0..) |op, i| {
        if (i % 1000 == 0) try utils.printf("Performing Ops: {d: >7} / {d: >7}\r", .{ i, ops.len });
        switch(op.op) {
            .I => try editor.insert(op.loc.at, op.text),
            .D => try editor.delete(op.loc.at, op.loc.len),
        }
    }
    const run_ns = timer.read();
    try utils.printf("Performing Ops: {d: >7} / {d: >7} ... ", .{ ops.len, ops.len });
    try utils.printf("Completed in {d} ms\n", .{ run_ns / 1_000_000 });

    // deinit is handled when returning an owned slice
    var out_buf = std.ArrayList(u8).init(alloc);
    // making the output buffer big enough to hold the input text is probably a safe assumption
    try out_buf.ensureTotalCapacity(init_text.len);

    timer.reset();
    try editor.materialize(out_buf.writer());
    const write_ns = timer.read();
    try utils.printf("Editor materialized {d} bytes in {d} ms\n", .{ out_buf.items.len, write_ns / 1_000_000 });

    return try out_buf.toOwnedSlice();
}

// -------------------- TEST FIXTURE GENERATOR IMPLEMENTATION --------------------

const GenConfig = struct {
    seed: u64,
    n_ops: usize,
    p_insert: u8,
    p_long: u8
};

const MIN_EDIT_LEN = 1;
const MAX_EDIT_LEN = 8;
const LONG_MULT = 100;

fn getLoc(rng: *utils.RNG, is_long: bool, doc_len: usize) Location {
    // randomly sample any location inside the document.
    // suitable as-is for appends, deletes require OOB verification
    const at: usize = rng.randInt(usize, 0, doc_len + 1);
    var len: usize = undefined;
    if (!is_long) { len = rng.randInt(usize, MIN_EDIT_LEN, MAX_EDIT_LEN); } 
    else { len = rng.randInt(usize, MIN_EDIT_LEN * LONG_MULT, MAX_EDIT_LEN * LONG_MULT); }
    return .{ .at = at, .len = len };
}

fn getSafeLoc(rng: *utils.RNG, op_type: OPType, is_long: bool, doc_len: usize) Location {
    // helper to generate a safe location to perform any operation at
    switch (op_type) {
        .I => return getLoc(rng, is_long, doc_len),
        .D => {
            debug.dassert(doc_len != 0, "cannot delete from empty document");
            // choose [at, at+len) fully inside [0, doc_len)
            while (true) {
                const loc = getLoc(rng, is_long, doc_len);
                if (loc.len <= doc_len - loc.at) return loc;
            }
        },
    }
}

fn generateText(a: std.mem.Allocator, rng: *utils.RNG, loc: Location) ![]u8 {
    var buf = try a.alloc(u8, loc.len);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        // printable ASCII is [32, 127)
        buf[i] = rng.randInt(u8, 32, 127);
    }
    return buf;
}

fn generateOps(a: std.mem.Allocator, rng: *utils.RNG, cfg: GenConfig, init_doc_len: usize) !std.ArrayList(TextOp) {
    debug.dassert(cfg.p_insert <= 100, "p_insert must be an integer from 0 to 100");
    debug.dassert(cfg.p_long <= 100, "p_long must be an integer from 100");
    var out = std.ArrayList(TextOp).init(a);
    errdefer {
        for (out.items) |op| if (op.op == .I) a.free(op.text);
        out.deinit();
    }
    var exp_doc_len = init_doc_len;
    var timer = try std.time.Timer.start();
    for (0..cfg.n_ops) |i| {
        if (i % 1000 == 0) try utils.printf("Generating Ops: {d: >7} / {d: >7}\r", .{ i, cfg.n_ops });

        var op_type: OPType = undefined;
        if (exp_doc_len == 0 or rng.randInt(u8, 0, 100) < cfg.p_insert) {
            op_type = .I;
        } else op_type = .D;
        const is_long = rng.randInt(u8, 0, 100) < cfg.p_long;
        const loc = getSafeLoc(rng, op_type, is_long, exp_doc_len);
        switch (op_type) {
            .I => {
                const text = try generateText(a, rng, loc);
                try out.append(TextOp.initInsert(loc, text));
                exp_doc_len += loc.len;
            },
            .D => {
                try out.append(TextOp.initDelete(loc));
                exp_doc_len -= loc.len;
            },
        }
    }
    const gen_ns = timer.read();
    try utils.printf("Generating Ops: {d: >7} / {d: >7} ... ", .{ cfg.n_ops, cfg.n_ops });
    try utils.printf("Completed in {d} ms\n", .{ gen_ns / 1_000_000 });
    return out;
}

fn generateFixture(alloc: std.mem.Allocator, cfg: GenConfig, init_text: []const u8) !TestFixture {
    // initialize an empty fixture and it's arena
    var fixture = TestFixture.init(alloc);
    errdefer fixture.deinit();
    const a = fixture.allocator();
    
    // move init text and operations into fixture, carefully manage memory
    fixture.init_text = try a.dupe(u8, init_text);
    var rng = utils.RNG.init(cfg.seed);
    var ops = try generateOps(a, &rng, cfg, init_text.len);
    fixture.ops = try ops.toOwnedSlice();

    fixture.final_text = try replayWithEngine(RefEngine, a, fixture.init_text, fixture.ops);

    return fixture;
}

// -------------------- FILE IO IMPLEMENTATION --------------------

fn writeFileAlloc(file: std.fs.File, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try file.writeAll(s);
}

fn writeFixtureToPath(alloc: std.mem.Allocator, path: []const u8, fixture: *const TestFixture) !void {
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();

    var timer = try std.time.Timer.start();
    // write number of ops at head of file
    try writeFileAlloc(file, alloc, "{d}\n", .{ fixture.ops.len });
    // write a hex-converted version of the init file on the next line
    const init_hex = try utils.bytesToHexAlloc(alloc, fixture.init_text);
    defer alloc.free(init_hex);
    try writeFileAlloc(file, alloc, "{s}\n", .{ init_hex });
    // write a series of lines, one for each file op
    for (fixture.ops) |op| try writeFileAlloc(file, alloc, "{f}\n", .{ op });
    // finally, convert the result to hex and write that on that last line
    const final_hex = try utils.bytesToHexAlloc(alloc, fixture.final_text);
    defer alloc.free(final_hex);
    try writeFileAlloc(file, alloc, "{s}\n", .{ final_hex });
    const write_ns = timer.read();
    try utils.printf("Wrote fixture to output file in {d} ms\n", .{ write_ns / 1_000_000 });
}

inline fn trimCR(s: []const u8) []const u8 {
    // in case there are also carriage returns seperating files
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

fn parseInsertLine(arena: std.mem.Allocator, line_in: []const u8) !TextOp {
    const line = trimCR(line_in);

    // Find the first ':'
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MissingColon;

    // Left: "I <at> <len>"
    var left = std.mem.trim(u8, line[0..colon], " \t");
    if (!std.mem.startsWith(u8, left, "I ")) return error.BadInsertPrefix;

    var toks = std.mem.tokenizeAny(u8, left[2..], " \t");
    const at_s  = toks.next() orelse return error.BadInsertAt;
    const len_s = toks.next() orelse return error.BadInsertLen;
    const at  = try std.fmt.parseInt(usize, at_s, 10);
    const len = try std.fmt.parseInt(usize, len_s, 10);

    // Right: payload; allow optional single space after ':'
    var right = line[colon + 1 ..];
    if (right.len > 0 and right[0] == ' ') right = right[1..];

    // Validate length and charset
    if (right.len != len) return error.LengthMismatch;

    // Copy into arena
    const text = try arena.alloc(u8, len);
    @memcpy(text, right);

    return TextOp.initInsert(.{ .at = at, .len = len }, text);
}

fn parseDeleteLine(line_in: []const u8) !TextOp {
    const line = std.mem.trim(u8, trimCR(line_in), " \t");
    if (!std.mem.startsWith(u8, line, "D ")) return error.BadDeletePrefix;

    var toks = std.mem.tokenizeAny(u8, line[2..], " \t");
    const at_s  = toks.next() orelse return error.BadDeleteAt;
    const len_s = toks.next() orelse return error.BadDeleteLen;
    const at  = try std.fmt.parseInt(usize, at_s, 10);
    const len = try std.fmt.parseInt(usize, len_s, 10);

    return TextOp.initDelete(.{ .at = at, .len = len });
}

pub fn parseFixtureFromPath(parent_alloc: std.mem.Allocator, path: []const u8) !TestFixture {
    // 0) Read whole file with parent allocator, NOT arena
    const contents = try std.fs.cwd().readFileAlloc(parent_alloc, path, 1 << 30);
    defer parent_alloc.free(contents);

    // 1) Create fixture + arena
    var fixture = TestFixture.init(parent_alloc);
    errdefer fixture.deinit();
    const a = fixture.allocator();

    // 2) Iterate lines
    var it = std.mem.splitScalar(u8, contents, '\n');

    // -- line 1: n_ops
    const l1_raw = it.next() orelse return error.EmptyFile;
    const l1 = std.mem.trim(u8, trimCR(l1_raw), " \t");
    const n_ops = std.fmt.parseInt(usize, l1, 10) catch return error.MissingOps;

    // -- line 2: init hex
    const l2_raw = it.next() orelse return error.MissingInit;
    const l2 = std.mem.trim(u8, trimCR(l2_raw), " \t");
    fixture.init_text = try utils.hexToBytesAlloc(a, l2);

    // -- lines 3..: exactly n_ops ops
    var ops_buf = std.ArrayList(TextOp).init(a);
    errdefer ops_buf.deinit();

    var read_ops: usize = 0;
    while (read_ops < n_ops) {
        const line_raw = it.next() orelse return error.TooFewOps;
        const line = trimCR(line_raw);
        if (line.len == 0) continue; // tolerate blank lines if needed

        const op = switch (line[0]) {
            'I' => try parseInsertLine(a, line),
            'D' => try parseDeleteLine(line),
            else => return error.UnknownLine,
        };
        try ops_buf.append(op);
        read_ops += 1;
    }
    fixture.ops = try ops_buf.toOwnedSlice();

    // -- last: final hex
    const final_raw = it.next() orelse return error.MissingFinal;
    const final_line = std.mem.trim(u8, trimCR(final_raw), " \t");
    fixture.final_text = try utils.hexToBytesAlloc(a, final_line);

    return fixture;
}


// -------------------- CLI IMPLEMENTATION --------------------

fn printUsage(cmd: [:0]u8) !void {
    try utils.printf("There are three accepted usage cases:\n", .{});
    try utils.printf("\tgenerate fixture:\t{s} generate <path_in> <insert %> <long %> <# ops> <path_out>\n", .{ cmd });
    try utils.printf("\ttest with fixture:\t{s} test <path_in>\n", .{ cmd });
    try utils.printf("\ttest all fixtures:\t{s} test all\n", .{ cmd });
}

pub fn fixtureGeneration(a: std.mem.Allocator, args: [][:0]u8) !void {
    const path_in = args[2];
    const path_out = args[6];
    const cfg = GenConfig{ 
        .seed = 0xdead_beef_dead_beef, 
        .p_insert = try std.fmt.parseInt(u8, args[3], 10),
        .p_long = try std.fmt.parseInt(u8, args[4], 10),
        .n_ops = try std.fmt.parseInt(usize, args[5], 10),
    };

    // read the input file
    const init = try std.fs.cwd().readFileAlloc(a, path_in, 1 << 30); // 1 GiB MiB max
    defer a.free(init);
    // use it to generate a new test fixture
    var fixture = try generateFixture(a, cfg, init);
    defer fixture.deinit();
    // write the fixture to the given path
    try writeFixtureToPath(a, path_out, &fixture);
}

pub fn testFixture(a: std.mem.Allocator, path_in: []const u8) !bool {
    try utils.printf("Parsing {s} ... ", .{ path_in });
    var timer = try std.time.Timer.start();
    var fixture = try parseFixtureFromPath(a, path_in);
    defer fixture.deinit();
    const parse_ns = timer.read();
    try utils.printf("Completed in {d} ms\n", .{ parse_ns / 1_000_000 });

    const final_text = try replayWithEngine(NewEngine, a, fixture.init_text, fixture.ops);
    defer a.free(final_text);
    const match = std.mem.eql(u8, fixture.final_text, final_text);

    if (match) { try utils.printf("Match!\n", .{}); }
    else { try utils.printf("TEST FAILED!\n", .{}); }
    return match;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 3 and args.len != 7) {
        try printUsage(args[0]);
        return;
    }
    const mode = args[1];
    if (!std.mem.eql(u8, mode, "generate") and !std.mem.eql(u8, mode, "test")) {
        try utils.printf("Error: unrecognized mode!\n", .{});
        try printUsage(args[0]);
        return;
    } else if (std.mem.eql(u8, mode, "generate") and args.len != 7) {
        try utils.printf("Error: expected 7 args for generate\n", .{});
        try printUsage(args[0]);
        return;
    } else if (std.mem.eql(u8, mode, "test") and args.len != 3) {
        try utils.printf("Error: expected 3 args for test\n", .{});
        try printUsage(args[0]);
        return;
    }

    if (args.len == 7) { try fixtureGeneration(alloc, args); }
    else if (std.mem.eql(u8, "all", args[2])) {
        var cwd = try std.fs.cwd().openDir("fixtures", .{ .iterate = true });
        defer cwd.close();
        var it = cwd.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    if (!std.mem.endsWith(u8, entry.name, "test.txt")) continue;
                    const rel_path = try std.fmt.allocPrint(alloc, "./fixtures/{s}", .{ entry.name });
                    defer alloc.free(rel_path);
                    _ = try testFixture(alloc, rel_path);
                },
                else => {},
            }
        }
    } else { _ = try testFixture(alloc, args[2]); }
}