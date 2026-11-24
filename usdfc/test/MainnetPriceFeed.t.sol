// SPDX-License-Identifier: MIT
pragma solidity 0.7.6;
pragma abicoder v2;

import "forge-std/Test.sol";
import "../upstream/contracts/PriceFeed.sol";

/// Runs against Filecoin mainnet state (FORK_URL, e.g. https://api.node.glif.io/rpc/v1). Skipped when unset.
/// Checks the deployed PriceFeed against its own oracles right now, and that the harness's mocks match how the
/// real oracles answer (decimals, timestamps not ahead of FEVM block.timestamp).
contract MainnetPriceFeed is Test {
    PriceFeed constant PF = PriceFeed(0x80e651c9739C1ed15A267c11b85361780164A368);

    function test_mainnetFeedConsistent() public {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        AggregatorV3Interface agg = PF.priceAggregator();
        (, int256 answer,, uint256 updatedAt,) = agg.latestRoundData();
        uint8 dec = agg.decimals();
        emit log_named_uint("status", uint256(PF.status()));
        emit log_named_uint("primary updatedAt age (s)", block.timestamp - updatedAt);
        assertLe(updatedAt, block.timestamp, "primary timestamp ahead of FEVM block.timestamp");
        assertGt(answer, 0, "primary answer <= 0");
        (uint256 price, IPriceFeed.PriceSource src) = PF.fetchPriceWithSourceView();
        emit log_named_uint("price", price);
        emit log_named_uint("source", uint256(src));
        if (src == IPriceFeed.PriceSource.primaryOracle) {
            assertEq(price, uint256(answer) * 10 ** (18 - uint256(dec)), "primary source but price != scaled primary answer");
        }
        (bool ok, uint256 v, uint256 ts) = PF.tellorCaller().getTellorCurrentValue();
        emit log_named_uint("fallback ok", ok ? 1 : 0);
        emit log_named_uint("fallback value", v);
        emit log_named_uint("fallback age (s)", block.timestamp - ts);
    }
}
