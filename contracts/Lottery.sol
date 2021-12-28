pragma solidity >=0.4.21 <0.6.0;


contract Lottery {

    struct BetInfo { // 구조체 이고 배팅한 사람의 정보를 담는 객체라고 생각하면 편하다.
        uint256 answerBlockNumber; // 배팅한 블록의 숫자
        address payable bettor; // 배팅한 사람의 주소
        byte challenges; // 배팅한 사람의 글자 '0xab','0xac'...
    }
    
    uint256 private _tail; // 맵구조의 들어갈 인덱스 숫자이다.
    uint256 private _head; // 맵구조를 뽑아낼 숫자이다.
    mapping (uint256 => BetInfo) private _bets; // 사용자가 배팅시 정보를 저장하는 mapping 이다.

    address payable public owner;
    
    
    uint256 private _pot; // 배팅할 금액
    bool private mode = false; // false : 테스트 단계로 난수값이 아닌 0x00 으로 고정이다 true로 하면 block.hash를 통해 여러 값이 알아서 들어간다.
    bytes32 public answerForTest; 

    uint256 constant internal BLOCK_LIMIT = 256; // 블록이 전에 있던 블록을 확인 할 수 있는 갯수는 256개가 최대이다. 그래서 상수로 준비했다.
    uint256 constant internal BET_BLOCK_INTERVAL = 3; // 3번째 이후의 결과를 알려주기 위해 상수로 준비
    uint256 constant internal BET_AMOUNT = 5 * 10 ** 15; // 배팅금액을 상수로 지정을 해놨다.

    enum BlockStatus {Checkable, NotRevealed, BlockLimitPassed} // 현재 블록이 체크중인지 확인할 수 없는지 지나갔는지 enum을 통한 상수 값으로 지정한 것 이다.
    enum BettingResult {Fail, Win, Draw} // 배팅후 상태 값

    // 이벤트 들..
    event BET(uint256 index, address indexed bettor, uint256 amount, byte challenges, uint256 answerBlockNumber);
    event WIN(uint256 index, address bettor, uint256 amount, byte challenges, byte answer, uint256 answerBlockNumber);
    event FAIL(uint256 index, address bettor, uint256 amount, byte challenges, byte answer, uint256 answerBlockNumber);
    event DRAW(uint256 index, address bettor, uint256 amount, byte challenges, byte answer, uint256 answerBlockNumber);
    event REFUND(uint256 index, address bettor, uint256 amount, byte challenges, uint256 answerBlockNumber);

    constructor() public { // 생성자
        owner = msg.sender; // 생성자는 배포할때 단 한번만 실행된다. 그래서 'owner'의 값은 배포한 사람의 주소가 들어가게 된다.
    }

    function getPot() public view returns (uint256 pot) { // 팟 머니를 가져오는 함수
        return _pot;
    }

    /**
     * @dev 베팅과 정답 체크를 한다. 유저는 0.005 ETH를 보내야 하고, 베팅용 1 byte 글자를 보낸다.
     * 큐에 저장된 베팅 정보는 이후 distribute 함수에서 해결된다.
     * @param challenges 유저가 베팅하는 글자
     * @return 함수가 잘 수행되었는지 확인해는 bool 값
     */
    function betAndDistribute(byte challenges) public payable returns (bool result) {
        bet(challenges); // 이 함수를 실행하면 먼저 배팅을 하고

        distribute(); // 배팅 정보를 저장하는 곳.

        return true;
    }

    // 90846 -> 75846
    /**
     * @dev 베팅을 한다. 유저는 0.005 ETH를 보내야 하고, 베팅용 1 byte 글자를 보낸다.
     * 큐에 저장된 베팅 정보는 이후 distribute 함수에서 해결된다.
     * @param challenges 유저가 베팅하는 글자
     * @return 함수가 잘 수행되었는지 확인해는 bool 값
     */
    function bet(byte challenges) public payable returns (bool result) { // 배팅
         // 사용자가 보낸 이더가 0.005ETH가 아닐경우 에러 발생
        require(msg.value == BET_AMOUNT, "Not enough ETH");

        // 사용자의 정보 저장 후 mapping에 저장한다. 반환값은 true OR false 로 나온다.
        require(pushBet(challenges), "Fail to add a new Bet Info");

        // Emit event
        emit BET(_tail - 1, msg.sender, msg.value, challenges, block.number + BET_BLOCK_INTERVAL);

        return true;
    }

    /**
     * @dev 베팅 결과값을 확인 하고 팟머니를 분배한다.
     * 정답 실패 : 팟머니 축척, 정답 맞춤 : 팟머니 획득, 한글자 맞춤 or 정답 확인 불가 : 베팅 금액만 획득
     */
    function distribute() public {
        // head 3 4 5 6 7 8 9 10 11 12 tail
        uint256 cur; // head에 들어갈 인덱스 번호
        uint256 transferAmount;

        BetInfo memory b; // 배팅 사용자 생성
        BlockStatus currentBlockStatus; // 블록 상태값 생성(enum)
        BettingResult currentBettingResult; // 배팅 값 생성(enum)

        for(cur=_head;cur<_tail;cur++) {
            b = _bets[cur]; // 현재 배팅된 정보를 꺼내온다.
            currentBlockStatus = getBlockStatus(b.answerBlockNumber); // 현재 블록 상태값이 확인 가능인지 불가능인지 체크하는 함수를 불러 변수에 담는다.
            // Checkable : 확인이 된 상태일때
            if(currentBlockStatus == BlockStatus.Checkable) {
                bytes32 answerBlockHash = getAnswerBlockHash(b.answerBlockNumber); // 현재 블록 해쉬의 값을 가져와 담는다.
                currentBettingResult = isMatch(b.challenges, answerBlockHash); // 그리고 사용자가 배팅한 게임이 이겼는지 졌는지를 확인해서 변수에 담는다.
                // 게임의 이겼을때
                if(currentBettingResult == BettingResult.Win) {
                    // 사용자에게 쌓인 팟 머니를 주고 팟 머니는 다시 0으로 지정한다.
                    transferAmount = transferAfterPayingFee(b.bettor, _pot + BET_AMOUNT);
                    
                    // pot = 0
                    _pot = 0;

                    // emit WIN
                    emit WIN(cur, b.bettor, transferAmount, b.challenges, answerBlockHash[0], b.answerBlockNumber);
                }
                // 게임의 졋을때
                if(currentBettingResult == BettingResult.Fail) {
                    // 팟 머니의 0.05ETH을 축적한다.
                    _pot += BET_AMOUNT;
                    // emit FAIL
                    emit FAIL(cur, b.bettor, 0, b.challenges, answerBlockHash[0], b.answerBlockNumber);
                }
                
                // 게임의 비겼을 때 
                if(currentBettingResult == BettingResult.Draw) {
                    // 사용자에게 배팅한 금액을 돌려준다.
                    transferAmount = transferAfterPayingFee(b.bettor, BET_AMOUNT);

                    // emit DRAW
                    emit DRAW(cur, b.bettor, transferAmount, b.challenges, answerBlockHash[0], b.answerBlockNumber);
                }
            }

            // Not Revealed : 확인할 수 없을 때
            if(currentBlockStatus == BlockStatus.NotRevealed) {
                break; // 반복문 탈출!!!
            }

            // Block Limit Passed : 256개의 블록을 넘어서 값을 확인 할 수 없을때
            if(currentBlockStatus == BlockStatus.BlockLimitPassed) {
                // 금액을 돌려준다.
                transferAmount = transferAfterPayingFee(b.bettor, BET_AMOUNT);
                // emit refund
                emit REFUND(cur, b.bettor, transferAmount, b.challenges, b.answerBlockNumber);
            }

            popBet(cur); // 확인이 완료됬으니 정보를 지운다.
        }
        _head = cur; // head있는 정보를 가지고 동작을 완료했으니 head의 값도 업데이트를 해줬다!
    }
    /*
        배팅의 성공한 사람이나. 비긴 사람 그리고 블록의 값을 찾지 못하는 경우
        사용자에게 일정 수수료를 뗀 금액을 돌려주는 함수
    */
    function transferAfterPayingFee(address payable addr, uint256 amount) internal returns (uint256) {
        
        // uint256 fee = amount / 100;
        uint256 fee = 0; // 수수료의 값은 일단 '0'으로 지정하였다.
        uint256 amountWithoutFee = amount - fee; // 그래서 사용자에 보낼 금액은 돌려줄 금액 - 수수료 를 제한 금액을 변수에 담았다.

        // transfer to addr
        addr.transfer(amountWithoutFee); // transfer을 이용한 이더 송금!! 0.8.0 버전 이하 이기 때문에 transfer을 사용했다.

        // transfer to owner
        owner.transfer(fee); // 배포자 즉 괸리 유저하는 사람에게 수수료를 보내준다.

        return amountWithoutFee; // 리턴 값은 사용자에게 보내진 금액을 리턴 해 준다.
    }

    // 테스트 모드 일때 블록 해쉬의 값을 지정하는 함수이다!1
    function setAnswerForTest(bytes32 answer) public returns (bool result) {
        require(msg.sender == owner, "Only owner can set the answer for test mode"); // 배포자만 이 함수를 실행 할 수 있다.
        answerForTest = answer; // getAnswerBlockHash 의 사용 하는 테스트의 값을 넣어준다.
        return true;
    }

    // 현재 테스트 모드인지 실제 모드인지를 구별해서 블럭해쉬 값을 반환하는 기능!
    function getAnswerBlockHash(uint256 answerBlockNumber) internal view returns (bytes32 answer) {
        return mode ? blockhash(answerBlockNumber) : answerForTest; // mode가 true일때 실제 블록의 해쉬값을 반환 false일시 배포자가 정의한 문자열을 반환
    }

    /**
     * @dev 베팅글자와 정답을 확인한다.
     * @param challenges 베팅 글자
     * @param answer 블락해쉬
     * @return 정답결과
     */
    function isMatch(byte challenges, bytes32 answer) public pure returns (BettingResult) {
        // challenges 0xab
        // answer 0xab......ff 32 bytes

        byte c1 = challenges; // 사용자가 입력한 challenges를 대입!
        byte c2 = challenges;

        byte a1 = answer[0];
        byte a2 = answer[0];

        // 시프트 연산자를 이용한 값 비교
        c1 = c1 >> 4; // 0xab -> 0x0a 
        c1 = c1 << 4; // 0x0a -> 0xa0

        a1 = a1 >> 4;
        a1 = a1 << 4;

        // Get Second number
        c2 = c2 << 4; // 0xab -> 0xb0
        c2 = c2 >> 4; // 0xb0 -> 0x0b

        a2 = a2 << 4;
        a2 = a2 >> 4;

        if(a1 == c1 && a2 == c2) { // 둘다 맞았을 경우 이다.
            return BettingResult.Win; // 1을 반환
        }

        if(a1 == c1 || a2 == c2) { // 하나만 맞았을 경우
            return BettingResult.Draw; // 2을 반환
        }

        return BettingResult.Fail; // 다 틀렸을 경우에는 0을 반환한다. 

    }

    function getBlockStatus(uint256 answerBlockNumber) internal view returns (BlockStatus) {
        // 현재 블록 번호가 배팅한 블록 번호보다 커야하고 현재 블록번호가 256+배팅한 블록번호보다 작을때 
        // 현재 확인완료 값을 반환한다!
        if(block.number > answerBlockNumber && block.number  <  BLOCK_LIMIT + answerBlockNumber) {
            return BlockStatus.Checkable;
        }
        // 현재 블록 번호가 배팅한 블록 번호보다 작거나 같을경우는 확인할 수 없음을 반환
        if(block.number <= answerBlockNumber) {
            return BlockStatus.NotRevealed;
        }
        // 최근 블록은 256개 까지만 확인 할 수 있기 때문에 
        //  현재 블록번호가 배팅한 블록 + 256 보다 크거나 같을 때 블록리밋을 벗어났습니다 를 반환
        if(block.number >= answerBlockNumber + BLOCK_LIMIT) {
            return BlockStatus.BlockLimitPassed;
        }

        return BlockStatus.BlockLimitPassed;
    }
    
    // 사용자의 배팅 정보를 반환하는 기능
    function getBetInfo(uint256 index) public view returns (uint256 answerBlockNumber, address bettor, byte challenges) {
        BetInfo memory b = _bets[index];
        answerBlockNumber = b.answerBlockNumber;
        bettor = b.bettor;
        challenges = b.challenges;
    }

    function pushBet(byte challenges) internal returns (bool) { // 배팅한 정보를 담는 공간
        BetInfo memory b; // 구조체 생성
        b.bettor = msg.sender; // 20 byte 구조체의 bettor에게 이더를 보낸 사용자의 주소 저장
        b.answerBlockNumber = block.number + BET_BLOCK_INTERVAL; // 32byte  20000 gas
        b.challenges = challenges; // byte // 20000 gas

        _bets[_tail] = b; // mapping에 있는 정보를 키 0 -> 위의 저장해둔 정보를 저장한다!!
        _tail++; // 32byte 값 변화 // 20000 gas -> 5000 gas 그 다음 tail 값 증가로 아무도 0 번지에 더 이상 저장할 수 없게 된다.

        return true;
    }

    function popBet(uint256 index) internal returns (bool) { // 지정한 Mapping의 값을 삭제하는 기능
        delete _bets[index];
        return true;
    }
}