// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "./openzeppelin/contracts@3.4.2-solc-0.7/token/ERC721/IERC721Receiver.sol";
import "./uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import "./uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "./uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "./uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "./uniswap/v3-core/contracts/libraries/TickMath.sol";

interface IERC20 {
    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
    
    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);

    /**
     * @dev Destroys `amount` tokens from the caller.
     *
     * See {ERC20-_burn}.
     */
    function burn(uint256 amount) external;
}

library SafeMath {

  /**
  * @dev Multiplies two numbers, throws on overflow.
  */
  function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
    if (a == 0) {
      return 0;
    }
    c = a * b;
    assert(c / a == b);
    return c;
  }
}

/// @title Uniswap V3 canonical staking interface
contract MUDUniswapV3Staker is IERC721Receiver {

    uint constant secPerMonth = 2592000;
    uint constant secPerDay = 86400;
    //This is the DAO fund address that will be appointed by DAO, the fund from the penalties will be used as R&D fund or 
    //bounty rewards which will be voted by the community members
    address constant  daoFundAddress = address(0x2cD63d1C39373d1Af4F68e57991924F5DAC1a8B6);
    address immutable admin;    
    //Uniswap liqudity pool address for MUDmud/USDTmud token pair, the pool address will be changed to MUD/USDT uniswap v3 token pair of matic mainnet
    IUniswapV3Pool constant lpPool = IUniswapV3Pool(address(0x5338968F9646e4A865D76e07C2A6E340Dd3aC462)); 
    //official NonfungiblePositionManager contract address of Uniswap v3
    INonfungiblePositionManager constant nonfungiblePositionManager = INonfungiblePositionManager(address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88));
    //official UniswapV3Factory contract address
    IUniswapV3Factory constant factory = IUniswapV3Factory(address(0x1F98431c8aD98523631AE4a59f267346ea31F984));
    //The official USDT token address of polygon mainnet
    address constant usdtAddr = address(0xc2132D05D31c914a87C6611C10748AEb04B58e8F);
    //The official MUD token address of polygon mainnet
    address constant mudAddr = address(0xf6EaC236757e82D6772E8bD02D36a0c791d78C51);
    IERC20 constant usdt = IERC20(usdtAddr);
    IERC20 constant mud = IERC20(mudAddr);

    /// @notice Represents a staking contract info
    struct StakingContractInfo {        
        uint256 tokenId; //UNISWAP V3 liquidity NFT position id
        uint8 duration; //staking period, 3,6,12 in months(every months 30 days)
        uint startTime;//staking start block time
        uint endTime;//staking end time
        uint256 startMUD; //initial MUD staked
        uint256 startUSDT; //initial USDT staked
    }  

    mapping(address => StakingContractInfo[]) private stakingContractInfoMap;
    mapping(uint256 => address) private tokenOwner;
    
    //event type
    event mudLPStaked(address owner, uint256 tokenId, uint8 duration, uint256 usdtToStake, uint256 mudToStake, uint256 usdtStaked, uint256 mudStaked, uint startTime, uint endTime, uint nodeId);
    event mudLPUnstaked(address owner, uint256 tokenId, uint256 usdtReleased, uint256 mudReleased);
    event mudLPUnstakeTokenIdNotFound(address owner, uint256 tokenId);    
    event mudLPPrematureUnstaked(address owner, uint256 tokenId, uint256 usdtToDAOFund, uint256 mudBurnt);
    event mudLPPrematureUnstakIgnored(address owner, uint256 tokenId);
    event mudLPAddressUnstaked(address addr);




    constructor() {        
        admin = address(msg.sender);
    }

    function getPositionInfo(uint256 tokenId)
        internal
        view
        returns (
            IUniswapV3Pool pool,
            address token0,
            address token1,
            int24 lowerTick,
            int24 upperTick,
            uint128 liquidity
        )
    {
        uint24 fee;
        (, , token0, token1, fee, lowerTick, upperTick, liquidity, , , , ) = nonfungiblePositionManager.positions(
            tokenId
        );

        pool = IUniswapV3Pool(
            PoolAddress.computeAddress(
                address(factory),
                PoolAddress.PoolKey({token0: token0, token1: token1, fee: fee})
            )
        );       
    }

    // Create new uniswap v3 liquidity for MUD/USDT token pair.
    // The amount of USDT and MUD will be transferred from the user's address to the contract first,
    // once the liquidity is created, the actual amount of the tokens staked will be known and the leftover of the user's tokens 
    // will be sent back to the user's address, and the approved amount will be cleared to 0
    // Parameters:
    //   usdtToStake: USDT to be staked
    //   mudToStake: MUD to be staked
    //   duration: stake period (3/6/12 months, each month 30 days)
    //   nodeId: DAPP to use, must return in events
    //   slippageFactor: range from 850 to 999 that is slippage 0.001% to 15%
    // Returns:
    //   tokenId: UNISWAP V3 liquidity NFT position id
    //   liquidity: uniswap v3 liquidity created
    //   amount0: USDT staked
    //   amount1: MUD staked
    //   startTime: staking start time
    //   endTime: staking end time
    function createNewStakingContract(uint256 usdtToStake, uint256 mudToStake, uint8 duration, uint nodeId, uint256 slippageFactor)
        external
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint startTime, 
            uint endTime
        )
    {
        require(nodeId > 0 && nodeId <= 500000, "nodeId should between 1-500000 !");
        require(slippageFactor >= 850 && slippageFactor <= 999, "slippageFactor should between 850 to 999 !");
        require(duration == 3 || duration == 6 || duration == 12, "Duration should be 3/6/12 !");
        require(usdtToStake > 0, "USDT amount should > 0 !");
        require(mudToStake > 0, "MUD amount should > 0");
        uint256 amount0ToMint = usdtToStake;
        uint256 amount1ToMint = mudToStake;

        // transfer tokens to contract
        require(usdt.transferFrom(msg.sender, address(this), amount0ToMint), "USDT transferFrom() failed!");
        require(mud.transferFrom(msg.sender, address(this), amount1ToMint), "MUD transferFrom() failed!");

        // Approve the position manager
        usdt.approve(address(nonfungiblePositionManager), amount0ToMint);
        mud.approve(address(nonfungiblePositionManager), amount1ToMint);

        INonfungiblePositionManager.MintParams memory params =
            INonfungiblePositionManager.MintParams({
                token0: usdtAddr,
                token1: mudAddr,
                fee: 3000,
                tickLower: -69060,//The actual token pair MUD/USDT of polygon mainnet
                tickUpper: 57060,//The actual token pair MUD/USDT of polygon mainnet
                amount0Desired: amount0ToMint,
                amount1Desired: amount1ToMint,
                amount0Min: SafeMath.mul(amount0ToMint, slippageFactor) / 1000, // slippage protection
                amount1Min: SafeMath.mul(amount1ToMint, slippageFactor) / 1000, // slippage protection
                recipient: address(this),
                deadline: block.timestamp
            });

        // Note that the pool defined by MUD/USDT and fee tier 0.3% must already be created and initialized in order to mint
        (tokenId, liquidity, amount0, amount1) = nonfungiblePositionManager.mint(params);

        // store the newly created staking contract
        tokenOwner[tokenId] = msg.sender;

        startTime = block.timestamp;
        endTime = block.timestamp + duration * secPerMonth;
        
        stakingContractInfoMap[msg.sender].push(
            StakingContractInfo(
                {tokenId : tokenId, 
                 duration: duration, 
                 startTime: startTime, 
                 endTime: endTime,
                 startMUD: amount1,
                 startUSDT: amount0
                }
            )
        );

        // Remove allowance and refund in both assets.
        if (amount0 < amount0ToMint) {
            usdt.approve(address(nonfungiblePositionManager), 0);
            uint256 refund0 = amount0ToMint - amount0;
            require(usdt.transfer(msg.sender, refund0), "USDT transfer failed !");
        }

        if (amount1 < amount1ToMint) {
            mud.approve(address(nonfungiblePositionManager), 0);
            uint256 refund1 = amount1ToMint - amount1;
            require(mud.transfer(msg.sender, refund1), "MUD transfer failed !");
        }
        
        uint nodeIdOut = nodeId;//to pass the compiling , otherwise compiler will have stack too deep error.
        emit mudLPStaked(msg.sender, tokenId, duration, amount0ToMint, amount1ToMint, amount0, amount1, startTime, endTime, nodeIdOut);
    }

   // Release the liquidity from Uniswap v3, return the assets to the owner address
   // Parameter:
   //   tokenId: UNISWAP V3 liquidity NFT position id
   // Returns:
   //   usdtReleased: USDT amount to the owner
   //   mudReleased: MUD amount to the owner
   function unstake(uint256 tokenId) public returns (uint256 usdtReleased, uint256 mudReleased) {
        require(tokenOwner[tokenId] == msg.sender, "User must be the owner of the staked nft");

        StakingContractInfo[] storage contractInfoArray = stakingContractInfoMap[msg.sender];
        require(contractInfoArray.length > 0, "msg.sender is not found !");

        for (uint i=0; i < contractInfoArray.length; i++) {
            if (contractInfoArray[i].tokenId == tokenId) {
                //found tokenId                
                require(block.timestamp > contractInfoArray[i].endTime, "Staking contract is not expired yet!");
                //put the last element to the found tokenId position
                contractInfoArray[i] = contractInfoArray[contractInfoArray.length - 1];                
                contractInfoArray.pop(); //remove last element                     
                
                address ownerAddress = tokenOwner[tokenId];
                delete tokenOwner[tokenId];

                (usdtReleased, mudReleased) = releaseLiquidity(tokenId, ownerAddress);    
                nonfungiblePositionManager.burn(tokenId);            
                emit mudLPUnstaked(msg.sender, tokenId, usdtReleased, mudReleased);
                break;
            }
        }

        emit mudLPUnstakeTokenIdNotFound(msg.sender, tokenId);
    }

    //Break the staking contract before it matures.
    //If the staking contract will be matured within 24 hours or already matured, do not break the contract and ignore it.
    //Otherwise, set the mature time to 24 hours after the current block time. 20% of the liquidity will be confiscated from the onwer. 
    //The USDT will be transferred to DAO fund address for DAO bounty & R&D funding. The MUD will be burned.
    //Parameter:
    //  tokenId:   UNISWAP V3 liquidity NFT position id (used as staking contract id)
    //Returns:
    //  amount0: USDT confiscated and transferred to DAO fund address
    //  amount1: MUD confiscated and burnt from the owner
    function prematureUnstake(uint256 tokenId) public returns (uint256 amount0, uint256 amount1) {
        require(tokenOwner[tokenId] == msg.sender, "User must be the owner of the staked nft");

        StakingContractInfo[] storage contractInfoArray = stakingContractInfoMap[msg.sender];
        require(contractInfoArray.length > 0, "msg.sender is not found !");

        for (uint i=0; i < contractInfoArray.length; i++) {
            if (contractInfoArray[i].tokenId == tokenId) {
                //found tokenId                
                if (block.timestamp + secPerDay > contractInfoArray[i].endTime) {
                    //If the stake contract will expire within 24 hours, do not do anything
                    emit mudLPPrematureUnstakIgnored(msg.sender, tokenId);
                    return(0, 0);
                } else {
                    //change the endtime to current time + 24 hours, so it will be expire after 24 hours
                    //the owner should call unstake() function after 24 hours to unstake it
                    contractInfoArray[i].endTime = block.timestamp + secPerDay;                                      

                    //take off 20% of the liquidity              
                    (IUniswapV3Pool pool, , , int24 lowerTick, int24 upperTick, uint128 liquidity) = getPositionInfo(tokenId);
                    
                    uint128 liquidityOff = liquidity / 5;
                    //slippage protection calculations
                    (amount0, amount1) = calculateLiquidityAmount(pool, lowerTick, upperTick, liquidityOff);
                    INonfungiblePositionManager.DecreaseLiquidityParams
                        memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
                            tokenId: tokenId,
                            liquidity: liquidityOff,
                            amount0Min: amount0,//slippage protection
                            amount1Min: amount1,//slippage protection
                            deadline: block.timestamp
                        });

                    (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(params);   
                    (uint256 amount0collected, uint256 amount1collected) = collectAllFees(tokenId);
                 
                    require(usdt.transfer(daoFundAddress, amount0collected), "USDT transfer failed !");//transfer the 20% usdt to DAO fund account
                    mud.burn(amount1collected); //burn 20% MUD as penalty                  

                    emit mudLPPrematureUnstaked(msg.sender, tokenId, amount0collected, amount1collected);
                    return(amount0collected, amount1collected);
                }                
            } //of found tokenId
        }

        emit mudLPUnstakeTokenIdNotFound(msg.sender, tokenId);
    }
    /// @notice Collects the fees associated with provided liquidity
    /// @dev The contract must hold the erc721 token before it can collect fees
    /// @param tokenId The id of the erc721 token
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function collectAllFees(uint256 tokenId) private returns (uint256 amount0, uint256 amount1) {
        // set amount0Max and amount1Max to uint256.max to collect all fees
        INonfungiblePositionManager.CollectParams memory params =
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (amount0, amount1) = nonfungiblePositionManager.collect(params);
    } 
    
    // release the 100% liquidity of the contract and return the assets to the owner address
    // Parameters: 
    //  tokenId:   UNISWAP V3 liquidity NFT position id (used as staking contract id)
    //  ownerAddress: the liquidity provider's address
    // Returns: 
    //  amount0collected: USDT returned to the owner address
    //  amount1collected: MUD returned to the owner address
    function releaseLiquidity(uint256 tokenId, address ownerAddress) private returns (uint256 amount0collected, uint256 amount1collected) {
        //calculat th amount0 and amount1 for slippage protection
        (IUniswapV3Pool pool, , , int24 lowerTick, int24 upperTick, uint128 liquidity) = getPositionInfo(tokenId);  
        (uint256 amount0, uint256 amount1) = calculateLiquidityAmount(pool, lowerTick, upperTick, liquidity);
        
        INonfungiblePositionManager.DecreaseLiquidityParams
            memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0,//slippage protection
                amount1Min: amount1,//slippage protection
                deadline: block.timestamp
            });

        nonfungiblePositionManager.decreaseLiquidity(params);   
        (amount0collected, amount1collected) = collectAllFees(tokenId);

        //return tokens to the owner
        require(usdt.transfer(ownerAddress, amount0collected), "USDT transfer failed !");
        require(mud.transfer(ownerAddress, amount1collected), "MUD transfer failed !");
    }

    //unstake the last staking tokenId of the address for mainnet mapping purpose, ignore the contract expiry time
    //Parameter:
    //  addr: liquidity owner address to be unstaked
    function unstakeForMainnetMapping(address addr) public {
        require(msg.sender == admin, "Only DAO admin is allowed !");        
        
        StakingContractInfo[] storage contractInfoArray = stakingContractInfoMap[addr];
        require(contractInfoArray.length > 0, "Addr is not found !");

        uint256 tokenId = contractInfoArray[contractInfoArray.length - 1].tokenId;                
        require(tokenOwner[tokenId] == addr, "The addr is not the owner of the token !");
        contractInfoArray.pop(); //remove the last staking contract 
        address ownerAddress = tokenOwner[tokenId];
        delete tokenOwner[tokenId]; //delete the nft position from owner map
        
        if (contractInfoArray.length == 0) {
            delete stakingContractInfoMap[addr];//delete the address from map
            emit mudLPAddressUnstaked(addr);
        }       

        (uint256 usdtReleased, uint256 mudReleased) = releaseLiquidity(tokenId, ownerAddress);  
        nonfungiblePositionManager.burn(tokenId);      
        emit mudLPUnstaked(addr, tokenId, usdtReleased, mudReleased); 
    }

    // Get total number of staking contracts of the given address
    // Parameter: 
    //   addressIn : contracts owner address
    // Return:
    //   uint: total number of staking contracts 
    function getContractCount(address addressIn) external view returns (uint) {
        address addressToCheck;
        
        if (msg.sender == admin) {
            require(addressIn != address(0), "Blackhole address is not allowed !");
            addressToCheck = addressIn;
        } else {
            addressToCheck = msg.sender;
        }

        return stakingContractInfoMap[addressToCheck].length;
    }

    // Get staking contract information
    // Parameters:
    //   addressIn: contract owner address
    //   index: index of the contract of the contract array
    // Returns: 
    //   tokenId: UNISWAP V3 liquidity NFT position id (used as staking contract id)
    //   duration: staking period (3/6/12 months, each month 30 days)
    //   startTime: contract start time
    //   endTime: contract end time
    //   startUSDT: USDT amount transferred to the contract on creation
    //   startMUD: MUD amount transferred to the contract on creation
    function getContractInfo(address addressIn, uint index) external view returns (uint256 tokenId, uint8 duration, uint startTime, uint endTime, uint256 startUSDT, uint256 startMUD){
        address addressToCheck;
        
        if (msg.sender == admin) {
            require(addressIn != address(0), "Blackhole address is not allowed !");
            addressToCheck = addressIn;
        } else {
            addressToCheck = msg.sender;
        }
        
        require(index < stakingContractInfoMap[addressToCheck].length, "getContractInfo: index out of range");

        return (stakingContractInfoMap[addressToCheck][index].tokenId, 
                stakingContractInfoMap[addressToCheck][index].duration,
                stakingContractInfoMap[addressToCheck][index].startTime,
                stakingContractInfoMap[addressToCheck][index].endTime,
                stakingContractInfoMap[addressToCheck][index].startUSDT,
                stakingContractInfoMap[addressToCheck][index].startMUD
               );
    }    

    // Get staking contract information by tokenId
    // Parameters:
    //   tokenId: UNISWAP V3 liquidity NFT position id (used as staking contract id)
    //   addressIn: contract owner address    
    // Returns:     
    //   duration: staking period (3/6/12 months, each month 30 days)
    //   startTime: contract start time
    //   endTime: contract end time
    //   startUSDT: USDT amount transferred to the contract on creation
    //   startMUD: MUD amount transferred to the contract on creation
    function getContractInfoByTokenId(uint256 tokenId, address addressIn) external view returns (uint8 duration, uint startTime, uint endTime, uint256 startUSDT, uint256 startMUD) {
        address addressToCheck;
        
        if (msg.sender == admin) {
            require(addressIn != address(0), "Blackhole address is not allowed !");
            addressToCheck = addressIn;
        } else {
            require(tokenOwner[tokenId] == msg.sender, "User must be the owner of the staked nft");
            addressToCheck = msg.sender;
        }        

        StakingContractInfo[] memory contractInfoArray = stakingContractInfoMap[addressToCheck];
        require(contractInfoArray.length > 0, "msg.sender is not found !");

        for (uint i=0; i < contractInfoArray.length; i++) {
            if (contractInfoArray[i].tokenId == tokenId) {
                return (contractInfoArray[i].duration,
                        contractInfoArray[i].startTime,
                        contractInfoArray[i].endTime,
                        contractInfoArray[i].startUSDT,
                        contractInfoArray[i].startMUD
                       );                
            }
        }    
    }

    /// This function is not used but need to be here for compiling
    function onERC721Received (
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure override returns (bytes4) {      
        return this.onERC721Received.selector;
    } 

    ///This function calculate the amount of tokens according to the liqudity amount
    function calculateLiquidityAmount(IUniswapV3Pool pool, int24 lowerTick, int24 upperTick, uint128 liqudityToRelease) private view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        (amount0, amount1) = LiquidityAmounts
            .getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(lowerTick),
                TickMath.getSqrtRatioAtTick(upperTick),
                liqudityToRelease
            );
    }

    // This function returns the amount of tokens of the current liquidity
    // Parameters:
    //   tokenId: NFT position of the staked liquidity
    //   addressToCheck: owner address of the NFT
    // Returns:
    //   amount0: USDT amount of the liquidity
    //   amount1: MUD amount of the liquidity
    function getLiquidityAmountByTokenId(uint256 tokenId, address addressToCheck) external view returns (uint256 amount0, uint256 amount1) {       
        if (msg.sender == admin) {
            require(tokenOwner[tokenId] == addressToCheck, "The staked nft does not belong to the addressToCheck !");            
        } else {
            require(tokenOwner[tokenId] == msg.sender, "User must be the owner of the staked nft");            
        }        
        (IUniswapV3Pool pool, , , int24 lowerTick, int24 upperTick, uint128 liquidity) = getPositionInfo(tokenId);

        return calculateLiquidityAmount(pool, lowerTick, upperTick, liquidity);            
    }
}
