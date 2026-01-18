// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";

import {SovereignPool} from "@valantis-core/pools/SovereignPool.sol";
import {SovereignPoolConstructorArgs} from "@valantis-core/pools/structs/SovereignPoolStructs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HLEALM} from "../src/modules/HLEALM.sol";
import {HLEQuoter} from "../src/modules/HLEQuoter.sol";
import {LendingModule} from "../src/modules/LendingModule.sol";
import {YieldOptimizer} from "../src/modules/YieldOptimizer.sol";

/**
 * @title DeployHLE
 * @notice Deployment script for HLE (Hyper Liquidity Engine)
 * 
 * Usage:
 *   # Deploy to local anvil
 *   forge script script/DeployHLE.s.sol --rpc-url http://localhost:8545 --broadcast
 * 
 *   # Deploy to testnet (dry run)
 *   forge script script/DeployHLE.s.sol --rpc-url $RPC_URL
 * 
 *   # Deploy to testnet (actual deployment)
 *   forge script script/DeployHLE.s.sol --rpc-url $RPC_URL --broadcast --verify
 * 
 * Environment Variables:
 *   PRIVATE_KEY - Deployer private key
 *   TOKEN0 - Token0 address (optional, will deploy mock if not set)
 *   TOKEN1 - Token1 address (optional, will deploy mock if not set)
 *   TOKEN0_INDEX - HyperCore token index for token0
 *   TOKEN1_INDEX - HyperCore token index for token1
 *   PROTOCOL_FACTORY - Valantis ProtocolFactory address
 */
contract DeployHLE is Script {
    // Deployed addresses (filled during deployment)
    address public pool;
    address public alm;
    address public quoter;
    address public lendingModule;
    address public yieldOptimizer;

    // Configuration
    address public token0;
    address public token1;
    uint64 public token0Index;
    uint64 public token1Index;
    address public protocolFactory;
    address public deployer;

    function setUp() public {
        // Load config from environment
        token0 = vm.envOr("TOKEN0", address(0));
        token1 = vm.envOr("TOKEN1", address(0));
        token0Index = uint64(vm.envOr("TOKEN0_INDEX", uint256(0)));
        token1Index = uint64(vm.envOr("TOKEN1_INDEX", uint256(1)));
        protocolFactory = vm.envOr("PROTOCOL_FACTORY", address(0));
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        console.log("=== HLE Deployment ===");
        console.log("Deployer:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy or use existing tokens
        if (token0 == address(0) || token1 == address(0)) {
            console.log("\n[1/5] Deploying mock tokens...");
            (token0, token1) = _deployMockTokens();
        } else {
            console.log("\n[1/5] Using existing tokens");
            console.log("  Token0:", token0);
            console.log("  Token1:", token1);
        }

        // 2. Deploy SovereignPool
        console.log("\n[2/5] Deploying SovereignPool...");
        pool = _deployPool();
        console.log("  Pool:", pool);

        // 3. Deploy HLEALM
        console.log("\n[3/5] Deploying HLEALM...");
        alm = _deployALM();
        console.log("  ALM:", alm);

        // 4. Deploy HLEQuoter
        console.log("\n[4/5] Deploying HLEQuoter...");
        quoter = _deployQuoter();
        console.log("  Quoter:", quoter);

        // 5. Deploy LendingModule
        console.log("\n[5/5] Deploying LendingModule...");
        lendingModule = _deployLendingModule();
        console.log("  LendingModule:", lendingModule);

        // 6. Configure pool
        console.log("\n[Config] Setting up pool...");
        _configurePool();

        // 7. Initialize ALM
        console.log("\n[Init] Initializing ALM EWMA...");
        HLEALM(alm).initialize();
        console.log("  ALM initialized with oracle price");

        vm.stopBroadcast();

        // Print summary
        _printSummary();
    }

    function _deployMockTokens() internal returns (address _token0, address _token1) {
        // Deploy simple mock tokens for testing
        MockERC20 mockToken0 = new MockERC20("Token0", "TKN0", 18);
        MockERC20 mockToken1 = new MockERC20("Token1", "TKN1", 18);
        
        _token0 = address(mockToken0);
        _token1 = address(mockToken1);
        
        // Ensure token0 < token1 (Valantis requirement)
        if (_token0 > _token1) {
            (_token0, _token1) = (_token1, _token0);
        }
        
        console.log("  Token0:", _token0);
        console.log("  Token1:", _token1);
    }

    function _deployPool() internal returns (address _pool) {
        // For local testing, we deploy a minimal pool
        // In production, use ProtocolFactory.deploySovereignPool()
        
        SovereignPoolConstructorArgs memory args = SovereignPoolConstructorArgs({
            token0: token0,
            token1: token1,
            protocolFactory: protocolFactory != address(0) ? protocolFactory : address(this),
            poolManager: deployer,
            sovereignVault: address(0), // Use pool as vault
            verifierModule: address(0),
            isToken0Rebase: false,
            isToken1Rebase: false,
            token0AbsErrorTolerance: 0,
            token1AbsErrorTolerance: 0,
            defaultSwapFeeBips: 0 // ALM handles fees via spread
        });
        
        SovereignPool newPool = new SovereignPool(args);
        _pool = address(newPool);
    }

    function _deployALM() internal returns (address _alm) {
        HLEALM newALM = new HLEALM(
            pool,
            token0Index,
            token1Index,
            deployer, // feeRecipient
            deployer  // owner
        );
        _alm = address(newALM);
    }

    function _deployQuoter() internal returns (address _quoter) {
        HLEQuoter newQuoter = new HLEQuoter(pool, alm);
        _quoter = address(newQuoter);
    }

    function _deployLendingModule() internal returns (address _lending) {
        LendingModule newLending = new LendingModule(
            pool,
            deployer, // strategist
            1e18,     // minSupplyAmount (1 token)
            10        // cooldownBlocks
        );
        _lending = address(newLending);
        
        // Set token indices
        LendingModule(newLending).setTokenIndex(token0, token0Index);
        LendingModule(newLending).setTokenIndex(token1, token1Index);
    }

    function _configurePool() internal {
        SovereignPool(pool).setALM(alm);
        SovereignPool(pool).setPoolManagerFeeBips(0); // ALM handles fees
        console.log("  ALM set on pool");
    }

    function _printSummary() internal view {
        console.log("\n");
        console.log("===========================================");
        console.log("         HLE DEPLOYMENT COMPLETE           ");
        console.log("===========================================");
        console.log("");
        console.log("Addresses:");
        console.log("  Pool:          ", pool);
        console.log("  HLEALM:        ", alm);
        console.log("  HLEQuoter:     ", quoter);
        console.log("  LendingModule: ", lendingModule);
        console.log("");
        console.log("Tokens:");
        console.log("  Token0:        ", token0);
        console.log("  Token1:        ", token1);
        console.log("  Token0 Index:  ", token0Index);
        console.log("  Token1 Index:  ", token1Index);
        console.log("");
        console.log("Next Steps:");
        console.log("  1. Add liquidity: pool.depositLiquidity(...)");
        console.log("  2. Get quote: quoter.quote(tokenIn, tokenOut, amountIn)");
        console.log("  3. Swap: pool.swap(swapParams)");
        console.log("");
        console.log("===========================================");
    }
}

/**
 * @notice Simple mock ERC20 for testing
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
