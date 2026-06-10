-- Zero-load latency test for Pktgen-DPDK 26.03.0
--
-- API confirmed by probing this exact build (not the repo scripts, which have
-- drifted): latency data is NOT readable from any stats getter — portStats and
-- portInfo carry no latency table, and pktStats does not exist. The only
-- programmatic path is the latency sampler, which writes raw per-packet
-- samples to a file that we then parse.
--
-- Confirmed calls:
--   pktgen.latency(port, "enable" | "disable")
--   pktgen.latency(port, "rate", N)            -- latency pkt injection rate ('page lat' Rate)
--   pktgen.latency(port, "entropy", N)         -- entropy ('page lat' Entropy)
--   pktgen.latsampler_params(portlist, "simple", num_samples, sample_rate, filepath)
--   pktgen.latsampler(portlist, "start")       -- arm
--   pktgen.latsampler(portlist, "stop")        -- stop + dump file
--
-- Sample file format: line 1 is the header "Latency"; each following line is
-- one latency sample in NANOSECONDS (confirmed against the 'page lat' us figures).

package.path = package.path .. ";?.lua;test/?.lua;app/?.lua;../?.lua"
require "Pktgen";

-- ----- configuration -------------------------------------------------------
local sendport = "0";
local recvport = "1";

local srcip   = "10.0.0.1";
local dstip   = "10.0.0.2";
local netmask = "/24";

-- Packet sizes to sweep. Latency needs room for the timestamp, so sizes below
-- ~96 B are skipped (64 B can't carry a valid timestamp on this build).
local pkt_sizes = { 1518 };
-- local pkt_sizes = { 128, 256, 512, 1024, 1280, 1518 };
local LAT_MIN_SIZE = 96;

local tx_rate     = 0.01;        -- TX rate, % of line rate (keep low: loss skews latency)
local lat_rate    = 256;      -- latency packet injection rate
local entropy     = 12;       -- latency entropy
local num_samples = 1000;    -- samples to capture per size
local sample_rate = 256;      -- sampler collection rate
local run_ms      = 5000;     -- transmit window per size
local pauseTime   = 1000;     -- settle time (ms)

local NS_PER_US = 1000.0;     -- sample file values are nanoseconds

-- ----- helpers -------------------------------------------------------------
local function setupTraffic()
    pktgen.set_ipaddr(sendport, "dst", dstip);
    pktgen.set_ipaddr(sendport, "src", srcip .. netmask);
    pktgen.set_ipaddr(recvport, "dst", srcip);
    pktgen.set_ipaddr(recvport, "src", dstip .. netmask);
    pktgen.set_proto(sendport .. "," .. recvport, "udp");
    pktgen.set(sendport, "count", 0);    -- continuous stream
end

-- Parse a sampler dump: skip the "Latency" header, collect integers (ns).
local function parseSamples(path)
    local f = io.open(path, "r");
    if not f then return nil; end
    local vals = {};
    local first = true;
    for line in f:lines() do
        if first then
            first = false;               -- discard header
        else
            local v = tonumber(line);
            if v then vals[#vals + 1] = v; end
        end
    end
    f:close();
    return vals;
end

local function percentile(sorted, p)
    local n = #sorted;
    if n == 0 then return 0; end
    local idx = math.ceil((p / 100.0) * n);
    if idx < 1 then idx = 1; end
    if idx > n then idx = n; end
    return sorted[idx];
end

-- Reduce raw ns samples to a stats table in microseconds.
local function summarize(vals)
    local n = #vals;
    if n == 0 then return nil; end
    local sum, vmin, vmax = 0, math.huge, -math.huge;
    for _, v in ipairs(vals) do
        sum = sum + v;
        if v < vmin then vmin = v; end
        if v > vmax then vmax = v; end
    end
    table.sort(vals);
    return {
        n      = n,
        min_us = vmin / NS_PER_US,
        avg_us = (sum / n) / NS_PER_US,
        max_us = vmax / NS_PER_US,
        p90_us = percentile(vals, 90) / NS_PER_US,
        p95_us = percentile(vals, 95) / NS_PER_US,
        p99_us = percentile(vals, 99) / NS_PER_US,
    };
end

local function runTest(pkt_size)
    if pkt_size < LAT_MIN_SIZE then
        printf("Skipping %d B: latency needs size >= %d B\n", pkt_size, LAT_MIN_SIZE);
        return nil;
    end

    local file = string.format("./lat_samples_%d.txt", pkt_size);

    pktgen.clr();
    pktgen.set(sendport, "rate", tx_rate);
    pktgen.set(sendport, "size", pkt_size);

    -- latency config on both ports
    pktgen.latency(sendport, "enable");
    pktgen.latency(recvport, "enable");
    pktgen.latency(sendport, "rate", lat_rate);
    pktgen.latency(recvport, "rate", lat_rate);
    pktgen.latency(sendport, "entropy", entropy);
    pktgen.latency(recvport, "entropy", entropy);

    -- sampler captures on the receive port and dumps to file on stop
    pktgen.latsampler_params(recvport, "simple", num_samples, sample_rate, file);

    pktgen.delay(1000);

    printf("Size %d B: capturing up to %d samples...\n", pkt_size, num_samples);
    pktgen.latsampler(recvport, "start");
    pktgen.start(sendport);
    pktgen.delay(run_ms);
    pktgen.stop(sendport);
    pktgen.latsampler(recvport, "stop");      -- dumps file
    pktgen.delay(pauseTime);

    pktgen.latency(sendport, "disable");
    pktgen.latency(recvport, "disable");

    local vals = parseSamples(file);
    if not vals or #vals == 0 then
        printf("No samples captured for %d B (file: %s).\n", pkt_size, file);
        printf("  Check that the far end is looping packets back to port %s.\n", recvport);
        return nil;
    end

    local s = summarize(vals);
    s.size = pkt_size;

    printf("\n=== Latency for %d B (%d samples) ===\n", pkt_size, s.n);
    printf("%10s %10s %10s %10s %10s %10s\n",
           "min_us", "avg_us", "max_us", "p90_us", "p95_us", "p99_us");
    printf("%10.3f %10.3f %10.3f %10.3f %10.3f %10.3f\n",
           s.min_us, s.avg_us, s.max_us, s.p90_us, s.p95_us, s.p99_us);

    return s;
end

function main()
    local results = {};
    setupTraffic();
    pktgen.delay(1000);

    for _, size in pairs(pkt_sizes) do
        local r = runTest(size);
        if r then table.insert(results, r); end
        pktgen.delay(pauseTime);
    end

    printf("\n=== Summary of All Tests (microseconds) ===\n");
    printf("%8s %10s %10s %10s %10s %10s %10s\n",
           "Size", "Min", "Avg", "Max", "p90", "p95", "p99");
    for _, r in ipairs(results) do
        printf("%8d %10.3f %10.3f %10.3f %10.3f %10.3f %10.3f\n",
               r.size, r.min_us, r.avg_us, r.max_us, r.p90_us, r.p95_us, r.p99_us);
    end

    printf("\nDone. Raw samples saved as ./lat_samples_<size>.txt\n");
end

main();