module CAFE::olddanft_example {
    use std::signer;
    use std::string::{String, utf8};
    use supra_framework::object::{Self, Object};
    use supra_framework::object::{ConstructorRef, ExtendRef};
    use aptos_token_objects::aptos_token::{Self, AptosToken};
    use aptos_token_objects::collection;
    use std::option;
    use std::vector;
    use std::error;
    use std::timestamp;
    use supra_framework::event::emit;
    use aptos_std::smart_table::{Self, SmartTable};

    /// Error codes
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_TOKEN_NOT_FOUND: u64 = 2;
    const E_COLLECTION_NOT_FOUND: u64 = 3;
    const E_INSUFFICIENT_SHARES: u64 = 4;
    const E_INVALID_PERCENTAGE: u64 = 5;
    const E_ALREADY_SHARED: u64 = 6;
    const E_NOT_OWNER: u64 = 7;
    const E_INVALID_SHARE_COUNT: u64 = 8;

    /// Struct to manage fractional ownership of a token
    struct FractionalToken has key {
        /// The original token object
        token: Object<AptosToken>,
        /// Total shares (always 10000 for percentage precision)
        total_shares: u64,
        /// Mapping of owner address to their share amount
        shares: SmartTable<address, u64>,
        /// List of all shareholders
        shareholders: vector<address>,
        /// Original owner who fractionalized the token
        original_owner: address,
        /// Extension reference for future upgrades
        extend_ref: ExtendRef,
        /// Creation timestamp
        created_at: u64
    }

    /// Individual share ownership record
    struct ShareOwnership has key, store {
        /// The fractionalized token object
        fractional_token: Object<FractionalToken>,
        /// Owner's share percentage (out of 10000)
        share_percentage: u64,
        /// When this share was acquired
        acquired_at: u64
    }

    /// Events
    #[event]
    struct TokenFractionalizedEvent has drop, store {
        token: Object<AptosToken>,
        fractional_token: Object<FractionalToken>,
        original_owner: address,
        total_shareholders: u64,
        timestamp: u64
    }

    #[event]
    struct SharesDistributedEvent has drop, store {
        fractional_token: Object<FractionalToken>,
        recipient: address,
        share_percentage: u64,
        timestamp: u64
    }

    #[event]
    struct ShareTransferredEvent has drop, store {
        fractional_token: Object<FractionalToken>,
        from: address,
        to: address,
        share_percentage: u64,
        timestamp: u64
    }

    /// Struct to hold collection configuration
    struct CollectionConfig has key {
        name: String,
        description: String,
        uri: String,
        max_supply: u64
    }

    /// Initialize a new NFT collection
    public entry fun initialize_collection(
        creator: &signer,
        name: String,
        description: String,
        uri: String,
        max_supply: u64,
        royalty_numerator: u64,
        royalty_denominator: u64
    ) {
        let collection_builder =
            collection::create_fixed_collection(
                creator,
                description,
                max_supply,
                name,
                option::none(),
                uri
            );

        // Store collection config
        move_to(
            creator,
            CollectionConfig { name, description, uri, max_supply }
        );
    }

    /// Mint a new NFT
    public entry fun mint_nft(
        creator: &signer,
        collection_name: String,
        token_name: String,
        description: String,
        uri: String
    ) {
        let creator_addr = signer::address_of(creator);
        assert!(exists<CollectionConfig>(creator_addr), E_COLLECTION_NOT_FOUND);

        aptos_token::mint(
            creator,
            collection_name,
            description,
            token_name,
            uri,
            vector::empty(),
            vector::empty(),
            vector::empty()
        );
    }

    /// Transfer an NFT to another address
    public entry fun transfer_nft(
        owner: &signer, token: Object<aptos_token::AptosToken>, to: address
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(token, owner_addr), E_NOT_AUTHORIZED);

        object::transfer(owner, token, to);
    }

    /// Burn an NFT
    public entry fun burn_nft(
        owner: &signer, token: Object<aptos_token::AptosToken>
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(token, owner_addr), E_NOT_AUTHORIZED);

        aptos_token::burn(owner, token);
    }

    public entry fun freeze_token_transfer(
        owner: &signer, token: Object<aptos_token::AptosToken>
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(token, owner_addr), E_NOT_AUTHORIZED);

        aptos_token::freeze_transfer(owner, token);
    }

    public entry fun unfreeze_token_transfer(
        owner: &signer, token: Object<aptos_token::AptosToken>
    ) {
        let owner_addr = signer::address_of(owner);
        assert!(object::is_owner(token, owner_addr), E_NOT_AUTHORIZED);

        aptos_token::unfreeze_transfer(owner, token);
    }

    /// Helper function to get collection object
    public fun get_collection_object(
        creator: address, collection_name: String
    ): Object<collection::Collection> {
        let collection_addr =
            collection::create_collection_address(&creator, &collection_name);
        object::address_to_object<collection::Collection>(collection_addr)
    }

    // /// Helper function to get token object
    // public fun get_token_object(
    //     creator: address, collection_name: String, token_name: String
    // ): Object<aptos_token::AptosToken> {
    //     let token_addr =
    //         aptos_token::create_token_address(&creator, &collection_name, &token_name);
    //     object::address_to_object<aptos_token::AptosToken>(token_addr)
    // }

    #[view]
    /// Check if a collection exists
    public fun collection_exists(
        creator: address, collection_name: String
    ): bool {
        let collection_addr =
            collection::create_collection_address(&creator, &collection_name);
        object::object_exists<collection::Collection>(collection_addr)
    }

    // #[view]
    // /// Check if a token exists
    // public fun token_exists(
    //     creator: address, collection_name: String, token_name: String
    // ): bool {
    //     let token_addr =
    //         aptos_token::create_token_address(&creator, &collection_name, &token_name);
    //     object::object_exists<aptos_token::AptosToken>(token_addr)
    // }

    /// Partial sharing of tokens
    ///  //// SHARING OF TOKENS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /// Fractionalize a token into shares
    public entry fun fractionalize_token(
        owner: &signer,
        token: Object<AptosToken>,
        recipients: vector<address>,
        share_percentages: vector<u64>
    ) {
        let owner_addr = signer::address_of(owner);

        // Verify ownership
        assert!(
            object::is_owner(token, owner_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        // Validate inputs
        let recipient_count = vector::length(&recipients);
        let percentage_count = vector::length(&share_percentages);
        assert!(
            recipient_count == percentage_count,
            error::invalid_argument(E_INVALID_SHARE_COUNT)
        );
        assert!(recipient_count > 0, error::invalid_argument(E_INVALID_SHARE_COUNT));

        // Sum must be 10000
        let total_percentage = 0u64;
        let i = 0;
        while (i < percentage_count) {
            total_percentage = total_percentage
                + *vector::borrow(&share_percentages, i);
            i = i + 1;
        };
        assert!(total_percentage == 10000, error::invalid_argument(E_INVALID_PERCENTAGE));

        // Prepare data
        let shares = smart_table::new<address, u64>();
        let shareholders = vector::empty<address>();

        let j = 0;
        while (j < recipient_count) {
            let recipient = *vector::borrow(&recipients, j);
            let percentage = *vector::borrow(&share_percentages, j);

            smart_table::add(&mut shares, recipient, percentage);
            vector::push_back(&mut shareholders, recipient);
            j = j + 1;
        };

        // Now safe to create FractionalToken object
        let constructor_ref = object::create_object(owner_addr);
        let object_signer = object::generate_signer(&constructor_ref);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        let fractional_token = FractionalToken {
            token,
            total_shares: 10000,
            shares, // safe: built fully before use
            shareholders,
            original_owner: owner_addr,
            extend_ref,
            created_at: timestamp::now_seconds()
        };

        move_to(&object_signer, fractional_token);

        let fractional_token_obj =
            object::object_from_constructor_ref<FractionalToken>(&constructor_ref);

        // Distribute share ownership + emit events
        let k = 0;
        while (k < recipient_count) {
            let recipient = *vector::borrow(&recipients, k);
            let percentage = *vector::borrow(&share_percentages, k);

            let share_ownership = ShareOwnership {
                fractional_token: fractional_token_obj,
                share_percentage: percentage,
                acquired_at: timestamp::now_seconds()
            };
            let constructor_ref_recipient = object::create_object(recipient);
            let object_signer_recipient =
                object::generate_signer(&constructor_ref_recipient);
            move_to(&object_signer_recipient, share_ownership);

            emit(
                SharesDistributedEvent {
                    fractional_token: fractional_token_obj,
                    recipient,
                    share_percentage: percentage,
                    timestamp: timestamp::now_seconds()
                }
            );

            k = k + 1;
        };

        emit(
            TokenFractionalizedEvent {
                token,
                fractional_token: fractional_token_obj,
                original_owner: owner_addr,
                total_shareholders: recipient_count,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Transfer shares from one owner to another
    public entry fun transfer_shares(
        from: &signer,
        fractional_token: Object<FractionalToken>,
        recipient: address,
        share_amount: u64
    ) acquires FractionalToken {
        let from_addr = signer::address_of(from);

        // Get current shares of sender
        let fractional_token_data =
            borrow_global_mut<FractionalToken>(object::object_address(&fractional_token));

        assert!(
            smart_table::contains(&fractional_token_data.shares, from_addr),
            error::not_found(E_TOKEN_NOT_FOUND)
        );

        let current_shares =
            *smart_table::borrow(&fractional_token_data.shares, from_addr);
        assert!(
            current_shares >= share_amount,
            error::invalid_argument(E_INSUFFICIENT_SHARES)
        );

        // Update sender's shares
        if (current_shares == share_amount) {
            // Transfer all shares - remove from table and shareholders list
            smart_table::remove(&mut fractional_token_data.shares, from_addr);
            let (found, index) = vector::index_of(
                &fractional_token_data.shareholders, &from_addr
            );
            if (found) {
                vector::remove(&mut fractional_token_data.shareholders, index);
            };
        } else {
            // Partial transfer - update share amount
            *smart_table::borrow_mut(&mut fractional_token_data.shares, from_addr) =
                current_shares - share_amount;
        };

        // Update recipient's shares
        if (smart_table::contains(&fractional_token_data.shares, recipient)) {
            // Recipient already has shares - add to existing
            let existing_shares =
                smart_table::borrow_mut(&mut fractional_token_data.shares, recipient);
            *existing_shares = *existing_shares + share_amount;
        } else {
            // New shareholder
            smart_table::add(&mut fractional_token_data.shares, recipient, share_amount);
            vector::push_back(&mut fractional_token_data.shareholders, recipient);
            let percentage = share_amount / fractional_token_data.total_shares * 10000;
            // Create share ownership record for recipient
            let share_ownership = ShareOwnership {
                fractional_token,
                share_percentage: percentage,
                acquired_at: timestamp::now_seconds()
            };

            let constructor_ref_recipient = object::create_object(recipient);
            let object_signer_recipient =
                object::generate_signer(&constructor_ref_recipient);
            // let extend_ref = object::generate_extend_ref(&constructor_ref);
            move_to(&object_signer_recipient, share_ownership);

        };

        // Emit transfer event
        emit(
            ShareTransferredEvent {
                fractional_token,
                from: from_addr,
                to: recipient,
                share_percentage: share_amount,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    /// Get share percentage for a specific owner
    #[view]
    public fun get_share_percentage(
        fractional_token: Object<FractionalToken>, owner: address
    ): u64 acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));

        if (smart_table::contains(&fractional_token_data.shares, owner)) {
            *smart_table::borrow(&fractional_token_data.shares, owner)
        } else { 0 }
    }

    /// Get all shareholders of a fractional token
    #[view]
    public fun get_shareholders(
        fractional_token: Object<FractionalToken>
    ): vector<address> acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        fractional_token_data.shareholders
    }

    /// Get the original token object from a fractional token
    #[view]
    public fun get_original_token(
        fractional_token: Object<FractionalToken>
    ): Object<AptosToken> acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        fractional_token_data.token
    }

    /// Get total shares (always 10000)
    #[view]
    public fun get_total_shares(
        fractional_token: Object<FractionalToken>
    ): u64 acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        fractional_token_data.total_shares
    }

    /// Get the original owner who fractionalized the token
    #[view]
    public fun get_original_owner(
        fractional_token: Object<FractionalToken>
    ): address acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        fractional_token_data.original_owner
    }

    /// Check if an address owns any shares in a fractional token
    #[view]
    public fun is_shareholder(
        fractional_token: Object<FractionalToken>, addr: address
    ): bool acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        smart_table::contains(&fractional_token_data.shares, addr)
    }

    /// Get number of shareholders
    #[view]
    public fun get_shareholder_count(
        fractional_token: Object<FractionalToken>
    ): u64 acquires FractionalToken {
        let fractional_token_data =
            borrow_global<FractionalToken>(object::object_address(&fractional_token));
        vector::length(&fractional_token_data.shareholders)
    }
}
