pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';
/*
此处定义UniswapV2ERC20是用于被UniswapV2Pair继承的，UniswapV2Pair也是一种ERC20 token，表示pool token。
当流动性提供者向一个币币兑换的pair中注入流动性后，就会得到pool token。
从这里可以看出，IUniswapV2ERC20被所有的UniswapV2Pair继承，意味着所有UniswapV2Pair的ERC20相关的状态变量和
函数都是相同的，比如，name都是Uniswap V2，symbol都是UNI-V2
*/
contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    /*constant说明不能改变*/
    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    uint8 public constant decimals = 18;
    /*totalSupply的值可以改变，比如通过_mint*/
    uint  public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    /*
    参考 https://uniswap.org/docs/v2/smart-contract-integration/supporting-meta-transactions/#domain-separator
    https://eips.ethereum.org/EIPS/eip-712
    所有Uniswap V2 pool tokens都通过permit函数支持元交易批准(meta-transaction approvals)。
    这就避免了在与pool tokens进行编程交互之前需要一个阻塞式的approve交易。
    在普通的ERC-20令牌合约中，owners只能通过直接调用一个使用msg.sender来授权自己的函数来注册approvals。
    使用元批准(meta-approvals)，所有权(ownership)和许可(permissioning)从调用者(有时候是中继者relayer)传递到函数的一个签名中派生出来。
    由于使用以太坊私钥签名数据是一项棘手的工作，Uniswap V2依赖于ERC-712，一种得到广泛社区支持的签名标准，以确保用户安全和钱包兼容性。
    */
    bytes32 public DOMAIN_SEPARATOR;
    // 参考 参考 https://uniswap.org/docs/v2/smart-contract-integration/supporting-meta-transactions/#domain-separator
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            // chainId是从ERC-1344的chainId操作码确定的
            chainId := chainid
        }
        /*
        name总是Uniswap V2
        chainId是从ERC-1344的chainId操作码确定的
        address(this)是继承了UniswapV2ERC20的pair的合约地址
        */
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        // 用了SafeMath里的add，确保不会溢出
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        // 由于是_mint，所以from地址是0地址
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        // 由于是_burn，多以to地址是0地址
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    // 调用者即是owner，如果value是uint(-1)，那么代表allowance无限
    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    // 调用者即是owner，from地址
    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    // 被授权的spender代表from进行转账
    function transferFrom(address from, address to, uint value) external returns (bool) {
        /*
        uint(-1)的值是0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff，64个十六进制数，即MAX_UINT，请参考：
        https://docs.soliditylang.org/en/latest/types.html#explicit-conversions
        https://github.com/ethereum/solidity/issues/534
        此处的实现逻辑是：如果allowance是MAX_UINT，那么代表无限的allowance，直接转账，参考：
        https://github.com/ethereum/EIPs/issues/717
        */
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        /*
        这是一种很好的在智能合约中判断超时的方法：通过传入一个deadline，然后和区块时间即block.timestamp比较。
        由于使用了require，那么如果超时，那交易就回滚，即revert。
        注意一个小细节：在以太坊中，block.timestamp的单位是秒，所以传入的deadline单位也是秒。
        在FISCO中，block.timestamp的单位是毫秒，所以传入的deadline单位也是毫秒。
        */
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        /*
        digest是期望hash，参数传入的签名v,r,s就是owner的私钥对digest的签名产生的。
        此处先用nonces[owner]，再自增1
        */
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        /*
        Solidity提供了一个内置函数ecrecover，该函数接受一个消息以及r、s和v参数，并返回用于对该消息进行签名的地址。
        */
        address recoveredAddress = ecrecover(digest, v, r, s);
        /*
        对digest签名的地址必须不为0地址，且等于owner的地址，即是owner的私钥对digest签名的
        */
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        // 签名验证通过，就执行_approve操作，否则回滚，不执行。
        _approve(owner, spender, value);
    }
}
