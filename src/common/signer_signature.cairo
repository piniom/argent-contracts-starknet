use ecdsa::check_ecdsa_signature;
use starknet::SyscallResultTrait;
use starknet::secp256_trait::{Secp256PointTrait, Signature as Secp256r1Signature, recover_public_key};
use starknet::secp256k1::Secp256k1Point;
use starknet::secp256r1::Secp256r1Point;
use starknet::{EthAddress, eth_signature::{Signature as Secp256k1Signature, is_eth_signature_valid}};

#[derive(Drop, Copy, Serde, PartialEq)]
struct StarknetSignature {
    r: felt252,
    s: felt252,
}

#[derive(Drop, Copy, Serde, PartialEq)]
enum SignerType {
    #[default]
    Starknet: StarknetSignature,
    Secp256k1: Secp256k1Signature,
    Secp256r1: Secp256r1Signature,
    Webauthn,
}

#[derive(Copy, Drop, Serde)]
struct SignerSignature {
    signer: felt252,
    signer_type: SignerType,
}

fn is_valid_signer_signature_internal(hash: felt252, sig: SignerSignature) -> bool {
    match sig.signer_type {
        SignerType::Starknet(signature) => { is_valid_starknet_signature(hash, sig.signer, signature) },
        SignerType::Secp256k1(signature) => { is_valid_secp256k1_signature(hash, sig.signer, signature) },
        SignerType::Secp256r1(signature) => { is_valid_secp256r1_signature(hash, sig.signer, signature) },
        SignerType::Webauthn => false,
    }
}

fn is_valid_starknet_signature(hash: felt252, signer: felt252, signature: StarknetSignature) -> bool {
    check_ecdsa_signature(hash, signer, signature.r, signature.s)
}

fn is_valid_secp256k1_signature(hash: felt252, signer: felt252, signature: Secp256k1Signature) -> bool {
    let eth_signer: EthAddress = signer.try_into().expect('argent/invalid-eth-signer');
    is_eth_signature_valid(hash.into(), signature, eth_signer).is_ok()
}

fn is_valid_secp256r1_signature(hash: felt252, owner: felt252, signature: Secp256r1Signature) -> bool {
    let recovered = recover_public_key::<Secp256r1Point>(hash.into(), signature).expect('argent/invalid-sig-format');
    let (recovered_x, _) = recovered.get_coordinates().expect('argent/invalid-sig-format');
    let recovered_owner = truncate_felt252(recovered_x);
    recovered_owner == owner
}

fn truncate_felt252(value: u256) -> felt252 {
    // using 248-bit mask instead of 251-bit mask to only remove characters from hex representation instead of modifying digits
    let value = value & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
    value.try_into().expect('truncate_felt252 failed')
}
