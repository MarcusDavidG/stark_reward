use starknet::ContractAddress;
use starknet::testing::{set_caller_address, set_contract_address, set_block_timestamp};
use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank};
use stark_reward::nft_auction::{
    INFTAuctionDispatcher, INFTAuctionDispatcherTrait, IERC721Dispatcher, IERC721DispatcherTrait,
    Auction, AuctionStatus
};

// Mock ERC721 contract for testing
#[starknet::contract]
mod MockERC721 {
    use starknet::ContractAddress;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        owners: LegacyMap::<u256, ContractAddress>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, token_id: u256) {
        self.owners.write(token_id, owner);
    }

    #[abi(embed_v0)]
    impl IERC721 of super::IERC721<ContractState> {
        fn transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256
        ) {
            self.owners.write(token_id, to);
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }
    }
}

#[test]
fn test_create_auction() {
    // Deploy mock NFT contract
    let seller = starknet::contract_address_const::<1>();
    let token_id = 1_u256;
    let mock_nft = declare('MockERC721').deploy(@array![seller.into(), token_id.into()]).unwrap();

    // Deploy auction contract
    let platform = starknet::contract_address_const::<2>();
    let platform_fee = 250_u256; // 2.5%
    let auction_contract = declare('NFTAuction').deploy(@array![platform.into(), platform_fee.into()]).unwrap();
    let auction_dispatcher = INFTAuctionDispatcher { contract_address: auction_contract };

    // Set caller as seller
    start_prank(mock_nft, seller);

    // Create auction parameters
    let min_bid = 1000000000000000000_u256; // 1 ETH
    let duration = 3600_u64; // 1 hour
    let reserve_price = 2000000000000000000_u256; // 2 ETH
    let current_time = 1000000_u64;

    // Set block timestamp
    set_block_timestamp(current_time);

    // Create auction
    auction_dispatcher.create_auction(mock_nft, token_id, min_bid, duration, reserve_price);

    // Get auction details
    let auction = auction_dispatcher.get_auction(0);

    // Assert auction details
    assert(auction.nft_contract == mock_nft, 'Wrong NFT contract');
    assert(auction.token_id == token_id, 'Wrong token ID');
    assert(auction.seller == seller, 'Wrong seller');
    assert(auction.min_bid == min_bid, 'Wrong min bid');
    assert(auction.reserve_price == reserve_price, 'Wrong reserve price');
    assert(auction.highest_bid == 0, 'Wrong initial bid');
    assert(auction.start_time == current_time, 'Wrong start time');
    assert(auction.end_time == current_time + duration, 'Wrong end time');
    assert(auction.status == AuctionStatus::Active, 'Wrong status');

    stop_prank(mock_nft);
}

#[test]
fn test_place_bid() {
    // Deploy contracts and create auction (similar setup as above)
    let seller = starknet::contract_address_const::<1>();
    let token_id = 1_u256;
    let mock_nft = declare('MockERC721').deploy(@array![seller.into(), token_id.into()]).unwrap();

    let platform = starknet::contract_address_const::<2>();
    let platform_fee = 250_u256;
    let auction_contract = declare('NFTAuction').deploy(@array![platform.into(), platform_fee.into()]).unwrap();
    let auction_dispatcher = INFTAuctionDispatcher { contract_address: auction_contract };

    // Create auction
    start_prank(mock_nft, seller);
    let min_bid = 1000000000000000000_u256;
    let duration = 3600_u64;
    let reserve_price = 2000000000000000000_u256;
    let current_time = 1000000_u64;
    set_block_timestamp(current_time);
    
    auction_dispatcher.create_auction(mock_nft, token_id, min_bid, duration, reserve_price);
    stop_prank(mock_nft);

    // Place bid
    let bidder = starknet::contract_address_const::<3>();
    start_prank(auction_contract, bidder);
    
    // TODO: In actual implementation, we need to mock the transaction value
    auction_dispatcher.place_bid(0);

    // Get updated auction
    let auction = auction_dispatcher.get_auction(0);
    
    // Assert bid details
    assert(auction.highest_bidder == bidder, 'Wrong highest bidder');
    assert(auction.highest_bid > min_bid, 'Bid not recorded');
    assert(auction.status == AuctionStatus::Active, 'Wrong status');

    stop_prank(auction_contract);
}

#[test]
fn test_end_auction() {
    // Deploy contracts and create auction with bid (similar setup as above)
    let seller = starknet::contract_address_const::<1>();
    let token_id = 1_u256;
    let mock_nft = declare('MockERC721').deploy(@array![seller.into(), token_id.into()]).unwrap();

    let platform = starknet::contract_address_const::<2>();
    let platform_fee = 250_u256;
    let auction_contract = declare('NFTAuction').deploy(@array![platform.into(), platform_fee.into()]).unwrap();
    let auction_dispatcher = INFTAuctionDispatcher { contract_address: auction_contract };

    // Create and setup auction
    start_prank(mock_nft, seller);
    let min_bid = 1000000000000000000_u256;
    let duration = 3600_u64;
    let reserve_price = 2000000000000000000_u256;
    let start_time = 1000000_u64;
    set_block_timestamp(start_time);
    
    auction_dispatcher.create_auction(mock_nft, token_id, min_bid, duration, reserve_price);
    stop_prank(mock_nft);

    // Place winning bid
    let bidder = starknet::contract_address_const::<3>();
    start_prank(auction_contract, bidder);
    auction_dispatcher.place_bid(0);
    stop_prank(auction_contract);

    // End auction
    set_block_timestamp(start_time + duration + 1); // After auction end time
    auction_dispatcher.end_auction(0);

    // Get final auction state
    let auction = auction_dispatcher.get_auction(0);
    
    // Assert auction ended correctly
    assert(auction.status == AuctionStatus::Ended, 'Wrong status');
    assert(auction.highest_bidder == bidder, 'Wrong winner');

    // Verify NFT ownership
    let nft_contract = IERC721Dispatcher { contract_address: mock_nft };
    assert(nft_contract.owner_of(token_id) == bidder, 'NFT not transferred');
}

#[test]
#[should_panic(expected: ('Auction not active', ))]
fn test_cannot_bid_on_ended_auction() {
    // Similar setup as above
    let seller = starknet::contract_address_const::<1>();
    let token_id = 1_u256;
    let mock_nft = declare('MockERC721').deploy(@array![seller.into(), token_id.into()]).unwrap();

    let platform = starknet::contract_address_const::<2>();
    let platform_fee = 250_u256;
    let auction_contract = declare('NFTAuction').deploy(@array![platform.into(), platform_fee.into()]).unwrap();
    let auction_dispatcher = INFTAuctionDispatcher { contract_address: auction_contract };

    // Create and end auction
    start_prank(mock_nft, seller);
    let min_bid = 1000000000000000000_u256;
    let duration = 3600_u64;
    let reserve_price = 2000000000000000000_u256;
    let start_time = 1000000_u64;
    set_block_timestamp(start_time);
    
    auction_dispatcher.create_auction(mock_nft, token_id, min_bid, duration, reserve_price);
    stop_prank(mock_nft);

    // End auction
    set_block_timestamp(start_time + duration + 1);
    auction_dispatcher.end_auction(0);

    // Try to place bid (should fail)
    let bidder = starknet::contract_address_const::<3>();
    start_prank(auction_contract, bidder);
    auction_dispatcher.place_bid(0);
    stop_prank(auction_contract);
}
