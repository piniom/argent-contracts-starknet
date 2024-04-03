use argent::offchain_message::{
    interface::{
        StarkNetDomain, StarknetDomain, StructHashStarkNetDomain, IOffChainMessageHashRev0, IStructHashRev0,
        IOffChainMessageHashRev1, IStructHashRev1
    },
    precalculated_hashing::get_message_hash_rev_1_with_precalc
};
use argent::outside_execution::interface::{OutsideExecution};
use hash::{HashStateTrait, HashStateExTrait};
use pedersen::PedersenTrait;
use poseidon::{poseidon_hash_span, hades_permutation, HashState};
use starknet::{get_tx_info, get_contract_address, account::Call};

const OUTSIDE_CALL_TYPE_HASH_REV_0: felt252 =
    selector!("OutsideCall(to:felt,selector:felt,calldata_len:felt,calldata:felt*)");

const OUTSIDE_EXECUTION_TYPE_HASH_REV_0: felt252 =
    selector!(
        "OutsideExecution(caller:felt,nonce:felt,execute_after:felt,execute_before:felt,calls_len:felt,calls:OutsideCall*)OutsideCall(to:felt,selector:felt,calldata_len:felt,calldata:felt*)"
    );

const OUTSIDE_EXECUTION_TYPE_HASH_REV_1: felt252 =
    selector!(
        "\"OutsideExecution\"(\"Caller\":\"ContractAddress\",\"Nonce\":\"felt\",\"Execute After\":\"u128\",\"Execute Before\":\"u128\",\"Calls\":\"Call*\")\"Call\"(\"To\":\"ContractAddress\",\"Selector\":\"selector\",\"Calldata\":\"felt*\")"
    );

const CALL_TYPE_HASH_REV_1: felt252 =
    selector!("\"Call\"(\"To\":\"ContractAddress\",\"Selector\":\"selector\",\"Calldata\":\"felt*\")");

impl StructHashOutsideExecutionRev0 of IStructHashRev0<OutsideExecution> {
    fn get_struct_hash_rev_0(self: @OutsideExecution) -> felt252 {
        let self = *self;
        let mut state = PedersenTrait::new(0);
        let mut calls_span = self.calls;
        let calls_len = self.calls.len().into();
        let calls_hash = loop {
            match calls_span.pop_front() {
                Option::Some(call) => state = state.update((call.get_struct_hash_rev_0())),
                Option::None => { break state.update(calls_len).finalize(); },
            }
        };

        PedersenTrait::new(0)
            .update_with(OUTSIDE_EXECUTION_TYPE_HASH_REV_0)
            .update_with(self.caller)
            .update_with(self.nonce)
            .update_with(self.execute_after)
            .update_with(self.execute_before)
            .update_with(calls_len)
            .update_with(calls_hash)
            .update_with(7)
            .finalize()
    }
}

impl StructHashCallRev0 of IStructHashRev0<Call> {
    fn get_struct_hash_rev_0(self: @Call) -> felt252 {
        let mut state = PedersenTrait::new(0);
        let mut calldata_span = *self.calldata;
        let calldata_len = calldata_span.len().into();
        let calldata_hash = loop {
            match calldata_span.pop_front() {
                Option::Some(item) => state = state.update(*item),
                Option::None => { break state.update(calldata_len).finalize(); },
            }
        };

        PedersenTrait::new(0)
            .update_with(OUTSIDE_CALL_TYPE_HASH_REV_0)
            .update_with(*self.to)
            .update_with(*self.selector)
            .update_with(calldata_len)
            .update_with(calldata_hash)
            .update_with(5)
            .finalize()
    }
}

impl OffChainMessageOutsideExecutionRev0 of IOffChainMessageHashRev0<OutsideExecution> {
    fn get_message_hash_rev_0(self: @OutsideExecution) -> felt252 {
        let domain = StarkNetDomain {
            name: 'Account.execute_from_outside', version: 1, chain_id: get_tx_info().unbox().chain_id,
        };

        PedersenTrait::new(0)
            .update_with('StarkNet Message')
            .update_with(domain.get_struct_hash_rev_0())
            .update_with(get_contract_address())
            .update_with((*self).get_struct_hash_rev_0())
            .update(4)
            .finalize()
    }
}

impl StructHashCallRev1 of IStructHashRev1<Call> {
    fn get_struct_hash_rev_1(self: @Call) -> felt252 {
        poseidon_hash_span(
            array![CALL_TYPE_HASH_REV_1, (*self.to).into(), *self.selector, poseidon_hash_span(*self.calldata)].span()
        )
    }
}

impl StructHashOutsideExecutionRev1 of IStructHashRev1<OutsideExecution> {
    fn get_struct_hash_rev_1(self: @OutsideExecution) -> felt252 {
        let self = *self;
        let mut calls_span = self.calls;
        let mut hashed_calls = array![];

        while let Option::Some(call) = calls_span.pop_front() {
            hashed_calls.append(call.get_struct_hash_rev_1());
        };
        poseidon_hash_span(
            array![
                OUTSIDE_EXECUTION_TYPE_HASH_REV_1,
                self.caller.into(),
                self.nonce,
                self.execute_after.into(),
                self.execute_before.into(),
                poseidon_hash_span(hashed_calls.span()),
            ]
                .span()
        )
    }
}

impl OffChainMessageOutsideExecutionRev1 of IOffChainMessageHashRev1<OutsideExecution> {
    fn get_message_hash_rev_1(self: @OutsideExecution) -> felt252 {
        // Version is shortstring '1' not felt 1 for for SNIP-9 due to a mistake made 
        // in the Braavos contracts and has been copied for compatibility.
        // Revision will also be a number for all SNIP12-rev1 signatures because of the same issue

        let chain_id = get_tx_info().unbox().chain_id;
        if chain_id == 'SN_MAIN' {
            let mainnet_first_hades_permutation = (
                466771826862796654720497916898873955545764255168198993180536052682392700659,
                8304264822580609485631142291553027424455705068469035347025093264477380363,
                105288646621191754218635047234198033888793063910621244998394884076270002325
            );

            return get_message_hash_rev_1_with_precalc(mainnet_first_hades_permutation, *self);
        }
        if chain_id == 'SN_GOERLI' {
            let goerli_first_hades_permutation = (
                525530995690438368115298687904315435654197055547696923992434565646087910422,
                3038768008552013550623612989523737978318878097021728028876203655331048060334,
                385518898049765577769956278469845800327401014397379779953573488122407330399
            );
            return get_message_hash_rev_1_with_precalc(goerli_first_hades_permutation, *self);
        }
        let domain = StarknetDomain { name: 'Account.execute_from_outside', version: 1, chain_id, revision: 1 };
        poseidon_hash_span(
            array![
                'StarkNet Message',
                domain.get_struct_hash_rev_1(),
                get_contract_address().into(),
                (*self).get_struct_hash_rev_1(),
            ]
                .span()
        )
    }
}

