// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {QuoteValidator} from "../../src/quote/QuoteValidator.sol";
import {IQuoteValidator} from "../../src/interfaces/IQuoteValidator.sol";
import {IOracleModule} from "../../src/interfaces/IOracleModule.sol";
import {MockSovereignPool} from "../mocks/MockSovereignPool.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title MockL1BlockPrecompile
 * @notice Mock for the L1 block number precompile (0x809)
 */
contract MockL1BlockPrecompile {
    uint64 public l1Block = 1000;

    function setL1Block(uint64 _l1Block) external {
        l1Block = _l1Block;
    }

    fallback() external {
        uint64 blockNum = l1Block;
        assembly {
            mstore(0x00, blockNum)
            return(0x00, 0x20)
        }
    }
}

/**
 * @title MockOracleModule
 * @notice Simple mock for testing quote validation
 */
contract MockOracleModule is IOracleModule {
    uint256 public currentPrice = uint256(2500) * uint256(2**96) / uint256(1e8); // $2500 in Q96

    function setPrice(uint256 _price) external {
        currentPrice = _price;
    }

    function getCurrentPrice(address, address) external view override returns (uint256) {
        return currentPrice;
    }

    function snapshotPrice(address, address) external view override returns (OracleSnapshot memory) {
        return OracleSnapshot({
            priceX96: currentPrice,
            l1BlockNumber: 1000,
            timestamp: block.timestamp
        });
    }

    function getLatestSnapshot(address, address) external view override returns (OracleSnapshot memory) {
        return OracleSnapshot({
            priceX96: currentPrice,
            l1BlockNumber: 1000,
            timestamp: block.timestamp
        });
    }

    function isPriceValid(address, address, uint256 priceX96, uint256 maxDeviationBps) 
        external view override returns (bool) 
    {
        uint256 deviation;
        if (priceX96 > currentPrice) {
            deviation = ((priceX96 - currentPrice) * 10000) / currentPrice;
        } else {
            deviation = ((currentPrice - priceX96) * 10000) / currentPrice;
        }
        return deviation <= maxDeviationBps;
    }
}

/**
 * @title QuoteValidatorTest
 * @notice Unit tests for the QuoteValidator
 */
contract QuoteValidatorTest is Test {
    QuoteValidator public validator;
    MockSovereignPool public pool;
    MockOracleModule public oracle;
    MockERC20 public token0;
    MockERC20 public token1;
    MockL1BlockPrecompile public l1BlockMock;

    address public strategist = address(0x1);
    address public user = address(0x2);
    address public otherUser = address(0x3);

    uint256 constant Q96 = 2**96;
    uint256 constant INITIAL_PRICE = 2500 * Q96 / 1e8;

    // L1 block precompile address
    address constant L1_BLOCK_PRECOMPILE = address(0x809);

    function setUp() public {
        // Deploy mocks
        token0 = new MockERC20("HYPE", "HYPE", 18);
        token1 = new MockERC20("USDC", "USDC", 6);
        pool = new MockSovereignPool(address(token0), address(token1));
        oracle = new MockOracleModule();

        // Deploy L1 block mock and etch at precompile address
        l1BlockMock = new MockL1BlockPrecompile();
        vm.etch(L1_BLOCK_PRECOMPILE, address(l1BlockMock).code);
        // Copy storage slot 0 (l1Block variable)
        vm.store(L1_BLOCK_PRECOMPILE, bytes32(uint256(0)), bytes32(uint256(1000)));

        // Deploy validator
        validator = new QuoteValidator(address(pool), address(oracle), strategist);

        // Setup user with tokens
        token0.mint(user, 1000 ether);
        vm.prank(user);
        token0.approve(address(validator), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_Constructor() public view {
        assertEq(address(validator.pool()), address(pool));
        assertEq(address(validator.oracleModule()), address(oracle));
        assertEq(validator.strategist(), strategist);
        assertEq(validator.globalMaxDeviationBps(), 100); // 1%
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // QUOTE VALIDATION TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_ValidateQuote_Valid() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        vm.prank(user);
        (bool valid, string memory reason) = validator.validateQuote(quote);

        assertTrue(valid, "Valid quote should pass");
        assertEq(bytes(reason).length, 0, "No reason for valid quote");
    }

    function test_ValidateQuote_NotIntendedUser() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // Call from different user
        vm.prank(otherUser);
        (bool valid, string memory reason) = validator.validateQuote(quote);

        assertFalse(valid, "Should fail for non-intended user");
        assertEq(reason, "Not intended user");
    }

    function test_ValidateQuote_Expired() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();
        quote.expirationBlock = block.number - 1; // Already expired

        vm.prank(user);
        (bool valid, string memory reason) = validator.validateQuote(quote);

        assertFalse(valid, "Expired quote should fail");
        assertEq(reason, "Quote expired");
    }

    function test_ValidateQuote_OracleDrifted() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // Move oracle price by 5% (beyond 1% max deviation)
        oracle.setPrice(INITIAL_PRICE * 105 / 100);

        vm.prank(user);
        (bool valid, string memory reason) = validator.validateQuote(quote);

        assertFalse(valid, "Should fail when oracle drifted");
        assertEq(reason, "Oracle drifted");
    }

    function test_ValidateQuote_AlreadyUsed() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // First execution
        pool.setReserves(1000 ether, 1000 ether);
        vm.prank(user);
        validator.executeQuote(quote);

        // Try again with same quote
        vm.prank(user);
        (bool valid, string memory reason) = validator.validateQuote(quote);

        assertFalse(valid, "Used quote should fail");
        assertEq(reason, "Quote already used");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ORACLE DRIFT TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_HasOracleDrifted_False() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // No drift
        bool drifted = validator.hasOracleDrifted(quote);
        assertFalse(drifted);
    }

    function test_HasOracleDrifted_True() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // 5% drift
        oracle.setPrice(INITIAL_PRICE * 105 / 100);

        bool drifted = validator.hasOracleDrifted(quote);
        assertTrue(drifted);
    }

    function test_HasOracleDrifted_AtBoundary() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        // Exactly at 1% boundary
        oracle.setPrice(INITIAL_PRICE * 101 / 100);

        // Should still be valid at boundary
        bool drifted = validator.hasOracleDrifted(quote);
        assertFalse(drifted, "Exactly at boundary should not be drifted");
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // ADMIN TESTS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_SetMaxDeviation() public {
        vm.prank(strategist);
        validator.setMaxDeviation(200); // 2%

        assertEq(validator.globalMaxDeviationBps(), 200);
    }

    function test_SetMaxDeviation_OnlyStrategist() public {
        vm.prank(user);
        vm.expectRevert(QuoteValidator.QuoteValidator__OnlyStrategist.selector);
        validator.setMaxDeviation(200);
    }

    function test_SetMaxDeviation_CannotExceedCap() public {
        vm.prank(strategist);
        vm.expectRevert(QuoteValidator.QuoteValidator__DeviationTooHigh.selector);
        validator.setMaxDeviation(600); // Max is 500
    }

    function test_SetStrategist() public {
        address newStrategist = address(0x999);

        vm.prank(strategist);
        validator.setStrategist(newStrategist);

        assertEq(validator.strategist(), newStrategist);
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // HELPER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════════

    function test_GenerateQuoteId() public view {
        bytes32 quoteId = validator.generateQuoteId(
            address(token0),
            address(token1),
            10 ether,
            user,
            1
        );

        assertTrue(quoteId != bytes32(0));
    }

    function test_GetOracleSnapshot() public view {
        (uint256 priceX96, uint64 l1Block) = validator.getOracleSnapshot(
            address(token0),
            address(token1)
        );

        assertEq(priceX96, INITIAL_PRICE);
        assertTrue(l1Block > 0);
    }

    function test_IsQuoteUsed() public {
        IQuoteValidator.Quote memory quote = _createValidQuote();

        assertFalse(validator.isQuoteUsed(quote.quoteId));

        pool.setReserves(1000 ether, 1000 ether);
        vm.prank(user);
        validator.executeQuote(quote);

        assertTrue(validator.isQuoteUsed(quote.quoteId));
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════════

    function _createValidQuote() internal view returns (IQuoteValidator.Quote memory) {
        return IQuoteValidator.Quote({
            tokenIn: address(token0),
            tokenOut: address(token1),
            amountIn: 10 ether,
            amountOutMin: 9 ether,
            executionPriceX96: INITIAL_PRICE,
            oracleSnapshotPriceX96: INITIAL_PRICE,
            oracleL1Block: 1000,
            expirationBlock: block.number + 100,
            intendedUser: user,
            maxDeviationBps: 100,
            quoteId: keccak256(abi.encodePacked(address(token0), address(token1), uint256(10 ether), user, uint256(1)))
        });
    }
}
