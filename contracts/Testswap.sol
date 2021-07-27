// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.7.6;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
// import "hardhat/console.sol";
import "./interfaces/TestPool.sol";
import './interfaces/IWETH.sol';
import './libraries/TestLibrary.sol';

interface IvUSD is IERC20 {
  function mint (address account, uint256 amount) external;

  function burn (address account, uint256 amount) external;
}


/**
 * The Test is ERC1155 contract does this and that...
 */
contract Testswap is Initializable, OwnableUpgradeable {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using SafeERC20 for IvUSD;

  IvUSD vUSD;
  address WETH;
  address feeTo;
  uint16 fees; // over 1e5, 300 means 0.3%
  uint16 devFee; // over 1e5, 50 means 0.05%

  uint256 constant MINIMUM_LIQUIDITY=100;
  

  struct PoolInfo {
    uint256 pid;
    uint256 lastPoolValue;
    address token;
    PoolStatus status;
    uint112 vusdDebt;
    uint112 vusdCredit;
    uint112 tokenBalance;
    uint112 price; // over 1e18
  }

  enum TxType {
    SELL,
    BUY
  }

  enum PoolStatus {
    UNLISTED,
    LISTED,
    OFFICIAL,
    SYNTHETIC,
    PAUSED
  }
  
  mapping (address => PoolInfo) public pools;
  // tokenStatus is for token lock/transfer. exempt means no need to verify post tx
  mapping (address => uint8) private tokenStatus; //0=unlocked, 1=locked, 2=exempt

  // token poool status is to track if the pool has already been created for the token
  mapping (address => uint8) public tokenPoolStatus; //0=undefined, 1=exists
  
  // negative vUSD balance allowed for each token
  mapping (address => uint) public tokenInsurance;

  uint256 public poolSize;

  uint private unlocked;
  modifier lock() {
    require(unlocked == 1, 'Test:LOCKED');
    unlocked = 0;
    _;
    unlocked = 1;
  }

  modifier lockToken(address _token) { 
    uint8 originalState = tokenStatus[_token];
    require(originalState!=1, 'Test:POOL_LOCKED');
    if(originalState==0) {
      tokenStatus[_token] = 1;
    }
    _;
    if(originalState==0) {
      tokenStatus[_token] = 0;
    }
  }

  modifier ensure(uint deadline) {
    require(deadline >= block.timestamp, 'Test:EXPIRED');
    _;
  }  

  modifier onlySyntheticPool(address _token){
    require(pools[_token].status==PoolStatus.SYNTHETIC,"Test:NOT_SYNT");
    _;
  }

  modifier onlyPriceAdjuster(){
    require(priceAdjusterRole[msg.sender]==true,"Test:BAD_ROLE");
    _;
  }

  event AddLiquidity(address indexed provider, 
    uint indexed pid,
    address indexed token,
    uint liquidityAmount,
    uint vusdAmount, uint tokenAmount);

  event RemoveLiquidity(address indexed provider, 
    uint indexed pid,
    address indexed token,
    uint liquidityAmount,
    uint vusdAmount, uint tokenAmount);

  event Swap(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint amountIn,
    uint amountOut
  );

  // event PriceAdjusterChanged(
  //   address indexed priceAdjuster,
  //   bool added
  // );

  event PoolBalanced(
    address _token,
    uint vusdIn
  );

  event SyntheticPoolPriceChanged(
    address _token,
    uint112 price
  );

  event PoolStatusChanged(
    address _token,
    PoolStatus oldStatus,
    PoolStatus newStatus
  );

  ITestPool public TestPool;
  
  // mapping (token address => block number of the last trade)
  mapping (address => uint) public lastTradedBlock; 

  uint256 constant MINIMUM_POOL_VALUE = 10000 * 1e18;
  mapping (address=>bool) public priceAdjusterRole;

  // ------------
  uint public poolSizeMinLimit;

  function initialize(ITestPool _TestPool, IvUSD _vusd) public initializer {
    OwnableUpgradeable.__Ownable_init();
    TestPool = _TestPool;
    vUSD = _vusd;
    WETH = _TestPool.getWETHAddr();

    fees = 300;
    devFee = 50;
    poolSize = 0;
    unlocked = 1;
  }

  // receive() external payable {
  //   assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
  // }

  function setFeeTo (address _feeTo) onlyOwner external {
    feeTo = _feeTo;
  }
  
  function setFees (uint16 _fees) onlyOwner external {
    require(_fees<1e3);
    fees = _fees;
  }

  function setDevFee (uint16 _devFee) onlyOwner external {
    require(_devFee<1e3);
    devFee = _devFee;
  }

  function setPoolSizeMinLimit(uint _poolSizeMinLimit) onlyOwner external {
    poolSizeMinLimit = _poolSizeMinLimit;
  }

  function setTokenInsurance (address _token, uint _insurance) onlyOwner external {
    tokenInsurance[_token] = _insurance;
  }

  // when safu, setting token status to 2 can achieve significant gas savings 
  function setTokenStatus (address _token, uint8 _status) onlyOwner external {
    tokenStatus[_token] = _status;
  } 
  

  // update status of a pool. onlyOwner.
  function updatePoolStatus(address _token, PoolStatus _status) external onlyOwner {
    // Remove code
  }
  
  /**
    @dev update pools price if there were no active trading for the last 6000 blocks
    @notice Only owner callable, new price can neither be 0 nor be equal to old one
    @param _token pool identifider (token address)
    @param _newPrice new price in wei (uint112)
   */
  function updatePoolPrice(address _token, uint112 _newPrice) external onlyOwner {
    // Remove code
  }

  function updatePriceAdjuster(address account, bool _status) external onlyOwner{
    priceAdjusterRole[account]=_status;
    //emit PriceAdjusterChanged(account,_status);
  }

  function setPoolPrice(address _token, uint112 price) external onlyPriceAdjuster onlySyntheticPool(_token){
    pools[_token].price=price;
    emit SyntheticPoolPriceChanged(_token,price);
  }

  function rebalancePool(address _token,uint256 vusdIn) external lockToken(_token) onlyOwner{
      // PoolInfo memory pool = pools[_token];
      // Remove code
      emit PoolBalanced(_token, vusdIn);
  }

  // creates a pool
  function _createPool (address _token, uint112 _price, PoolStatus _status) lock internal returns(uint256 _pid)  {
    require(tokenPoolStatus[_token]==0, "Test:POOL_EXISTS");
    require (_token != address(vUSD), "Test:NO_vUSD");
    _pid = poolSize;
    pools[_token] = PoolInfo({
      token: _token,
      pid: _pid,
      vusdCredit: 0,
      vusdDebt: 0,
      tokenBalance: 0,
      lastPoolValue: 0,
      status: _status,
      price: _price
    });

    poolSize = _pid.add(1);
    tokenPoolStatus[_token]=1;

    // initialze pool's lasttradingblocknumber as the block number on which the pool is created
    lastTradedBlock[_token] = block.number;
  }

  // creates a pool with special status
  function addSpecialToken (address _token, uint112 _price, PoolStatus _status) onlyOwner external returns(uint256 _pid)  {
    _pid = _createPool(_token, _price, _status);
  }

  // internal func to pay contract owner
  function _mintFee (uint256 pid, uint256 lastPoolValue, uint256 newPoolValue) internal {
    
    // uint256 _totalSupply = TestPool.totalSupplyOf(pid);
    if(newPoolValue>lastPoolValue && lastPoolValue>0) {
      // safe ops, since newPoolValue>lastPoolValue
      uint256 deltaPoolValue = newPoolValue - lastPoolValue; 
      // safe ops, since newPoolValue = deltaPoolValue + lastPoolValue > deltaPoolValue
      uint256 devLiquidity = TestPool.totalSupplyOf(pid).mul(deltaPoolValue).mul(devFee).div(newPoolValue-deltaPoolValue)/1e5;
      TestPool.mint(feeTo, pid, devLiquidity);
    }
    
  }

  // util func to get some basic pool info
  function getPool (address _token) view public returns (uint256 poolValue, 
    uint256 tokenBalanceVusdValue, uint256 vusdCredit, uint256 vusdDebt) {
    // PoolInfo memory pool = pools[_token];
    vusdCredit = pools[_token].vusdCredit;
    vusdDebt = pools[_token].vusdDebt;
    tokenBalanceVusdValue = uint(pools[_token].price).mul(pools[_token].tokenBalance)/1e18;

    poolValue = tokenBalanceVusdValue.add(vusdCredit).sub(vusdDebt);
  }

  // trustless listing pool creation. always creates unofficial pool
  function listNewToken (address _token, uint112 _price, 
    uint256 vusdAmount, 
    uint256 tokenAmount,
    address to) external returns(uint _pid, uint256 liquidity) {
    _pid = _createPool(_token, _price, PoolStatus.LISTED);
    liquidity = _addLiquidityPair(_token, vusdAmount, tokenAmount, msg.sender, to);
  }

  // add liquidity pair to a pool. allows adding vusd.
  function addLiquidityPair (address _token, 
    uint256 vusdAmount, 
    uint256 tokenAmount,
    address to) external returns(uint256 liquidity) {
    liquidity = _addLiquidityPair(_token, vusdAmount, tokenAmount, msg.sender, to);
  }

    // add liquidity pair to a pool. allows adding vusd.
  function _addLiquidityPair (address _token, 
    uint256 vusdAmount, 
    uint256 tokenAmount,
    address from,
    address to) internal lockToken(_token) returns(uint256 liquidity) {
    require (tokenAmount>0, "Test:BAD_AMOUNT");

    require(tokenPoolStatus[_token]==1, "Test:NO_POOL");

    // (uint256 poolValue, , ,) = getPool(_token);
    // Remove code as comment

    emit AddLiquidity(to, 
    pool.pid,
    _token,
    liquidity, 
    vusdAmount, tokenAmount);
  }
  
  // add one-sided liquidity to a pool. no vusd
  function addLiquidity (address _token, uint256 _amount, address to) external returns(uint256 liquidity)  {
    liquidity = _addLiquidityPair(_token, 0, _amount, msg.sender, to);
  }  

  // add one-sided ETH liquidity to a pool. no vusd
  function addLiquidityETH (address to) external payable returns(uint256 liquidity)  {
    TestLibrary.safeTransferETH(address(TestPool), msg.value);
    TestPool.depositWETH(msg.value);
    liquidity = _addLiquidityPair(WETH, 0, msg.value, address(this), to);
  }  

  // updates pool vusd balance, token balance and last pool value.
  // this function requires others to do the input validation
  function _syncPoolInfo (address _token, uint256 vusdIn, uint256 vusdOut) internal returns(uint256 poolValue, 
    uint256 tokenBalanceVusdValue, uint256 vusdCredit, uint256 vusdDebt) {
    // PoolInfo memory pool = pools[_token];
    uint256 tokenPoolPrice = pools[_token].price;
    (vusdCredit, vusdDebt) = _updateVusdBalance(_token, vusdIn, vusdOut);

    uint256 tokenReserve = IERC20(_token).balanceOf(address(TestPool));
    tokenBalanceVusdValue = tokenPoolPrice.mul(tokenReserve)/1e18;

    require(tokenReserve <= uint112(-1));
    pools[_token].tokenBalance = uint112(tokenReserve);
    // poolValue = tokenBalanceVusdValue.add(vusdCredit).sub(vusdDebt);
    pools[_token].lastPoolValue = tokenBalanceVusdValue.add(vusdCredit).sub(vusdDebt);
  }
  
  // view func for removing liquidity
  function _removeLiquidity (address _token, uint256 liquidity,
    address to) view public returns(
    uint256 poolValue, uint256 liquidityIn, uint256 vusdOut, uint256 tokenOut) {
    
    require (liquidity>0, "Test:BAD_AMOUNT");
    // Remove code

  }
  
  // actually removes liquidity
  function removeLiquidity (address _token, uint256 liquidity, address to, 
    uint256 minVusdOut, 
    uint256 minTokenOut) external returns(uint256 vusdOut, uint256 tokenOut)  {
    (vusdOut, tokenOut) = _removeLiquidityHelper (_token, liquidity, to, minVusdOut, minTokenOut, false);
  }

  // actually removes liquidity
  function _removeLiquidityHelper (address _token, uint256 liquidity, address to, 
    uint256 minVusdOut, 
    uint256 minTokenOut,
    bool isETH) lockToken(_token) internal returns(uint256 vusdOut, uint256 tokenOut)  {
    require (tokenPoolStatus[_token]==1, "Test:NO_TOKEN");
    // Remove code

    emit RemoveLiquidity(to, 
      pool.pid,
      _token,
      liquidityIn, 
      vusdOut, tokenOut);
  }

  // actually removes ETH liquidity
  function removeLiquidityETH (uint256 liquidity, address to, 
    uint256 minVusdOut, 
    uint256 minTokenOut) external returns(uint256 vusdOut, uint256 tokenOut)  {

    (vusdOut, tokenOut) = _removeLiquidityHelper (WETH, liquidity, to, minVusdOut, minTokenOut, true);
  }

  // util func to compute new price
  function _getNewPrice (uint256 originalPrice, uint256 reserve, 
    uint256 delta, TxType txType) pure internal returns(uint256 price) {
    if(txType==TxType.SELL) {
      // no risk of being div by 0
      price = originalPrice.mul(reserve)/(reserve.add(delta));
    }else{ // BUY
      price = originalPrice.mul(reserve).div(reserve.sub(delta));
    }
  }

  // util func to compute new price
  function _getAvgPrice (uint256 originalPrice, uint256 newPrice) pure internal returns(uint256 price) {
    price = originalPrice.add(newPrice.mul(4))/5;
  }

  // standard swap interface implementing uniswap router V2
  
  function swapExactETHForToken(
    address tokenOut,
    uint amountOutMin,
    address to,
    uint deadline
  ) external virtual payable ensure(deadline) returns (uint amountOut) {
    uint amountIn = msg.value;
    TestLibrary.safeTransferETH(address(TestPool), amountIn);
    TestPool.depositWETH(amountIn);
    amountOut = swapIn(WETH, tokenOut, address(this), to, amountIn);
    require(amountOut >= amountOutMin, 'Test:INSUFF_OUTPUT');
  }
  
  function swapExactTokenForETH(
    address tokenIn,
    uint amountIn,
    uint amountOutMin,
    address to,
    uint deadline
  ) external virtual ensure(deadline) returns (uint amountOut) {
    ITestPool TestPoolLocal = TestPool;
    amountOut = swapIn(tokenIn, WETH, msg.sender, address(TestPoolLocal), amountIn);
    require(amountOut >= amountOutMin, 'Test:INSUFF_OUTPUT');
    TestPoolLocal.withdrawWETH(amountOut);
    TestPoolLocal.safeTransferETH(to, amountOut);
  }

  function swapETHForExactToken(
    address tokenOut,
    uint amountInMax,
    uint amountOut,
    address to,
    uint deadline
  ) external virtual payable ensure(deadline) returns (uint amountIn) {
    uint amountSentIn = msg.value;
    ( , , amountIn, ) = getAmountIn(WETH, tokenOut, amountOut);
    TestLibrary.safeTransferETH(address(TestPool), amountIn);
    TestPool.depositWETH(amountIn);
    amountIn = swapOut(WETH, tokenOut, address(this), to, amountOut);
    require(amountIn < amountSentIn, 'Test:BAD_INPUT');
    require(amountIn <= amountInMax, 'Test:EXCESSIVE_INPUT');
    if (amountSentIn > amountIn) {
      TestLibrary.safeTransferETH(msg.sender, amountSentIn.sub(amountIn));
    }
  }

  function swapTokenForExactETH(
    address tokenIn,
    uint amountInMax,
    uint amountOut,
    address to,
    uint deadline
  ) external virtual ensure(deadline) returns (uint amountIn) {
    ITestPool TestPoolLocal = TestPool;
    amountIn = swapOut(tokenIn, WETH, msg.sender, address(TestPoolLocal), amountOut);
    require(amountIn <= amountInMax, 'Test:EXCESSIVE_INPUT');
    TestPoolLocal.withdrawWETH(amountOut);
    TestPoolLocal.safeTransferETH(to, amountOut);
  }

  function swapExactTokenForToken(
    address tokenIn,
    address tokenOut,
    uint amountIn,
    uint amountOutMin,
    address to,
    uint deadline
  ) external virtual ensure(deadline) returns (uint amountOut) {
    amountOut = swapIn(tokenIn, tokenOut, msg.sender, to, amountIn);
    require(amountOut >= amountOutMin, 'Test:INSUFF_OUTPUT');
  }

  function swapTokenForExactToken(
    address tokenIn,
    address tokenOut,
    uint amountInMax,
    uint amountOut,
    address to,
    uint deadline
  ) external virtual ensure(deadline) returns (uint amountIn) {
    amountIn = swapOut(tokenIn, tokenOut, msg.sender, to, amountOut);
    require(amountIn <= amountInMax, 'Test:EXCESSIVE_INPUT');
  }

  // util func to manipulate vusd balance
  function _updateVusdBalance (address _token, 
    uint _vusdIn, uint _vusdOut) internal returns (uint _vusdCredit, uint _vusdDebt) {
    if(_vusdIn>_vusdOut){
      _vusdIn = _vusdIn - _vusdOut;
      _vusdOut = 0;
    }else{
      _vusdOut = _vusdOut - _vusdIn;
      _vusdIn = 0;
    }

    // Remove code
  }
  
  // updates pool token balance and price.
  function _updateTokenInfo (address _token, uint256 _price,
      uint256 _vusdIn, uint256 _vusdOut, uint256 _ETHDebt) internal {
    // Remove code
    
    
  }

  function directSwapAllowed(uint tokenInPoolPrice,uint tokenOutPoolPrice, 
                              uint tokenInPoolTokenBalance, uint tokenOutPoolTokenBalance, PoolStatus status, bool getsAmountOut) internal pure returns(bool){
      uint tokenInValue  = tokenInPoolTokenBalance.mul(tokenInPoolPrice).div(1e18);
      uint tokenOutValue = tokenOutPoolTokenBalance.mul(tokenOutPoolPrice).div(1e18);
      bool priceExists   = getsAmountOut?tokenInPoolPrice>0:tokenOutPoolPrice>0;
      
      // only if it's official pool with similar size
      return priceExists&&status==PoolStatus.OFFICIAL&&tokenInValue>0&&tokenOutValue>0&&
        ((tokenInValue/tokenOutValue)+(tokenOutValue/tokenInValue)==1);
        
  }

  // view func to compute amount required for tokenIn to get fixed amount of tokenOut
  function getAmountIn(address tokenIn, address tokenOut, 
    uint256 amountOut) public view returns (uint256 tokenInPrice, uint256 tokenOutPrice, 
    uint256 amountIn, uint256 tradeVusdValue) {
    require(amountOut > 0, 'Test:INSUFF_INPUT');
    
    // Remove code
  }

  // view func to compute amount required for tokenOut to get fixed amount of tokenIn
  function getAmountOut(address tokenIn, address tokenOut, 
    uint256 amountIn) public view returns (uint256 tokenInPrice, uint256 tokenOutPrice, 
    uint256 amountOut, uint256 tradeVusdValue) {
    // Remove code
  }


  // swap from tokenIn to tokenOut with fixed tokenIn amount.
  function swapIn (address tokenIn, address tokenOut, address from, address to,
      uint256 amountIn) internal lockToken(tokenIn) returns(uint256 amountOut)  {

    address TestPoolLocal = address(TestPool);

    // Live code
    
  }

  
  // swap from tokenIn to tokenOut with fixed tokenOut amount.
  function swapOut (address tokenIn, address tokenOut, address from, address to, 
      uint256 amountOut) internal lockToken(tokenIn) returns(uint256 amountIn)  {
    uint256 tokenInPrice;
    uint256 tokenOutPrice;
    uint256 tradeVusdValue;
    (tokenInPrice, tokenOutPrice, amountIn, tradeVusdValue) = getAmountIn(tokenIn, tokenOut, amountOut);
    
    address TestPoolLocal = address(TestPool);

    // Live code

    emit Swap(to, tokenIn, tokenOut, amountIn, amountOut);

  }

  // function balanceOf(address account, uint256 id) public view returns (uint256) {
  //   return TestPool.balanceOf(account, id);
  // }

  // function getConfig() public view returns (address _vUSD, address _feeTo, uint16 _fees, uint16 _devFee) {
  //   _vUSD = address(vUSD);
  //   _feeTo = feeTo;
  //   _fees = fees;
  //   _devFee = devFee;
  // }

  function transferAndCheck(address from,address to,address _token,uint amount) internal returns (uint256){
    if(from == address(this)){
      return amount; // if it's ETH
    }

    // if it's not ETH
    if(tokenStatus[_token]==2){
      IERC20(_token).safeTransferFrom(from, to, amount);
      return amount;
    }else{
      uint256 balanceIn0 = IERC20(_token).balanceOf(to);
      IERC20(_token).safeTransferFrom(from, to, amount);
      uint256 balanceIn1 = IERC20(_token).balanceOf(to);
      return balanceIn1.sub(balanceIn0);
    }   

  }
}
