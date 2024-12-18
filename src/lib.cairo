use starknet::ContractAddress;

/// Interface representing `HelloContract`.
/// This interface allows modification and retrieval of the contract balance.
#[starknet::interface]
pub trait IHelloStarknet<TContractState> {
    /// Increase contract balance.
    fn increase_point(ref self: TContractState, user: ContractAddress, amount: u256);
    /// Retrieve contract balance.
    fn get_balance(self: @TContractState, user: ContractAddress) -> u256;
    fn redeem_points(ref self: TContractState, amount: u256);
}
                
/// Simple contract for managing balance.
#[starknet::contract]
mod HelloStarknet {
    use starknet::{get_caller_address, ContractAddress};
    use core::starknet::storage::{Map, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        points: Map<ContractAddress, u256>,
    }

    #[abi(embed_v0)]
    impl HelloStarknetImpl of super::IHelloStarknet<ContractState> {
        fn increase_point(ref self: ContractState, user: ContractAddress, amount: u256) {
            assert(amount != 0, 'Amount cannot be 0');
            // get his balance, add 
            self.points.entry(user).write(self.points.entry(user).read() + amount);
        }

        fn get_balance(self: @ContractState, user: ContractAddress) -> u256 {
            self.points.entry(user).read()
        }

        fn redeem_points(ref self: ContractState, amount: u256) {
            assert(amount != 0, 'Amount cannot be 0');
            let caller = get_caller_address();
            let user_balance = self.points.entry(caller).read();
            
            assert(user_balance >= amount, 'Insufficient funds');
            self.points.entry(caller).write(user_balance - amount);
        }
    }
}
