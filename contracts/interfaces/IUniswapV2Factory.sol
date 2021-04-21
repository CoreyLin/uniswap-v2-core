pragma solidity >=0.5.0;

interface IUniswapV2Factory {
    /*
    每次通过createPair创建一个pair时触发
    1.根据排序顺序，保证token0地址严格小于token1地址。
    2.对于创建的第一对pair，最后的uint值为1，第二对pair，uint为2，以此类推(参见allPairs/getPair)。
    */
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    /*
    未来可能要收取0.05%的协议费，占0.3%手续费的1/6
    如果feeTo不是address(0)，那就意味着协议费生效，feeTo地址就是协议费的接收地址
    */
    function feeTo() external view returns (address);
    /*允许更改feeTo地址的地址*/
    function feeToSetter() external view returns (address);

    /*
    返回tokenA和tokenB的pair的地址，如果它已经被创建，否则返回address(0)
    1.tokenA和tokenB可以互换
    2.pair的地址也可以确定地计算出来
    */
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    /*
    返回通过factory创建的第n个pair(从0开始索引)的地址，如果还没有创建足够的pair，则返回地址address(0)
    */
    function allPairs(uint) external view returns (address pair);
    /*
    返回迄今为止通过factory创建的pairs的总数
    */
    function allPairsLength() external view returns (uint);

    /*
    为tokenA和tokenB创建一个pair，如果这个pair还不存在
    1.tokenA和tokenB可以互换
    2.发出PairCreated event
    */
    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
    function setFeeToSetter(address) external;
}
