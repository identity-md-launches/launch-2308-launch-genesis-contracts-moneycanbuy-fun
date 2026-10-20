// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {LaunchPlan, LocalFactory} from "../script/LaunchPlan.sol";
import {ProjectVesting} from "../src/token/ProjectVesting.sol";
import {DevVesting} from "../src/token/Vestings.sol";
import {YoloSplitter} from "../src/token/YoloSplitter.sol";
import {NftGate} from "../src/token/NftGate.sol";

/// @dev ADAPTATION.md: the two changes made for the launch's static analysis keep their behaviour, and the imported
///      audit's findings reproduce as the documented design of the genesis contracts (no change required).
contract AdaptationTest is Base {
    uint256 internal constant WEEK = 7 days;

    // ================================================================== YoloLockHub._checkpoint writes _history[who]

    /// A checkpoint in the same block overwrites the last point; a later block appends one, and the old point stays
    /// readable at its time (the history is the same storage, written directly instead of through a pointer).
    function test_LockHub_HistoryCheckpoints_SameBlockOverwritesLaterBlockAppends() public {
        uint256 t0 = _now();
        vm.prank(alice);
        hub.lock(52e18, 52); // power 52e18 x 52 / 52
        assertEq(hub.powerAt(alice, t0), 0, "a point counts strictly after its time");
        assertEq(hub.powerAt(alice, t0 + 1), 52e18);

        vm.prank(alice);
        hub.lock(52e18, 0); // same block, add only: the one point is overwritten: 52 + 52 x 52 / 52
        assertEq(hub.powerAt(alice, t0 + 1), 104e18, "the same-block point was overwritten");
        assertEq(hub.power(alice), 104e18);

        _warp(10 * WEEK);
        uint256 t1 = _now();
        vm.prank(alice);
        hub.lock(104e18, 0); // 42 weeks left: 104 + 104 x 42 / 52
        assertEq(hub.powerAt(alice, t0 + 1), 104e18, "the earlier point is kept");
        assertEq(hub.powerAt(alice, t1), 104e18, "strictly before the new point");
        assertEq(hub.powerAt(alice, t1 + 1), 188e18, "the new point was appended");
        assertEq(hub.stakePower(alice, uint64(t0 + 1)), 104e18, "same epoch, lock running");

        _warp(43 * WEEK);
        vm.prank(alice);
        hub.withdraw();
        assertEq(hub.power(alice), 0);
        assertEq(hub.powerAt(alice, t1 + 1), 188e18, "history survives the withdrawal");
        assertEq(hub.stakePower(alice, uint64(t1 + 1)), 0, "withdrawn: another epoch");
        assertEq(yolo.balanceOf(address(hub)), 0);
    }

    // ================================================================== TaskVault._pullToken (collectBondPart)

    /// The "rew" part of a doer bond on a USDC task is pulled from the submitter, booked as a liability.
    function test_Vault_BondPartInUsdc_PulledFromTheSubmitter() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        Bond memory q = vault.quoteSubmission(t);
        assertEq(q.rew, 30e6, "3% of 1,000 USDC");
        uint256 u0 = usdc.balanceOf(doer);
        uint256 v0 = usdc.balanceOf(address(vault));
        uint256 l0 = TaskVault(payable(address(vault))).liabilities(address(usdc));
        _submit(doer, t);
        assertEq(u0 - usdc.balanceOf(doer), 30e6, "the doer paid the USDC part");
        assertEq(usdc.balanceOf(address(vault)) - v0, 30e6);
        assertEq(TaskVault(payable(address(vault))).liabilities(address(usdc)) - l0, 30e6, "booked");
    }

    /// Only a desk may name the payer of a bond part: an approved wallet's tokens cannot be pulled by anyone else.
    function test_Vault_CollectBondPart_OnlyADesk() public {
        TaskVault v = TaskVault(payable(address(vault)));
        uint256 u0 = usdc.balanceOf(doer);
        vm.expectRevert(NotAuthorized.selector);
        vm.prank(alice);
        v.collectBondPart(doer, 0, address(usdc), 1e6);
        vm.expectRevert(NotAuthorized.selector);
        vm.prank(doer);
        v.collectBondPart(doer, 0, address(yolo), 1e18);
        assertEq(usdc.balanceOf(doer), u0);
    }

    // ================================================================== imported audit, finding 1 (low)

    /// A vesting deployed without the splitter has no starter and so no clock (the designed code-length skip); the
    /// genesis launch deploys the six in one factory transaction, which binds the splitter to all four, and its
    /// first split starts every clock and pays the at-once parts.
    function test_Audit_LoneVestingHasNoClock_GenesisLaunchBindsAllFour() public {
        DevVesting lone = new DevVesting(address(0xBEEF));
        assertEq(lone.starter(), address(0));
        yolo.mint(address(lone), 77_777_777e18);
        lone.release(address(yolo));
        assertEq(lone.startOf(address(yolo)), 0, "nobody started the clock");
        vm.warp(_now() + 3650 days);
        assertEq(lone.releasable(address(yolo)), 0);
        assertEq(yolo.balanceOf(address(lone)), 77_777_777e18, "the vested part stays");

        LocalFactory f = new LocalFactory();
        address incentives = makeAddr("incentives");
        address stabilizer = makeAddr("stabilizer");
        address team = makeAddr("team");
        LaunchPlan.Owners memory o = LaunchPlan.Owners(treasury, incentives, stabilizer, devWallet, team);
        (bytes[] memory codes,, LaunchPlan.Genesis memory g) = LaunchPlan.genesisLaunchWith(f, 0, o, address(nft));
        address[] memory out = f.launchContracts(0, codes);
        assertEq(out.length, 6);
        assertEq(out[0], g.gate);
        assertEq(out[5], g.splitter);
        for (uint256 i = 1; i < 5; ++i) {
            assertEq(ProjectVesting(out[i]).starter(), g.splitter, "the splitter is the starter");
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            ProjectVesting(out[i]).bindStarter();
        }
        assertEq(NftGate(g.gate).writer(), treasury);
        assertEq(NftGate(g.gate).nft(), address(nft));

        // launch 2 sends the project's 75%; the first split hands it out and starts the clocks
        uint256 tr0 = yolo.balanceOf(treasury);
        uint256 dv0 = yolo.balanceOf(devWallet);
        yolo.mint(g.splitter, 750_000_000e18);
        YoloSplitter(g.splitter).split(address(yolo));
        uint64 now_ = uint64(_now());
        assertEq(ProjectVesting(g.incentives).startOf(address(yolo)), now_);
        assertEq(ProjectVesting(g.dev).startOf(address(yolo)), now_);
        assertEq(ProjectVesting(g.team).startOf(address(yolo)), now_);
        assertEq(ProjectVesting(g.treasury).startOf(address(yolo)), now_);
        assertEq(yolo.balanceOf(incentives), 62_500_000e18, "incentives at once");
        assertEq(yolo.balanceOf(stabilizer), 150_000_000e18, "stabilizer, no vesting");
        assertEq(yolo.balanceOf(treasury) - tr0, 74_074_074e18, "treasury at once");
        assertEq(yolo.balanceOf(devWallet), dv0, "dev: linear only");
        assertEq(yolo.balanceOf(team), 0, "team: linear only");
        assertEq(yolo.balanceOf(g.incentives), 250_000_000e18 - 62_500_000e18);
        assertEq(yolo.balanceOf(g.dev), 77_777_777e18);
        assertEq(yolo.balanceOf(g.team), 50_000_000e18);
        assertEq(yolo.balanceOf(g.treasury), 222_222_223e18 - 74_074_074e18);
        assertEq(yolo.balanceOf(g.splitter), 0);
    }

    // ================================================================== imported audit, findings 2 and 3 (info)

    /// Before the seal the writer's list is bounded only off chain (the brief's accepted trust assumption); a wallet
    /// is written once; after the seal the writer has no power and the gate books per calling token, only what fits.
    function test_Audit_GateWriterPowersEndAtTheSeal() public {
        NftGate gate = new NftGate(address(nft), treasury);
        address[] memory a = new address[](1);
        a[0] = alice;
        uint256[] memory n = new uint256[](1);
        n[0] = 5000;
        vm.prank(treasury);
        gate.record(a, n);
        n[0] = 1;
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, alice));
        vm.prank(treasury);
        gate.record(a, n);
        assertEq(gate.nftsOf(alice), 5000, "a mis-recorded wallet cannot be amended");
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(alice, 1);

        vm.prank(treasury);
        gate.seal(block.number - 1);
        assertEq(gate.totalNfts(), 5000);
        assertEq(gate.left(address(this), alice), 5000 * 500_000e18);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        vm.prank(treasury);
        gate.record(a, n);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        vm.prank(treasury);
        gate.seal(1);

        (uint256 allowance, uint256 usedBefore) = gate.consume(alice, 500_000e18);
        assertEq(allowance, 5000 * 500_000e18);
        assertEq(usedBefore, 0);
        assertEq(gate.used(address(this), alice), 500_000e18, "booked for this caller");
        (, usedBefore) = gate.consume(alice, 5000 * 500_000e18);
        assertEq(usedBefore, 500_000e18);
        assertEq(gate.used(address(this), alice), 500_000e18, "a buy that does not fit is not booked");
        assertEq(gate.used(address(vault), alice), 0, "another caller's books are its own");
    }
}
