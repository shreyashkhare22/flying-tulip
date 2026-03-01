// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IftPut} from "./interfaces/IftPut.sol";

// Minimal view interface to read msig from PutManager for upgrade auth
interface IPutManagerView {
    function msig() external view returns (address);
}

contract pFT is
    Initializable,
    IftPut,
    ERC721EnumerableUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    UUPSUpgradeable
{
    using Strings for uint256;

    // we keep only the Put logic here, so that capital can be serviced from anywhere
    /// @notice NFT position data for a PUT option.
    /// @dev ftPerUSD is FT per 1 USD scaled to 1e8 (same base as oracle).
    struct Put {
        // slot 0
        address token; // 20: the denomination of asset
        uint96 amount; // 12: the amount of denomination asset
        // slot 1
        uint96 ft; // 12: updating value of FT for calcs
        uint96 ft_bought; // 12: amount of FT originally bought
        // (8 bytes unused)

        // slot 2
        uint96 withdrawn; // 12: amount of FT that has been withdrawn
        uint96 burned; // 12: amount of FT that has been burned via excercising the PUT option
        // (8 bytes unused)

        // slot 3
        uint96 strike; // 12: collateral USD price at purchase (1e8 scale)
        uint96 amountRemaining; // 12: amount of denomination asset remaining
        uint64 ftPerUSD; // 8: FT per USD scaled to 1e8 at time of purchase
    }

    mapping(uint256 tokenId => Put put) public puts;

    uint96 public nextIndex;
    address public putManager;
    string private _baseTokenURI;
    bool private _appendTokenIdInURI; // default is false

    error pFTZeroAddress();
    error pFTOnlyPutOwner();
    error pFTInsufficientTokens();
    error pFTNotPutManager();
    error pFTAmountOverflow();
    error pFTFTOverflow();
    error pFTUsdOverflow();
    error pFTInsufficientCollateral();
    error pFTNotMsig();
    error pFTBaseURINotSet();

    event PutManagerUpdated(address indexed newManager);
    event BaseTokenURIUpdated(string previousBaseURI, string newBaseURI);
    event TokenURIAppendTokenIdUpdated(bool previousValue, bool newValue);

    modifier onlyPutManager() {
        if (msg.sender != putManager) revert pFTNotPutManager();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract with the put manager
     * @notice Can only be called once
     * @param _putManager The address of the put manager
     */
    function initialize(address _putManager) public initializer {
        __ERC721_init("Flying Tulip PUT", "ftPUT");
        __ERC721Enumerable_init();
        _setPutManager(_putManager);
    }

    // UUPS upgradeability authorization: only PutManager's msig may upgrade
    function _authorizeUpgrade(address) internal view override {
        address _pm = putManager;
        if (_pm == address(0)) revert pFTNotMsig();
        address _msig = IPutManagerView(_pm).msig();
        if (msg.sender != _msig) revert pFTNotMsig();
    }

    /**
     * @dev Set the put manager
     * @notice Can only be called by the current put manager
     * @param _putManager The address of the put manager
     */
    function setPutManager(address _putManager) external onlyPutManager {
        _setPutManager(_putManager);
    }

    function _setPutManager(address _putManager) internal {
        if (_putManager == address(0x0)) revert pFTZeroAddress();
        if (_putManager == putManager) return; // no-op, avoid spurious event
        emit PutManagerUpdated(_putManager);
        putManager = _putManager;
    }

    /**
     *
     * @param owner The address to mint the put token to
     * @param amount The amount of denomination asset
     * @param ft The amount of FT
     * @param usd The strike price in USD
     * @param token The token address
     * @param ftPerUSD FT per 1 USD scaled to 1e8 (same base as oracle) at time of purchase
     * @return id The ID of the minted put token
     */
    function mint(
        address owner,
        uint256 amount,
        uint256 ft,
        uint256 usd,
        address token,
        uint64 ftPerUSD
    )
        external
        nonReentrant
        onlyPutManager
        returns (uint256 id)
    {
        if (amount > type(uint96).max) revert pFTAmountOverflow();
        if (ft > type(uint96).max) revert pFTFTOverflow();
        if (usd > type(uint96).max) revert pFTUsdOverflow();

        uint256 _nextIndex = nextIndex;
        if (_nextIndex == type(uint96).max) revert pFTAmountOverflow();
        puts[_nextIndex] = Put(
            token,
            uint96(amount),
            uint96(ft),
            uint96(ft),
            0,
            0,
            uint96(usd),
            uint96(amount),
            ftPerUSD
        );
        nextIndex = uint96(_nextIndex + 1);
        _safeMint(owner, _nextIndex);

        return _nextIndex;
    }

    /**
     * @notice Withdraw FT from the put token
     * @param owner The owner of the put token
     * @param id The ID of the put token
     * @param amount The amount of FT to withdraw
     * @param amountDivested The corresponding collateral amount deducted from the position
     * @return strike The strike price of the put
     * @return token The token associated with the put
     */
    function withdrawFT(
        address owner,
        uint256 id,
        uint256 amount,
        uint256 amountDivested
    )
        external
        nonReentrant
        onlyPutManager
        returns (uint256 strike, address token)
    {
        if (ownerOf(id) != owner) revert pFTOnlyPutOwner();
        Put storage _put = puts[id];

        if (amount > type(uint96).max) revert pFTAmountOverflow();
        uint96 _amount = uint96(amount);

        if (amountDivested > type(uint96).max) revert pFTAmountOverflow();
        uint96 _amountDivested = uint96(amountDivested);

        if (_amount > _put.ft) revert pFTInsufficientTokens();
        if (_amountDivested > _put.amountRemaining) revert pFTInsufficientCollateral();

        _put.ft -= _amount;
        _put.withdrawn += _amount;
        _put.amountRemaining -= _amountDivested;

        // Burn NFT when fully withdrawn and clear residual amountRemaining dust
        if (_put.ft == 0) {
            _put.amountRemaining = 0;
            _burn(id);
        }

        return (_put.strike, _put.token);
    }

    /**
     * @notice Divest FT from the put token
     * @param owner The owner of the put token
     * @param id The ID of the put token
     * @param amount The amount of FT to divest
     * @return strikeAmount The strike price of the put
     * @return token The token associated with the put
     */
    function divest(
        address owner,
        uint256 id,
        uint256 amount,
        uint256 amountDivested
    )
        external
        nonReentrant
        onlyPutManager
        returns (uint256 strikeAmount, address token)
    {
        if (ownerOf(id) != owner) revert pFTOnlyPutOwner();
        Put storage _put = puts[id];

        if (amount > type(uint96).max) revert pFTAmountOverflow();
        uint96 _amount = uint96(amount);

        if (amountDivested > type(uint96).max) revert pFTAmountOverflow();
        uint96 _amountDivested = uint96(amountDivested);

        if (_amount > _put.ft) revert pFTInsufficientTokens();
        if (_amountDivested > _put.amountRemaining) revert pFTInsufficientCollateral();

        _put.ft -= _amount;
        _put.burned += _amount;
        _put.amountRemaining -= _amountDivested;

        // Burn NFT when fully divested and clear residual amountRemaining dust
        if (_put.ft == 0) {
            _put.amountRemaining = 0;
            _burn(id);
        }
        return (_put.strike, _put.token);
    }

    /**
     *
     * @dev Burn the put token
     * @notice Used for exit during IN_PUB_OFFERING
     * @param owner The owner of the put token
     * @param id The ID of the put token
     */
    function burn(address owner, uint256 id) external nonReentrant onlyPutManager {
        if (ownerOf(id) != owner) revert pFTOnlyPutOwner();
        _burn(id);
    }

    /**
     *
     * @param id The ID of the put token
     * @return ft The amount of FT that can be divested
     * @return strike The strike price of the put
     * @return token The token associated with the put
     */
    /**
     * @notice View how much FT can be divested for a position.
     * @param id The ID of the put token
     * @return ft The amount of FT currently divestable
     * @return strike The strike (oracle price) scaled to 1e8
     * @return token The collateral token address
     * @return ftPerUSD FT per 1 USD scaled to 1e8 (same base as oracle)
     */
    function divestable(uint256 id)
        external
        view
        returns (uint256 ft, uint256 strike, address token, uint64 ftPerUSD)
    {
        Put memory _put = puts[id];
        return (_put.ft, _put.strike, _put.token, _put.ftPerUSD);
    }

    /**
     * @notice Returns the currently configured base token URI.
     */
    function baseTokenURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    function appendTokenIdInURI() external view returns (bool) {
        return _appendTokenIdInURI;
    }

    /**
     * @notice Allows the PutManager msig to set the base token URI used for metadata hosting.
     */
    function setBaseTokenURI(string calldata newBaseURI) external {
        if (msg.sender != _getMsig()) revert pFTNotMsig();

        emit BaseTokenURIUpdated(_baseTokenURI, newBaseURI);
        _baseTokenURI = newBaseURI;
    }

    function setAppendTokenIdInURI(bool enabled) external {
        if (msg.sender != _getMsig()) revert pFTNotMsig();
        emit TokenURIAppendTokenIdUpdated(_appendTokenIdInURI, enabled);
        _appendTokenIdInURI = enabled;
    }

    /**
     * @inheritdoc ERC721Upgradeable
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory baseURI = _baseURI();
        if (bytes(baseURI).length == 0) revert pFTBaseURINotSet();
        if (_appendTokenIdInURI) {
            return string.concat(baseURI, tokenId.toString());
        }
        return baseURI;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _getMsig() internal view returns (address) {
        address _pm = putManager;
        if (_pm == address(0)) revert pFTNotMsig();
        address _msig = IPutManagerView(_pm).msig();
        if (_msig == address(0)) revert pFTNotMsig();
        return _msig;
    }

    // --- OpenZeppelin v5 multiple inheritance requirements ---

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721EnumerableUpgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _update(
        address to,
        uint256 tokenId,
        address auth
    )
        internal
        override(ERC721EnumerableUpgradeable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(
        address account,
        uint128 value
    )
        internal
        override(ERC721EnumerableUpgradeable)
    {
        super._increaseBalance(account, value);
    }
}
