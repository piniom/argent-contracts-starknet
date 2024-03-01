use argent::presets::argent_account::ArgentAccount;
use argent::signer::signer_signature::{
    Signer, SignerSignature, StarknetSignature, StarknetSigner, SignerTrait, starknet_signer_from_pubkey
};
use argent_tests::setup::account_test_setup::{
    ITestArgentAccountDispatcherTrait, owner_pubkey, wrong_owner_pubkey, initialize_account_with, initialize_account,
    initialize_account_without_guardian
};
use core::option::OptionTrait;
use core::result::ResultTrait;
use core::serde::Serde;
use core::traits::TryInto;
use starknet::{contract_address_const, deploy_syscall, testing::{set_version, set_contract_address}};

const new_owner_pubkey: felt252 = 0xa7da05a4d664859ccd6e567b935cdfbfe3018c7771cb980892ef38878ae9bc;
const new_owner_r: felt252 = 0x149c4c5bcf1676d440a6095b8635f027c45ceb7aa5e731d0785ade0e086aa83;
const new_owner_s: felt252 = 0x52988bad1a94404491228228b6a923d1106ff4ba7f37e4d0710df4aaa4f8528;

const wrong_owner_r: felt252 = 0x4be5db0599a2e5943f207da3f9bf2dd091acf055b71a1643e9c35fcd7e2c0df;
const wrong_owner_s: felt252 = 0x2e44d5bad55a0d692e02529e7060f352fde85fae8d5946f28c34a10a29bc83b;

#[test]
fn initialize() {
    let account = initialize_account_with(1, 2);
    assert(account.get_owner() == 1, 'value should be 1');
    assert(account.get_guardian() == 2, 'value should be 2');
    assert(account.get_guardian_backup() == 0, 'value should be 0');
}

#[test]
#[should_panic(expected: ('argent/invalid-tx-version', 'ENTRYPOINT_FAILED'))]
fn check_transaction_version_on_execute() {
    let account = initialize_account();
    set_contract_address(contract_address_const::<0>());
    set_version(32);
    account.__execute__(array![]);
}

#[test]
#[should_panic(expected: ('argent/invalid-tx-version', 'ENTRYPOINT_FAILED'))]
fn check_transaction_version_on_validate() {
    let account = initialize_account();
    set_contract_address(contract_address_const::<0>());
    set_version(32);
    account.__validate__(array![]);
}

#[test]
fn initialized_no_guardian_no_backup() {
    let account = initialize_account_with(1, 0);
    assert(account.get_owner() == 1, 'value should be 1');
    assert(account.get_guardian() == 0, 'guardian should be zero');
    assert(account.get_guardian_backup() == 0, 'guardian backup should be zero');
}

#[test]
fn erc165_unsupported_interfaces() {
    let account = initialize_account();
    assert(!account.supports_interface(0), 'Should not support 0');
    assert(!account.supports_interface(0xffffffff), 'Should not support 0xffffffff');
}

#[test]
fn erc165_supported_interfaces() {
    let account = initialize_account();
    assert(account.supports_interface(0x3f918d17e5ee77373b56385708f855659a07f75997f365cf87748628532a055), 'IERC165');
    assert(account.supports_interface(0x01ffc9a7), 'IERC165_OLD');
    assert(account.supports_interface(0x2ceccef7f994940b3962a6c67e0ba4fcd37df7d131417c604f91e03caecc1cd), 'IACCOUNT');
    assert(account.supports_interface(0xa66bd575), 'IACCOUNT_OLD_1');
    assert(account.supports_interface(0x3943f10f), 'IACCOUNT_OLD_2');

    assert(
        account.supports_interface(0x68cfd18b92d1907b8ba3cc324900277f5a3622099431ea85dd8089255e4181),
        'OUTSIDE_EXECUTION'
    );
}

// Test commented until we use forge, because the account address keeps changing.
// There is an equivalent test on the integration tests
// #[test]
// fn change_owner() {
//     let signer_signature = SignerSignature::Starknet(
//         (
//             StarknetSigner { pubkey: new_owner_pubkey.try_into().expect('argent/zero-pubkey') },
//             StarknetSignature { r: new_owner_r, s: new_owner_s }
//         )
//     );
//     account.change_owner(signer_signature);
//     assert(account.get_owner() == new_owner_pubkey.try_into().unwrap(), 'value should be new owner pub');
// }

#[test]
#[should_panic(expected: ('argent/only-self', 'ENTRYPOINT_FAILED'))]
fn change_owner_only_self() {
    let account = initialize_account();
    set_contract_address(contract_address_const::<42>());
    let signer_signature = SignerSignature::Starknet(
        (
            StarknetSigner { pubkey: new_owner_pubkey.try_into().expect('argent/zero-pubkey') },
            StarknetSignature { r: new_owner_r, s: new_owner_s }
        )
    );
    account.change_owner(signer_signature);
}

#[test]
#[should_panic(expected: ('argent/invalid-owner-sig', 'ENTRYPOINT_FAILED'))]
fn change_owner_invalid_message() {
    let account = initialize_account();
    let signer_signature = SignerSignature::Starknet(
        (
            StarknetSigner { pubkey: new_owner_pubkey.try_into().expect('argent/zero-pubkey') },
            StarknetSignature { r: wrong_owner_r, s: wrong_owner_s }
        )
    );
    account.change_owner(signer_signature);
}

#[test]
#[should_panic(expected: ('argent/invalid-owner-sig', 'ENTRYPOINT_FAILED'))]
fn change_owner_wrong_pub_key() {
    let account = initialize_account();
    let signer_signature = SignerSignature::Starknet(
        (
            StarknetSigner { pubkey: wrong_owner_pubkey.try_into().expect('argent/zero-pubkey') },
            StarknetSignature { r: new_owner_r, s: new_owner_s }
        )
    );
    account.change_owner(signer_signature);
}

#[test]
fn change_guardian() {
    let account = initialize_account();
    let guardian = starknet_signer_from_pubkey(22);
    account.change_guardian(Option::Some(guardian));
    assert(account.get_guardian() == guardian.into_guid(), 'value should be 22');
}

#[test]
#[should_panic(expected: ('argent/only-self', 'ENTRYPOINT_FAILED'))]
fn change_guardian_only_self() {
    let account = initialize_account();
    let guardian = Option::Some(starknet_signer_from_pubkey(22));
    set_contract_address(contract_address_const::<42>());
    account.change_guardian(guardian);
}

#[test]
#[should_panic(expected: ('argent/backup-should-be-null', 'ENTRYPOINT_FAILED'))]
fn change_guardian_to_zero() {
    let account = initialize_account();
    let guardian_backup = Option::Some(starknet_signer_from_pubkey(42));
    let guardian: Option<Signer> = Option::None;
    account.change_guardian_backup(guardian_backup);
    account.change_guardian(guardian);
}

#[test]
fn change_guardian_to_zero_without_guardian_backup() {
    let account = initialize_account();
    let guardian: Option<Signer> = Option::None;
    account.change_guardian(guardian);
    assert(account.get_guardian().is_zero(), 'value should be 0');
}

#[test]
fn change_guardian_backup() {
    let account = initialize_account();
    let guardian_backup = starknet_signer_from_pubkey(33);
    account.change_guardian_backup(Option::Some(guardian_backup));
    assert(account.get_guardian_backup() == guardian_backup.into_guid(), 'value should be 33');
}

#[test]
#[should_panic(expected: ('argent/only-self', 'ENTRYPOINT_FAILED'))]
fn change_guardian_backup_only_self() {
    let account = initialize_account();
    let guardian_backup = Option::Some(starknet_signer_from_pubkey(42));
    set_contract_address(contract_address_const::<42>());
    account.change_guardian_backup(guardian_backup);
}

#[test]
fn change_guardian_backup_to_zero() {
    let account = initialize_account();
    let guardian_backup: Option<Signer> = Option::None;
    account.change_guardian_backup(guardian_backup);
    assert(account.get_guardian_backup().is_zero(), 'value should be 0');
}

#[test]
#[should_panic(expected: ('argent/guardian-required', 'ENTRYPOINT_FAILED'))]
fn change_invalid_guardian_backup() {
    let account = initialize_account_without_guardian();
    let guardian_backup = Option::Some(starknet_signer_from_pubkey(2));
    account.change_guardian_backup(guardian_backup);
}

#[test]
fn get_version() {
    let version = initialize_account().get_version();
    assert(version.major == 0, 'Version major = 0');
    assert(version.minor == 4, 'Version minor = 4');
    assert(version.patch == 0, 'Version patch = 0');
}

#[test]
fn getVersion() {
    assert(initialize_account().getVersion() == '0.4.0', 'Version should be 0.4.0');
}

#[test]
fn get_name() {
    assert(initialize_account().get_name() == 'ArgentAccount', 'Name should be ArgentAccount');
}

#[test]
fn getName() {
    assert(initialize_account().getName() == 'ArgentAccount', 'Name should be ArgentAccount');
}

#[test]
fn unsuported_supportsInterface() {
    let account = initialize_account();
    assert(account.supportsInterface(0) == 0, 'value should be false');
    assert(account.supportsInterface(0xffffffff) == 0, 'Should not support 0xffffffff');
}

#[test]
fn supportsInterface() {
    let account = initialize_account();
    assert(account.supportsInterface(0x01ffc9a7) == 1, 'ERC165_IERC165_INTERFACE_ID');
    assert(account.supportsInterface(0xa66bd575) == 1, 'ERC165_ACCOUNT_INTERFACE_ID');
    assert(account.supportsInterface(0x3943f10f) == 1, 'ERC165_OLD_ACCOUNT_INTERFACE_ID');
}
