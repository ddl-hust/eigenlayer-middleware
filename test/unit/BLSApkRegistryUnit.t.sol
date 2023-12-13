//SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;


import "forge-std/Test.sol";
import "src/BLSApkRegistry.sol";
import "src/interfaces/IRegistryCoordinator.sol";
import "test/mocks/BLSPublicKeyCompendiumMock.sol";
import "test/mocks/RegistryCoordinatorMock.sol";


contract BLSApkRegistryUnitTests is Test {
    using BN254 for BN254.G1Point;
    Vm cheats = Vm(HEVM_ADDRESS);

    address defaultOperator = address(4545);
    address defaultOperator2 = address(4546);

    bytes32 internal constant ZERO_PK_HASH = hex"ad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5";

    BLSApkRegistry public blsApkRegistry;
    BLSPublicKeyCompendiumMock public pkCompendium;
    RegistryCoordinatorMock public registryCoordinator;

    BN254.G1Point internal defaultPubKey =  BN254.G1Point(18260007818883133054078754218619977578772505796600400998181738095793040006897,3432351341799135763167709827653955074218841517684851694584291831827675065899);

    uint8 internal defaultQuorumNumber = 0;

    // Track initialized quorums so we can filter these out when fuzzing
    mapping(uint8 => bool) initializedQuorums;

    function setUp() external {
        registryCoordinator = new RegistryCoordinatorMock();
        pkCompendium = new BLSPublicKeyCompendiumMock();
        blsApkRegistry = new BLSApkRegistry(registryCoordinator, pkCompendium);

        // Initialize a quorum
        _initializeQuorum(defaultQuorumNumber);
    }

    function testConstructorArgs() public view {
        require(blsApkRegistry.registryCoordinator() == registryCoordinator, "registryCoordinator not set correctly");
        require(blsApkRegistry.pubkeyCompendium() == pkCompendium, "pubkeyCompendium not set correctly");
    }

    function testCallRegisterOperatorFromNonCoordinatorAddress(address nonCoordinatorAddress) public {
        cheats.assume(nonCoordinatorAddress != address(registryCoordinator));

        cheats.startPrank(nonCoordinatorAddress);
        cheats.expectRevert(bytes("BLSApkRegistry.onlyRegistryCoordinator: caller is not the registry coordinator"));
        blsApkRegistry.registerOperator(nonCoordinatorAddress, new bytes(0));
        cheats.stopPrank();
    }

    function testCallDeregisterOperatorFromNonCoordinatorAddress(address nonCoordinatorAddress) public {
        cheats.assume(nonCoordinatorAddress != address(registryCoordinator));

        cheats.startPrank(nonCoordinatorAddress);
        cheats.expectRevert(bytes("BLSApkRegistry.onlyRegistryCoordinator: caller is not the registry coordinator"));
        blsApkRegistry.deregisterOperator(nonCoordinatorAddress, new bytes(0));
        cheats.stopPrank();
    }

    function testOperatorDoesNotOwnPubKeyRegister() public {
        cheats.startPrank(address(registryCoordinator));
        cheats.expectRevert(bytes("BLSPublicKeyCompendium.getRegisteredPubkey: operator is not registered"));
        blsApkRegistry.registerOperator(defaultOperator, new bytes(1));
        cheats.stopPrank();
    }

    function testRegisterOperatorBLSPubkey(address operator, bytes32 x) public returns(bytes32){
        
        BN254.G1Point memory pubkey = BN254.hashToG1(x);
        bytes32 pkHash = BN254.hashG1Point(pubkey);

        cheats.startPrank(operator);
        pkCompendium.registerPublicKey(pubkey);
        cheats.stopPrank();

        //register for one quorum
        bytes memory quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(defaultQuorumNumber);
        
        cheats.startPrank(address(registryCoordinator));
        bytes32 registeredpkHash = blsApkRegistry.registerOperator(operator, quorumNumbers);
        cheats.stopPrank();


        require(registeredpkHash == pkHash, "registeredpkHash not set correctly");
        emit log("ehey");

        return pkHash;
    }

    function testQuorumApkUpdates(uint8 quorumNumber1, uint8 quorumNumber2) public {
        cheats.assume(quorumNumber1 != quorumNumber2);

        bytes memory quorumNumbers = new bytes(2);
        quorumNumbers[0] = bytes1(quorumNumber1);
        quorumNumbers[1] = bytes1(quorumNumber2);
        if (!initializedQuorums[quorumNumber1]) {
            _initializeFuzzedQuorum(quorumNumber1);
        }
        if (!initializedQuorums[quorumNumber2]) {
            _initializeFuzzedQuorum(quorumNumber2);
        }

        BN254.G1Point[] memory quorumApksBefore = new BN254.G1Point[](quorumNumbers.length);
        for(uint8 i = 0; i < quorumNumbers.length; i++){
            quorumApksBefore[i] = blsApkRegistry.getApk(uint8(quorumNumbers[i]));
        }

        cheats.prank(defaultOperator);
        pkCompendium.registerPublicKey(defaultPubKey);
        
        cheats.prank(address(registryCoordinator));
        blsApkRegistry.registerOperator(defaultOperator, quorumNumbers);

        //check quorum apk updates
        for(uint8 i = 0; i < quorumNumbers.length; i++){
            BN254.G1Point memory quorumApkAfter = blsApkRegistry.getApk(uint8(quorumNumbers[i]));
            bytes32 temp = BN254.hashG1Point(BN254.plus(quorumApkAfter, BN254.negate(quorumApksBefore[i])));
            require(temp == BN254.hashG1Point(defaultPubKey), "quorum apk not updated correctly");
        }
    }

    function testRegisterWithNegativeQuorumApk(address operator, bytes32 x) external {
        testRegisterOperatorBLSPubkey(defaultOperator, x);

        BN254.G1Point memory quorumApk = blsApkRegistry.getApk(defaultQuorumNumber);

        BN254.G1Point memory negatedQuorumApk = BN254.negate(quorumApk);

        //register for one quorum
        bytes memory quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(defaultQuorumNumber);

        cheats.startPrank(operator);
        pkCompendium.registerPublicKey(negatedQuorumApk);
        cheats.stopPrank();

        cheats.startPrank(address(registryCoordinator));
        blsApkRegistry.registerOperator(operator, quorumNumbers);
        cheats.stopPrank();

        require(BN254.hashG1Point(blsApkRegistry.getApk(defaultQuorumNumber)) == ZERO_PK_HASH, "quorumApk not set correctly");
    }
    
    function testQuorumApkUpdatesDeregistration(uint8 quorumNumber1, uint8 quorumNumber2) external {
        cheats.assume(quorumNumber1 != quorumNumber2);
        bytes memory quorumNumbers = new bytes(2);
        quorumNumbers[0] = bytes1(quorumNumber1);
        quorumNumbers[1] = bytes1(quorumNumber2);
        _initializeFuzzedQuorum(quorumNumber1);
        _initializeFuzzedQuorum(quorumNumber2);

        testQuorumApkUpdates(quorumNumber1, quorumNumber2);

        BN254.G1Point[] memory quorumApksBefore = new BN254.G1Point[](2);
        for(uint8 i = 0; i < quorumNumbers.length; i++){
            quorumApksBefore[i] = blsApkRegistry.getApk(uint8(quorumNumbers[i]));
        }

        cheats.startPrank(address(registryCoordinator));
        blsApkRegistry.deregisterOperator(defaultOperator, quorumNumbers);
        cheats.stopPrank();

        
        BN254.G1Point memory quorumApkAfter;
        for(uint8 i = 0; i < quorumNumbers.length; i++){
            quorumApkAfter = blsApkRegistry.getApk(uint8(quorumNumbers[i]));
            require(BN254.hashG1Point(quorumApksBefore[i].plus(defaultPubKey.negate())) == BN254.hashG1Point(quorumApkAfter), "quorum apk not updated correctly");
        }
    }

    function testDeregisterOperatorWithQuorumApk(bytes32 x1, bytes32 x2) external {
        testRegisterOperatorBLSPubkey(defaultOperator, x1);
        testRegisterOperatorBLSPubkey(defaultOperator2, x2);

        BN254.G1Point memory quorumApksBefore= blsApkRegistry.getApk(defaultQuorumNumber);

        bytes memory quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(defaultQuorumNumber);

        cheats.startPrank(defaultOperator);
        pkCompendium.registerPublicKey(quorumApksBefore);
        cheats.stopPrank();

        cheats.prank(address(registryCoordinator));
        blsApkRegistry.deregisterOperator(defaultOperator, quorumNumbers);

        BN254.G1Point memory pk = blsApkRegistry.getApk(defaultQuorumNumber);
        require(pk.X == 0, "quorum apk not set to zero");
        require(pk.Y == 0, "quorum apk not set to zero");
    }

    function testQuorumApkUpdatesAtBlockNumber(uint256 numRegistrants, uint256 blockGap) external{
        cheats.assume(numRegistrants > 0 && numRegistrants <  100);
        cheats.assume(blockGap < 100);

        BN254.G1Point memory quorumApk = BN254.G1Point(0,0);
        bytes24 quorumApkHash;
        for (uint256 i = 0; i < numRegistrants; i++) {
            bytes32 pk = _getRandomPk(i);
            testRegisterOperatorBLSPubkey(defaultOperator, pk);
            quorumApk = quorumApk.plus(BN254.hashToG1(pk));
            quorumApkHash = bytes24(BN254.hashG1Point(quorumApk));
            uint historyLength = blsApkRegistry.getApkHistoryLength(defaultQuorumNumber);
            assertEq(quorumApkHash, blsApkRegistry.getApkHashAtBlockNumberAndIndex(defaultQuorumNumber, uint32(block.number + blockGap), historyLength-1), "incorrect quorum apk update");
            cheats.roll(block.number + 100);
            if(_generateRandomNumber(i) % 2 == 0){
                _deregisterOperator();
                quorumApk = quorumApk.plus(BN254.hashToG1(pk).negate());
                quorumApkHash = bytes24(BN254.hashG1Point(quorumApk));
                historyLength = blsApkRegistry.getApkHistoryLength(defaultQuorumNumber);
                assertEq(quorumApkHash, blsApkRegistry.getApkHashAtBlockNumberAndIndex(defaultQuorumNumber, uint32(block.number + blockGap), historyLength-1), "incorrect quorum apk update");
                cheats.roll(block.number + 100);
                i++;
            }
        }
    }

    /// TODO - fix test
    function testIncorrectBlockNumberForQuorumApkUpdates(uint256 numRegistrants, uint32 indexToCheck, uint32 wrongBlockNumber) external {
        cheats.assume(numRegistrants > 0 && numRegistrants <  100);
        cheats.assume(indexToCheck < numRegistrants - 1);

        uint256 startingBlockNumber = block.number;

        for (uint256 i = 0; i < numRegistrants; i++) {
            bytes32 pk = _getRandomPk(i);
            testRegisterOperatorBLSPubkey(defaultOperator, pk);
            cheats.roll(block.number + 100);
        }
        if(wrongBlockNumber < startingBlockNumber + indexToCheck*100){
            emit log_named_uint("index too recent: ", indexToCheck);
            cheats.expectRevert(bytes("BLSApkRegistry._validateApkHashAtBlockNumber: index too recent"));
            blsApkRegistry.getApkHashAtBlockNumberAndIndex(defaultQuorumNumber, wrongBlockNumber, indexToCheck);
        } 
        if (wrongBlockNumber >= startingBlockNumber + (indexToCheck+1)*100){
            emit log_named_uint("index not latest: ", indexToCheck);
            cheats.expectRevert(bytes("BLSApkRegistry._validateApkHashAtBlockNumber: not latest apk update"));
            blsApkRegistry.getApkHashAtBlockNumberAndIndex(defaultQuorumNumber, wrongBlockNumber, indexToCheck);
        }
    }

    function _initializeQuorum(
        uint8 quorumNumber
    ) internal {
        cheats.prank(address(registryCoordinator));

        blsApkRegistry.initializeQuorum(quorumNumber);
        initializedQuorums[quorumNumber] = true;
    }

    function _initializeFuzzedQuorum(
        uint8 quorumNumber
    ) internal {
        cheats.assume(!initializedQuorums[quorumNumber]);
        _initializeQuorum(quorumNumber);
    }

    function _getRandomPk(uint256 seed) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, seed));
    }

    function _generateRandomNumber(uint256 seed) internal view returns (uint256) {
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(block.timestamp, seed)));
        return (randomNumber % 100) + 1; 
    }

    function _deregisterOperator() internal {
        bytes memory quorumNumbers = new bytes(1);
        quorumNumbers[0] = bytes1(defaultQuorumNumber);
        cheats.startPrank(address(registryCoordinator));
        blsApkRegistry.deregisterOperator(defaultOperator, quorumNumbers);
        cheats.stopPrank();
    }

}