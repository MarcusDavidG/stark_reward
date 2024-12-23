use starknet::ContractAddress;

#[starknet::interface]
trait IContentPlatform<TContractState> {
    // Creator Management
    fn register_creator(ref self: TContractState, profile_data: felt252);
    fn update_subscription_fee(ref self: TContractState, new_fee: u256);
    
    // Content Management
    fn post_content(
        ref self: TContractState, 
        content_hash: felt252,
        is_premium: bool,
        tip_enabled: bool
    ) -> u256;
    
    // Subscription & Engagement
    fn subscribe_to_creator(ref self: TContractState, creator: ContractAddress);
    fn tip_content(ref self: TContractState, content_id: u256, amount: u256);
    fn engage_with_content(ref self: TContractState, content_id: u256, engagement_type: felt252);
    
    // View Functions
    fn is_subscribed(self: @TContractState, user: ContractAddress, creator: ContractAddress) -> bool;
    fn get_creator_stats(self: @TContractState, creator: ContractAddress) -> CreatorStats;
    fn get_content_details(self: @TContractState, content_id: u256) -> Content;
    fn get_user_engagement_score(self: @TContractState, user: ContractAddress) -> u256;
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct CreatorStats {
    total_subscribers: u256,
    total_content: u256,
    total_tips_received: u256,
    subscription_fee: u256,
    engagement_score: u256
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Content {
    creator: ContractAddress,
    content_hash: felt252,
    timestamp: u64,
    is_premium: bool,
    tip_enabled: bool,
    total_tips: u256,
    total_engagements: u256
}

#[starknet::contract]
mod ContentPlatform {
    use super::{Content, CreatorStats, IContentPlatform};
    use starknet::{
        get_caller_address, get_block_timestamp, ContractAddress
    };
    
    #[storage]
    struct Storage {
        // Platform Configuration
        platform_token: ContractAddress,
        platform_fee_percentage: u256,
        
        // Creator Data
        creators: LegacyMap::<ContractAddress, CreatorStats>,
        creator_profiles: LegacyMap::<ContractAddress, felt252>,
        
        // Content Management
        contents: LegacyMap::<u256, Content>,
        content_counter: u256,
        
        // Subscription Management
        subscriptions: LegacyMap::<(ContractAddress, ContractAddress), (bool, u64)>, // (subscriber, creator) => (is_active, expiry)
        
        // Engagement Tracking
        user_engagement_scores: LegacyMap::<ContractAddress, u256>,
        content_engagements: LegacyMap::<(u256, ContractAddress), bool> // (content_id, user) => has_engaged
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CreatorRegistered: CreatorRegistered,
        ContentPosted: ContentPosted,
        NewSubscription: NewSubscription,
        ContentTipped: ContentTipped,
        ContentEngaged: ContentEngaged,
    }

    #[derive(Drop, starknet::Event)]
    struct CreatorRegistered {
        creator: ContractAddress,
        profile_data: felt252,
        timestamp: u64
    }

    #[derive(Drop, starknet::Event)]
    struct ContentPosted {
        content_id: u256,
        creator: ContractAddress,
        content_hash: felt252,
        is_premium: bool
    }

    #[derive(Drop, starknet::Event)]
    struct NewSubscription {
        subscriber: ContractAddress,
        creator: ContractAddress,
        expiry: u64
    }

    #[derive(Drop, starknet::Event)]
    struct ContentTipped {
        content_id: u256,
        tipper: ContractAddress,
        amount: u256
    }

    #[derive(Drop, starknet::Event)]
    struct ContentEngaged {
        content_id: u256,
        user: ContractAddress,
        engagement_type: felt252
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        platform_token: ContractAddress,
        platform_fee_percentage: u256
    ) {
        assert(platform_fee_percentage <= 1000, 'Fee too high'); // Max 10%
        self.platform_token.write(platform_token);
        self.platform_fee_percentage.write(platform_fee_percentage);
        self.content_counter.write(0);
    }

    #[abi(embed_v0)]
    impl ContentPlatformImpl of super::IContentPlatform<ContractState> {
        fn register_creator(ref self: ContractState, profile_data: felt252) {
            let creator = get_caller_address();
            assert(self.creator_profiles.read(creator) == 0, 'Already registered');

            // Initialize creator stats
            self.creators.write(
                creator,
                CreatorStats {
                    total_subscribers: 0,
                    total_content: 0,
                    total_tips_received: 0,
                    subscription_fee: 0,
                    engagement_score: 0
                }
            );

            self.creator_profiles.write(creator, profile_data);

            self.emit(
                CreatorRegistered {
                    creator,
                    profile_data,
                    timestamp: get_block_timestamp()
                }
            );
        }

        fn update_subscription_fee(ref self: ContractState, new_fee: u256) {
            let creator = get_caller_address();
            assert(self.creator_profiles.read(creator) != 0, 'Not a creator');

            let mut stats = self.creators.read(creator);
            stats.subscription_fee = new_fee;
            self.creators.write(creator, stats);
        }

        fn post_content(
            ref self: ContractState,
            content_hash: felt252,
            is_premium: bool,
            tip_enabled: bool
        ) -> u256 {
            let creator = get_caller_address();
            assert(self.creator_profiles.read(creator) != 0, 'Not a creator');

            let content_id = self.content_counter.read();
            
            // Create content
            self.contents.write(
                content_id,
                Content {
                    creator,
                    content_hash,
                    timestamp: get_block_timestamp(),
                    is_premium,
                    tip_enabled,
                    total_tips: 0,
                    total_engagements: 0
                }
            );

            // Update creator stats
            let mut stats = self.creators.read(creator);
            stats.total_content += 1;
            self.creators.write(creator, stats);

            // Increment counter
            self.content_counter.write(content_id + 1);

            self.emit(
                ContentPosted {
                    content_id,
                    creator,
                    content_hash,
                    is_premium
                }
            );

            content_id
        }

        fn subscribe_to_creator(ref self: ContractState, creator: ContractAddress) {
            let subscriber = get_caller_address();
            assert(self.creator_profiles.read(creator) != 0, 'Not a creator');
            
            let stats = self.creators.read(creator);
            assert(stats.subscription_fee > 0, 'Subscriptions not enabled');

            // Handle subscription payment
            // Note: In production, implement proper token transfer

            // Set subscription for 30 days
            let expiry = get_block_timestamp() + 2592000;
            self.subscriptions.write((subscriber, creator), (true, expiry));

            // Update creator stats
            let mut new_stats = stats;
            new_stats.total_subscribers += 1;
            self.creators.write(creator, new_stats);

            self.emit(
                NewSubscription {
                    subscriber,
                    creator,
                    expiry
                }
            );
        }

        fn tip_content(ref self: ContractState, content_id: u256, amount: u256) {
            let tipper = get_caller_address();
            let mut content = self.contents.read(content_id);
            
            assert(content.tip_enabled, 'Tipping not enabled');
            assert(amount > 0, 'Invalid tip amount');

            // Handle tip payment
            // Note: In production, implement proper token transfer

            // Update content stats
            content.total_tips += amount;
            self.contents.write(content_id, content);

            // Update creator stats
            let mut creator_stats = self.creators.read(content.creator);
            creator_stats.total_tips_received += amount;
            self.creators.write(content.creator, creator_stats);

            self.emit(
                ContentTipped {
                    content_id,
                    tipper,
                    amount
                }
            );
        }

        fn engage_with_content(
            ref self: ContractState,
            content_id: u256,
            engagement_type: felt252
        ) {
            let user = get_caller_address();
            let mut content = self.contents.read(content_id);
            
            // Check if user already engaged with this content
            assert(
                !self.content_engagements.read((content_id, user)),
                'Already engaged'
            );

            // If premium content, verify subscription
            if content.is_premium {
                let (is_subscribed, expiry) = self.subscriptions.read((user, content.creator));
                assert(is_subscribed && expiry > get_block_timestamp(), 'Not subscribed');
            }

            // Record engagement
            self.content_engagements.write((content_id, user), true);
            content.total_engagements += 1;
            self.contents.write(content_id, content);

            // Update user engagement score
            let current_score = self.user_engagement_scores.read(user);
            self.user_engagement_scores.write(user, current_score + 1);

            self.emit(
                ContentEngaged {
                    content_id,
                    user,
                    engagement_type
                }
            );
        }

        fn is_subscribed(
            self: @ContractState,
            user: ContractAddress,
            creator: ContractAddress
        ) -> bool {
            let (is_subscribed, expiry) = self.subscriptions.read((user, creator));
            is_subscribed && expiry > get_block_timestamp()
        }

        fn get_creator_stats(self: @ContractState, creator: ContractAddress) -> CreatorStats {
            self.creators.read(creator)
        }

        fn get_content_details(self: @ContractState, content_id: u256) -> Content {
            self.contents.read(content_id)
        }

        fn get_user_engagement_score(self: @ContractState, user: ContractAddress) -> u256 {
            self.user_engagement_scores.read(user)
        }
    }
}
