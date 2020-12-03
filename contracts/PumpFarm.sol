pragma solidity 0.6.12;


import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IFarmToken.sol";
import "./uniswapv2/interfaces/IUniswapV2Pair.sol";
import "./uniswapv2/interfaces/IUniswapV2Router02.sol";

import "./uniswapv2/interfaces/IWETH.sol";

interface IMigratorFarm {
    // Perform LP token migration from legacy UniswapV2 to FarmSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // FarmSwap must mint EXACTLY the same amount of FarmSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// Farm is the master of FarmToken. He can make FarmToken and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once the FarmToken is
// sufficiently distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract PumpFarm is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 unlockDate; // Unlock date.
        uint256 liqAmount;  // ETH/Single token split, swap and addLiq.
        //
        // We do some fancy math here. Basically, any point in time, the amount of FarmTokens
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accFarmTokenPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accFarmTokenPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;               // Address of LP token contract.
        uint256 allocPoint;           // How many allocation points assigned to this pool. FarmTokens to distribute per block.
        uint256 lockSec;              // Lock seconds, 0 means no lock.
        uint256 pumpRatio;            // Pump ratio, 0 means no ratio. 5 means 0.5%
        uint256 tokenType;            // Pool type, 0 - Token/ETH(default), 1 - Single Token(include ETH), 2 - Uni/LP
        uint256 lpAmount;             // Lp amount
        uint256 tmpAmount;            // ETH/Token convert to uniswap liq amount, remove latter.
        uint256 lastRewardBlock;      // Last block number that FarmTokens distribution occurs.
        uint256 accFarmTokenPerShare; // Accumulated FarmTokens per share, times 1e12. See below.
    }
    
    // ===========================================================================================
    // Pump
    address public pairaddr;
    
    // mainnet
    address public constant WETHADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant UNIV2ROUTER2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    // ropsten
    // address public constant WETHADDR = 0xc778417E063141139Fce010982780140Aa0cD5Ab;
    // address public constant UNIV2ROUTER2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    
    // Pump End
    // ===========================================================================================

    // The FarmToken.
    IFarmToken public farmToken;
    // FarmTokens created per block.
    uint256 public farmTokenPerBlock;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorFarm public migrator;
    
    // Farm
    uint256 public blocksPerHalvingCycle;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when FarmToken mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 pumpAmount, uint256 liquidity);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, uint256 pumpAmount, uint256 liquidity);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        IFarmToken _farmToken,
        uint256 _farmTokenPerBlock,
        uint256 _startBlock,
        uint256 _blocksPerHalvingCycle
    ) public {
        farmToken = _farmToken;
        farmTokenPerBlock = _farmTokenPerBlock;
        startBlock = _startBlock;
        blocksPerHalvingCycle = _blocksPerHalvingCycle;
    }

    receive() external payable {
        assert(msg.sender == WETHADDR); // only accept ETH via fallback from the WETH contract
    }

    function setPair(address _pairaddr) public onlyOwner {
        pairaddr = _pairaddr;

        // full trust UNISWAP approve max for UNISWAP.
        IERC20(pairaddr).safeApprove(UNIV2ROUTER2, 0);
        IERC20(pairaddr).safeApprove(UNIV2ROUTER2, uint(-1));
        IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, 0);
        IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, uint(-1));
        IERC20(address(farmToken)).safeApprove(UNIV2ROUTER2, 0);
        IERC20(address(farmToken)).safeApprove(UNIV2ROUTER2, uint(-1));
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate, uint256 _lockSec, uint256 _pumpRatio, uint256 _type) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lockSec: _lockSec,
            pumpRatio: _pumpRatio,
            tokenType: _type,
            lpAmount: 0,
            tmpAmount: 0,
            lastRewardBlock: lastRewardBlock,
            accFarmTokenPerShare: 0
        }));
        // full trust UNISWAP approve max for UNISWAP.
        _lpToken.safeApprove(UNIV2ROUTER2, 0);
        _lpToken.safeApprove(UNIV2ROUTER2, uint(-1));

        if (_type == 2) {
            address token0 = IUniswapV2Pair(address(_lpToken)).token0();
            address token1 = IUniswapV2Pair(address(_lpToken)).token1();
            // need to approve token0 and token1 for UNISWAP, in
            IERC20(token0).safeApprove(UNIV2ROUTER2, 0);
            IERC20(token0).safeApprove(UNIV2ROUTER2, uint(-1));
            IERC20(token1).safeApprove(UNIV2ROUTER2, 0);
            IERC20(token1).safeApprove(UNIV2ROUTER2, uint(-1));
        }
    }

    // Update the given pool's FarmToken allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate, uint256 _lockSec, uint256 _pumpRatio) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].lockSec = _lockSec;
        poolInfo[_pid].pumpRatio = _pumpRatio;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorFarm _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }
    
    // need test
    function getMultiplier(uint256 _to) public view returns (uint256) {
        uint256 blockCount = _to.sub(startBlock);
        uint256 weekCount = blockCount.div(blocksPerHalvingCycle);
        uint256 multiplierPart1 = 0;
        uint256 multiplierPart2 = 0;
        uint256 divisor = 1;
        
        for (uint256 i = 0; i < weekCount; ++i) {
            multiplierPart1 = multiplierPart1.add(blocksPerHalvingCycle.div(divisor));
            divisor = divisor.mul(2);
        }
        
        multiplierPart2 = blockCount.mod(blocksPerHalvingCycle).div(divisor);
        
        return multiplierPart1.add(multiplierPart2);
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= _from) {
            return 0;
        }
        return getMultiplier(_to).sub(getMultiplier(_from));
    }

    // View function to see pending FarmTokens on frontend.
    function pendingFarmToken(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accFarmTokenPerShare = pool.accFarmTokenPerShare;
        //uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 lpSupply = pool.lpAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 farmTokenReward = multiplier.mul(farmTokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accFarmTokenPerShare = accFarmTokenPerShare.add(farmTokenReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accFarmTokenPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        //uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        uint256 lpSupply = pool.lpAmount;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 farmTokenReward = multiplier.mul(farmTokenPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        farmToken.mint(address(this), farmTokenReward);
        pool.accFarmTokenPerShare = pool.accFarmTokenPerShare.add(farmTokenReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to Farm for FarmToken allocation.
    function deposit(uint256 _pid, uint256 _amount) public payable {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pumpAmount;
        uint256 liquidity;
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accFarmTokenPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeFarmTokenTransfer(msg.sender, pending);
            }
        }
        if (msg.value > 0) {
            // once msg.value, support ETH single token deposit
		    IWETH(WETHADDR).deposit{value: msg.value}();
		    _amount = msg.value;
        } else if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        }
        if(_amount > 0) {
            // _amount == 0 or pumpRatio == 0
            pumpAmount = _amount.mul(pool.pumpRatio).div(1000);
            if (pool.tokenType == 0 && pumpAmount > 0) {
                pump(pumpAmount);
            } else if (pool.tokenType == 1) {
                // use the actually pumpAmount
                liquidity = investTokenToLp(pool.lpToken, _amount, pool.pumpRatio);
                user.liqAmount = user.liqAmount.add(liquidity);
            } else if (pool.tokenType == 2) {
                pumpLp(pool.lpToken, pumpAmount);
            }
            _amount = _amount.sub(pumpAmount);
            if (pool.tokenType == 1) {
                pool.tmpAmount = pool.tmpAmount.add(liquidity);
            }
            pool.lpAmount = pool.lpAmount.add(_amount);
            // once pumpRatio == 0, single token/eth should addLiq
            user.amount = user.amount.add(_amount);
            user.unlockDate = block.timestamp.add(pool.lockSec);
        }
        user.rewardDebt = user.amount.mul(pool.accFarmTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount, pumpAmount, liquidity);
    }
    
    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }

    function _swapExactTokensForTokens(address fromToken, address toToken, uint256 fromAmount) internal returns (uint256) {
        if (fromToken == toToken || fromAmount == 0) return fromAmount;
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;
        uint[] memory amount = IUniswapV2Router02(UNIV2ROUTER2).swapExactTokensForTokens(
                      fromAmount, 0, path, address(this), now.add(60));
        return amount[amount.length - 1];
    }

    function investTokenToLp(IERC20 lpToken, uint256 _amount, uint256 _pumpRatio) internal returns (uint256 liq) {
        // ETH, ETH/2->buy FarmToken, FarmTokenAmount
        if (_amount == 0) return 0;

        if (address(lpToken) != WETHADDR) {
            // IERC20(lpToken).safeApprove(UNIV2ROUTER2, 0);
            // IERC20(lpToken).safeApprove(UNIV2ROUTER2, _amount);
            _amount = _swapExactTokensForTokens(address(lpToken), WETHADDR, _amount);
        }
        uint256 amountEth = _amount.sub(_amount.mul(_pumpRatio).div(1000)).div(2);
        uint256 amountBuy = _amount.sub(amountEth);

        address[] memory path = new address[](2);
        path[0] = WETHADDR;
        path[1] = address(farmToken);
        // buy token use another half amount.
        uint256[] memory amounts = IUniswapV2Router02(UNIV2ROUTER2).swapExactTokensForTokens(
                  amountBuy, 0, path, address(this), now.add(60));
        uint256 amountToken = amounts[1];

        // IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, 0);
        // IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, amountEth);
        // IERC20(farmToken).safeApprove(UNIV2ROUTER2, 0);
        // IERC20(farmToken).safeApprove(UNIV2ROUTER2, amountToken);
        uint256 amountEthReturn;
        (amountEthReturn,, liq) = IUniswapV2Router02(UNIV2ROUTER2).addLiquidity(
                WETHADDR, address(farmToken), amountEth, amountToken, 0, 0, address(this), now.add(60));

        if (amountEth > amountEthReturn) {
            // this is ETH left(hard to see). then swap all eth to token
            // IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, 0);
            // IERC20(WETHADDR).safeApprove(UNIV2ROUTER2, amountEth.sub(amountEthReturn));
            _swapExactTokensForTokens(WETHADDR, address(farmToken), amountEth.sub(amountEthReturn));
        }
    }

    // return actually amount of invest token(ETH, USDT, DAI etc)
    function lpToInvestToken(IERC20 lpToken, uint256 _liquidity, uint256 _pumpRatio) internal returns (uint256 amountInvest){
        // removeLiq all
        if (_liquidity == 0) return 0;
        // IERC20(pairaddr).safeApprove(UNIV2ROUTER2, 0);
        // IERC20(pairaddr).safeApprove(UNIV2ROUTER2, IERC20(pairaddr).balanceOf(address(this)));
        (uint256 amountToken, uint256 amountEth) = IUniswapV2Router02(UNIV2ROUTER2).removeLiquidity(
            address(farmToken), WETHADDR, _liquidity, 0, 0, address(this), now.add(60));

        // pumpRation must <50% amountToken pump double, so no need to pump ETH or Token
        uint256 pumpAmount = amountToken.mul(_pumpRatio).mul(2).div(1000);
        amountEth = amountEth.add(_swapExactTokensForTokens(address(farmToken), WETHADDR, amountToken.sub(pumpAmount)));

        if (address(lpToken) == WETHADDR) {
            amountInvest = amountEth;
        } else {
            address[] memory path = new address[](2);
            path[0] = WETHADDR;
            path[1] = address(lpToken);
            // IERC20(farmToken).safeApprove(UNIV2ROUTER2, 0);
            // IERC20(farmToken).safeApprove(UNIV2ROUTER2, amountToken);
            uint256[] memory amounts = IUniswapV2Router02(UNIV2ROUTER2).swapExactTokensForTokens(
                  amountEth, 0, path, address(this), now.add(60));
            amountInvest = amounts[1];
        }
    }

    function _pumpLp(address token0, address token1, uint256 _amount) internal {
        if (_amount == 0) return;
        // IERC20(_lpToken).safeApprove(UNIV2ROUTER2, _amount);
        (uint256 amount0, uint256 amount1) = IUniswapV2Router02(UNIV2ROUTER2).removeLiquidity(
            token0, token1, _amount, 0, 0, address(this), now.add(60));
        amount0 = _swapExactTokensForTokens(token0, WETHADDR, amount0);
        amount1 = _swapExactTokensForTokens(token1, WETHADDR, amount1);
        _swapExactTokensForTokens(WETHADDR, address(farmToken), amount0.add(amount1));
    }

    function pump(uint256 _amount) internal {
        if (_amount == 0) return;
        // IERC20(_pairToken).safeApprove(UNIV2ROUTER2, _amount);
        // keep farmToken and spent amountEth to buy farmtoken
        (,uint256 amountEth) = IUniswapV2Router02(UNIV2ROUTER2).removeLiquidity(
            address(farmToken), WETHADDR, _amount, 0, 0, address(this), now.add(60));
        _swapExactTokensForTokens(WETHADDR, address(farmToken), amountEth);
    }

    function pumpLp(IERC20 _lpToken, uint256 _amount) internal {
        address token0 = IUniswapV2Pair(address(_lpToken)).token0();
        address token1 = IUniswapV2Pair(address(_lpToken)).token1();
        return _pumpLp(token0, token1, _amount);
    }
    
    function getWithdrawableBalance(uint256 _pid, address _user) public view returns (uint256) {
      UserInfo storage user = userInfo[_pid][_user];
      
      if (user.unlockDate > block.timestamp) {
          return 0;
      }
      
      return user.amount;
    }

    // Withdraw LP tokens from Farm.
    function withdraw(uint256 _pid, uint256 _amount) public {
        uint256 withdrawable = getWithdrawableBalance(_pid, msg.sender);
        require(_amount <= withdrawable, 'Your attempting to withdraw more than you have available');
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accFarmTokenPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeFarmTokenTransfer(msg.sender, pending);
        }
        uint256 pumpAmount;
        uint256 liquidity;
        if(_amount > 0) {
            pumpAmount = _amount.mul(pool.pumpRatio).div(1000);
            user.amount = user.amount.sub(_amount);
            pool.lpAmount = pool.lpAmount.sub(_amount);
            // pool.pumpRatio = 0, pumpAmount = 0;
            if (pool.tokenType == 0 && pumpAmount > 0) {
                pump(pumpAmount);
                _amount = _amount.sub(pumpAmount);
            } else if (pool.tokenType == 1) {
                // use the ratio to map amount -> liqAmount
                // remove liq also has the positive ETH or USDT
                liquidity = user.liqAmount.mul(_amount).div(user.amount.add(_amount));
                // return amount_ may > amount_ arg
                _amount = lpToInvestToken(pool.lpToken, liquidity, pool.pumpRatio);
                user.liqAmount = user.liqAmount.sub(liquidity);
            } else if (pool.tokenType == 2) {
                pumpLp(pool.lpToken, pumpAmount);
                _amount = _amount.sub(pumpAmount);
            }
            if (pool.tokenType == 1) {
                pool.tmpAmount = pool.tmpAmount.sub(liquidity);
            }
            if (address(pool.lpToken) == WETHADDR) {
                IWETH(WETHADDR).withdraw(_amount);
                safeTransferETH(address(msg.sender), _amount);
            } else {
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accFarmTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount, pumpAmount, liquidity);
    }

    // Safe FarmToken transfer function, just in case if rounding error causes pool to not have enough FarmTokens.
    function safeFarmTokenTransfer(address _to, uint256 _amount) internal {
        uint256 farmTokenBal = farmToken.balanceOf(address(this));
        if (_amount > farmTokenBal) {
            farmToken.transfer(_to, farmTokenBal);
        } else {
            farmToken.transfer(_to, _amount);
        }
    }
}
