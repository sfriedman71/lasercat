// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/common/ERC2981.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "erc721psi/contracts/ERC721Psi.sol";


contract VRFMysteryBoxConsumer is ERC721Psi, ERC2981, Ownable {
    using Strings for uint256;

    uint256 public fee = 0.0001 ether;
    uint256 public constant MAX_MINT_AMOUNT_TX = 10;
    uint256 public constant MAX_MINT_AMOUNT_ACCOUNT = 20;
    
    uint96 constant private ROYALTY_NUMERATOR = 500; // 5.00 %
    
    string public constant BASE_EXTENSION = ".json";

    string public baseURI;
    uint256 public maxSupply;
    bool public mintActive = true;
    bool public publicSale = false;
    bool public revealed = false;
    bytes32 public whitelistRoot;
    mapping(address => uint256) public whitelistMintBalance;

    address private royaltiesReceiver;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _unrevealedURI,
        uint256 _maxSupply,
        bytes32 _whitelistRoot,
        address _royaltiesReceiver
    ) ERC721Psi(_name, _symbol) {
        maxSupply = _maxSupply;
        setBaseURI(_unrevealedURI);
        setWhitelistRoot(_whitelistRoot);
        setRoyaltiesReceiver(_royaltiesReceiver);
    }

    // External functions
    
    function mintPresale(
        uint256 _amount,
        uint256 _allowance,
        bytes32[] calldata _proof
    ) external payable {
        require(
            isWhitelisted(msg.sender, _allowance, _proof),
            "user is not whitelisted or allowance is incorrect"
        );
        require(
            whitelistMintBalance[msg.sender] + _amount <= _allowance,
            "allowance exceeded"
        );
        _mintAmount(_amount);
        whitelistMintBalance[msg.sender] += _amount;
    }


    function tokenURI(uint256 _tokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        require(
            _exists(_tokenId),
            "ERC721Metadata: URI query for nonexistent token"
        );
        string memory uri = _baseURI();
        if (revealed) {
            return
                bytes(uri).length > 0
                    ? string(
                        abi.encodePacked(
                            uri,
                            _tokenId.toString(),
                            BASE_EXTENSION
                        )
                    )
                    : "";
        }
        return uri;
    }


    function reveal() external onlyOwner {
        // TODO: add the VRF call here
        revealed = true;
    }

    /// @notice The owner can toggle this switch to enable/disable the
    /// minting.
    /// @dev This is state is defaulting to `true`, if not intended for
    /// the sale to start immediately - configure initial state pre-deployment.
    /// @param _state a boolean value for setting the minting on/off state.
    function setMintActive(bool _state) external onlyOwner {
        mintActive = _state;
    }

    /// @notice The owner can toggle the contract state between public
    /// sale and private (whitelisted only) sale.
    /// @dev This is state is defaulting to `false`, make sure the admin
    /// invokes this function to toggle the public sale to true
    /// when it is required to start.
    /// @param _state a boolean value for setting the public sale state.
    function setPublicSale(bool _state) external onlyOwner {
        publicSale = _state;
    }

    /// @notice The address with owner access control can withdraw
    /// the collected funds from the fees paid for minting.
    /// @dev Sends all of the collected funds to the owner address.
    function withdraw() external onlyOwner {
        (bool sent, ) = payable(owner()).call{value: address(this).balance}("");
        require(sent, "failed to send funds to owner");
    }

    // Public functions
    
    function mint(uint256 _amount) external payable {
        require(publicSale, "not in public sale");
        require(
            _amount <= MAX_MINT_AMOUNT_TX,
            "max mint amount per tx exceeded"
        );
        require(
            balanceOf(msg.sender) + _amount <= MAX_MINT_AMOUNT_ACCOUNT,
            "max mint amount per acc exceeded"
        );
        _mintAmount(_amount);
    }

    function isWhitelisted(
        address _user,
        uint256 _allowance,
        bytes32[] memory _proof
    ) public view returns (bool) {
        return
            MerkleProof.verify(
                _proof,
                whitelistRoot,
                keccak256(abi.encodePacked(_user, _allowance))
            );
    }

    function supportsInterface(bytes4 _interfaceId)
        public
        view
        virtual
        override(ERC721Psi, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(_interfaceId);
    }

    // Setting the provenance hash for pre-committing the artwork
    function setBaseURI(string memory _newBaseURI) public onlyOwner {
        baseURI = _newBaseURI;
    }

    // Internal functions
    
    function _baseURI() internal view virtual override returns (string memory) {
        return baseURI;
    }

    function _mintAmount(uint256 _amount) internal {
        require(mintActive, "minting not active");
        require(_amount > 0, "need to mint at least 1 NFT");
        uint256 supply = totalSupply();
        require(supply + _amount <= maxSupply, "max supply exceeded");
        require(msg.value >= fee * _amount, "insufficient funds");

        _safeMint(msg.sender, _amount);
    }

    /// @notice The address with owner access control can set and change
    /// the whitelist merkle tree root hash. The contract will allow
    /// only addresses present in the mekrle tree to mint tokens.
    /// @dev The root hash should be computed off-chain with a supported
    /// library. The merkle root verification in the contract is done
    /// using the openzeppelin's MerkleTree utility contract.
    /// @param _root a bytes32 merkle tree root hash
    function setWhitelistRoot(bytes32 _root) public onlyOwner {
        whitelistRoot = _root;
    }

    /// @notice The address with owner access control can change
    /// the royalties receiver address where royalties fees will be
    /// sent to if royalties are to be paid.
    /// @dev Make sure this is a valid address to avoid stuck funds.
    /// @param _receiver the address which is to receive the royalties fees.
    function setRoyaltiesReceiver(address _receiver) public onlyOwner {
         _setDefaultRoyalty(_receiver, ROYALTY_NUMERATOR); 
    }

    /// @notice The address with owner access control can configure
    /// and change the required fee for single token minting.
    /// @dev The default fee is set initially pre-deployment.
    /// This function requires only positive values to be provided.
    /// @param newFee the new fee to be set.
    function setMintFee(uint256 newFee) public onlyOwner {
        require(newFee >= 0, "fee must be positive");
        fee = newFee;
    }
}
