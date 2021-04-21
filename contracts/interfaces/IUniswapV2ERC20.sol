pragma solidity >=0.5.0;
/*
此接口定义了Uniswap中ERC20 token需要实现的函数，遵循ERC20标准(https://eips.ethereum.org/EIPS/eip-20)，不再赘述。
*/
interface IUniswapV2ERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
    /*以下函数不是ERC20标准中定义的，是uniswap定义的*/
    /*
    参考 https://uniswap.org/docs/v2/smart-contract-integration/supporting-meta-transactions/#domain-separator
    https://eips.ethereum.org/EIPS/eip-712
    所有Uniswap V2 pool tokens都通过permit函数支持元交易批准(meta-transaction approvals)。
    这就避免了在与pool tokens进行编程交互之前需要一个阻塞式的approve交易。
    在普通的ERC-20令牌合约中，owners只能通过直接调用一个使用msg.sender来授权自己的函数来注册approvals。
    使用元批准(meta-approvals)，所有权(ownership)和许可(permissioning)从调用者(有时候是中继者relayer)传递到函数的一个签名中派生出来。
    由于使用以太坊私钥签名数据是一项棘手的工作，Uniswap V2依赖于ERC-712，一种得到广泛社区支持的签名标准，以确保用户安全和钱包兼容性。
    DOMAIN_SEPARATOR,PERMIT_TYPEHASH,nonces,permit是紧密关联的，结合起来用于approve
    */
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}
