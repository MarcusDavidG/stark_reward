use starknet::ContractAddress;
use starknet::testing::{set_caller_address, set_contract_address};
use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank};
use stark_reward::staking::{IStakingDispatcher, IStakingDispatcherTrait};

// Mock ERC20 contract for testing
#[starknet::contract]
mod MockERC20 {
    use starknet::ContractAddress;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
        total_supply: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_supply: u256, owner: ContractAddress) {
        self.total_supply.write(initial_supply);
        self.balances.write(owner, initial_supply);
    }

    #[abi(embed_v0)]
    impl IERC20 of super::IERC20<ContractState> {
        fn transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            amount: u256
        ) -> bool {
            let caller = get_caller_address();
            let allowed = self.allowances.read((from, caller));
            assert(allowed >= amount, 'Insufficient allowance');
            
            let from_balance = self.balances.read(from);
            assert(from_balance >= amount, 'Insufficient balance');
            
            self.allowances.write((from, caller), allowed - amount);
            self.balances.write(from, from_balance - amount);
            self.balances.write(to, self.balances.read(to) + amount);
            
            true
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            let caller = get_caller_address();
            let caller_balance = self.balances.read(caller);
            assert(caller_balance >= amount, 'Insufficient balance');
            
            self.balances.write(caller, caller_balance - amount);
            self.balances.write(recipient, self.balances.read(recipient) + amount);
            
            true
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            self.balances.read(account)
        }
    }

    #[generate_trait]
    impl MockImpl of MockTrait {
        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) {
            let caller = get_caller_address();
            self.allowances.write((caller, spender), amount);
        }

        fn mint(ref self: ContractState, to: ContractAddress, amount: u256) {
            let new_balance = self.balances.read(to) + amount;
            self.balances.write(to, new_balance);
            self.total_supply.write(self.total_supply.read() + amount);
        }
    }
}

#[test]
fn test_stake() {
    // Deploy mock token
    let initial_supply = 1000000000000000000000_u256; // 1000 tokens
    let user = starknet::contract_address_const::<1>();
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), user.into()]).unwrap();

    // Deploy staking contract
    let staking_contract = declare('Staking').deploy(@array![mock_token.into()]).unwrap();
    let staking = IStakingDispatcher { contract_address: staking_contract };

    // Setup: Approve staking contract to spend tokens
    start_prank(mock_token, user);
    let mock = MockERC20::MockImpl::approve(mock_token, staking_contract, initial_supply);

    // Stake tokens
    let stake_amount = 100000000000000000000_u256; // 100 tokens
    staking.stake(stake_amount);

    // Verify staked balance
    let staked_balance = staking.get_staked_balance(user);
    assert(staked_balance == stake_amount, 'Wrong staked balance');

    // Verify total staked
    let total_staked = staking.get_total_staked();
    assert(total_staked == stake_amount, 'Wrong total staked');

    stop_prank(mock_token);
}

#[test]
fn test_withdraw() {
    // Deploy contracts
    let initial_supply = 1000000000000000000000_u256;
    let user = starknet::contract_address_const::<1>();
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), user.into()]).unwrap();
    let staking_contract = declare('Staking').deploy(@array![mock_token.into()]).unwrap();
    let staking = IStakingDispatcher { contract_address: staking_contract };

    // Setup: Approve and stake tokens
    start_prank(mock_token, user);
    let mock = MockERC20::MockImpl::approve(mock_token, staking_contract, initial_supply);
    
    let stake_amount = 100000000000000000000_u256;
    staking.stake(stake_amount);

    // Withdraw half of staked tokens
    let withdraw_amount = 50000000000000000000_u256;
    staking.withdraw(withdraw_amount);

    // Verify remaining staked balance
    let staked_balance = staking.get_staked_balance(user);
    assert(staked_balance == withdraw_amount, 'Wrong remaining balance');

    // Verify total staked
    let total_staked = staking.get_total_staked();
    assert(total_staked == withdraw_amount, 'Wrong total staked');

    stop_prank(mock_token);
}

#[test]
#[should_panic(expected: ('Insufficient balance', ))]
fn test_withdraw_more_than_staked() {
    // Deploy contracts
    let initial_supply = 1000000000000000000000_u256;
    let user = starknet::contract_address_const::<1>();
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), user.into()]).unwrap();
    let staking_contract = declare('Staking').deploy(@array![mock_token.into()]).unwrap();
    let staking = IStakingDispatcher { contract_address: staking_contract };

    // Setup: Approve and stake tokens
    start_prank(mock_token, user);
    let mock = MockERC20::MockImpl::approve(mock_token, staking_contract, initial_supply);
    
    let stake_amount = 100000000000000000000_u256;
    staking.stake(stake_amount);

    // Try to withdraw more than staked (should fail)
    let withdraw_amount = 200000000000000000000_u256;
    staking.withdraw(withdraw_amount);

    stop_prank(mock_token);
}

#[test]
#[should_panic(expected: ('Cannot stake 0', ))]
fn test_cannot_stake_zero() {
    // Deploy contracts
    let initial_supply = 1000000000000000000000_u256;
    let user = starknet::contract_address_const::<1>();
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), user.into()]).unwrap();
    let staking_contract = declare('Staking').deploy(@array![mock_token.into()]).unwrap();
    let staking = IStakingDispatcher { contract_address: staking_contract };

    // Try to stake 0 tokens (should fail)
    start_prank(mock_token, user);
    staking.stake(0);
    stop_prank(mock_token);
}

#[test]
fn test_multiple_users_staking() {
    // Deploy contracts
    let initial_supply = 1000000000000000000000_u256;
    let user1 = starknet::contract_address_const::<1>();
    let user2 = starknet::contract_address_const::<2>();
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), user1.into()]).unwrap();
    let staking_contract = declare('Staking').deploy(@array![mock_token.into()]).unwrap();
    let staking = IStakingDispatcher { contract_address: staking_contract };

    // Mint tokens for user2
    start_prank(mock_token, user1);
    let mock = MockERC20::MockImpl::mint(mock_token, user2, initial_supply);
    stop_prank(mock_token);

    // User1 stakes tokens
    start_prank(mock_token, user1);
    let mock = MockERC20::MockImpl::approve(mock_token, staking_contract, initial_supply);
    let stake_amount1 = 100000000000000000000_u256;
    staking.stake(stake_amount1);
    stop_prank(mock_token);

    // User2 stakes tokens
    start_prank(mock_token, user2);
    let mock = MockERC20::MockImpl::approve(mock_token, staking_contract, initial_supply);
    let stake_amount2 = 150000000000000000000_u256;
    staking.stake(stake_amount2);
    stop_prank(mock_token);

    // Verify individual balances
    assert(staking.get_staked_balance(user1) == stake_amount1, 'Wrong user1 balance');
    assert(staking.get_staked_balance(user2) == stake_amount2, 'Wrong user2 balance');

    // Verify total staked
    assert(staking.get_total_staked() == stake_amount1 + stake_amount2, 'Wrong total staked');
}
