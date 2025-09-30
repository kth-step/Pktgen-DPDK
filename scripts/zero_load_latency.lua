-- Improved pktgen configuration for latency testing
-- TODO: This is currently also doing packet capturing for debug purposes, commment out when no longer needed
package.path = package.path ..";?.lua;test/?.lua;app/?.lua;"

require "Pktgen";

-- Function to dump all statistics for debugging
function dump_stats(port)
    local stats = pktgen.portStats(port, "port");
    printf("\nDumping all port stats for debugging:\n");
    for k,v in pairs(stats) do
        if type(v) == "table" then
            printf("  %s: (table)\n", k);
            for k2,v2 in pairs(v) do
                printf("    %s: %s\n", k2, tostring(v2));
            end
        else
            printf("  %s: %s\n", k, tostring(v));
        end
    end
end

-- Function to run a latency test with a specific packet size
function run_test(size,iterations)
    printf("\nRunning latency test with %d byte packets...\n", size);

    -- Reset stats before test
    pktgen.stop("all");
    pktgen.clr();
    
    -- count 0 will send max packets, count 1 will send only 1
    pktgen.set("0", "count", 1);
    -- rate 0 will send max packets, rate 1 will send only 1
    -- pktgen.set("0", "rate", 0.00001);
    pktgen.set("0", "size", size);

    -- TODO: Use default ones instead?
    -- Set IP addresses
    pktgen.set_ipaddr("0", "src", "10.0.0.1/24");
    pktgen.set_ipaddr("0", "dst", "10.0.0.2");
    pktgen.set_ipaddr("1", "src", "10.0.0.2/24");
    pktgen.set_ipaddr("1", "dst", "10.0.0.1");
    pktgen.set_proto("all", "udp");

    pktgen.delay(1000);

    -- Enable latency
    pktgen.latency("0", "enable");
    pktgen.latency("0", "rate", 1000);
    pktgen.latency("0", "entropy", 12);
    pktgen.latency("1", "enable");
    pktgen.latency("1", "rate", 10000);
    pktgen.latency("1", "entropy", 8);
    
    -- Additional settings to help with measurement
    -- pktgen.set("all", "count", 1000);  -- Send exactly 1000 packets
    
    -- Short delay to ensure settings are applied
    -- pktgen.sleep(1);
    pktgen.delay(1000);
    
    -- pktgen.capture("0", "enable");
    -- pktgen.capture("1", "enable");
    
    -- Start sending packets on port 0 only (to measure one-way)
    printf("Starting traffic...\n");
    for i = 1, iterations, 1 do
        pktgen.start("0");
        
        -- Wait for packets to be sent and processed
        pktgen.sleep(2);
        
        -- Stop traffic
        pktgen.stop("all");
    end

    -- pktgen.capture("0", "disable");
    -- pktgen.capture("1", "disable");

    -- Dump all stats for port 1 (receiving port)
    dump_stats("1");

    -- Get and display stats
    local port_stats = pktgen.pktStats("1");
    if port_stats and port_stats[tonumber("1")] and port_stats[tonumber("1")].latency then
        local lat = port_stats[tonumber("1")].latency;
        local avg_cycles = lat.avg_cycles or 0;
        local avg_us = lat.avg_us or 0;
        local min_us = lat.min_us or 0;
        local max_us = lat.max_us or 0;
        local jitter_us = lat.jitter_us or 0;
        
        -- Show latency stats
        printf("\n=== Latency Results for %d byte packets ===\n", size);
        printf("%10s %10s %10s %10s %10s\n", "min_us", "avg_us", "max_us", "jitter_us", "avgCycles");
        printf("%10.2f %10.2f %10.2f %10.2f %10d\n", min_us, avg_us, max_us, jitter_us, avg_cycles);

        pktgen.latency("0", "disable");
        pktgen.latency("1", "disable");
        
        return {
            size = size,
            min_us = min_us,
            avg_us = avg_us,
            max_us = max_us,
            jitter_us = jitter_us,
            avg_cycles = avg_cycles
        };
    else
        printf("No latency statistics available for %d byte packets\n", size);
        return nil;
    end
end

function main()
    -- Wait for initialization
    pktgen.sleep(3);
    printf("Starting latency tests...\n");
    
    -- Run tests with different packet sizes to compare with ping results
    local results = {};

    -- For tests of VSS with varying table sizes
    local sizes = {1518};
    -- local iterations = 50

    -- For generic zero-load latency tests
    -- local sizes = {64, 128, 256, 512, 1024, 1280, 1518};
    local iterations = 30
    
    for _, size in ipairs(sizes) do
        table.insert(results, run_test(size, iterations));
        pktgen.sleep(1);  -- Pause between tests
    end
    
    -- Print summary of all results
    printf("\n=== Summary of All Tests ===\n");
    printf("%10s %10s %10s %10s %10s\n", "Size", "Min (us)", "Avg (us)", "Max (us)", "Jitter (us)");
    for _, result in ipairs(results) do
        if result then
            printf("%10d %10.2f %10.2f %10.2f %10.2f\n", 
                   result.size, result.min_us, result.avg_us, result.max_us, result.jitter_us);
        end
    end
    
    -- Return to interactive mode
    printf("\nTests completed. You can now interact with pktgen or press Ctrl+C to exit.\n");
    return 0;
end

main()
