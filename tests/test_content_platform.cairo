use starknet::ContractAddress;
use starknet::testing::{set_caller_address, set_block_timestamp};
use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank};
use stark_reward::content_platform::{
    IContentPlatformDispatcher, IContentPlatformDispatcherTrait, Content, CreatorStats
};

// Mock ERC20 token for platform currency
#[starknet::contract]
mod MockERC20 {
    use starknet::ContractAddress;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, initial_supply: u256, owner: ContractAddress) {
        self.balances.write(owner, initial_supply);
    }

    #[external(v0)]
    fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
        let caller = get_caller_address();
        let caller_balance = self.balances.read(caller);
        assert(caller_balance >= amount, 'Insufficient balance');
        
        self.balances.write(caller, caller_balance - amount);
        self.balances.write(recipient, self.balances.read(recipient) + amount);
        
        true
    }

    #[external(v0)]
    fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
        let caller = get_caller_address();
        self.allowances.write((caller, spender), amount);
        true
    }
}

#[test]
fn test_creator_registration() {
    // Deploy mock token
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256; // 1000 tokens
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();

    // Deploy content platform
    let platform_fee = 250_u256; // 2.5%
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    // Register as creator
    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    
    let profile_data = 'Creator Profile';
    platform.register_creator(profile_data);

    // Verify creator stats
    let stats = platform.get_creator_stats(creator);
    assert(stats.total_subscribers == 0, 'Wrong subscriber count');
    assert(stats.total_content == 0, 'Wrong content count');
    assert(stats.total_tips_received == 0, 'Wrong tips count');
    assert(stats.subscription_fee == 0, 'Wrong subscription fee');
    assert(stats.engagement_score == 0, 'Wrong engagement score');

    stop_prank(content_platform);
}

#[test]
fn test_content_posting() {
    // Similar setup as above
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256;
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();
    
    let platform_fee = 250_u256;
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    // Register and post content
    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    
    platform.register_creator('Creator Profile');
    
    let content_hash = 'Content Hash';
    let is_premium = true;
    let tip_enabled = true;
    
    let content_id = platform.post_content(content_hash, is_premium, tip_enabled);

    // Verify content details
    let content = platform.get_content_details(content_id);
    assert(content.creator == creator, 'Wrong creator');
    assert(content.content_hash == content_hash, 'Wrong content hash');
    assert(content.is_premium == is_premium, 'Wrong premium status');
    assert(content.tip_enabled == tip_enabled, 'Wrong tip status');
    assert(content.total_tips == 0, 'Wrong tips count');
    assert(content.total_engagements == 0, 'Wrong engagements count');

    // Verify creator stats updated
    let stats = platform.get_creator_stats(creator);
    assert(stats.total_content == 1, 'Content count not updated');

    stop_prank(content_platform);
}

#[test]
fn test_subscription() {
    // Similar setup as above
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256;
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();
    
    let platform_fee = 250_u256;
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    // Setup creator
    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    platform.register_creator('Creator Profile');
    
    let subscription_fee = 100000000000000000_u256; // 0.1 tokens
    platform.update_subscription_fee(subscription_fee);
    stop_prank(content_platform);

    // Subscribe to creator
    let subscriber = starknet::contract_address_const::<3>();
    start_prank(content_platform, subscriber);
    platform.subscribe_to_creator(creator);

    // Verify subscription
    assert(platform.is_subscribed(subscriber, creator), 'Not subscribed');

    // Verify creator stats
    let stats = platform.get_creator_stats(creator);
    assert(stats.total_subscribers == 1, 'Subscriber count not updated');

    stop_prank(content_platform);
}

#[test]
fn test_content_engagement() {
    // Similar setup as above
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256;
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();
    
    let platform_fee = 250_u256;
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    // Setup creator and content
    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    platform.register_creator('Creator Profile');
    
    let content_id = platform.post_content('Content Hash', false, true);
    stop_prank(content_platform);

    // Engage with content
    let user = starknet::contract_address_const::<3>();
    start_prank(content_platform, user);
    platform.engage_with_content(content_id, 'LIKE');

    // Verify engagement
    let content = platform.get_content_details(content_id);
    assert(content.total_engagements == 1, 'Engagement not counted');

    // Verify user engagement score
    let score = platform.get_user_engagement_score(user);
    assert(score == 1, 'Wrong engagement score');

    stop_prank(content_platform);
}

#[test]
fn test_content_tipping() {
    // Similar setup as above
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256;
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();
    
    let platform_fee = 250_u256;
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    // Setup creator and content
    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    platform.register_creator('Creator Profile');
    
    let content_id = platform.post_content('Content Hash', false, true);
    stop_prank(content_platform);

    // Tip content
    let tipper = starknet::contract_address_const::<3>();
    start_prank(content_platform, tipper);
    let tip_amount = 100000000000000000_u256; // 0.1 tokens
    platform.tip_content(content_id, tip_amount);

    // Verify tip recorded
    let content = platform.get_content_details(content_id);
    assert(content.total_tips == tip_amount, 'Tips not recorded');

    // Verify creator stats
    let stats = platform.get_creator_stats(creator);
    assert(stats.total_tips_received == tip_amount, 'Creator tips not updated');

    stop_prank(content_platform);
}

#[test]
#[should_panic(expected: ('Already registered', ))]
fn test_cannot_register_twice() {
    let platform_owner = starknet::contract_address_const::<1>();
    let initial_supply = 1000000000000000000000_u256;
    let mock_token = declare('MockERC20').deploy(@array![initial_supply.into(), platform_owner.into()]).unwrap();
    
    let platform_fee = 250_u256;
    let content_platform = declare('ContentPlatform').deploy(@array![mock_token.into(), platform_fee.into()]).unwrap();
    let platform = IContentPlatformDispatcher { contract_address: content_platform };

    let creator = starknet::contract_address_const::<2>();
    start_prank(content_platform, creator);
    
    platform.register_creator('First Profile');
    platform.register_creator('Second Profile'); // Should fail

    stop_prank(content_platform);
}
