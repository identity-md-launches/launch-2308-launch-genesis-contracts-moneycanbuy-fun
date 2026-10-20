// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {GenesisFixture} from "./GenesisLaunch.t.sol";

/// @dev Drives the splitter and the four vestings in random order: arrivals at the splitter (the remainder, then
///      anything later), donations straight to a vesting, splits and releases by random callers, time.
contract SplitHandler is Test {
    YoloSplitter immutable splitter;
    MockERC20 immutable yolo;
    ProjectVesting[4] vs;

    uint256 public ghostMinted;
    uint256[4] public ghostDonated;
    uint256 public ghostSplitAt;
    uint256 public ghostLateToTreasury;
    uint256 public splitBalance;
    bool public splitFailedAboveFixed;
    uint256 public calls;

    constructor(YoloSplitter s, MockERC20 y, ProjectVesting[4] memory v) {
        splitter = s;
        yolo = y;
        vs = v;
    }

    function arrive(uint256 amount) external {
        // the remainder or anything later: 0 .. 800M
        amount = bound(amount, 0, 800_000_000e18);
        yolo.mint(address(splitter), amount);
        ghostMinted += amount;
        calls++;
    }

    function donate(uint256 which, uint256 amount) external {
        which = bound(which, 0, 3);
        amount = bound(amount, 0, 100_000_000e18);
        yolo.mint(address(vs[which]), amount);
        ghostMinted += amount;
        ghostDonated[which] += amount;
        calls++;
    }

    /// @dev only the splitter's own code acts as the splitter
    function _notSplitter(address caller) internal view returns (address) {
        return caller == address(splitter) ? address(0xCA11) : caller;
    }

    function split(address caller) external {
        caller = _notSplitter(caller);
        uint256 bal = yolo.balanceOf(address(splitter));
        bool wasDone = splitter.done(address(yolo));
        vm.prank(caller);
        try splitter.split(address(yolo)) {
            if (!wasDone) {
                ghostSplitAt = block.timestamp;
                splitBalance = bal;
            } else {
                ghostLateToTreasury += bal;
            }
        } catch {
            if (wasDone || bal > splitter.FIXED()) splitFailedAboveFixed = true;
        }
        calls++;
    }

    function release(uint256 which, address caller) external {
        ProjectVesting v = vs[bound(which, 0, 3)];
        vm.prank(_notSplitter(caller));
        v.release(address(yolo));
        calls++;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 120 days));
        calls++;
    }
}

contract GenesisSplitInvariantTest is GenesisFixture {
    SplitHandler handler;
    uint256[4] startSeen;

    function setUp() public {
        _launch();
        handler = new SplitHandler(splitter, yolo, _vestings());
        targetContract(address(handler));
    }

    function _held() internal view returns (uint256 sum) {
        sum = yolo.balanceOf(address(splitter)) + yolo.balanceOf(STABILIZER);
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            sum += yolo.balanceOf(address(vs[i])) + yolo.balanceOf(vs[i].beneficiary());
        }
    }

    /// Nothing is created or lost: every token minted sits in the splitter, a vesting, a beneficiary or the
    /// stabilizer.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_conservation() public view {
        assertEq(_held(), handler.ghostMinted());
    }

    /// A beneficiary holds exactly what its vesting released, and never more than the vesting received.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_beneficiaryGetsOnlyReleases_releasedWithinSchedule() public view {
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            uint256 rel = vs[i].released(address(yolo));
            uint256 total = yolo.balanceOf(address(vs[i])) + rel;
            assertEq(yolo.balanceOf(vs[i].beneficiary()), rel);
            assertLe(rel, total);
            uint256 vested = vs[i].vestedAmount(address(yolo), block.timestamp);
            assertLe(rel, vested, "never paid ahead of the schedule");
            assertLe(vested, total);
            uint256 start = vs[i].startOf(address(yolo));
            if (start == 0) {
                // no clock: at most the at-once part
                assertLe(rel, vs[i].unlocked());
            } else if (block.timestamp - start < vs[i].duration()) {
                uint256 free = total < vs[i].unlocked() ? total : vs[i].unlocked();
                uint256 line = free + (total - free) * (block.timestamp - start) / vs[i].duration();
                assertLe(rel, line, "within the straight line");
            }
        }
    }

    /// Only the split starts the $YOLO clocks, all four at the split's second; before it no clock runs.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_clocksStartOnlyAtTheSplit() public view {
        ProjectVesting[4] memory vs = _vestings();
        bool done = splitter.done(address(yolo));
        for (uint256 i; i < 4; ++i) {
            uint256 start = vs[i].startOf(address(yolo));
            if (!done) assertEq(start, 0);
            else assertEq(start, handler.ghostSplitAt());
            assertEq(vs[i].starter(), address(splitter));
        }
    }

    /// The fixed shares are paid once and exactly; everything else that reached the splitter went to the treasury
    /// vesting; a split above the fixed shares never fails.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_sharesPaidOnceAndExactly() public view {
        assertFalse(handler.splitFailedAboveFixed());
        ProjectVesting[4] memory vs = _vestings();
        uint256[4] memory received;
        for (uint256 i; i < 4; ++i) {
            received[i] = yolo.balanceOf(address(vs[i])) + vs[i].released(address(yolo)) - handler.ghostDonated(i);
        }
        if (!splitter.done(address(yolo))) {
            assertEq(yolo.balanceOf(STABILIZER), 0);
            for (uint256 i; i < 4; ++i) {
                assertEq(received[i], 0);
            }
            return;
        }
        assertEq(yolo.balanceOf(STABILIZER), 150_000_000e18);
        assertEq(received[0], 250_000_000e18);
        assertEq(received[1], 77_777_777e18);
        assertEq(received[2], 50_000_000e18);
        assertEq(received[3], handler.splitBalance() - FIXED + handler.ghostLateToTreasury());
    }
}

/// @dev Drives the gate: the writer records and seals, several callers (tokens) consume for several buyers.
contract GateHandler is Test {
    NftGate immutable gate;
    address immutable writer;
    address[5] public buyers;
    address[3] public callers;

    uint256 public ghostTotal;
    uint256 public ghostWallets;
    bytes32 public ghostHash;
    bool public ghostSealed;
    uint256 public sealedAtSeen;
    mapping(address => mapping(address => uint256)) public ghostUsed;

    constructor(NftGate g, address w) {
        gate = g;
        writer = w;
        buyers = [address(0xB1), address(0xB2), address(0xB3), address(0xB4), address(0xB5)];
        callers = [address(0xC1), address(0xC2), address(0xC3)];
    }

    function record(uint256 who, uint256 nfts, address caller, bool asWriter) external {
        address b = buyers[bound(who, 0, 4)];
        nfts = bound(nfts, 0, 2_000);
        address[] memory a = new address[](1);
        a[0] = b;
        uint256[] memory n = new uint256[](1);
        n[0] = nfts;
        address sender = asWriter ? writer : caller;
        bool ok = sender == writer && !ghostSealed && nfts != 0 && gate.nftsOf(b) == 0;
        vm.prank(sender);
        try gate.record(a, n) {
            assertTrue(ok, "a record that should have failed went through");
            ghostTotal += nfts;
            ghostWallets += 1;
            ghostHash = keccak256(abi.encode(ghostHash, b, nfts));
        } catch {
            assertFalse(ok, "a valid record failed");
        }
    }

    function seal(uint256 blockNo, bool asWriter) external {
        bool ok = asWriter && !ghostSealed && ghostWallets != 0;
        vm.prank(asWriter ? writer : address(0xBAD));
        try gate.seal(blockNo) {
            assertTrue(ok, "a seal that should have failed went through");
            ghostSealed = true;
            sealedAtSeen = block.timestamp;
        } catch {
            assertFalse(ok, "a valid seal failed");
        }
    }

    function consume(uint256 c, uint256 who, uint256 amount) external {
        address caller = callers[bound(c, 0, 2)];
        address b = buyers[bound(who, 0, 4)];
        uint256 allowance = gate.nftsOf(b) * gate.ALLOWANCE_PER_NFT();
        amount = bound(amount, 0, allowance + 1e18);
        vm.prank(caller);
        try gate.consume(b, amount) returns (uint256 al, uint256 ub) {
            assertTrue(ghostSealed, "consumed before the seal");
            assertEq(al, allowance);
            assertEq(ub, ghostUsed[caller][b]);
            if (amount <= allowance - ub) ghostUsed[caller][b] = ub + amount;
        } catch {
            assertFalse(ghostSealed, "consume failed after the seal");
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 1 days));
    }
}

contract GenesisGateInvariantTest is GenesisFixture {
    GateHandler handler;

    function setUp() public {
        _launch();
        handler = new GateHandler(gate, WRITER);
        targetContract(address(handler));
    }

    /// The gate's books match the list as written, and no caller ever books more than a buyer's allowance.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_gateBooks() public view {
        assertEq(gate.totalNfts(), handler.ghostTotal());
        assertEq(gate.walletCount(), handler.ghostWallets());
        assertEq(gate.snapshotHash(), handler.ghostHash());
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            address b = handler.buyers(i);
            sum += gate.nftsOf(b);
            for (uint256 j; j < 3; ++j) {
                address c = handler.callers(j);
                uint256 u = gate.used(c, b);
                assertEq(u, handler.ghostUsed(c, b));
                assertLe(u, gate.allowanceOf(b));
            }
        }
        assertEq(sum, gate.totalNfts());
    }

    /// A sealed snapshot stays sealed at the same second.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    function invariant_sealIsFinal() public view {
        if (handler.ghostSealed()) assertEq(gate.sealedAt(), handler.sealedAtSeen());
        else assertEq(gate.sealedAt(), 0);
    }
}
