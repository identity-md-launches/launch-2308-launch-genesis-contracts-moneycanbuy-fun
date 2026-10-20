// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../../src/token/Vestings.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Launch 1 of 4 (genesis, evm_contracts) as the brief states it: the six contracts with their mainnet
///      constructor arguments, deployed in ONE call through the LocalFactory (the vestings' `bindStarter` flag is
///      transient and lives only in that transaction), then the remainder split, the vesting schedules and the gate.
abstract contract GenesisFixture is Test {
    // the brief's constructor arguments, written out here rather than read from LaunchPlan
    address constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant WRITER = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant INCENTIVES_WALLET = 0x7085193516EDc587fAebFF7a48548eAC8db5fAb5;
    address constant DEV_WALLET = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant TEAM_WALLET = 0x153D12cc398d79A99B781B23DB6399556b84ca76;
    address constant TREASURY_WALLET = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant STABILIZER = 0xaaB0269b956bd5F97B44529569b042e7BD72B508;

    uint256 constant REMAINDER = 750_000_000e18;
    uint256 constant FIXED = 527_777_777e18;

    LocalFactory factory;
    NftGate gate;
    IncentivesVesting incentives;
    DevVesting dev;
    TeamVesting team;
    TreasuryVesting treasury;
    YoloSplitter splitter;
    MockERC20 yolo;

    function _launch() internal {
        vm.warp(1_800_000_000);
        factory = new LocalFactory();
        bytes[] memory codes = new bytes[](6);
        codes[0] = abi.encodePacked(type(NftGate).creationCode, abi.encode(NFT, WRITER));
        codes[1] = abi.encodePacked(type(IncentivesVesting).creationCode, abi.encode(INCENTIVES_WALLET));
        codes[2] = abi.encodePacked(type(DevVesting).creationCode, abi.encode(DEV_WALLET));
        codes[3] = abi.encodePacked(type(TeamVesting).creationCode, abi.encode(TEAM_WALLET));
        codes[4] = abi.encodePacked(type(TreasuryVesting).creationCode, abi.encode(TREASURY_WALLET));
        address[4] memory v;
        for (uint256 i; i < 4; ++i) {
            v[i] = factory.predictContract(0, i + 1, codes[i + 1]);
        }
        codes[5] = abi.encodePacked(type(YoloSplitter).creationCode, abi.encode(v[0], v[1], v[2], v[3], STABILIZER));
        address[] memory out = factory.launchContracts(0, codes); // one transaction, as on chain
        gate = NftGate(out[0]);
        incentives = IncentivesVesting(out[1]);
        dev = DevVesting(out[2]);
        team = TeamVesting(out[3]);
        treasury = TreasuryVesting(out[4]);
        splitter = YoloSplitter(out[5]);
        yolo = new MockERC20("YOLO", "YOLO", 18);
    }

    function _vestings() internal view returns (ProjectVesting[4] memory) {
        return [ProjectVesting(incentives), ProjectVesting(dev), ProjectVesting(team), ProjectVesting(treasury)];
    }

    function _arriveAndSplit(uint256 amount) internal {
        yolo.mint(address(splitter), amount);
        splitter.split(address(yolo));
    }
}

contract GenesisLaunchTest is GenesisFixture {
    function setUp() public {
        _launch();
    }

    // ------------------------------------------------------------------ the launch as the brief states it

    function test_launch_constructorArgumentsAndSchedulesMatchTheBrief() public view {
        assertEq(gate.nft(), NFT);
        assertEq(gate.writer(), WRITER);
        assertEq(gate.ALLOWANCE_PER_NFT(), 500_000e18);
        assertEq(gate.sealedAt(), 0);
        assertEq(gate.walletCount(), 0);
        assertEq(gate.snapshotHash(), bytes32(0));

        assertEq(incentives.beneficiary(), INCENTIVES_WALLET);
        assertEq(incentives.unlocked(), 62_500_000e18);
        assertEq(incentives.duration(), 730 days);
        assertEq(dev.beneficiary(), DEV_WALLET);
        assertEq(dev.unlocked(), 0);
        assertEq(dev.duration(), 365 days);
        assertEq(team.beneficiary(), TEAM_WALLET);
        assertEq(team.unlocked(), 0);
        assertEq(team.duration(), 365 days);
        assertEq(treasury.beneficiary(), TREASURY_WALLET);
        assertEq(treasury.unlocked(), 74_074_074e18);
        assertEq(treasury.duration(), 365 days);

        assertEq(splitter.incentivesVesting(), address(incentives));
        assertEq(splitter.devVesting(), address(dev));
        assertEq(splitter.teamVesting(), address(team));
        assertEq(splitter.treasuryVesting(), address(treasury));
        assertEq(splitter.stabilizer(), STABILIZER);
        assertEq(splitter.INCENTIVES(), 250_000_000e18);
        assertEq(splitter.STABILIZER(), 150_000_000e18);
        assertEq(splitter.DEV(), 77_777_777e18);
        assertEq(splitter.TEAM(), 50_000_000e18);
        assertEq(splitter.FIXED(), splitter.INCENTIVES() + splitter.STABILIZER() + splitter.DEV() + splitter.TEAM());
        assertEq(splitter.FIXED(), FIXED);

        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            assertEq(vs[i].starter(), address(splitter), "the splitter is every vesting's starter");
        }
    }

    function test_launch_planMatchesTheBrief() public {
        LaunchPlan.Owners memory o = LaunchPlan.projectOwners();
        assertEq(o.treasury, TREASURY_WALLET);
        assertEq(o.incentives, INCENTIVES_WALLET);
        assertEq(o.stabilizer, STABILIZER);
        assertEq(o.dev, DEV_WALLET);
        assertEq(o.team, TEAM_WALLET);
        LocalFactory f = new LocalFactory();
        (bytes[] memory codes, bytes32[] memory names, LaunchPlan.Genesis memory g) = LaunchPlan.genesisLaunch(f, 7, o);
        assertEq(names[0], "NftGate");
        assertEq(names[5], "YoloSplitter");
        // byte for byte the same creation codes as the brief's arguments (fixture above, same factory = same code)
        assertEq(codes[0], abi.encodePacked(type(NftGate).creationCode, abi.encode(NFT, WRITER)));
        assertEq(
            codes[5],
            abi.encodePacked(
                type(YoloSplitter).creationCode, abi.encode(g.incentives, g.dev, g.team, g.treasury, STABILIZER)
            )
        );
        address[] memory out = f.launchContracts(7, codes);
        assertEq(out[5], g.splitter);
        assertEq(ProjectVesting(g.treasury).starter(), g.splitter);
    }

    /// The gate never reads the NFT: on this chain the mainnet NFT address holds no code, and the whole gate works.
    function test_launch_gateNeverCallsTheNft() public {
        assertEq(NFT.code.length, 0);
        address[] memory a = new address[](1);
        a[0] = address(0xB0B);
        uint256[] memory n = new uint256[](1);
        n[0] = 3;
        vm.startPrank(WRITER);
        gate.record(a, n);
        gate.seal(23_000_000);
        vm.stopPrank();
        (uint256 allowance, uint256 usedBefore) = gate.consume(address(0xB0B), 1_500_000e18);
        assertEq(allowance, 1_500_000e18);
        assertEq(usedBefore, 0);
    }

    /// Nothing here holds funds or runs a clock until the token arrives; release before the split pays nothing.
    function test_launch_beforeTheSplitNothingMoves() public {
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            vs[i].release(address(yolo));
            assertEq(vs[i].startOf(address(yolo)), 0);
            assertEq(vs[i].released(address(yolo)), 0);
        }
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, 0));
        splitter.split(address(yolo));
    }

    // ------------------------------------------------------------------ starter binding

    function test_bindStarter_closedAfterTheLaunchTransaction_evenForTheSplitter() public {
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            vs[i].bindStarter();
            vm.prank(address(splitter));
            vm.expectRevert(ProjectVesting.BindingClosed.selector);
            vs[i].bindStarter();
            assertEq(vs[i].starter(), address(splitter));
        }
    }

    /// Inside the deployment transaction the flag is consumed by the first binder: a second binder in the same
    /// transaction fails, so the splitter's position in the launch cannot be taken over by a later contract.
    function test_bindStarter_onlyOncePerDeployment() public {
        DoubleBinder d = new DoubleBinder();
        assertTrue(d.secondFailed());
        assertEq(ProjectVesting(d.vesting()).starter(), address(d));
    }

    function test_vestings_rejectZeroBeneficiary() public {
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new IncentivesVesting(address(0));
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new DevVesting(address(0));
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new TeamVesting(address(0));
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new TreasuryVesting(address(0));
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(address(1), 0, 0);
        vm.expectRevert(ProjectVesting.BadSchedule.selector);
        new ProjectVesting(address(1), 0, 10 * 365 days + 1);
    }

    function test_splitter_rejectsAZeroAddressInEveryPosition() public {
        for (uint256 i; i < 5; ++i) {
            address[5] memory a = [address(11), address(12), address(13), address(14), address(15)];
            a[i] = address(0);
            vm.expectRevert(YoloSplitter.ZeroAddress.selector);
            new YoloSplitter(a[0], a[1], a[2], a[3], a[4]);
        }
    }

    // ------------------------------------------------------------------ the split

    function test_split_atOrBelowFixedReverts() public {
        yolo.mint(address(splitter), FIXED);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, FIXED));
        splitter.split(address(yolo));
        assertFalse(splitter.done(address(yolo)));
        yolo.mint(address(splitter), 1);
        splitter.split(address(yolo));
        assertEq(yolo.balanceOf(address(treasury)) + yolo.balanceOf(TREASURY_WALLET), 1, "one wei over: treasury 1");
        assertEq(yolo.balanceOf(STABILIZER), 150_000_000e18);
    }

    function test_split_theWholeRemainder_byAnyone() public {
        yolo.mint(address(splitter), REMAINDER);
        vm.prank(address(0xCAFE));
        vm.expectEmit(address(splitter));
        emit YoloSplitter.Split(address(yolo), REMAINDER);
        splitter.split(address(yolo));
        uint256 t = vm.getBlockTimestamp();

        assertEq(yolo.balanceOf(address(splitter)), 0);
        assertEq(yolo.balanceOf(STABILIZER), 150_000_000e18, "stabilizer at once");
        assertEq(yolo.balanceOf(INCENTIVES_WALLET), 62_500_000e18, "incentives at once");
        assertEq(yolo.balanceOf(address(incentives)), 187_500_000e18);
        assertEq(yolo.balanceOf(DEV_WALLET), 0);
        assertEq(yolo.balanceOf(address(dev)), 77_777_777e18);
        assertEq(yolo.balanceOf(TEAM_WALLET), 0);
        assertEq(yolo.balanceOf(address(team)), 50_000_000e18);
        assertEq(yolo.balanceOf(TREASURY_WALLET), 74_074_074e18, "treasury at once");
        assertEq(yolo.balanceOf(address(treasury)), 222_222_223e18 - 74_074_074e18);
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            assertEq(vs[i].startOf(address(yolo)), t, "every clock starts at the split");
        }
        assertTrue(splitter.done(address(yolo)));
    }

    /// The factory's rounding of the pool seed leaves the remainder a few wei short: the treasury absorbs it.
    function test_split_aFewWeiShortStillSplits() public {
        _arriveAndSplit(REMAINDER - 3);
        assertEq(
            yolo.balanceOf(address(treasury)) + yolo.balanceOf(TREASURY_WALLET), 222_222_223e18 - 3, "treasury short"
        );
        assertEq(yolo.balanceOf(address(dev)), 77_777_777e18);
    }

    function test_split_laterArrivalsGoToTheTreasuryVesting_clocksUntouched() public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 10 days);
        // a second call with nothing new is a no-op
        splitter.split(address(yolo));
        uint256 trBefore = yolo.balanceOf(address(treasury));
        yolo.mint(address(splitter), 5e18);
        vm.prank(address(0xD00D));
        splitter.split(address(yolo));
        assertEq(yolo.balanceOf(address(treasury)), trBefore + 5e18);
        assertEq(yolo.balanceOf(STABILIZER), 150_000_000e18, "fixed shares paid only once");
        assertEq(yolo.balanceOf(address(dev)), 77_777_777e18);
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            assertEq(vs[i].startOf(address(yolo)), t0, "no restart");
        }
    }

    /// A second token split through the splitter gets clocks of its own; $YOLO's are not touched.
    function test_split_anotherTokenHasItsOwnBooks() public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 100 days);
        MockERC20 other = new MockERC20("X", "X", 18);
        other.mint(address(splitter), FIXED + 1e18);
        splitter.split(address(other));
        assertEq(dev.startOf(address(yolo)), t0);
        assertEq(dev.startOf(address(other)), t0 + 100 days);
        assertTrue(splitter.done(address(other)));
    }

    /// A recipient that refuses the token reverts the whole split: nothing is half paid and `done` stays false.
    function test_split_isAllOrNothing() public {
        yolo.mint(address(splitter), REMAINDER);
        yolo.setBlocked(STABILIZER, true);
        vm.expectRevert(bytes("blocked"));
        splitter.split(address(yolo));
        assertFalse(splitter.done(address(yolo)));
        assertEq(yolo.balanceOf(address(splitter)), REMAINDER);
        assertEq(dev.startOf(address(yolo)), 0);
        yolo.setBlocked(STABILIZER, false);
        splitter.split(address(yolo));
        assertTrue(splitter.done(address(yolo)));
    }

    // ------------------------------------------------------------------ the vesting schedules

    function test_schedules_atKeyTimes() public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        ProjectVesting[4] memory vs = _vestings();

        // the split second: only the at-once parts
        for (uint256 i; i < 4; ++i) {
            assertEq(vs[i].releasable(address(yolo)), 0);
        }
        // one year: dev, team and treasury fully open; incentives half of its linear part
        vm.warp(t0 + 365 days);
        assertEq(dev.releasable(address(yolo)), 77_777_777e18);
        assertEq(team.releasable(address(yolo)), 50_000_000e18);
        assertEq(treasury.releasable(address(yolo)), 222_222_223e18 - 74_074_074e18);
        assertEq(incentives.releasable(address(yolo)), 187_500_000e18 / 2);
        // half a year: dev half
        vm.warp(t0 + 365 days / 2);
        assertEq(dev.releasable(address(yolo)), 77_777_777e18 * (365 days / 2) / 365 days);
        // two years: everything
        vm.warp(t0 + 730 days);
        for (uint256 i; i < 4; ++i) {
            vs[i].release(address(yolo));
            assertEq(yolo.balanceOf(address(vs[i])), 0, "fully paid");
            assertEq(vs[i].releasable(address(yolo)), 0);
        }
        assertEq(yolo.balanceOf(INCENTIVES_WALLET), 250_000_000e18);
        assertEq(yolo.balanceOf(DEV_WALLET), 77_777_777e18);
        assertEq(yolo.balanceOf(TEAM_WALLET), 50_000_000e18);
        assertEq(yolo.balanceOf(TREASURY_WALLET), 222_222_223e18);
        // releasing again pays nothing
        vm.warp(t0 + 3000 days);
        dev.release(address(yolo));
        assertEq(yolo.balanceOf(DEV_WALLET), 77_777_777e18);
    }

    /// Anyone may call release; it only ever pays the beneficiary, never the caller.
    function test_release_byAnyonePaysOnlyTheBeneficiary() public {
        _arriveAndSplit(REMAINDER);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        address stranger = address(0x5157);
        uint256 due = team.releasable(address(yolo));
        assertGt(due, 0);
        vm.prank(stranger);
        vm.expectEmit(address(team));
        emit ProjectVesting.Released(address(yolo), due);
        team.release(address(yolo));
        assertEq(yolo.balanceOf(stranger), 0);
        assertEq(yolo.balanceOf(TEAM_WALLET), due);
        assertEq(team.released(address(yolo)), due);
    }

    /// Before the split no one but the splitter starts a clock, whoever sends what to a vesting.
    function test_release_aDonationBeforeTheSplitStartsNoClock() public {
        yolo.mint(address(dev), 1e18);
        yolo.mint(address(incentives), 100_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 400 days);
        dev.release(address(yolo));
        incentives.release(address(yolo));
        assertEq(dev.startOf(address(yolo)), 0);
        assertEq(incentives.startOf(address(yolo)), 0);
        assertEq(yolo.balanceOf(DEV_WALLET), 0, "dev: nothing free without a clock");
        assertEq(yolo.balanceOf(INCENTIVES_WALLET), 62_500_000e18, "incentives: only the at-once part");
        // the split later starts the clock as usual
        uint256 tSplit = vm.getBlockTimestamp();
        _arriveAndSplit(REMAINDER);
        assertEq(dev.startOf(address(yolo)), tSplit);
        assertEq(incentives.startOf(address(yolo)), tSplit);
        assertEq(dev.releasable(address(yolo)), 0, "dev: linear from the split");
    }

    /// Whatever arrives after the clock started streams on the same schedule (a share of everything received).
    function test_release_lateArrivalFollowsTheRunningSchedule() public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 365 days / 4);
        team.release(address(yolo));
        yolo.mint(address(team), 50_000_000e18);
        // a quarter of everything received is open
        assertEq(team.vestedAmount(address(yolo), vm.getBlockTimestamp()), 100_000_000e18 / 4);
        vm.warp(t0 + 365 days);
        team.release(address(yolo));
        assertEq(yolo.balanceOf(TEAM_WALLET), 100_000_000e18);
    }

    // ------------------------------------------------------------------ with the real $YOLO token

    /// The real token with this gate: the factory (launcher) sends the remainder, the split and every release are
    /// plain transfers (never taxed, never gated), before trading opens and inside the taxed hour alike.
    function test_realToken_splitAndReleasesAreNeverTaxed() public {
        address pm = address(0x4444);
        YoloToken t = new YoloToken(pm, address(gate), TREASURY_WALLET, vm.getBlockTimestamp() + 1 hours);
        t.transfer(address(splitter), REMAINDER);
        splitter.split(address(t));
        assertEq(t.balanceOf(STABILIZER), 150_000_000e18);
        assertEq(t.balanceOf(INCENTIVES_WALLET), 62_500_000e18);
        assertEq(t.balanceOf(TREASURY_WALLET), 74_074_074e18);
        // inside the taxed hour: minute 10 after opening
        vm.warp(t.openAt() + 10 minutes);
        uint256 due = dev.releasable(address(t));
        dev.release(address(t));
        assertEq(t.balanceOf(DEV_WALLET), due, "untaxed");
        t.transfer(address(splitter), 1e18);
        splitter.split(address(t));
        assertEq(t.balanceOf(address(splitter)), 0);
    }

    /// Unsealed at `openAt`, the gate makes the token refuse every buy of the window; sealed before, it books per buyer.
    function test_realToken_gateDecidesTheWindow() public {
        address pm = address(0x4444);
        YoloToken t = new YoloToken(pm, address(gate), TREASURY_WALLET, vm.getBlockTimestamp() + 1 hours);
        t.transfer(pm, 10_000_000e18);
        address[] memory a = new address[](1);
        a[0] = address(0xB0B);
        uint256[] memory n = new uint256[](1);
        n[0] = 2;
        vm.prank(WRITER);
        gate.record(a, n);
        vm.warp(t.openAt());
        vm.prank(pm);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(address(0xB0B), 1e18);
        // sealed at openAt is too late as well
        vm.prank(WRITER);
        gate.seal(1);
        vm.prank(pm);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(address(0xB0B), 1e18);
    }

    // ------------------------------------------------------------------ the gate

    function _list(address who, uint256 nfts) internal {
        address[] memory a = new address[](1);
        a[0] = who;
        uint256[] memory n = new uint256[](1);
        n[0] = nfts;
        vm.prank(WRITER);
        gate.record(a, n);
    }

    function test_gate_writerOnly_andAFailedBatchLeavesNoTrace() public {
        address[] memory a = new address[](3);
        a[0] = address(0xA1);
        a[1] = address(0xA2);
        a[2] = address(0xA1); // twice in one batch
        uint256[] memory n = new uint256[](3);
        n[0] = 1;
        n[1] = 2;
        n[2] = 3;
        vm.prank(address(splitter));
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.record(a, n);
        vm.prank(address(factory));
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.seal(1);
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, address(0xA1)));
        gate.record(a, n);
        assertEq(gate.nftsOf(address(0xA1)), 0, "reverted batch: nothing kept");
        assertEq(gate.walletCount(), 0);
        assertEq(gate.snapshotHash(), bytes32(0));
        n[2] = 0;
        a[2] = address(0xA3);
        vm.prank(WRITER);
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 2));
        gate.record(a, n);
        vm.prank(WRITER);
        vm.expectRevert(NftGate.EmptySnapshot.selector);
        gate.seal(1);
    }

    function test_gate_consumeRevertsUntilTheSealForEveryCaller() public {
        _list(address(0xB0B), 1);
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(address(0xB0B), 0);
        vm.prank(WRITER);
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(address(0xB0B), 1);
    }

    function test_gate_booksPerCallerAndOnlyWhatFits() public {
        _list(address(0xB0B), 2);
        vm.prank(WRITER);
        gate.seal(1);
        address tokenA = address(0xA);
        address tokenB = address(0xB);

        vm.prank(tokenA);
        (uint256 al, uint256 ub) = gate.consume(address(0xB0B), 1_000_000e18 + 1);
        assertEq(al, 1_000_000e18);
        assertEq(ub, 0);
        assertEq(gate.used(tokenA, address(0xB0B)), 0, "over the allowance: nothing booked");

        vm.prank(tokenA);
        gate.consume(address(0xB0B), 600_000e18);
        vm.prank(tokenA);
        (, ub) = gate.consume(address(0xB0B), 400_000e18 + 1);
        assertEq(ub, 600_000e18);
        assertEq(gate.used(tokenA, address(0xB0B)), 600_000e18);
        vm.prank(tokenA);
        gate.consume(address(0xB0B), 400_000e18);
        assertEq(gate.left(tokenA, address(0xB0B)), 0, "exactly used up");
        vm.prank(tokenA);
        (al, ub) = gate.consume(address(0xB0B), 1);
        assertEq(ub, 1_000_000e18);
        assertEq(gate.used(tokenA, address(0xB0B)), 1_000_000e18);

        // another caller spends only its own books
        assertEq(gate.left(tokenB, address(0xB0B)), 1_000_000e18);
        vm.prank(tokenB);
        gate.consume(address(0xB0B), 1_000_000e18);
        assertEq(gate.used(tokenA, address(0xB0B)), 1_000_000e18);

        // a wallet outside the snapshot: allowance 0, nothing booked, no revert
        vm.prank(tokenA);
        (al, ub) = gate.consume(address(0xEEE), 1);
        assertEq(al, 0);
        assertEq(ub, 0);
        assertEq(gate.used(tokenA, address(0xEEE)), 0);
        // zero: books nothing
        vm.prank(tokenA);
        (al,) = gate.consume(address(0xEEE), 0);
        assertEq(al, 0);
    }

    function test_gate_sealIsFinal() public {
        _list(address(0xB0B), 1);
        vm.warp(vm.getBlockTimestamp() + 5);
        vm.prank(WRITER);
        gate.seal(19_000_000);
        uint256 at = gate.sealedAt();
        bytes32 h = gate.snapshotHash();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(WRITER);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.seal(20_000_000);
        address[] memory a = new address[](1);
        a[0] = address(0xC0C);
        uint256[] memory n = new uint256[](1);
        n[0] = 1;
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(a, n);
        vm.stopPrank();
        assertEq(gate.sealedAt(), at);
        assertEq(gate.snapshotBlock(), 19_000_000);
        assertEq(gate.snapshotHash(), h);
        assertEq(gate.nftsOf(address(0xC0C)), 0);
    }

    // ------------------------------------------------------------------ fuzz

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_split_anyArrivalAboveFixed(uint256 amount) public {
        amount = bound(amount, FIXED + 1, 1_000_000_000e18);
        _arriveAndSplit(amount);
        uint256 toTreasury = amount - FIXED;
        assertEq(yolo.balanceOf(address(treasury)) + yolo.balanceOf(TREASURY_WALLET), toTreasury);
        uint256 atOnceTreasury = toTreasury < 74_074_074e18 ? toTreasury : 74_074_074e18;
        assertEq(yolo.balanceOf(TREASURY_WALLET), atOnceTreasury);
        uint256 sum = yolo.balanceOf(address(splitter)) + yolo.balanceOf(STABILIZER);
        ProjectVesting[4] memory vs = _vestings();
        for (uint256 i; i < 4; ++i) {
            sum += yolo.balanceOf(address(vs[i])) + yolo.balanceOf(vs[i].beneficiary());
        }
        assertEq(sum, amount, "nothing created, nothing lost");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_split_atOrBelowFixedAlwaysReverts(uint256 amount) public {
        amount = bound(amount, 0, FIXED);
        yolo.mint(address(splitter), amount);
        vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, amount));
        splitter.split(address(yolo));
    }

    /// The paid amount at any time stays within [at-once part, at-once + linear share], never decreases, and is
    /// everything after the duration.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_schedule_boundedAndMonotone(uint256 which, uint256 dt1, uint256 dt2) public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        ProjectVesting v = _vestings()[bound(which, 0, 3)];
        uint256 total = yolo.balanceOf(address(v)) + v.released(address(yolo));
        uint256 dur = v.duration();
        dt1 = bound(dt1, 0, 2 * dur);
        dt2 = bound(dt2, dt1, 3 * dur);
        vm.warp(t0 + dt1);
        v.release(address(yolo));
        uint256 paid1 = v.released(address(yolo));
        uint256 free = v.unlocked();
        assertGe(paid1, free);
        if (dt1 >= dur) {
            assertEq(paid1, total);
        } else {
            // never ahead of the straight line from the at-once part to the total
            assertLe(paid1, free + (total - free) * dt1 / dur);
            assertGe(paid1 + 1, free + (total - free) * dt1 / dur);
        }
        vm.warp(t0 + dt2);
        v.release(address(yolo));
        assertGe(v.released(address(yolo)), paid1, "never decreases");
        assertEq(yolo.balanceOf(v.beneficiary()), v.released(address(yolo)));
    }

    /// Releasing in many small steps pays exactly what one release at the end pays.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_schedule_stepsDoNotGainOrLose(uint256 seed, uint8 steps) public {
        _arriveAndSplit(REMAINDER);
        uint256 t0 = vm.getBlockTimestamp();
        steps = uint8(bound(steps, 1, 30));
        uint256 t = t0;
        for (uint256 i; i < steps; ++i) {
            t += bound(uint256(keccak256(abi.encode(seed, i))), 0, 60 days);
            vm.warp(t);
            dev.release(address(yolo));
        }
        uint256 elapsed = t - t0;
        uint256 expected = elapsed >= 365 days ? 77_777_777e18 : 77_777_777e18 * elapsed / 365 days;
        assertEq(dev.released(address(yolo)), expected);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_gate_bookingsNeverExceedTheAllowance(uint8 nfts, uint256[6] memory amounts) public {
        nfts = uint8(bound(nfts, 1, 50));
        _list(address(0xB0B), nfts);
        vm.prank(WRITER);
        gate.seal(1);
        uint256 allowance = uint256(nfts) * 500_000e18;
        uint256 booked;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amt = bound(amounts[i], 0, allowance + 1e18);
            (uint256 al, uint256 ub) = gate.consume(address(0xB0B), amt);
            assertEq(al, allowance);
            assertEq(ub, booked);
            if (amt <= allowance - booked) booked += amt;
            assertEq(gate.used(address(this), address(0xB0B)), booked);
            assertLe(booked, allowance);
        }
    }
}

/// @dev Deploys a vesting and binds twice in the same transaction: the second bind must fail.
contract DoubleBinder {
    address public vesting;
    bool public secondFailed;

    constructor() {
        vesting = address(new DevVesting(address(0xDE5)));
        ProjectVesting(vesting).bindStarter();
        Rebinder r = new Rebinder();
        try r.bind(vesting) {
            secondFailed = false;
        } catch {
            secondFailed = true;
        }
    }
}

contract Rebinder {
    function bind(address v) external {
        ProjectVesting(v).bindStarter();
    }
}
