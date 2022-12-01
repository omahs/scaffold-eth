// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";

enum MoveDirection {
    Up,
    Down,
    Left,
    Right
}

abstract contract TokenContract {
  function mint(address to, uint256 amount) virtual public;
}

abstract contract NFTContract {
  function tokenURI(uint256 id) external virtual view returns (string memory);
  function ownerOf(uint256 id) external virtual view returns (address);
  function rechargeHealth(uint256 id, uint256 amount) public virtual;
  function decreaseHealth(uint256 id, uint256 amount) public virtual;
  function healthStatus(uint256 id) public virtual view returns (uint256);
}

contract Game is Ownable  {
    event Restart(uint8 width, uint8 height);
    event Register(address indexed txOrigin, address indexed msgSender, uint8 x, uint8 y, uint256 indexed nftId);
    event Move(uint256 indexed nftId, address indexed txOrigin, uint8 x, uint8 y, uint256 health);
    event GameOver(address indexed player);
    event CollectedTokens(address indexed player, uint256 indexed nftId, uint256 amount);
    event CollectedHealth(address indexed player, uint256 indexed nftId, uint256 amount);
    event NewDrop(bool indexed isHealth, uint256 amount, uint8 x, uint8 y);

    struct Field {
        uint256 player;
        uint256 tokenAmountToCollect;
        uint256 healthAmountToCollect;
    }

    struct Position {
        uint8 x;
        uint8 y;
    }

    NFTContract public nftContract;
    TokenContract public tokenContract;

    bool public gameOn;
    uint public collectInterval;

    uint8 public constant width = 24;
    uint8 public constant height = 24;
    Field[width][height] public worldMatrix;

    mapping(uint256 => Position) public yourPosition;
    mapping(uint256 => uint256) public lastCollectAttempt;
    uint256[] public players;

    uint256 public restartBlockNumber;
    bool public dropOnCollect;
    uint256 public attritionDivider = 50;
    uint256 public healthByMove = 50;

    modifier onlyNftOwner(uint256 nftId) {
        require(nftContract.ownerOf(nftId) == tx.origin, "ONLY NFT THAT YOU OWN");

        _;
    }

    constructor(uint256 _collectInterval, address _nftContractAddress, address _tokenContractAddress) {
        collectInterval = _collectInterval;
        nftContract = NFTContract(_nftContractAddress);
        tokenContract = TokenContract(_tokenContractAddress);
        restartBlockNumber = block.number;

        emit Restart(width, height);
    }

    function setCollectInterval(uint256 _collectInterval) public onlyOwner {
        collectInterval = _collectInterval;
    }

    function setDropOnCollect(bool _dropOnCollect) public onlyOwner {
        dropOnCollect = _dropOnCollect;
    }

    function start() public onlyOwner {
        gameOn = true;
    }

    function end() public onlyOwner {
        gameOn = false;
    }

    function restart() public onlyOwner {
        for (uint i=0; i<players.length; i++) {
            Position memory playerPosition = yourPosition[players[i]];
            worldMatrix[playerPosition.x][playerPosition.y] = Field(0,0,0);
            yourPosition[players[i]] = Position(0,0);
            lastCollectAttempt[players[i]] = 0;
        }

        delete players;

        restartBlockNumber = block.number;

        emit Restart(width, height);
    }

    function getPlayers() public view returns(uint256[] memory) {
        return players;
    }

    function register(uint256 nftId) public onlyNftOwner(nftId) {
        require(gameOn, "TOO LATE");
        require(players.length <= 50, "MAX 50 PLAYERS REACHED");

        players.push(nftId);

        randomlyPlace(nftId);

        emit Register(tx.origin, msg.sender, yourPosition[nftId].x, yourPosition[nftId].y, nftId);
    }

    function randomlyPlace(uint256 nftId) internal {
        bytes32 predictableRandom = keccak256(abi.encodePacked( blockhash(block.number-1), msg.sender, tx.origin, nftId, address(this) ));

        uint8 index = 0;
        uint8 x  = uint8(predictableRandom[index++])%width;
        uint8 y  = uint8(predictableRandom[index++])%height;

        Field memory field = worldMatrix[x][y];

        while(field.player != 0){
            x  = uint8(predictableRandom[index++])%width;
            y  = uint8(predictableRandom[index++])%height;
            field = worldMatrix[x][y];
        }

        worldMatrix[x][y].player = nftId;
        worldMatrix[yourPosition[nftId].x][yourPosition[nftId].y].player = 0;
        yourPosition[nftId] = Position(x, y);

        uint256 healthStatus = nftContract.healthStatus(nftId);
        emit Move(nftId, tx.origin, x, y, healthStatus);
    }

    function positionOf(uint256 nftId) public view returns(Position memory) {
        return yourPosition[nftId];
    }

    function tokenURIOf(uint256 nftId) public view returns(string memory) {
        return nftContract.tokenURI(nftId);
    }

    function collectTokens(uint256 nftId) public onlyNftOwner(nftId) {
        require(nftContract.healthStatus(nftId) > 0, "NO HEALTH");
        require(block.timestamp - lastCollectAttempt[nftId] >= collectInterval, "TOO EARLY");
        lastCollectAttempt[nftId] = block.timestamp;

        Position memory position = yourPosition[nftId];
        Field memory field = worldMatrix[position.x][position.y];
        require(field.tokenAmountToCollect > 0, "NOTHING TO COLLECT");

        if(field.tokenAmountToCollect > 0) {
            uint256 amount = field.tokenAmountToCollect;
            // mint tokens to tx.origin
            tokenContract.mint(tx.origin, amount);
            worldMatrix[position.x][position.y].tokenAmountToCollect = 0;
            emit CollectedTokens(tx.origin, nftId, amount);
            if (dropOnCollect) {
                dropToken(amount);
            }
        }

    }

    function collectHealth(uint256 nftId) public onlyNftOwner(nftId) {
        require(nftContract.healthStatus(nftId) > 0, "NO HEALTH");
        require(block.timestamp - lastCollectAttempt[nftId] >= collectInterval, "TOO EARLY");
        lastCollectAttempt[nftId] = block.timestamp;

        Position memory position = yourPosition[nftId];
        Field memory field = worldMatrix[position.x][position.y];
        require(field.healthAmountToCollect > 0, "NOTHING TO COLLECT");

        if(field.healthAmountToCollect > 0) {
            uint256 amount = field.healthAmountToCollect;
            nftContract.rechargeHealth(nftId, amount);
            worldMatrix[position.x][position.y].healthAmountToCollect = 0;
            emit CollectedHealth(tx.origin, nftId, amount);
            if (dropOnCollect) {
                dropHealth(amount);
            }
        }
    }

    function setAttritionDivider(uint8 newDivider) public onlyOwner {
        attritionDivider = newDivider;
    }

    function move(uint256 nftId, MoveDirection direction) public onlyNftOwner(nftId) {
        require(nftContract.healthStatus(nftId) > healthByMove, "NOT ENOUGH HEALTH");
        (uint8 x, uint8 y) = getCoordinates(direction, nftId);
        require(x < width && y < height, "OUT OF BOUNDS");

        Field memory field = worldMatrix[x][y];

        require(field.player == 0, "ANOTHER PLAYER ON THIS POSITION");

        bytes32 predictableRandom = keccak256(abi.encodePacked( blockhash(block.number-1), msg.sender, nftId, address(this)));

        // TODO: make it based on nft attribute
        nftContract.decreaseHealth(nftId, healthByMove);
        uint256 healthStatus = nftContract.healthStatus(nftId);

        worldMatrix[x][y].player = nftId;
        worldMatrix[yourPosition[nftId].x][yourPosition[nftId].y].player = 0;
        yourPosition[nftId] = Position(x, y);
        emit Move(nftId, tx.origin, x, y, healthStatus);
    }

    function getCoordinates(MoveDirection direction, uint256 nftId) internal view returns(uint8 x, uint8 y) {
        //       x ----->
        //      _______________
        //  y  |____|____|_____
        //     |____|____|_____
        //     |____|____|_____
        //     |____|____|_____

        if (direction == MoveDirection.Up) {
            x = yourPosition[nftId].x;
            y = yourPosition[nftId].y - 1;
        }

        if (direction == MoveDirection.Down) {
            x = yourPosition[nftId].x;
            y = yourPosition[nftId].y + 1;
        }

        if (direction == MoveDirection.Left) {
            x = yourPosition[nftId].x - 1;
            y = yourPosition[nftId].y;
        }

        if (direction == MoveDirection.Right) {
            x = yourPosition[nftId].x + 1;
            y = yourPosition[nftId].y;
        }
    }

    function dropToken(uint256 amount) internal {
        bytes32 predictableRandom = keccak256(abi.encodePacked( blockhash(block.number-1), msg.sender, address(this) ));

        uint8 x = uint8(predictableRandom[0]) % width;
        uint8 y = uint8(predictableRandom[1]) % height;

        worldMatrix[x][y].tokenAmountToCollect += amount;
        emit NewDrop(false, amount, x, y);
    }

    function dropHealth(uint256 amount) internal {
        bytes32 predictableRandom = keccak256(abi.encodePacked( blockhash(block.number-1), msg.sender, address(this) ));

        uint8 x = uint8(predictableRandom[0]) % width;
        uint8 y = uint8(predictableRandom[1]) % height;

        worldMatrix[x][y].healthAmountToCollect += amount;
        emit NewDrop(true, amount, x, y);
    }

    function shufflePrizes(uint256 firstRandomNumber, uint256 secondRandomNumber) public onlyOwner {
        uint8 x;
        uint8 y;

        x = uint8(uint256(keccak256(abi.encode(firstRandomNumber, 1))) % width);
        y = uint8(uint256(keccak256(abi.encode(secondRandomNumber, 1))) % height);
        worldMatrix[x][y].tokenAmountToCollect += 1000;
        emit NewDrop(false, 1000, x, y);

        x = uint8(uint256(keccak256(abi.encode(firstRandomNumber, 2))) % width);
        y = uint8(uint256(keccak256(abi.encode(secondRandomNumber, 2))) % height);
        worldMatrix[x][y].tokenAmountToCollect += 500;
        emit NewDrop(false, 500, x, y);

        x = uint8(uint256(keccak256(abi.encode(firstRandomNumber, 3))) % width);
        y = uint8(uint256(keccak256(abi.encode(secondRandomNumber, 3))) % height);
        worldMatrix[x][y].healthAmountToCollect += 100000;
        emit NewDrop(true, 100000, x, y);

        x = uint8(uint256(keccak256(abi.encode(firstRandomNumber, 4))) % width);
        y = uint8(uint256(keccak256(abi.encode(secondRandomNumber, 4))) % height);
        worldMatrix[x][y].healthAmountToCollect += 50000;
        emit NewDrop(true, 50000, x, y);
    }
}
