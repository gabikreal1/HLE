// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MockPrecompiles
 * @notice Mock HyperCore precompiles for testing without forking
 * @dev Simulates the behavior of HyperCore precompiles
 */
contract MockPrecompiles {
    // Configurable mock values
    uint64 public mockSpotPrice = 2500 * 1e8; // $2500 with 8 decimals
    uint64 public mockOraclePrice = 2500 * 1e8;
    uint64 public mockL1BlockNumber = 1000;
    
    // Per-index price mappings
    mapping(uint64 => uint64) public spotPrices;
    mapping(uint32 => uint64) public oraclePrices;
    
    mapping(address => mapping(uint64 => uint64)) public spotBalances;
    mapping(address => Delegation[]) public delegations;
    mapping(address => DelegatorSummary) public delegatorSummaries;

    struct Delegation {
        address validator;
        uint64 amount;
        uint64 lockedUntilTimestamp;
    }

    struct DelegatorSummary {
        uint64 delegated;
        uint64 undelegated;
        uint64 totalPendingWithdrawal;
        uint64 nPendingWithdrawals;
    }

    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // SETTERS FOR TESTING
    // ═══════════════════════════════════════════════════════════════════════════════

    function setSpotPrice(uint64 _price) external {
        mockSpotPrice = _price;
    }

    function setSpotPrice(uint64 spotIndex, uint64 _price) external {
        spotPrices[spotIndex] = _price;
    }

    function setOraclePrice(uint64 _price) external {
        mockOraclePrice = _price;
    }

    function setOraclePrice(uint32 perpIndex, uint64 _price) external {
        oraclePrices[perpIndex] = _price;
    }

    function setL1BlockNumber(uint64 _blockNumber) external {
        mockL1BlockNumber = _blockNumber;
    }

    function setSpotBalance(address user, uint64 token, uint64 balance) external {
        spotBalances[user][token] = balance;
    }

    function addDelegation(address user, address validator, uint64 amount) external {
        delegations[user].push(Delegation({
            validator: validator,
            amount: amount,
            lockedUntilTimestamp: 0
        }));
        delegatorSummaries[user].delegated += amount;
    }

    // ═══════════════════════════════════════════════════════════════════════════════
    // PRECOMPILE SIMULATION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice Simulate spot price precompile (0x808)
    function spotPx(uint64 spotIndex) external view returns (uint64) {
        if (spotPrices[spotIndex] != 0) {
            return spotPrices[spotIndex];
        }
        return mockSpotPrice;
    }

    /// @notice Simulate oracle price precompile (0x807)  
    function oraclePx(uint32 perpIndex) external view returns (uint64) {
        if (oraclePrices[perpIndex] != 0) {
            return oraclePrices[perpIndex];
        }
        return mockOraclePrice;
    }

    /// @notice Simulate L1 block number precompile (0x809)
    function l1BlockNumber() external view returns (uint64) {
        return mockL1BlockNumber;
    }

    /// @notice Simulate spot balance precompile (0x801)
    function spotBalance(address user, uint64 token) external view returns (SpotBalance memory) {
        return SpotBalance({
            total: spotBalances[user][token],
            hold: 0,
            entryNtl: 0
        });
    }

    /// @notice Simulate delegations precompile (0x804)
    function getDelegations(address user) external view returns (Delegation[] memory) {
        return delegations[user];
    }

    /// @notice Simulate delegator summary precompile (0x805)
    function getDelegatorSummary(address user) external view returns (DelegatorSummary memory) {
        return delegatorSummaries[user];
    }

    /// @notice Simulate spot info precompile (0x80b)
    function spotInfo(uint64 spotIndex) external pure returns (SpotInfo memory) {
        uint64[2] memory tokens = [uint64(1105), uint64(0)]; // HYPE/USDC
        return SpotInfo({
            name: "HYPE/USDC",
            tokens: tokens
        });
    }

    /// @notice Simulate token info precompile (0x80c)
    function tokenInfo(uint64 token) external pure returns (TokenInfo memory) {
        uint64[] memory spots = new uint64[](1);
        spots[0] = 1035; // Spot index
        
        return TokenInfo({
            name: "HYPE",
            spots: spots,
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(0),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: 10
        });
    }
}
