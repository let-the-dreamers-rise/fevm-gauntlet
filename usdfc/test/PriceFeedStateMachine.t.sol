// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import "../upstream/contracts/PriceFeed.sol";

/// Chainlink-compatible aggregator whose answer the handler controls (stands in for the RedStone feed on mainnet).
contract MockAggregator {
    uint80 public roundId = 1;
    int256 public answer = 5e7; // 0.50 USD, 8 decimals like the mainnet feed
    uint256 public updatedAt;
    uint8 public dec = 8;
    bool public reverts;
    function set(int256 a, uint256 t, uint80 r, bool rev) external { answer = a; updatedAt = t; roundId = r; reverts = rev; }
    function decimals() external view returns (uint8) { require(!reverts, "agg down"); return dec; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "agg down");
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }
}

contract MockTellorCaller {
    bool public ok = true;
    uint256 public value = 5e17; // 18 decimals
    uint256 public ts;
    bool public reverts;
    function set(bool o, uint256 v, uint256 t, bool rev) external { ok = o; value = v; ts = t; reverts = rev; }
    function getTellorCurrentValue() external view returns (bool, uint256, uint256) {
        require(!reverts, "tellor down");
        return (ok, value, ts);
    }
}

/// Minimal proxy so the upgradeable PriceFeed can be initialized like on mainnet.
contract Proxy {
    bytes32 constant SLOT = keccak256("fevm-gauntlet.proxy.impl");
    constructor(address impl) { bytes32 s = SLOT; assembly { sstore(s, impl) } }
    fallback() external payable {
        bytes32 s = SLOT;
        assembly {
            let impl := sload(s)
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
        }
    }
}

contract PFHandler is Test {
    PriceFeed public pf;
    MockAggregator public agg;
    MockTellorCaller public tel;
    uint256 public constant ORACLE_TIMEOUT = 16 hours; // mainnet value
    uint256 public constant LGP_TIMEOUT = 2 days; // mainnet value
    uint256 public lastTs; // lastGoodPriceTimestamp seen last time
    mapping(bytes32 => uint256) public calls;

    constructor() {
        agg = new MockAggregator();
        tel = new MockTellorCaller();
        agg.set(5e7, block.timestamp, 1, false);
        tel.set(true, 5e17, block.timestamp, false);
        PriceFeed impl = new PriceFeed(ORACLE_TIMEOUT, LGP_TIMEOUT);
        pf = PriceFeed(address(new Proxy(address(impl))));
        pf.initialize(address(agg), address(tel));
        lastTs = pf.lastGoodPriceTimestamp();
    }

    /// Move the primary oracle: fresh, stale, broken (0/negative, future timestamp, round 0, reverting), or a jump.
    function primary(uint8 mode, uint256 pct, uint256 age) external {
        int256 base = int256(_scaled() / 1e10);
        if (base <= 0) base = 5e7;
        pct = bound(pct, 1, 300); // new price = base * pct / 100
        age = bound(age, 0, 3 days);
        uint256 t = block.timestamp > age ? block.timestamp - age : 0;
        mode = mode % 6;
        if (mode == 0) agg.set(base * int256(pct) / 100, block.timestamp, agg.roundId() + 1, false); // fresh
        else if (mode == 1) agg.set(agg.answer(), t, agg.roundId(), false); // ageing
        else if (mode == 2) agg.set(0, block.timestamp, agg.roundId() + 1, false); // broken answer
        else if (mode == 3) agg.set(agg.answer(), block.timestamp + 1 + age, agg.roundId() + 1, false); // future timestamp
        else if (mode == 4) agg.set(agg.answer(), agg.updatedAt(), agg.roundId(), true); // reverts
        else agg.set(agg.answer(), agg.updatedAt(), agg.roundId(), false); // comes back
        calls["primary"]++;
    }

    function fallbackOracle(uint8 mode, uint256 pct, uint256 age) external {
        uint256 base = tel.value() == 0 ? 5e17 : tel.value();
        pct = bound(pct, 1, 300);
        age = bound(age, 0, 3 days);
        uint256 t = block.timestamp > age ? block.timestamp - age : 0;
        mode = mode % 5;
        if (mode == 0) tel.set(true, base * pct / 100, block.timestamp, false);
        else if (mode == 1) tel.set(true, tel.value(), t, false);
        else if (mode == 2) tel.set(false, 0, tel.ts(), false);
        else if (mode == 3) tel.set(tel.ok(), tel.value(), tel.ts(), true);
        else tel.set(true, tel.value(), tel.ts(), false);
        calls["fallback"]++;
    }

    /// Both oracles report the same fresh price (within 5%): the system must be able to return to the primary oracle.
    function agree(uint256 price, uint256 spreadBps) external {
        price = bound(price, 1e6, 1e10); // 0.01 .. 100 USD, 8 decimals
        spreadBps = bound(spreadBps, 0, 400); // < 5%
        agg.set(int256(price), block.timestamp, agg.roundId() + 1, false);
        tel.set(true, price * 1e10 * (10000 + spreadBps) / 10000, block.timestamp, false);
        (uint256 p, IPriceFeed.PriceSource src) = _fetch();
        // Liveness: two live, agreeing oracles always restore the primary oracle, whatever state the feed was in.
        assertEq(uint256(src), uint256(IPriceFeed.PriceSource.primaryOracle), "agree: primary not restored");
        assertEq(uint256(pf.status()), 0, "agree: status not chainlinkWorking");
        assertEq(p, price * 1e10, "agree: price is not the primary price");
        calls["agree"]++;
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 30, 3 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 30);
        calls["warp"]++;
    }

    function fetch() external {
        _fetch();
        calls["fetch"]++;
    }

    function _scaled() internal view returns (uint256) {
        int256 a = agg.answer();
        return a > 0 ? uint256(a) * 1e10 : 0;
    }

    function _fetch() internal returns (uint256 p, IPriceFeed.PriceSource src) {
        uint256 lgpTsBefore = pf.lastGoodPriceTimestamp();
        uint256 statusBefore = uint256(pf.status());
        try pf.fetchPriceWithSource() returns (uint256 price, IPriceFeed.PriceSource s) {
            p = price;
            src = s;
        } catch Error(string memory why) {
            // The only allowed revert is a stale last good price.
            assertEq(why, "PriceFeed: lastGoodPrice is too old", "fetch reverted for another reason");
            assertGt(block.timestamp - lgpTsBefore, LGP_TIMEOUT, "fetch reverted before LAST_GOOD_PRICE_TIMEOUT");
            calls["fetch.stale"]++;
            (p, src) = pf.fetchPriceWithSourceView();
            return (p, src);
        }
        assertGt(p, 0, "price is zero");
        if (src == IPriceFeed.PriceSource.lastGoodPrice) {
            assertLe(block.timestamp - pf.lastGoodPriceTimestamp(), LGP_TIMEOUT, "stale lastGoodPrice served by fetchPrice");
        }
        if (statusBefore != 0 && uint256(pf.status()) == 0) {
            // Returning to the primary oracle needs both oracles live and within 5% of each other.
            uint256 c = _scaled();
            uint256 v = tel.value();
            uint256 lo = c < v ? c : v;
            uint256 hi = c < v ? v : c;
            assertLe((hi - lo) * 1e18 / lo, 5e16, "returned to primary while oracles disagree by more than 5%");
            assertLe(block.timestamp - tel.ts(), ORACLE_TIMEOUT, "returned to primary with a frozen fallback");
        }
        assertEq(p, pf.lastGoodPrice(), "returned price != lastGoodPrice");
        if (src == IPriceFeed.PriceSource.primaryOracle) {
            assertEq(p, _scaled(), "primary source but not the primary price");
            assertLe(agg.updatedAt(), block.timestamp, "primary price from the future");
            assertLe(block.timestamp - agg.updatedAt(), ORACLE_TIMEOUT, "primary price older than ORACLE_TIMEOUT");
        } else if (src == IPriceFeed.PriceSource.fallbackOracle) {
            assertEq(p, tel.value(), "fallback source but not the fallback price");
            assertLe(block.timestamp - tel.ts(), ORACLE_TIMEOUT, "fallback price older than ORACLE_TIMEOUT");
        }
        uint256 lgpTs = pf.lastGoodPriceTimestamp();
        assertGe(lgpTs, lastTs, "lastGoodPriceTimestamp went backwards");
        assertLe(lgpTs, block.timestamp, "lastGoodPriceTimestamp in the future");
        lastTs = lgpTs;
    }
}

/// Stateful fuzzing of USDFC's PriceFeed oracle state machine with the mainnet timeouts (16 h / 2 days).
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract PriceFeedStateMachine is Test {
    PFHandler h;

    function setUp() public {
        vm.warp(1_795_400_000);
        h = new PFHandler();
        targetContract(address(h));
    }

    function invariant_statusInRange() public view {
        assertLe(uint256(h.pf().status()), 4);
    }

    function invariant_lastGoodPriceNonZero() public view {
        assertGt(h.pf().lastGoodPrice(), 0);
    }
}
