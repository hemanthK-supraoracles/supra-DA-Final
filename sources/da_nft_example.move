module CAFE::da_nft_example_1 {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use std::option;
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::account;
    use supra_framework::timestamp;
    use 0x4::collection;
    use 0x4::royalty;
    use 0x4::token::{Self, Token};
    use 0x1::object::{Self, Object};
    use aptos_token_objects::token::{BurnRef, MutatorRef};
    use std::debug;

    use std::option::Option;
    use supra_framework::object::{ConstructorRef, ExtendRef};
    use supra_framework::event::emit;
    use aptos_std::table::{Self, Table};
    use aptos_std::smart_table::{Self, SmartTable};

    // Error codes
    const E_ALREADY_MINTED: u64 = 1;
    const E_NOT_AUTHORIZED: u64 = 2;
    const E_TOKEN_NOT_FOUND: u64 = 3;
    const E_TARGET_OBJECT_NOT_FOUND: u64 = 4;
    const E_COLLECTION_NOT_FOUND: u64 = 5;
    const E_NOT_IMPLEMENTED: u64 = 6;
    const E_INVALID_TRANSFER: u64 = 7;
    const E_BURN_REF_NOT_FOUND: u64 = 8;
    const E_BURN_REF_INVALID: u64 = 9;
    const E_BURN_REF_ALREADY_EXISTS: u64 = 10;
    const E_BURN_REF_NOT_OWNER: u64 = 11;
    const E_BURN_REF_INVALID_OWNER: u64 = 12;
    const E_BURN_REF_ALREADY_EXISTS_FOR_TOKEN: u64 = 13;
    const E_BURN_REF_NOT_FOUND_FOR_TOKEN: u64 = 14;
    const E_BURN_REF_INVALID_FOR_TOKEN: u64 = 15;
    const E_BURN_REF_NOT_OWNER_FOR_TOKEN: u64 = 16;
    const E_INSUFFICIENT_SHARES: u64 = 17;
    const E_INVALID_PERCENTAGE: u64 = 18;
    const E_ALREADY_SHARED: u64 = 20;
    const E_NOT_OWNER: u64 = 21;
    const E_INVALID_SHARE_COUNT: u64 = 22;

    // Struct to store collection metadata
    struct CollectionMetadata has key {
        creation_timestamp_secs: u64,
        mint_event_handle: EventHandle<MintEvent>,
        transfer_event_handle: EventHandle<TransferEvent>,
        burn_event_handle: EventHandle<BurnEvent>,
        mutate_event_handle: EventHandle<MutateEvent>
    }

    /// Struct to manage fractional ownership of a token
    struct FractionalToken has key {
        /// The original token object
        token: Object<Token>,
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

    struct Burn has key, drop {
        burn_ref: BurnRef
    }

    struct Mutator has key, drop {
        mutator_ref: MutatorRef
    }

    // Struct to track which addresses have minted
    struct MintTracker has key {
        minted_addresses: vector<address>
    }

    // Event structs
    struct MintEvent has drop, store {
        token_name: String,
        receiver: address,
        timestamp: u64
    }

    struct TransferEvent has drop, store {
        token_name: String,
        from: address,
        to: address,
        timestamp: u64
    }

    struct BurnEvent has drop, store {
        token_name: String,
        owner: address,
        timestamp: u64
    }

    struct MutateEvent has drop, store {
        token_name: String,
        owner: address,
        property_name: String,
        new_value: String,
        timestamp: u64
    }

    /// Events
    #[event]
    struct TokenFractionalizedEvent has drop, store {
        token: Object<Token>,
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
 
    // Initialize the collection and necessary resources
    public entry fun initialize_collection(creator: &signer, collection_description: String, collection_name: String, uri: String) {
        let creator_addr = signer::address_of(creator);

       let royalty =  royalty::create(
            500, // 5% royalty
            10000, // 100% denominator
            creator_addr // Payee is the creator
        );

        // Create an unlimited collection
        let collection_constructor_ref =
            collection::create_unlimited_collection(
                creator,
                collection_description,
                collection_name,
                option::some(royalty),
                uri
            );

        // Create collection signer and add metadata
        let collection_signer = object::generate_signer(&collection_constructor_ref);
        move_to(
            &collection_signer,
            CollectionMetadata {
                creation_timestamp_secs: timestamp::now_seconds(),
                mint_event_handle: account::new_event_handle<MintEvent>(creator),
                transfer_event_handle: account::new_event_handle<TransferEvent>(creator),
                burn_event_handle: account::new_event_handle<BurnEvent>(creator),
                mutate_event_handle: account::new_event_handle<MutateEvent>(creator)
            }
        );

        // Initialize mint tracker if it doesn't exist
        if (!exists<MintTracker>(creator_addr)) {
            move_to(creator, MintTracker { minted_addresses: vector::empty() });
        }; // Focus  Dharana
    }

    // Mint an NFT with a check for one-per-wallet
    public entry fun mint_nft(
        creator: &signer,
        receiver: address,
        collection_name: String,
        name: String,
        description: String,
        uri: String
    ) acquires CollectionMetadata, MintTracker {
        let creator_addr = signer::address_of(creator);
        let tracker = borrow_global_mut<MintTracker>(creator_addr);

        // Check if receiver has already minted
        // assert!(
        //     !vector::contains(&tracker.minted_addresses, &receiver),
        //     error::already_exists(E_ALREADY_MINTED)
        // );

         let royalty =  royalty::create(
            800, // 8% royalty
            10000, // 100% denominator
            creator_addr // Payee is the creator
        );

        // Mint the NFT
        let token_constructor_ref =
            token::create(
                creator,
                collection_name,
                description,
                name,
                option::some(royalty),
                uri
            );

        let token_signer = &object::generate_signer(&token_constructor_ref);
        let burn_ref = token::generate_burn_ref(&token_constructor_ref);
        let mutator_ref = token::generate_mutator_ref(&token_constructor_ref);

        // Store the burn ref somewhere safe
        move_to(token_signer, Burn { burn_ref });
        move_to(token_signer, Mutator { mutator_ref });

        // Transfer to receiver
        let token_obj =
            object::object_from_constructor_ref<token::Token>(&token_constructor_ref);
        object::transfer(creator, token_obj, receiver);

        // Update mint tracker
        vector::push_back(&mut tracker.minted_addresses, receiver);

        // Emit mint event
        let collection_addr =
            collection::create_collection_address(
                &creator_addr, &collection_name
            );
        // let collection_signer = object::generate_signer_for_object(&collection_addr);
        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.mint_event_handle,
            MintEvent { token_name: name, receiver, timestamp: timestamp::now_seconds() }
        );
    }

    // Transfer an NFT
    public entry fun transfer_nft(
        sender: &signer,
        token_addr: address,
        receiver: address,
        collection_addr: address
    ) acquires CollectionMetadata {
        let sender_addr = signer::address_of(sender);
        let token_obj = object::address_to_object<token::Token>(token_addr);

        // Verify sender owns the token
        assert!(
            object::is_owner(token_obj, sender_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        // Perform transfer
        object::transfer(sender, token_obj, receiver);

        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.transfer_event_handle,
            TransferEvent {
                token_name: token::name(token_obj),
                from: sender_addr,
                to: receiver,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    // Transfer an NFT
    public entry fun transfer_nft_to_nft(
        sender: &signer,
        token_addr: address,
        collection_addr: address,
        target_object_addr: address
    ) acquires CollectionMetadata {

        let sender_addr = signer::address_of(sender);
        let token_obj = object::address_to_object<Token>(token_addr);

        // Verify sender owns the token
        assert!(
            object::is_owner(token_obj, sender_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        // Get the target object to transfer to
        let target_obj = object::address_to_object<Token>(target_object_addr);

        // Verify the target object exists and belongs to target collection
        assert!(
            object::object_exists<Token>(target_object_addr),
            error::not_found(E_TARGET_OBJECT_NOT_FOUND)
        );

        // Transfer to the target object's address
        object::transfer(sender, token_obj, target_object_addr);

        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.transfer_event_handle,
            TransferEvent {
                token_name: token::name(token_obj),
                from: sender_addr,
                to: target_object_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    // Transfer an NFT to a collection object, This is un conventional but useful for some use cases.
    public entry fun transfer_nft_to_collection(
        sender: &signer,
        token_addr: address,
        collection_addr: address,
        target_object_addr: address
    ) acquires CollectionMetadata {

        let sender_addr = signer::address_of(sender);
        let token_obj = object::address_to_object<Token>(token_addr);

        // Verify sender owns the token
        assert!(
            object::is_owner(token_obj, sender_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        // Get the target object to transfer to
        let target_obj = object::address_to_object<collection::Collection>(target_object_addr);

        // Verify the target object exists and belongs to target collection
        assert!(
            object::object_exists<collection::Collection>(target_object_addr),
            error::not_found(E_TARGET_OBJECT_NOT_FOUND)
        );

        // Transfer to the target object's address
        // let target_owner = object::owner(target_obj);
        object::transfer(sender, token_obj, target_object_addr);

        // Emit transfer event
        // let collection_addr =
        //     collection::create_collection_address(
        //         &collection_owner_address, &string::utf8(b"My NFT Collection")
        //     );
        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.transfer_event_handle,
            TransferEvent {
                token_name: token::name(token_obj),
                from: sender_addr,
                to: target_object_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    public entry fun mutate_nft_description(
        sender: &signer,
        token_addr: address,
        collection_addr: address,
        new_description: String
    ) acquires CollectionMetadata, Mutator {

        let sender_addr = signer::address_of(sender);
        let token_obj = object::address_to_object<Token>(token_addr);

        // Verify sender owns the token
        assert!(
            object::is_owner(token_obj, sender_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        let Mutator { mutator_ref } = move_from<Mutator>(token_addr);
        token::set_description(&mutator_ref, new_description);

        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.mutate_event_handle,
            MutateEvent {
                token_name: token::name(token_obj),
                owner: sender_addr,
                property_name: string::utf8(b"description"),
                new_value: new_description,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    // Burn an NFT
    public entry fun burn_nft(
        owner: &signer, token: Object<Token>, collection_addr: address
    ) acquires CollectionMetadata, Burn {
        let owner_addr = signer::address_of(owner);
        let token_address = object::object_address(&token);

        let token_name = token::name(token);

        // Verify owner
        assert!(
            object::is_owner(token, owner_addr),
            error::permission_denied(E_NOT_AUTHORIZED)
        );

        // Retrieve the burn ref from storage
        let Burn { burn_ref } = move_from<Burn>(token_address);
        // Burn the token
        token::burn(burn_ref);

        // Emit burn event
        // let collection_addr =
        //     collection::create_collection_address(
        //         &collection_owner, &string::utf8(b"My NFT Collection")
        //     );
        let metadata = borrow_global_mut<CollectionMetadata>(collection_addr);
        event::emit_event(
            &mut metadata.burn_event_handle,
            BurnEvent {
                token_name,
                owner: owner_addr,
                timestamp: timestamp::now_seconds()
            }
        );
    }

    // View function to check if an address has minted
    #[view]
    public fun has_minted(creator_addr: address, user_addr: address): bool acquires MintTracker {
        if (!exists<MintTracker>(creator_addr)) {
            return false
        };
        let tracker = borrow_global<MintTracker>(creator_addr);
        vector::contains(&tracker.minted_addresses, &user_addr)
    }

    //// SHARING OF TOKENS
    //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    /// Fractionalize a token into shares
    public entry fun fractionalize_token(
        owner: &signer,
        token: Object<Token>,
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

    public fun object_test(caller: &signer){
        let constructor_ref_A = object::create_object(signer::address_of(caller));
        let object_signer_A = object::generate_signer(&constructor_ref_A);
        let p = object::object_from_constructor_ref<Token>(&constructor_ref_A);

        let constructor_ref_B = object::create_object(signer::address_of(caller));
        let object_signer_B = object::generate_signer(&constructor_ref_B);

        object::transfer(
                    caller,
                    object::object_from_constructor_ref<Token>(&constructor_ref_A),
                    signer::address_of(&object_signer_B)
                );

        debug::print(& object::object_from_constructor_ref<Token>((&constructor_ref_A)));
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
    ): Object<Token> acquires FractionalToken {
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
