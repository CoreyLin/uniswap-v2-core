pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

/*
UniswapV2Pair既是pair，即币币兑换pair，也是一种ERC20 token，为流动性提供者提供UNI token，即pool token。
这里面包含注入流动性和兑换的核心逻辑，大量用到了require来做业务逻辑的校验和判断，如果有问题，就回滚。
*/
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    /*
    为了改善四舍五入误差并增加流动性提供的理论最小点位大小，pairs burn掉第一个MINIMUM_LIQUIDITY pool tokens。
    对于绝大多数pairs，这将表示一个微不足道的值。burn会在第一次提供流动性时自动发生，在这之后，totalSupply将永远有界限。
    */
    uint public constant MINIMUM_LIQUIDITY = 10**3;
    // 转账函数的function selector
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    // 创建pair合约的factory合约的地址
    address public factory;
    address public token0;
    address public token1;

    /*
    静态大小的状态变量(除了mapping和动态大小的数组类型之外的所有变量)都是从位置0开始连续地布局在存储中。
    如果可能的话，将需要少于32字节的多个连续项打包到单个存储槽(a single storage slot)中，也就是说，32字节的存储槽是最小存储空间。
    打个比方，一个address，只有20字节，但是在storage中存储的时候依然需要32字节的存储空间。
    此处112+112+32=256，刚好是32个字节，可以被打包存储在一个存储槽中，这样能节约storage空间，从而节约gas fee。
    此处的设计可以看出uniswap对合约的设计是精益求精，值得我们在开发solidity智能合约的时候借鉴。
    参考 https://docs.soliditylang.org/en/v0.5.16/miscellaneous.html#layout-of-state-variables-in-storage
    */
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    /*
    锁机制可以用modifier实现，先获取锁，执行完业务逻辑后，再释放锁。用这个lock修饰function是为了防止重入。
    请参考 https://ethereum.stackexchange.com/questions/59386/reentrancy-attack-in-a-smart-contract/68024
    https://ethereum.stackexchange.com/questions/57699/are-solidity-modifiers-functionally-equivalent-to-python-decorators
    https://blog.51cto.com/u_13784902/2324021
    */
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /*
    返回用于为交易定价和分配流动性的token0和token1的储备。
    也返回最后一个与当前pair发生交互的区块的时间戳(block.timestamp mod 2**32)。
    注：block.timestamp是uint，此处需要返回的是uint32，所以需要mod 2**32
    */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        /*
        调用ERC20 token合约的transfer(address,uint256)函数，转账给to。from就是pair合约地址。
        */
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        /*
        调用必须成功，且对返回的data用abi.decode解码后必须为true，因为在UniswapV2ERC20中，transfer(address,uint256)返回类型是bool
        */
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    // 每次通过mint创建流动性代币时都会发出。
    event Mint(address indexed sender, uint amount0, uint amount1);
    // 每次通过burn销毁流动性代币时都会发出。
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    // 每次通过mint、burn、swap或sync更新储备时发出。
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        /*
        由于pair合约都是由factory创建的，所以msg.sender就是factory合约的地址
        */
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    // factory合约在创建pair合约后会马上调用此函数
    function initialize(address _token0, address _token1) external {
        // 只有factory合约才有权限initialize pair合约
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // update reserves and, on the first call per block, price accumulators
    /*
    1.更新pair中两种token的储备
    2.如果是每个区块的第一笔交易，计算价格累积值
    */
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        /*pair在token0和token1中的余额不能超过uint112的最大值，否则就溢出了*/
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        /*
        由于block.timestamp是uint256，所以对其取2**32的模，只保留32位的值，然后type cast为uint32
        */
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        /*
        判断是否是一个区块的第一笔交易，blockTimestamp取模后再相减的话很有可能发生下溢，但是由于timeElapsed是uint32类型，
        所以值始终为正或者0，如果为正，就说明时间变化了，即区块变化了，那么就计算价格累积值，注意此处的+=
        价格就是token0和token1的储备的比例，价格累积就乘上区块与区块间隔的时间
        timeElapsed的单位是秒
        */
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            /*
            UQ112x112.encode(_reserve1)就等于_reserve1的二进制表示左移112位，此处暂时不能理解，为什么要左右112位再相除
            price0CumulativeLast和price1CumulativeLast随着时间的推移是会溢出的，但是是期望的、可以接受的
            */
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        /*更新储备，即pair地址在token0和token1合约中的余额*/
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        /*更新blockTimestampLast，不过个人觉得只需要在区块的第一笔交易中更新时间戳即可，可以放到上面的if中*/
        blockTimestampLast = blockTimestamp;
        /*发出Sync事件，带上最新的储备*/
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    /*注意：这个函数做了很多事，但返回值只是feeOn，即是否收取协议费，这个返回值会被mint函数用到*/
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 获取feeTo地址，即协议费的接收地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        // 如果feeTo不是0地址，则feeOn为true
        feeOn = feeTo != address(0);
        // 获取reserve0 * reserve1
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            /*
            如果不收取协议费，且kLast为非0，就将其重置为0
            kLast值的更新只有两种情况：
            1.收取协议费的情况：把其值置为uint(reserve0).mul(reserve1)
            2.不收取协议费的情况：把其值置为0，也就是说，在从一开始就不收取协议费的情况下，kLast的值永远是0
            */
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 这个低级函数应该从执行了重要安全检查的一个合约中调用，即外围合约(UniswapV2Router02.sol的addLiquidity函数)，mint是addLiquidity逻辑的最后一部分
    // https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/UniswapV2Router02.sol
    function mint(address to) external lock returns (uint liquidity) {
        /*
        单独的存储槽，节约gas
        在addLiquidity后，pair在token0和token1中拥有的余额增加了，具体增加了多少需要用token0和token1中的余额减去pair当前还未更新的储备
        */
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        // 直接用接口+地址锁定合约
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 获取该pair作为ERC20的最新的totalSupply，即UNI的supply
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            /*
            如果_totalSupply为0，说明从来没有_mint过，UNI的总供应量为0.计算需要_mint的UNI的数量
            amount0*amount1的平方根，再减去MINIMUM_LIQUIDITY
            注意：此处MINIMUM_LIQUIDITY是1000，那么amount0*amount1的平方根必须大于1000才行，否则sub会下溢，交易回滚
            另外，UNI的decimal是18，和大多数ERC20一样
            */
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            /*
            向0地址_mint MINIMUM_LIQUIDITY UNI token, _mint函数会增加totalSupply，意味着MINIMUM_LIQUIDITY被算进了totalSupply，
            但是属于0地址，永远把这笔资金锁住了
            */
           _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            /*
            如果_totalSupply不为0，说明不是第一次_mint UNI，计算需要_mint的UNI的数量
            分别对token0和token1，首先计算增加的流动性占当前储备的占比，再乘以当前的UNI _totalSupply，分别得到token0和token1应该_mint的UNI数量，再取更小的那个
            */
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 给to地址_mint UNI token，作为向pair添加流动性的回报
        _mint(to, liquidity);

        /*
        1.更新pair中两种token的储备
        2.如果是每个区块的第一笔交易，计算价格累积值
        */
        _update(balance0, balance1, _reserve0, _reserve1);
        /*收取协议费的情况下，更新kLast的值；如果不收取协议费，那么不更新其值，值永远是0*/
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        /*
        此处msg.sender是UniswapV2Router02.sol的地址，因为是通过UniswapV2Router02.sol调用pair的mint
        */
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // 这个低级函数应该从执行了重要安全检查的一个合约中调用，即外围合约(UniswapV2Router02.sol的removeLiquidity函数)
    // https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/UniswapV2Router02.sol
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        /*获取当前pair的储备*/
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        /*获取当前pair分别在token0和token1中的余额。注意：单位是uint，和储备的单位uint112不同*/
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        /*
        获取pair自己的UNI token的余额。pair本身也是一种ERC20，此处即获取pair自己的地址的余额。
        这个余额实质上就是在router的removeLiquidity中，从UNI token持有者转给pair的。
        */
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        /*
        必须在_mintFee之后获取最新的totalSupply，因为在_mintFee里，如果开启了协议费，会更新totalSupply
        */
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        /*
        此处用到了SafeMath里的乘法mul，防止溢出。实际上这里的逻辑是根据本次要移除的liquidity(UNI token)占总的UNI token的比例，
        计算出应该给退出流动性池的账户转多少toekn0和token1。总的原则就是按比例分配。
        */
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        /*从UNI token池中销毁liquidity数量的UNI token*/
        _burn(address(this), liquidity);
        /*把pair在token0和token1中的部分资产转账给to地址。转账必须成功，如果不成功，就回滚*/
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        /*
        转账之后，pair在token0和token1中的余额肯定减少了，获取pair的最新余额，然后：
        1.更新pair中两种token的储备
        2.如果是每个区块的第一笔交易，计算价格累积值
        经过了_update之后，reserve0和reserve1就能反应最新的储备了
        */
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);
        /*
        如果开启协议费，通过SafeMath.mul(x, y)重新计算kLast
        */
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        /*
        此处msg.sender是UniswapV2Router02.sol的地址，因为是通过UniswapV2Router02.sol调用pair的burn
        amount0和amount1就是应该转给先前流动性提供者的资产
        to通常来说就是先前的流动性提供者，但流动性提供者也可以指定另一个地址来作为to，这个to相当于就是流动性提供的受益人，和保险中的受益人很像
        */
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    /*
    这个低级函数应该从执行了重要安全检查的一个合约中调用，即外围合约(比如UniswapV2Router02.sol的swapExactTokensForTokens函数)
    https://github.com/Uniswap/uniswap-v2-periphery/blob/master/contracts/UniswapV2Router02.sol
    swap的逻辑是：1.把一种token从兑换人转给pair合约 2.把另一种token从pair合约转给兑换人
    在UniswapV2Router02.sol的swapExactTokensForTokens函数中，已经完成了“1.把一种token从兑换人转给pair合约”，
    所以此处的swap函数仅完成“2.把另一种token从pair合约转给兑换人”。
    注意：pair中的token0和token1是排好序的，外围的router在调用pair的函数的时候，已经把token A,token B转换成了token0,token1，
    所以在pair的swap中完全不用担心token的顺序的问题，外围的router已经处理好了amount0Out和amount1Out，
    且已经计算好了应该从pair转多少资产给兑换人，所以传进来的值绝对没问题。
    */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        /*通常来讲，amount0Out和amount1Out其中有一个是uint(0)。其中非0的那一个代表需要从pair合约转给兑换人的资产数量*/
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        /*确保储备够用*/
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        /*
        to代表兑换人或其受益人，不能为token0和token1
        */
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        /*
        调用ERC20 token合约的transfer(address,uint256)函数，转账给to。from就是pair合约地址。
        */
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        /*
        uniswapV2Call用于flash swap，如果to是一个合约地址的话，可以执行它的uniswapV2Call函数。目前暂时还没有对flash swap的源码做太深入的研究。
        */
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
        /*
        经过把pair的资产转账给兑换人之后，pair的资产更新了，获取其最新资产。
        */
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        /*
        假设amount0Out为0，amount1Out为非0，那么balance1 == _reserve1 - amount1Out，所以amount1In为0；
        上面已经提到，“1.把一种token从兑换人转给pair合约”不是在当前的swap函数中完成的，而是在外围函数完成的，
        所以balance0 - _reserve0就是从兑换人转给pair合约的资产的数量，其值必须大于0，说明兑换人已经转资产给pair合约了。
        在此处的例子中，balance0增加了，balance1减少了。
        */
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        /*
        _reserve0和_reserve1还是未更新前的储备，不是最新的储备。
        同样，假设amount0Out为0，amount1Out为非0，amount1In为0，那么此处的require的含义就是：
        (balance0*1000-amount0In*3)*(balance1*1000)>=_reserve0*_reserve1*1000*1000
        而balance0=_reserve0+amount0In, balance1=_reserve1-amount1Out，那么上述的等式就演变成了：
        ((_reserve0+amount0In)*1000-amount0In*3)*(_reserve1-amount1Out)*1000>=_reserve0*_reserve1*1000*1000，
        继续演化一下：
        (_reserve0+0.997*amount0In)*(_reserve1-amount1Out)>=_reserve0*_reserve1
        从这个公式可以看出来，这就是考虑了0.3%手续费的uniswap恒定乘积公式。
        此处通过此公式来确保“1.把一种token从兑换人转给pair合约”中转账的数量是足够的，这个判断非常重要，因为上面的
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');仅仅要求转账数量大于0，
        如果不加上这个判断，就会引起bug，导致黑客转一点点amount0In给pair，然后套出大量amount1Out。
        所以这个require是整个swap函数的核心部分。
        */
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }
        /*
        1.更新pair中两种token的储备
        2.如果是每个区块的第一笔交易，计算价格累积值
        */
        _update(balance0, balance1, _reserve0, _reserve1);
        /*
        此处msg.sender是UniswapV2Router02.sol的地址
        to是兑换人或其受益人
        */
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    /*仅仅在uniswap-v2-periphery的测试用例里使用*/
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
