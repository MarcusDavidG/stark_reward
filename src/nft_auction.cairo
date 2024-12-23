use starknet::ContractAddress;

#[starknet::interface]
trait IERC721<TContractState> {
    fn transfer_from(ref self: TContractState, from: ContractAddress, to: ContractAddress, token_id: u256);
    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
}

#[starknet::interface]
trait INFTAuction<TContractState> {
    fn create_auction(
        ref self: TContractState,
        nft_contract: ContractAddress,
        token_id: u256,
        min_bid: u256,
        duration: u64,
        reserve_price: u256  // Added reserve price
    );
    fn place_bid(ref self: TContractState, auction_id: u256);
    fn end_auction(ref self: TContractState, auction_id: u256);
    fn cancel_auction(ref self: TContractState, auction_id: u256);  // Added cancel auction
    fn withdraw_bid(ref self: TContractState, auction_id: u256);    // Added bid withdrawal
    fn get_auction(self: @TContractState, auction_id: u256) -> Auction;
    fn get_highest_bid(self: @TContractState, auction_id: u256) -> u256;
    fn get_highest_bidder(self: @TContractState, auction_id: u256) -> ContractAddress;
    fn get_auction_status(self: @TContractState, auction_id: u256) -> AuctionStatus;  // Added status check
}

#[derive(Copy, Drop, Serde, starknet::Store)]
struct Auction {
    nft_contract: ContractAddress,
    token_id: u256,
    seller: ContractAddress,
    min_bid: u256,
    reserve_price: u256,  // Added reserve price
    highest_bid: u256,
    highest_bidder: ContractAddress,
    start_time: u64,     // Added start time
    end_time: u64,
    status: AuctionStatus,
}

#[derive(Copy, Drop, Serde, starknet::Store)]
enum AuctionStatus {
    Active,
    Ended,
    Cancelled,
    Reserved    // When highest bid is below reserve price
}

#[starknet::contract]
mod NFTAuction {
    use super::{Auction, AuctionStatus, IERC721Dispatcher, IERC721DispatcherTrait};
    use starknet::{
        get_caller_address, get_block_timestamp, ContractAddress, contract_address_const
    };
    use zeroable::Zeroable;

    #[storage]
    struct Storage {
        auctions: LegacyMap::<u256, Auction>,
        auction_counter: u256,
        pending_returns: LegacyMap::<(u256, ContractAddress), u256>,  // Track refundable bids
        platform_fee: u256,  // Platform fee percentage (e.g., 250 = 2.5%)
        platform_address: ContractAddress,  // Address to receive platform fees
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        AuctionCreated: AuctionCreated,
        BidPlaced: BidPlaced,
        AuctionEnded: AuctionEnded,
        AuctionCancelled: AuctionCancelled,
        BidWithdrawn: BidWithdrawn,
    }

    // Events with additional fields
    #[derive(Drop, starknet::Event)]
    struct AuctionCreated {
        auction_id: u256,
        seller: ContractAddress,
        nft_contract: ContractAddress,
        token_id: u256,
        min_bid: u256,
        reserve_price: u256,
        start_time: u64,
        end_time: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct BidPlaced {
        auction_id: u256,
        bidder: ContractAddress,
        amount: u256,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct AuctionEnded {
        auction_id: u256,
        winner: ContractAddress,
        amount: u256,
        platform_fee: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct AuctionCancelled {
        auction_id: u256,
        seller: ContractAddress,
        timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct BidWithdrawn {
        auction_id: u256,
        bidder: ContractAddress,
        amount: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        platform_address: ContractAddress,
        platform_fee: u256
    ) {
        self.auction_counter.write(0);
        self.platform_fee.write(platform_fee);
        self.platform_address.write(platform_address);
    }

    #[abi(embed_v0)]
    impl NFTAuctionImpl of super::INFTAuction<ContractState> {
        fn create_auction(
            ref self: ContractState,
            nft_contract: ContractAddress,
            token_id: u256,
            min_bid: u256,
            duration: u64,
            reserve_price: u256
        ) {
            assert(!nft_contract.is_zero(), 'Invalid NFT contract');
            assert(min_bid > 0, 'Min bid must be > 0');
            assert(duration >= 3600, 'Min duration 1 hour');  // Minimum 1 hour duration
            assert(reserve_price >= min_bid, 'Reserve below min bid');

            let caller = get_caller_address();
            let nft_contract_dispatcher = IERC721Dispatcher { contract_address: nft_contract };
            
            // Verify ownership
            assert(nft_contract_dispatcher.owner_of(token_id) == caller, 'Not token owner');

            // Transfer NFT to auction contract
            let this_contract = starknet::get_contract_address();
            nft_contract_dispatcher.transfer_from(caller, this_contract, token_id);

            let auction_id = self.auction_counter.read();
            let current_time = get_block_timestamp();
            
            // Create new auction
            self.auctions.write(
                auction_id,
                Auction {
                    nft_contract,
                    token_id,
                    seller: caller,
                    min_bid,
                    reserve_price,
                    highest_bid: 0,
                    highest_bidder: contract_address_const::<0>(),
                    start_time: current_time,
                    end_time: current_time + duration,
                    status: AuctionStatus::Active,
                }
            );

            // Emit event
            self.emit(
                AuctionCreated {
                    auction_id,
                    seller: caller,
                    nft_contract,
                    token_id,
                    min_bid,
                    reserve_price,
                    start_time: current_time,
                    end_time: current_time + duration,
                }
            );

            self.auction_counter.write(auction_id + 1);
        }

        fn place_bid(ref self: ContractState, auction_id: u256) {
            let mut auction = self.auctions.read(auction_id);
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            assert(auction.status == AuctionStatus::Active, 'Auction not active');
            assert(current_time >= auction.start_time, 'Auction not started');
            assert(current_time < auction.end_time, 'Auction expired');
            assert(caller != auction.seller, 'Seller cannot bid');
            
            let bid_amount = starknet::get_tx_info().unbox().value;
            assert(bid_amount > auction.highest_bid, 'Bid not high enough');
            assert(bid_amount >= auction.min_bid, 'Bid below min bid');

            // Store previous bid for withdrawal
            if (!auction.highest_bidder.is_zero()) {
                self.pending_returns.write(
                    (auction_id, auction.highest_bidder),
                    auction.highest_bid
                );
            }

            // Update auction
            auction.highest_bid = bid_amount;
            auction.highest_bidder = caller;
            self.auctions.write(auction_id, auction);

            // Emit event
            self.emit(
                BidPlaced {
                    auction_id,
                    bidder: caller,
                    amount: bid_amount,
                    timestamp: current_time
                }
            );
        }

        fn end_auction(ref self: ContractState, auction_id: u256) {
            let mut auction = self.auctions.read(auction_id);
            let current_time = get_block_timestamp();

            assert(auction.status == AuctionStatus::Active, 'Auction not active');
            assert(
                current_time >= auction.end_time || get_caller_address() == auction.seller,
                'Auction not ended'
            );

            let platform_fee = (auction.highest_bid * self.platform_fee.read()) / 10000;
            
            if (!auction.highest_bidder.is_zero() && auction.highest_bid >= auction.reserve_price) {
                auction.status = AuctionStatus::Ended;
                
                // Transfer NFT to winner
                let this_contract = starknet::get_contract_address();
                let nft_contract = IERC721Dispatcher { contract_address: auction.nft_contract };
                nft_contract.transfer_from(this_contract, auction.highest_bidder, auction.token_id);

                // Transfer bid amount minus platform fee to seller
                // Note: In production, implement proper payment transfer
                
                // Emit event
                self.emit(
                    AuctionEnded {
                        auction_id,
                        winner: auction.highest_bidder,
                        amount: auction.highest_bid,
                        platform_fee,
                    }
                );
            } else {
                auction.status = AuctionStatus::Reserved;
                // Return NFT to seller if reserve not met
                let this_contract = starknet::get_contract_address();
                let nft_contract = IERC721Dispatcher { contract_address: auction.nft_contract };
                nft_contract.transfer_from(this_contract, auction.seller, auction.token_id);
            }

            self.auctions.write(auction_id, auction);
        }

        fn cancel_auction(ref self: ContractState, auction_id: u256) {
            let mut auction = self.auctions.read(auction_id);
            let caller = get_caller_address();
            
            assert(auction.status == AuctionStatus::Active, 'Auction not active');
            assert(caller == auction.seller, 'Only seller can cancel');
            assert(auction.highest_bidder.is_zero(), 'Bids already placed');

            auction.status = AuctionStatus::Cancelled;
            self.auctions.write(auction_id, auction);

            // Return NFT to seller
            let this_contract = starknet::get_contract_address();
            let nft_contract = IERC721Dispatcher { contract_address: auction.nft_contract };
            nft_contract.transfer_from(this_contract, auction.seller, auction.token_id);

            self.emit(
                AuctionCancelled {
                    auction_id,
                    seller: caller,
                    timestamp: get_block_timestamp(),
                }
            );
        }

        fn withdraw_bid(ref self: ContractState, auction_id: u256) {
            let caller = get_caller_address();
            let amount = self.pending_returns.read((auction_id, caller));
            
            assert(amount > 0, 'No funds to withdraw');
            
            // Reset the pending return before sending to prevent re-entrancy
            self.pending_returns.write((auction_id, caller), 0);
            
            // Transfer the funds
            // Note: In production, implement proper payment transfer

            self.emit(BidWithdrawn { auction_id, bidder: caller, amount });
        }

        fn get_auction(self: @ContractState, auction_id: u256) -> Auction {
            self.auctions.read(auction_id)
        }

        fn get_highest_bid(self: @ContractState, auction_id: u256) -> u256 {
            self.auctions.read(auction_id).highest_bid
        }

        fn get_highest_bidder(self: @ContractState, auction_id: u256) -> ContractAddress {
            self.auctions.read(auction_id).highest_bidder
        }

        fn get_auction_status(self: @ContractState, auction_id: u256) -> AuctionStatus {
            self.auctions.read(auction_id).status
        }
    }
}
