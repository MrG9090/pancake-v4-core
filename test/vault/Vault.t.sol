// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {Vault} from "../../src/Vault.sol";
import {BalanceDelta, toBalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {FakePoolManager} from "./FakePoolManager.sol";
import {FakeHook} from "./FakeHook.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {NoIsolate} from "../helpers/NoIsolate.sol";
import {CurrencySettlement} from "../helpers/CurrencySettlement.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Basic functionality test for Vault
 * More tests in terms of security and edge cases will be covered by VaultReentracy.t.sol & VaultInvariant.t.sol
 */
contract VaultTest is Test, NoIsolate, TokenFixture {
    using CurrencySettlement for Currency;

    error ContractSizeTooLarge(uint256 diff);

    Vault public vault;
    FakePoolManager public unRegPoolManager;
    FakePoolManager public poolManager1;
    FakePoolManager public poolManager2;

    PoolKey public poolKey1;
    PoolKey public poolKey2;
    FakeHook public fakeHook1;

    MockERC20 token0;
    MockERC20 token1;

    function setUp() public {
        vault = new Vault();

        unRegPoolManager = new FakePoolManager(vault);

        poolManager1 = new FakePoolManager(vault);
        poolManager2 = new FakePoolManager(vault);
        vault.registerApp(address(poolManager1));
        vault.registerApp(address(poolManager2));

        initializeTokens();
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        fakeHook1 = new FakeHook(vault);
        token0.mint(address(fakeHook1), 1000 ether);
        token1.mint(address(fakeHook1), 1000 ether);

        poolKey1 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(fakeHook1)),
            poolManager: poolManager1,
            fee: 0,
            parameters: 0x00
        });

        poolKey2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager2,
            fee: 1,
            parameters: 0x00
        });
    }

    function test_bytecodeSize() public {
        vm.snapshotValue("VaultBytecodeSize", address(vault).code.length);

        // forge coverage will run with '--ir-minimum' which set optimizer run to min
        // thus we do not want to revert for forge coverage case
        if (vm.envExists("FOUNDRY_PROFILE") && address(vault).code.length > 24576) {
            revert ContractSizeTooLarge(address(vault).code.length - 24576);
        }
    }

    function test_initcodeHash() public {
        vm.snapshotValue(
            "Vault initcode hash (without constructor params, as uint256)", uint256(keccak256(type(Vault).creationCode))
        );
    }

    function testRegisterPoolManager() public {
        assertEq(vault.isAppRegistered(address(unRegPoolManager)), false);
        assertEq(vault.isAppRegistered(address(poolManager1)), true);

        vm.expectEmit();
        emit IVault.AppRegistered(address(unRegPoolManager));
        vault.registerApp(address(unRegPoolManager));
        vm.snapshotGasLastCall("registerPoolManager");

        assertEq(vault.isAppRegistered(address(unRegPoolManager)), true);
        assertEq(vault.isAppRegistered(address(poolManager1)), true);
    }

    function testAccountPoolBalanceDeltaFromUnregistedPoolManager() public {
        vault.lock(abi.encodeCall(VaultTest._testAccountPoolBalanceDeltaFromUnregistedPoolManager, ()));
    }

    function _testAccountPoolBalanceDeltaFromUnregistedPoolManager() external {
        PoolKey memory key = PoolKey(currency0, currency1, IHooks(address(0)), unRegPoolManager, 0x0, 0x0);
        vm.expectRevert(IVault.AppUnregistered.selector);
        unRegPoolManager.mockAccounting(key, -10 ether, -10 ether);
    }

    function testAccountPoolBalanceDeltaWithHookDeltaFromUnregistedPoolManager() public {
        vault.lock(abi.encodeCall(VaultTest._testAccountPoolBalanceDeltaWithHookDeltaFromUnregistedPoolManager, ()));
    }

    function _testAccountPoolBalanceDeltaWithHookDeltaFromUnregistedPoolManager() external {
        PoolKey memory key = PoolKey(currency0, currency1, IHooks(makeAddr("hook")), unRegPoolManager, 0x0, 0x0);
        vm.expectRevert(IVault.AppUnregistered.selector);
        unRegPoolManager.mockAccountingWithHookDelta(key, -10 ether, -10 ether, 10 ether, 10 ether);
    }

    function testAccountPoolBalanceDeltaFromArbitraryAddr() public {
        vault.lock(abi.encodeCall(VaultTest._testAccountPoolBalanceDeltaFromArbitraryAddr, ()));
    }

    function _testAccountPoolBalanceDeltaFromArbitraryAddr() external {
        vm.expectRevert(IVault.AppUnregistered.selector);
        vault.accountAppBalanceDelta(
            poolKey1.currency0, poolKey1.currency1, toBalanceDelta(int128(-1), int128(0)), address(0)
        );
    }

    function testAccountPoolBalanceDeltaWithoutLock() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager1,
            fee: uint24(3000),
            parameters: 0x00
        });
        BalanceDelta delta = toBalanceDelta(0x7, 0x8);

        vm.expectRevert(abi.encodeWithSelector(IVault.NoLocker.selector));
        vm.prank(address(poolManager1));
        vault.accountAppBalanceDelta(key.currency0, key.currency1, delta, address(this));

        vm.expectRevert(abi.encodeWithSelector(IVault.NoLocker.selector));
        vm.prank(address(poolManager1));
        vault.accountAppBalanceDelta(key.currency0, key.currency1, delta, address(this), delta, makeAddr("hook"));
    }

    function testLockNotSettledWithoutPayment() public {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledWithoutPayment, ()));
    }

    function _testLockNotSettledWithoutPayment() external {
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);
    }

    function testLockNotSettledWithoutPayment_HookDelta() public {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledWithoutPayment_HookDelta, ()));
    }

    function _testLockNotSettledWithoutPayment_HookDelta() external {
        poolManager1.mockAccountingWithHookDelta(poolKey1, -10 ether, -10 ether, 0 ether, 0 ether);
    }

    function testLockNotSettledWithoutFullyPayment() public noIsolate {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledWithoutFullyPayment, ()));
    }

    function _testLockNotSettledWithoutFullyPayment() external {
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        currency0.settle(vault, address(this), 10 ether, false);

        // didnt actually transfer the currency
        vault.sync(currency1);
        vault.settle();
    }

    function testLockNotSettledWithoutFullyPayment_HookDelta() public noIsolate {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledWithoutFullyPayment, ()));
    }

    function _testLockNotSettledWithoutFullyPayment_HookDelta() external {
        poolManager1.mockAccountingWithHookDelta(poolKey1, -10 ether, -10 ether, -1 ether, 0 ether);

        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);

        // didnt actually transfer the currency for hook's 1 ether
        vault.sync(currency1);
        vault.settle();
    }

    function testLockNotSettledAsPayTooMuch() public noIsolate {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledAsPayTooMuch, ()));
    }

    function _testLockNotSettledAsPayTooMuch() external {
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 12 ether, false);
    }

    function testLockNotSettledAsPayTooMuch_HookDelta() public noIsolate {
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vault.lock(abi.encodeCall(VaultTest._testLockNotSettledAsPayTooMuch_HookDelta, ()));
    }

    function _testLockNotSettledAsPayTooMuch_HookDelta() external {
        poolManager1.mockAccountingWithHookDelta(poolKey1, -10 ether, -10 ether, -1 ether, 0 ether);
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);

        // hook overpay
        fakeHook1.settle(currency0, 2 ether, false);
    }

    function testNotCorrectPoolManager() public {
        // DOUBLE-CHECK:
        // The tx will complete without revert, is this going to be a problem ?
        vault.lock(abi.encodeCall(VaultTest._testNotCorrectPoolManager, ()));
    }

    function _testNotCorrectPoolManager() external {
        // poolKey.poolManager was hacked hence not equal to msg.sender
        PoolKey memory maliciousPoolKey = poolKey1;
        poolManager1.mockAccounting(maliciousPoolKey, -3 ether, -3 ether);
        currency0.settle(vault, address(this), 3 ether, false);
        currency1.settle(vault, address(this), 3 ether, false);

        maliciousPoolKey.poolManager = IPoolManager(address(0));
        poolManager1.mockAccounting(maliciousPoolKey, -3 ether, 3 ether);
        currency0.settle(vault, address(this), 3 ether, false);
        currency1.take(vault, address(this), 3 ether, false);
    }

    function testLockSettledWhenAddLiquidity() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockSettledWhenAddLiquidity, ()));
    }

    function _testLockSettledWhenAddLiquidity() external {
        // verify it's all zero before adding liquidity
        vault.sync(currency0);
        (Currency currency, uint256 amount) = vault.getVaultReserve();
        assertEq(Currency.unwrap(currency), Currency.unwrap(currency0));
        assertEq(amount, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 0 ether);
        currency0.transfer(address(vault), 10 ether);
        vault.settle();

        vault.sync(currency1);
        (currency, amount) = vault.getVaultReserve();
        assertEq(Currency.unwrap(currency), Currency.unwrap(currency1));
        assertEq(amount, 0 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 0 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 0 ether);

        currency1.transfer(address(vault), 10 ether);
        vault.settle();

        // generating delta for adding liquidity
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 10 ether);
    }

    function testLockSettledWhenSwap() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockSettledWhenSwap, ()));
    }

    function _testLockSettledWhenSwap() external {
        // adding enough liquidity before swap
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        uint256 token0Before = currency0.balanceOfSelf();
        uint256 token1Before = currency1.balanceOfSelf();

        // swap
        poolManager1.mockAccounting(poolKey1, -3 ether, 3 ether);
        currency0.settle(vault, address(this), 3 ether, false);
        currency1.take(vault, address(this), 3 ether, false);

        // user paid 3 token0 and received 3 token1
        assertEq(token0Before - currency0.balanceOfSelf(), 3 ether);
        assertEq(currency1.balanceOfSelf() - token1Before, 3 ether);

        // vault received 3 token0 and paid 3 token1
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 13 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 7 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 13 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 7 ether);
    }

    function testLockWhenAlreadyLocked() public noIsolate {
        vm.expectRevert(abi.encodeWithSelector(IVault.LockerAlreadySet.selector, address(this)));
        vault.lock(abi.encodeCall(VaultTest._testLockWhenAlreadyLocked, ()));
    }

    function _testLockWhenAlreadyLocked() external {
        vault.lock(new bytes(0));
    }

    function testLockWhenMoreThanOnePoolManagers() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockWhenMoreThanOnePoolManagers, ()));
    }

    function _testLockWhenMoreThanOnePoolManagers() external {
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager2.mockAccounting(poolKey2, -10 ether, -10 ether);

        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 20 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency1), 10 ether);
    }

    function testVaultFuzz_mint(uint256 amt) public noIsolate {
        amt = bound(amt, 0, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_mint, (amt)));
    }

    function _testVaultFuzz_mint(uint256 amt) external {
        currency0.settle(vault, address(this), amt, false);
        vault.mint(address(this), currency0, amt);
        assertEq(vault.balanceOf(address(this), currency0), amt);
    }

    function testVaultFuzz_mint_toSomeoneElse(uint256 amt) public noIsolate {
        amt = bound(amt, 0, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_mint_toSomeoneElse, (amt)));
    }

    function _testVaultFuzz_mint_toSomeoneElse(uint256 amt) external {
        currency0.settle(vault, address(this), amt, false);
        vault.mint(makeAddr("someone"), currency0, amt);
        assertEq(vault.balanceOf(makeAddr("someone"), currency0), amt);
    }

    function testVaultFuzz_burn(uint256 amt) public noIsolate {
        amt = bound(amt, 0, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_burn, (amt)));
    }

    function _testVaultFuzz_burn(uint256 amt) external {
        // make sure router has enough tokens
        currency0.settle(vault, address(this), amt, false);
        vault.mint(address(this), currency0, amt);

        vault.burn(address(this), currency0, amt);
        currency0.take(vault, address(this), amt, false);
        assertEq(vault.balanceOf(address(this), currency0), 0);
    }

    function testVaultFuzz_burnHalf(uint256 amt) public noIsolate {
        amt = bound(amt, 0, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_burnHalf, (amt)));
    }

    function _testVaultFuzz_burnHalf(uint256 amt) external {
        // make sure router has enough tokens
        currency0.settle(vault, address(this), amt, false);
        vault.mint(address(this), currency0, amt);

        vault.burn(address(this), currency0, amt / 2);
        currency0.take(vault, address(this), amt / 2, false);
        assertEq(vault.balanceOf(address(this), currency0), amt - amt / 2);
    }

    function testVaultFuzz_burnFrom_withoutApprove(uint256 amt) public noIsolate {
        amt = bound(amt, 1, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_burnFrom_withoutApprove, (amt)));
    }

    function _testVaultFuzz_burnFrom_withoutApprove(uint256 amt) external {
        // make sure router has enough tokens
        currency0.settle(vault, address(this), amt, false);
        vault.mint(makeAddr("someone"), currency0, amt);

        vm.expectRevert(stdError.arithmeticError);
        vault.burn(makeAddr("someone"), currency0, amt);
    }

    function testVaultFuzz_burnFrom_withApprove(uint256 amt) public noIsolate {
        amt = bound(amt, 10, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testVaultFuzz_burnFrom_withApprove, (amt)));
    }

    function _testVaultFuzz_burnFrom_withApprove(uint256 amt) external {
        address someone = makeAddr("someone");
        // make sure router has enough tokens
        currency0.settle(vault, address(this), amt, false);
        vault.mint(someone, currency0, amt);

        vm.prank(someone);
        vault.approve(address(this), currency0, amt);
        assertEq(vault.allowance(someone, address(this), currency0), amt);

        vault.burn(someone, currency0, amt);
        currency0.take(vault, someone, amt, false);

        // burn from someone and consumed all the allowance
        assertEq(vault.balanceOf(someone, currency0), 0);
        assertEq(vault.allowance(someone, address(this), currency0), 0);

        // approve max
        {
            someone = makeAddr("someone2");
            // make sure router has enough tokens
            currency0.settle(vault, address(this), amt, false);
            vault.mint(someone, currency0, amt);

            vm.prank(someone);
            vault.approve(address(this), currency0, type(uint256).max);

            vault.burn(someone, currency0, amt);
            currency0.take(vault, someone, amt, false);

            // approve max will never consume allowance
            assertEq(vault.balanceOf(someone, currency0), 0);
            assertEq(vault.allowance(someone, address(this), currency0), type(uint256).max);
        }

        // operator
        {
            someone = makeAddr("someone3");
            // make sure router has enough tokens
            currency0.settle(vault, address(this), amt, false);
            vault.mint(someone, currency0, amt);

            // set a insufficient allowance
            vm.prank(someone);
            vault.approve(address(this), currency0, 1);

            // set this as operator
            vm.prank(someone);
            vault.setOperator(address(this), true);

            vault.burn(someone, currency0, amt);
            currency0.take(vault, someone, amt, false);

            // transfer from operator don't consume allowance
            assertEq(vault.balanceOf(someone, currency0), 0);
            assertEq(vault.allowance(someone, address(this), currency0), 1);
        }
    }

    function testLockInSufficientBalanceWhenMoreThanOnePoolManagers() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockInSufficientBalanceWhenMoreThanOnePoolManagers, ()));
    }

    function _testLockInSufficientBalanceWhenMoreThanOnePoolManagers() external {
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager2.mockAccounting(poolKey2, -10 ether, -10 ether);

        // now pool1 and pool2 both have 10 ether of each currency
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 20 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency1), 10 ether);

        // try to get more than 10 ether from pool1
        assertEq(currency0.balanceOfSelf(), 980 ether);
        currency0.transfer(address(vault), 15 ether);

        vm.expectRevert(stdError.arithmeticError);
        poolManager1.mockAccounting(poolKey1, 15 ether, -10 ether);
    }

    function testLockFlashloanCrossMoreThanOnePoolManagers() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockFlashloanCrossMoreThanOnePoolManagers, ()));
    }

    function _testLockFlashloanCrossMoreThanOnePoolManagers() external {
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager2.mockAccounting(poolKey2, -10 ether, -10 ether);

        // now pool1 and pool2 both have 10 ether of each currency
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 20 ether);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 20 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency0), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey2.poolManager), currency1), 10 ether);

        // flashloan are allowed to take more than the pool has
        vault.take(currency0, address(this), 20 ether);
        vault.take(currency1, address(this), 20 ether);

        // ... flashloan logic

        currency0.settle(vault, address(this), 20 ether, false);
        currency1.settle(vault, address(this), 20 ether, false);
    }

    function test_CollectFee() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._test_CollectFee, ()));

        // collectFee can be called no matter vault is locked or not
        vm.prank(address(poolManager1));
        vault.collectFee(currency0, 10 ether, address(poolManager1));

        // after collectFee assert
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager1)), 10 ether);
    }

    function _test_CollectFee() external {
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        // before collectFee assert
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager1)), 0 ether);
    }

    function test_CollectFee_WhenVaultLocked() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._test_CollectFee_WhenVaultLocked, ()));
    }

    function _test_CollectFee_WhenVaultLocked() external {
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKey1, -10 ether, -10 ether);

        // before collectFee assert
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 10 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 10 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager1)), 0 ether);

        // collectFee can be called no matter vault is locked or not
        vm.prank(address(poolManager1));
        vault.collectFee(currency0, 10 ether, address(poolManager1));

        // after collectFee assert
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 0 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 0 ether);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager1)), 10 ether);
    }

    function test_CollectFeeFromRandomUser() public {
        address bob = makeAddr("bob");
        vm.startPrank(bob);
        // expected revert as bob is not a valid pool manager
        vm.expectRevert(IVault.AppUnregistered.selector);
        vault.collectFee(currency0, 10 ether, bob);
    }

    function test_CollectFeeWhenCurrencyIsSynced() public noIsolate {
        vm.expectRevert(IVault.FeeCurrencySynced.selector);
        vault.lock(abi.encodeCall(VaultTest._test_CollectFeeWhenCurrencyIsSynced, ()));
    }

    function _test_CollectFeeWhenCurrencyIsSynced() external {
        vault.sync(currency0);
        vm.prank(address(poolManager1));
        vault.collectFee(currency0, 10 ether, address(poolManager1));
    }

    function testTake_failsWithNoLiquidity() public {
        vault.lock(abi.encodeCall(VaultTest._testTake_failsWithNoLiquidity, ()));
    }

    function _testTake_failsWithNoLiquidity() external {
        vm.expectRevert();
        vault.take(currency1, address(this), 5 ether);
    }

    function testLock_NoOperation() public {
        vault.lock(abi.encodeCall(VaultTest._testLock_NoOperation, ()));
    }

    function _testLock_NoOperation() external {}

    function testVault_ethSupport_transferInAndSettle() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_ethSupport_transferInAndSettle, ()));
    }

    function _testVault_ethSupport_transferInAndSettle() external {
        PoolKey memory poolKeyWithNativeToken = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager1,
            fee: 0,
            parameters: 0x00
        });

        // transfer in & settle
        CurrencyLibrary.NATIVE.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);

        poolManager1.mockAccounting(poolKeyWithNativeToken, -10 ether, -10 ether);

        assertEq(CurrencyLibrary.NATIVE.balanceOf(address(vault)), 10 ether);
        assertEq(vault.reservesOfApp(address(poolManager1), CurrencyLibrary.NATIVE), 10 ether);
    }

    function testVault_ethSupport_SettleNonNativeCurrencyWithValue() public {
        vault.lock(abi.encodeCall(VaultTest._testVault_ethSupport_SettleNonNativeCurrencyWithValue, ()));
    }

    function _testVault_ethSupport_SettleNonNativeCurrencyWithValue() external {
        vault.sync(currency0);
        vm.expectRevert(IVault.SettleNonNativeCurrencyWithValue.selector);
        vault.settle{value: 10}();
    }

    function testVault_ethSupport_settleAndTake() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_ethSupport_settleAndTake, ()));
    }

    function _testVault_ethSupport_settleAndTake() external {
        CurrencyLibrary.NATIVE.settle(vault, address(this), 10 ether, false);
        CurrencyLibrary.NATIVE.take(vault, makeAddr("receiver"), 10 ether, false);
    }

    function testVault_ethSupport_flashloan() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_ethSupport_flashloan, ()));
    }

    function _testVault_ethSupport_flashloan() external {
        PoolKey memory poolKeyWithNativeToken1 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager1,
            fee: 0,
            parameters: 0x00
        });

        PoolKey memory poolKeyWithNativeToken2 = PoolKey({
            currency0: CurrencyLibrary.NATIVE,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager2,
            fee: 0,
            parameters: 0x00
        });

        CurrencyLibrary.NATIVE.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager1.mockAccounting(poolKeyWithNativeToken1, -10 ether, -10 ether);

        CurrencyLibrary.NATIVE.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);
        poolManager2.mockAccounting(poolKeyWithNativeToken2, -10 ether, -10 ether);

        // flashloan are allowed to take more than the pool has
        address borrower = makeAddr("borrower");
        vm.startPrank(borrower);
        vault.take(CurrencyLibrary.NATIVE, borrower, 20 ether);
        vault.take(currency1, borrower, 20 ether);

        // ... flashloan logic

        vault.settle{value: 20 ether}();
        vault.sync(currency1);
        currency1.transfer(address(vault), 20 ether);
        vault.settle();
        vm.stopPrank();

        assertEq(CurrencyLibrary.NATIVE.balanceOf(borrower), 0 ether);
        assertEq(currency1.balanceOf(borrower), 0 ether);
    }

    function testVault_clear_existingDeltaNegative() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_existingDeltaNegative, ()));
    }

    function _testVault_clear_existingDeltaNegative() external {
        poolManager1.mockAccounting(poolKey1, -10 ether, 0 ether);
        // clear with negative delta
        vm.expectRevert(IVault.MustClearExactPositiveDelta.selector);
        vault.clear(currency0, 10 ether);

        currency0.settle(vault, address(this), 10 ether, false);
    }

    function testVault_clear_existingDeltaGreaterThanInput() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_existingDeltaGreaterThanInput, ()));
    }

    function _testVault_clear_existingDeltaGreaterThanInput() external {
        // make sure vault has enough balance
        currency0.settle(vault, address(this), 20 ether, false);
        poolManager1.mockAccounting(poolKey1, -20 ether, 0);

        poolManager1.mockAccounting(poolKey1, 11 ether, 0 ether);
        // clear with smaller delta
        vm.expectRevert(IVault.MustClearExactPositiveDelta.selector);
        vault.clear(currency0, 10 ether);

        currency0.take(vault, address(this), 11 ether, true);
    }

    function testVault_clear_existingDeltaLessThanInput() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_existingDeltaLessThanInput, ()));
    }

    function _testVault_clear_existingDeltaLessThanInput() external {
        // make sure vault has enough balance
        currency0.settle(vault, address(this), 20 ether, false);
        poolManager1.mockAccounting(poolKey1, -20 ether, 0);

        poolManager1.mockAccounting(poolKey1, 9 ether, 0 ether);
        // clear with greater delta
        vm.expectRevert(IVault.MustClearExactPositiveDelta.selector);
        vault.clear(currency0, 10 ether);

        currency0.take(vault, address(this), 9 ether, true);
    }

    function testVault_clear_withAmountZero() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_withAmountZero, ()));
    }

    function _testVault_clear_withAmountZero() external {
        // make sure vault has enough balance
        currency0.settle(vault, address(this), 20 ether, false);
        poolManager1.mockAccounting(poolKey1, -20 ether, 0);

        poolManager1.mockAccounting(poolKey1, 10 ether, 0 ether);
        // clear with 0 amount
        vm.expectRevert(IVault.MustClearExactPositiveDelta.selector);
        vault.clear(currency0, 0);

        currency0.take(vault, address(this), 10 ether, true);
    }

    function testVault_clear_successWithNonZeroExistingDelta() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_successWithNonZeroExistingDelta, ()));
    }

    function _testVault_clear_successWithNonZeroExistingDelta() external {
        // make sure vault has enough balance
        currency0.settle(vault, address(this), 20 ether, false);
        poolManager1.mockAccounting(poolKey1, -20 ether, 0);

        poolManager1.mockAccounting(poolKey1, 10 ether, 0 ether);
        vault.clear(currency0, 10 ether);
        vm.snapshotGasLastCall("testVault_clear_successWithNonZeroExistingDelta");
    }

    function testVault_clear_successWithZeroExistingDelta() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testVault_clear_successWithZeroExistingDelta, ()));
    }

    function _testVault_clear_successWithZeroExistingDelta() external {
        // make sure vault has enough balance
        currency0.settle(vault, address(this), 20 ether, false);
        poolManager1.mockAccounting(poolKey1, -20 ether, 0);

        vault.clear(currency0, 0);
        vm.snapshotGasLastCall("testVault_clear_successWithZeroExistingDelta");
    }

    function testLockSettledWhenAddLiquidity_HookDelta() public noIsolate {
        vault.lock(abi.encodeCall(VaultTest._testLockSettledWhenAddLiquidity_HookDelta, ()));
    }

    function _testLockSettledWhenAddLiquidity_HookDelta() external {
        // adding enough liquidity before swap
        currency0.settle(vault, address(this), 10 ether, false);
        currency1.settle(vault, address(this), 10 ether, false);

        // hook provide some incentive by giving 2 eth worth of token0
        fakeHook1.settle(currency0, 2 ether, false);

        poolManager1.mockAccountingWithHookDelta(poolKey1, -10 ether, -10 ether, -2 ether, 0 ether);

        uint256 token0Before = currency0.balanceOfSelf();
        uint256 token1Before = currency1.balanceOfSelf();
        uint256 token0BeforeHook = token0.balanceOf(address(poolKey1.hooks));
        uint256 token1BeforeHook = token1.balanceOf(address(poolKey1.hooks));

        // swap
        poolManager1.mockAccountingWithHookDelta(poolKey1, -3 ether, 3 ether, 1 ether, -1 ether);
        currency0.settle(vault, address(this), 3 ether, false);
        currency1.take(vault, address(this), 3 ether, false);

        // hook take 1 eth of token0 and give 1 eth of token1
        fakeHook1.take(currency0, 1 ether, false);
        fakeHook1.settle(currency1, 1 ether, false);

        // user paid 3 token0 and received 3 token1
        assertEq(token0Before - currency0.balanceOfSelf(), 3 ether);
        assertEq(currency1.balanceOfSelf() - token1Before, 3 ether);

        // hook take 1 ether of token0 and given 1 ether of token1 incentives
        assertEq(token0.balanceOf(address(poolKey1.hooks)) - token0BeforeHook, 1 ether);
        assertEq(token1BeforeHook - token1.balanceOf(address(poolKey1.hooks)), 1 ether);

        // token0: add 10 ether, + 3 ether in swap + hook give 2 eth in liquidity - hook take 1 eth in swap
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(vault)), 14 ether);
        // token1: add 10 ether, - 3 ether in swap + hook give 1 eth
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(vault)), 8 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 14 ether);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 8 ether);
    }

    function testFuzzAccountBalanceDeltaWithHookDelta_OverwriteCurve(uint256 amt0, uint256 amt1) public noIsolate {
        amt0 = bound(amt0, 0, 10 ether);
        amt1 = bound(amt1, 0, 10 ether);
        vault.lock(abi.encodeCall(VaultTest._testFuzzAccountBalanceDeltaWithHookDelta_OverwriteCurve, (amt0, amt1)));
    }

    /// @dev assume stableSwap curve 1:1 wihere hookDelta + delta = 0
    function _testFuzzAccountBalanceDeltaWithHookDelta_OverwriteCurve(uint256 amt0, uint256 amt1) external {
        int128 amt0Int128 = int128(uint128(amt0));
        int128 amt1Int128 = int128(uint128(amt1));

        poolManager1.mockAccountingWithHookDelta(poolKey1, -amt0Int128, amt1Int128, amt0Int128, -amt1Int128);
        currency0.settle(vault, address(this), amt0, false);
        currency1.take(vault, address(this), amt1, true); // mint VaultToken

        fakeHook1.take(currency0, amt0, true); // mint VaultToken
        fakeHook1.settle(currency1, amt1, false);

        // reserveOfApp should be 0 as delta/hookDelta balnce out each other
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), 0);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), 0);
    }

    /// @dev assume add liqudiity where user add liquidity and hook also take a fee (half of liquidity)
    function testFuzzAccountBalanceDeltaWithHookDelta_AddLiquidityHookFee(uint256 amt0, uint256 amt1)
        public
        noIsolate
    {
        amt0 = bound(amt0, 0, 10 ether);
        amt1 = bound(amt1, 0, 10 ether);
        vault.lock(
            abi.encodeCall(VaultTest._testFuzzAccountBalanceDeltaWithHookDelta_AddLiquidityHookFee, (amt0, amt1))
        );
    }

    function _testFuzzAccountBalanceDeltaWithHookDelta_AddLiquidityHookFee(uint256 amt0, uint256 amt1) external {
        int128 amt0Int128 = int128(uint128(amt0));
        int128 amt1Int128 = int128(uint128(amt1));

        poolManager1.mockAccountingWithHookDelta(poolKey1, -amt0Int128, -amt1Int128, amt0Int128 / 2, amt1Int128 / 2);
        assertEq(vault.currencyDelta(msg.sender, currency0), -amt0Int128);
        assertEq(vault.currencyDelta(msg.sender, currency1), -amt1Int128);
        assertEq(vault.currencyDelta(address(poolKey1.hooks), currency0), amt0Int128 / 2);
        assertEq(vault.currencyDelta(address(poolKey1.hooks), currency1), amt1Int128 / 2);

        // user add liquidity and settle with vault
        currency0.settle(vault, address(this), amt0, false);
        currency1.settle(vault, address(this), amt1, false);

        // hook take a fee
        uint256 fee0 = amt0 / 2;
        uint256 fee1 = amt1 / 2;
        fakeHook1.take(currency0, fee0, false);
        fakeHook1.take(currency1, fee1, false);

        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), amt0 - fee0);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), amt1 - fee1);
    }

    /// @dev assume add liqudiity where user remove liquidity and hook also take a fee (half of liquidity)
    function testFuzzAccountBalanceDeltaWithHookDelta_RemoveLiquidityHookFee(uint256 amt0, uint256 amt1)
        public
        noIsolate
    {
        amt0 = bound(amt0, 0, 10 ether);
        amt1 = bound(amt1, 0, 10 ether);
        vault.lock(
            abi.encodeCall(VaultTest._testFuzzAccountBalanceDeltaWithHookDelta_RemoveLiquidityHookFee, (amt0, amt1))
        );
    }

    function _testFuzzAccountBalanceDeltaWithHookDelta_RemoveLiquidityHookFee(uint256 amt0, uint256 amt1) external {
        int128 amt0Int128 = int128(uint128(amt0));
        int128 amt1Int128 = int128(uint128(amt1));

        /// Assume some liquidity added before.
        poolManager1.mockAccountingWithHookDelta(poolKey1, -(amt0Int128 * 2), -(amt1Int128 * 2), 0, 0);
        currency0.settle(vault, address(this), amt0 * 2, false);
        currency1.settle(vault, address(this), amt1 * 2, false);
        uint256 reserve0Before = vault.reservesOfApp(address(poolKey1.poolManager), currency0);
        uint256 reserve1Before = vault.reservesOfApp(address(poolKey1.poolManager), currency1);

        // if no liqudiity added above, reserveOfApp will underflow here, as taking more out of app
        // in the real world, this will not happen as user will need to pay the hook fee
        poolManager1.mockAccountingWithHookDelta(poolKey1, amt0Int128, amt1Int128, amt0Int128 / 2, amt1Int128 / 2);

        // user remove liquidity
        currency0.take(vault, address(this), amt0, false);
        currency1.take(vault, address(this), amt1, false);

        // hook take a fee
        uint256 fee0 = amt0 / 2;
        uint256 fee1 = amt1 / 2;
        fakeHook1.take(currency0, fee0, false);
        fakeHook1.take(currency1, fee1, false);

        // reserveOfApp should be 0 as delta/hookDelta balnce out each other
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency0), reserve0Before - amt0 - fee0);
        assertEq(vault.reservesOfApp(address(poolKey1.poolManager), currency1), reserve1Before - amt1 - fee1);
    }

    function testVaultOwner_get() public noIsolate {
        assertEq(vault.owner(), address(this));
    }

    function testVaultOwner_registerApp() public noIsolate {
        vault.registerApp(makeAddr("app1"));
        assertEq(vault.isAppRegistered(makeAddr("app1")), true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("someone")));
        vm.prank(makeAddr("someone"));
        vault.registerApp(makeAddr("app2"));
    }

    function testVaultOwner_2StepsTransferOwnership() public noIsolate {
        assertEq(vault.owner(), address(this));
        vault.transferOwnership(makeAddr("newOwner"));

        // ownership is not transferred yet, it's still this contract
        assertEq(vault.owner(), address(this));
        assertEq(vault.pendingOwner(), makeAddr("newOwner"));

        // new owner must accept the ownership manually
        vm.prank(makeAddr("newOwner"));
        vault.acceptOwnership();
        assertEq(vault.owner(), makeAddr("newOwner"));
    }

    function lockAcquired(bytes calldata data) external returns (bytes memory result) {
        // forward the call and bubble up the error if revert
        bool success;
        (success, result) = address(this).call(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
