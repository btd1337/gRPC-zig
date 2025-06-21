const std = @import("std");
const GrpcClient = @import("client.zig").GrpcClient;
const GrpcServer = @import("server.zig").GrpcServer;
const json = std.json;

// Benchmark configuration
const BenchmarkConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 50051,
    num_requests: u32 = 1000,
    concurrent_clients: u32 = 10,
    request_size_bytes: u32 = 1024,
    warmup_requests: u32 = 100,
    secret_key: []const u8 = "benchmark-secret-key",
};

// Benchmark results structure
const BenchmarkResults = struct {
    total_requests: u32,
    successful_requests: u32,
    failed_requests: u32,
    total_duration_ms: f64,
    requests_per_second: f64,
    latency_stats: LatencyStats,
    error_rate: f64,
    timestamp: i64,

    const LatencyStats = struct {
        min_ms: f64,
        max_ms: f64,
        avg_ms: f64,
        p95_ms: f64,
        p99_ms: f64,
    };
};

// Simple benchmarking timer
const Timer = struct {
    start_time: i128,

    fn start() Timer {
        return Timer{
            .start_time = std.time.nanoTimestamp(),
        };
    }

    fn elapsed_ms(self: Timer) f64 {
        const end_time = std.time.nanoTimestamp();
        return @as(f64, @floatFromInt(end_time - self.start_time)) / 1_000_000.0;
    }
};

// Test client worker
const ClientWorker = struct {
    allocator: std.mem.Allocator,
    config: BenchmarkConfig,
    results: std.ArrayList(f64),

    fn init(allocator: std.mem.Allocator, config: BenchmarkConfig) ClientWorker {
        return ClientWorker{
            .allocator = allocator,
            .config = config,
            .results = std.ArrayList(f64).init(allocator),
        };
    }

    fn deinit(self: *ClientWorker) void {
        self.results.deinit();
    }

    fn runBenchmark(self: *ClientWorker) !void {
        var client = try GrpcClient.init(self.allocator, self.config.host, self.config.port);
        defer client.deinit();

        try client.setAuth(self.config.secret_key);

        // Generate test payload
        const payload = try self.generatePayload();
        defer self.allocator.free(payload);

        // Warmup requests
        for (0..self.config.warmup_requests) |_| {
            _ = client.call("Benchmark", payload, .none) catch continue;
        }

        // Actual benchmark requests
        for (0..self.config.num_requests) |_| {
            const timer = Timer.start();
            
            const response = client.call("Benchmark", payload, .none) catch |err| {
                std.log.warn("Request failed: {}", .{err});
                continue;
            };
            
            const elapsed = timer.elapsed_ms();
            try self.results.append(elapsed);
            
            self.allocator.free(response);
        }
    }

    fn generatePayload(self: *ClientWorker) ![]u8 {
        const payload = try self.allocator.alloc(u8, self.config.request_size_bytes);
        var prng = std.rand.DefaultPrng.init(@as(u64, @intCast(std.time.milliTimestamp())));
        const random = prng.random();
        
        for (payload) |*byte| {
            byte.* = random.int(u8);
        }
        
        return payload;
    }
};

fn calculateLatencyStats(latencies: []f64) BenchmarkResults.LatencyStats {
    if (latencies.len == 0) {
        return BenchmarkResults.LatencyStats{
            .min_ms = 0,
            .max_ms = 0,
            .avg_ms = 0,
            .p95_ms = 0,
            .p99_ms = 0,
        };
    }

    // Sort latencies for percentile calculations
    std.sort.pdq(f64, latencies, {}, comptime std.sort.asc(f64));

    var sum: f64 = 0;
    for (latencies) |lat| {
        sum += lat;
    }

    const p95_index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(latencies.len)) * 0.95));
    const p99_index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(latencies.len)) * 0.99));

    return BenchmarkResults.LatencyStats{
        .min_ms = latencies[0],
        .max_ms = latencies[latencies.len - 1],
        .avg_ms = sum / @as(f64, @floatFromInt(latencies.len)),
        .p95_ms = latencies[@min(p95_index, latencies.len - 1)],
        .p99_ms = latencies[@min(p99_index, latencies.len - 1)],
    };
}

fn runBenchmark(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResults {
    std.log.info("Starting benchmark with {} concurrent clients, {} requests each", .{ config.concurrent_clients, config.num_requests });

    var all_latencies = std.ArrayList(f64).init(allocator);
    defer all_latencies.deinit();

    const overall_timer = Timer.start();

    // Create and run client workers concurrently
    var workers = std.ArrayList(ClientWorker).init(allocator);
    defer {
        for (workers.items) |*worker| {
            worker.deinit();
        }
        workers.deinit();
    }

    // Initialize workers
    for (0..config.concurrent_clients) |_| {
        var worker = ClientWorker.init(allocator, config);
        try workers.append(worker);
    }

    // Run workers (simplified - in real implementation you'd use threads)
    var total_successful: u32 = 0;
    var total_failed: u32 = 0;

    for (workers.items) |*worker| {
        worker.runBenchmark() catch |err| {
            std.log.warn("Worker failed: {}", .{err});
            total_failed += config.num_requests;
            continue;
        };

        // Collect results
        for (worker.results.items) |latency| {
            try all_latencies.append(latency);
        }
        total_successful += @as(u32, @intCast(worker.results.items.len));
        total_failed += config.num_requests - @as(u32, @intCast(worker.results.items.len));
    }

    const total_duration = overall_timer.elapsed_ms();
    const total_requests = config.concurrent_clients * config.num_requests;
    const requests_per_second = @as(f64, @floatFromInt(total_successful)) / (total_duration / 1000.0);

    return BenchmarkResults{
        .total_requests = total_requests,
        .successful_requests = total_successful,
        .failed_requests = total_failed,
        .total_duration_ms = total_duration,
        .requests_per_second = requests_per_second,
        .latency_stats = calculateLatencyStats(all_latencies.items),
        .error_rate = @as(f64, @floatFromInt(total_failed)) / @as(f64, @floatFromInt(total_requests)),
        .timestamp = std.time.timestamp(),
    };
}

fn outputResults(allocator: std.mem.Allocator, results: BenchmarkResults, format: enum { json, text }) !void {
    switch (format) {
        .json => {
            const json_string = try json.stringifyAlloc(allocator, results, .{ .whitespace = .indent_2 });
            defer allocator.free(json_string);
            std.log.info("Benchmark Results (JSON):\n{s}", .{json_string});
        },
        .text => {
            std.log.info("Benchmark Results:");
            std.log.info("==================");
            std.log.info("Total Requests: {}", .{results.total_requests});
            std.log.info("Successful: {}", .{results.successful_requests});
            std.log.info("Failed: {}", .{results.failed_requests});
            std.log.info("Error Rate: {d:.2}%", .{results.error_rate * 100});
            std.log.info("Total Duration: {d:.2}ms", .{results.total_duration_ms});
            std.log.info("Requests/sec: {d:.2}", .{results.requests_per_second});
            std.log.info("Latency Stats:");
            std.log.info("  Min: {d:.2}ms", .{results.latency_stats.min_ms});
            std.log.info("  Max: {d:.2}ms", .{results.latency_stats.max_ms});
            std.log.info("  Avg: {d:.2}ms", .{results.latency_stats.avg_ms});
            std.log.info("  P95: {d:.2}ms", .{results.latency_stats.p95_ms});
            std.log.info("  P99: {d:.2}ms", .{results.latency_stats.p99_ms});
        },
    }
}

fn parseArgs(allocator: std.mem.Allocator) !struct { config: BenchmarkConfig, output_format: enum { json, text } } {
    var config = BenchmarkConfig{};
    var output_format: enum { json, text } = .text;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            config.host = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            config.port = try std.fmt.parseInt(u16, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--requests") and i + 1 < args.len) {
            config.num_requests = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--clients") and i + 1 < args.len) {
            config.concurrent_clients = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--size") and i + 1 < args.len) {
            config.request_size_bytes = try std.fmt.parseInt(u32, args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "json")) {
                output_format = .json;
            } else if (std.mem.eql(u8, args[i + 1], "text")) {
                output_format = .text;
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--help")) {
            printUsage();
            std.process.exit(0);
        }
    }

    return .{ .config = config, .output_format = output_format };
}

fn printUsage() void {
    std.log.info("gRPC-zig Benchmark Tool");
    std.log.info("Usage: benchmark [options]");
    std.log.info("");
    std.log.info("Options:");
    std.log.info("  --host <host>       Server host (default: localhost)");
    std.log.info("  --port <port>       Server port (default: 50051)");
    std.log.info("  --requests <n>      Number of requests per client (default: 1000)");
    std.log.info("  --clients <n>       Number of concurrent clients (default: 10)");
    std.log.info("  --size <bytes>      Request payload size (default: 1024)");
    std.log.info("  --output <format>   Output format: text|json (default: text)");
    std.log.info("  --help              Show this help message");
}

// Simple benchmark handler for testing
pub fn benchmarkHandler(request: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Echo the request back with a timestamp
    const response = try std.fmt.allocPrint(allocator, "Echo: {s} (processed at {})", .{ request, std.time.milliTimestamp() });
    return response;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed = try parseArgs(allocator);
    const config = parsed.config;
    const output_format = parsed.output_format;

    std.log.info("gRPC-zig Benchmark Tool");
    std.log.info("Configuration:");
    std.log.info("  Host: {s}:{}", .{ config.host, config.port });
    std.log.info("  Requests per client: {}", .{config.num_requests});
    std.log.info("  Concurrent clients: {}", .{config.concurrent_clients});
    std.log.info("  Request size: {} bytes", .{config.request_size_bytes});
    std.log.info("  Output format: {}", .{output_format});

    const results = try runBenchmark(allocator, config);
    try outputResults(allocator, results, output_format);
}