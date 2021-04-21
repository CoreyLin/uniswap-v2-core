pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;
    address public feeToSetter;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    /*
    每次通过createPair创建一个pair时触发
    1.根据排序顺序，保证token0地址严格小于token1地址。
    2.对于创建的第一对pair，最后的uint值为1，第二对pair，uint为2，以此类推(参见allPairs/getPair)。
    */
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    /*
    在初始化的时候设置可以修改feeTo地址的地址，这个地址的设置很重要，因为用于设置协议费收款地址
    */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    /*
    返回迄今为止通过factory创建的pairs的总数
    */
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /*
    为tokenA和tokenB创建一个pair，如果这个pair还不存在
    1.tokenA和tokenB可以互换
    2.发出PairCreated event
    */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        // tokenA和tokenB的地址不能相同
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 对地址进行排序
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        /*
        token0不能为0地址。这个其实有个隐含的意思：token1也不能为0地址。因为token0和token1是已经排序过后的地址
        token0比token1小，即使token0是0地址，token1都是比0大的地址，绝不可能是0地址
        此处仅判断token0，很妙，节省gas fee
        */
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        /*
        token0和token1的pair地址不存在，才创建pair，否则回滚，不创建pair
        注：mapping中address的默认值是address(0)
        */
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        /*
        参考 https://docs.soliditylang.org/en/v0.5.16/units-and-global-variables.html#type-information
        表达式type(X)可用于检索有关X类型的信息。对于合约类型C，type(C).creationCode代表包含合约的创建字节码的内存字节数组。
        这可以在inline assembly中用于构建自定义创建例程，特别是通过使用create2操作码。
        该属性不能在合约自身或任何派生的合约中访问。它导致字节码被包含在调用合约的字节码中，因此这样的循环引用是不可能的。
        */
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        /*
        操作码create2(v, p, n, s)：在地址keccak256(0xff . this . s . keccak256(mem[p…(p+n)))上创建代码为mem[p…(p+n))的合约，
        并且发送v wei给这个合约，然后返回新创建的合约地址。
        keccak256(0xff . this . s . keccak256(mem[p…(p+n)))：
        - 0xff是一字节值
        - this是当前合约的地址，20字节，在当前场景就是factory合约的地址
        - s是一个大端(big-endian)256位的值，32字节，此处可以理解为盐，在uniswap的场景中这也是确定的，由token0和token1的地址确定
        - keccak256(mem[p…(p+n))：合约代码的哈希
        add也是一个操作码(opcode)，add(x, y)代表相加x+y
        mload(0xAB)加载位于内存地址0xAB的word(32字节): https://ethereum.stackexchange.com/questions/9603/understanding-mload-assembly-function/9610
        总之，这里就是创建token0和token1的pair合约，这是固定用法，凡是在合约里创建新合约，都可以用这个方式
        */
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        // 调用pair合约的initialize函数
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        // push用于在数组尾部添加一个元素
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        // 首先判断权限
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        // 首先判断权限
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
