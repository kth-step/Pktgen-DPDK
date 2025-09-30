-- RFC2544 Throughput Test
-- as defined by https://www.ietf.org/rfc/rfc2544.txt
--  SPDX-License-Identifier: BSD-3-Clause

package.path = package.path ..";?.lua;test/?.lua;app/?.lua;../?.lua"

require "Pktgen";

-- define packet sizes to test
-- RFC2544:
local pkt_sizes		= { 64, 128, 256, 512, 1024, 1280, 1518 };
-- Quick test:
-- local pkt_sizes		= { 1518 };

-- Time in seconds to transmit for
-- RFC2544:
-- local duration		= 10000;
-- local confirmDuration	= 60000;
-- local pauseTime		= 1000;
-- Quick version:
local duration		= 1000;
local confirmDuration	= 3000;
local pauseTime		= 1000;

-- define the ports in use
local sendport		= "0";
local recvport		= "1";

-- ip addresses to use
local srcip		= "10.0.0.1";
local dstip		= "10.0.0.2";
local netmask		= "/24";

-- RFC2544:
-- local initialRate	= 50;
-- For HOL4P4 and BMv2
local initialRate	= 3;
-- For HOL4P4 with Google FBR program
-- local initialRate	= 0.1;
-- for petr4
-- local initialRate	= 0.001;

local function setupTraffic()
	pktgen.set_ipaddr(sendport, "dst", dstip);
	pktgen.set_ipaddr(sendport, "src", srcip..netmask);

	pktgen.set_ipaddr(recvport, "dst", srcip);
	pktgen.set_ipaddr(recvport, "src", dstip..netmask);

	pktgen.set_proto(sendport..","..recvport, "udp");
	-- set Pktgen to send continuous stream of traffic
	pktgen.set(sendport, "count", 0);
end

local function runTrial(pkt_size, rate, duration, count)
	local num_tx, num_rx, num_dropped;

	pktgen.clr();
	pktgen.set(sendport, "rate", rate);
	pktgen.set(sendport, "size", pkt_size);

	pktgen.start(sendport);
	print("Running trial " .. count .. ". % Rate: " .. rate .. ". Packet Size: " .. pkt_size .. ". Duration (ms):" .. duration);
	file:write("Running trial " .. count .. ". % Rate: " .. rate .. ". Packet Size: " .. pkt_size .. ". Duration (ms):" .. duration .. "\n");
	pktgen.delay(duration);
	pktgen.stop(sendport);

	pktgen.delay(pauseTime);

	statTx = pktgen.portStats(sendport, "port")[tonumber(sendport)];
	statRx = pktgen.portStats(recvport, "port")[tonumber(recvport)];
	num_tx = statTx.opackets;
	num_rx = statRx.ipackets;
	num_dropped = num_tx - num_rx;

	print("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped);
	file:write("Tx: " .. num_tx .. ". Rx: " .. num_rx .. ". Dropped: " .. num_dropped .. "\n");
	pktgen.delay(pauseTime);

	return num_dropped;
end

local function runThroughputTest(pkt_size)
	local num_dropped, max_rate, min_rate, trial_rate;

	-- max_rate = 100;
	-- min_rate = 1;
	-- For HOL4P4 and BMv2
	max_rate = 3;
	min_rate = 0.001;
	-- For Google FBR program
	-- max_rate = 0.1;
	-- min_rate = 0.0001;
	-- For petr4
	-- max_rate = 0.01;
	-- vss:
	-- max_rate = 0.001;
	-- min_rate = 0.00001;
	trial_rate = initialRate;
	for count=1, 10, 1
	do
		num_dropped = runTrial(pkt_size, trial_rate, duration, count);
		-- In case additional stray packets appear, we allow for this (e.g., num_dropped is -1)
		if num_dropped <= 0
		then
			min_rate = trial_rate;
		else
			max_rate = trial_rate;
		end
		trial_rate = min_rate + ((max_rate - min_rate)/2);
	end

	-- Ensure we test confirmation run with the last succesful zero-drop rate
	trial_rate = min_rate;

	-- confirm throughput rate for at least 60 seconds
	num_dropped = runTrial(pkt_size, trial_rate, confirmDuration, "Confirmation");
	-- In case additional stray packets appear, we allow for this (e.g., num_dropped is -1)
	if num_dropped <= 0
	then
		print("Max rate for packet size "  .. pkt_size .. "B is: " .. trial_rate);
		file:write("Max rate for packet size "  .. pkt_size .. "B is: " .. trial_rate .. "\n\n");
	else
		print("Max rate of " .. trial_rate .. "% could not be confirmed for 60 seconds as required by RFC 2544.");
		file:write("Max rate of " .. trial_rate .. "% could not be confirmed for 60 seconds as required by RFC 2544." .. "\n\n");
	end
	
  local statTx = pktgen.portStats(sendport, "port")[tonumber(sendport)]
  local packets = statTx.opackets
  local mbits = (statTx.obytes * 8) / 1000000
	
  return {
    size = pkt_size,
    rate_relative = trial_rate,
    pps = packets,
    mbps = mbits
  };
end

function main()
  local results = {};
	file = io.open("./RFC2544_throughput_results.txt", "w");
	setupTraffic();
	for _,size in pairs(pkt_sizes)
	do
	  table.insert(results, runThroughputTest(size));
	end
	file:close();
	
  -- Print summary of all results
  printf("\n=== Summary of All Tests ===\n");
  printf("%10s %10s %10s %10s\n", "Size", "Pktgen Rate (%)", "Rate (pps)", "Rate (Mbps)");
  for _, result in ipairs(results) do
      if result then
          printf("%10d %10.2f %10.2f %10.2f\n", 
                 result.size, result.rate_relative, result.pps / (confirmDuration / 1000), result.mbps / (confirmDuration / 1000));
      end
  end
end

main();
