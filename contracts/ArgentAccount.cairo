%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.math import assert_not_zero, assert_le, assert_nn
from starkware.starknet.common.syscalls import call_contract, get_tx_signature, get_contract_address, get_caller_address
from starkware.cairo.common.hash_state import (
    hash_init, hash_finalize, hash_update, hash_update_single
)

####################
# CONSTANTS
####################

const VERSION = '0.2.0' # '0.2.0' = 30 2E 32 2E 30 = 0x302E322E30 = 206933470768

const CHANGE_SIGNER_SELECTOR = 1540130945889430637313403138889853410180247761946478946165786566748520529557
const CHANGE_GUARDIAN_SELECTOR = 1374386526556551464817815908276843861478960435557596145330240747921847320237
const TRIGGER_ESCAPE_GUARDIAN_SELECTOR = 73865429733192804476769961144708816295126306469589518371407068321865763651
const TRIGGER_ESCAPE_SIGNER_SELECTOR = 651891265762986954898774236860523560457159526623523844149280938288756256223
const ESCAPE_GUARDIAN_SELECTOR = 1662889347576632967292303062205906116436469425870979472602094601074614456040
const ESCAPE_SIGNER_SELECTOR = 578307412324655990419134484880427622068887477430675222732446709420063579565
const CANCEL_ESCAPE_SELECTOR = 992575500541331354489361836180456905167517944319528538469723604173440834912

const ESCAPE_SECURITY_PERIOD = 500 # set to e.g. 7 days in prod

const FALSE = 0
const TRUE = 1

####################
# STRUCTS
####################

struct Escape:
    member active_at: felt
    member caller_is_signer: felt
end

####################
# STORAGE VARIABLES
####################

@storage_var
func _current_nonce() -> (res: felt):
end

@storage_var
func _signer() -> (res: felt):
end

@storage_var
func _guardian() -> (res: felt):
end

@storage_var
func _guardian_backup() -> (res: felt):
end

@storage_var
func _escape() -> (res: Escape):
end

####################
# EXTERNAL FUNCTIONS
####################

@constructor
func constructor{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        signer: felt,
        guardian: felt
    ):
    # check that the signer is not zero
    assert_not_zero(signer)
    # initialize the contract
    _signer.write(signer)
    _guardian.write(guardian)
    return ()
end

@external
func execute{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        to: felt,
        selector: felt,
        calldata_len: felt,
        calldata: felt*,
        nonce: felt
    ) -> (response : felt):
    alloc_locals

    # validate and bump nonce
    validate_and_bump_nonce(nonce)

    # get the signature(s)
    let (sig_len : felt, sig : felt*) = get_tx_signature()

    # get self address
    let (self) = get_contract_address()

    # compute message hash
    let (message_hash) = get_message_hash(to, selector, calldata_len, calldata, nonce)

    # rebind pointers
    local syscall_ptr: felt* = syscall_ptr
    local range_check_ptr = range_check_ptr
    local pedersen_ptr: HashBuiltin* = pedersen_ptr

    if to == self:
        tempvar signer_condition = (selector - ESCAPE_GUARDIAN_SELECTOR) * (selector - TRIGGER_ESCAPE_GUARDIAN_SELECTOR)
        tempvar guardian_condition = (selector - ESCAPE_SIGNER_SELECTOR) * (selector - TRIGGER_ESCAPE_SIGNER_SELECTOR)
        if signer_condition == 0:
            # validate signer signature
            validate_signer_signature(message_hash, sig, sig_len)
            jmp do_execute
        end
        if guardian_condition == 0:
            # validate guardian signature
            validate_guardian_signature(message_hash, sig, sig_len)
            jmp do_execute
        end
    end
    # validate signer and guardian signatures
    validate_signer_signature(message_hash, sig, sig_len)
    validate_guardian_signature(message_hash, sig + 2, sig_len - 2)
    
    # execute call
    do_execute:
    let response = call_contract(
        contract_address=to,
        function_selector=selector,
        calldata_size=calldata_len,
        calldata=calldata
    )
    return (response=response.retdata_size)
end

@external
func change_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        new_signer: felt
    ):
    # only called via execute
    assert_only_self()

    # change signer
    assert_not_zero(new_signer)
    _signer.write(new_signer)
    return()
end

@external
func change_guardian{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        new_guardian: felt
    ):
    # only called via execute
    assert_only_self()
    
    # assert !(guardian_backup != 0 && new_guardian == 0)
    if new_guardian == 0:
        let (guardian_backup) = _guardian_backup.read()
        assert guardian_backup = 0
        tempvar syscall_ptr: felt* = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
        tempvar pedersen_ptr: HashBuiltin* = pedersen_ptr
    else:
        tempvar syscall_ptr: felt* = syscall_ptr
        tempvar range_check_ptr = range_check_ptr
        tempvar pedersen_ptr: HashBuiltin* = pedersen_ptr
    end

    # change guardian
    _guardian.write(new_guardian)
    return()
end

@external
func change_guardian_backup{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        new_guardian: felt
    ):
    # only called via execute
    assert_only_self()

    # no backup when there is no guardian set
    assert_guardian_set()

    # change guardian
    _guardian_backup.write(new_guardian)
    return()
end

@external
func trigger_escape_guardian{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } ():
    alloc_locals
    
    # only called via execute
    assert_only_self()
    # no escape when the guardian is not set
    assert_guardian_set()

    # store new escape
    let (block_timestamp) = _block_timestamp.read()
    let new_escape: Escape = Escape(block_timestamp + ESCAPE_SECURITY_PERIOD, TRUE)
    _escape.write(new_escape)
    return()
end

@external
func trigger_escape_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } ():
    alloc_locals

    # only called via execute
    assert_only_self()
    # no escape when there is no guardian set
    assert_guardian_set()

    # no escape if there is an escape by the signer
    let (current_escape) = _escape.read()
    assert (current_escape.active_at * current_escape.caller_is_signer) = 0

    # store new escape
    let (block_timestamp) = _block_timestamp.read()
    let new_escape: Escape = Escape(block_timestamp + ESCAPE_SECURITY_PERIOD, FALSE)
    _escape.write(new_escape)
    return()
end

@external
func cancel_escape{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } ():

    # only called via execute
    assert_only_self()

    # validate there is an active escape
    let (current_escape) = _escape.read()
    assert_not_zero(current_escape.active_at)

    # clear escape
    let new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)
    return()
end

@external
func escape_guardian{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        new_guardian: felt
    ):
    alloc_locals

    # only called via execute
    assert_only_self()
    # no escape when the guardian is not set
    assert_guardian_set()
    
    let (current_escape) = _escape.read()
    let (block_timestamp) = _block_timestamp.read()
    # assert there is an active escape
    assert_le(current_escape.active_at, block_timestamp)
    # assert the escape was triggered by the signer
    assert current_escape.caller_is_signer = TRUE

    # clear escape
    let new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)

    # change guardian
    assert_not_zero(new_guardian)
    _guardian.write(new_guardian)

    return()
end

@external
func escape_signer{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        new_signer: felt
    ):
    alloc_locals

    # only called via execute
    assert_only_self()
    # no escape when the guardian is not set
    assert_guardian_set()

    let (current_escape) = _escape.read()
    let (block_timestamp) = _block_timestamp.read()
    # validate there is an active escape
    assert_le(current_escape.active_at, block_timestamp)
    # assert the escape was triggered by the guardian
    assert current_escape.caller_is_signer = FALSE

    # clear escape
    let new_escape: Escape = Escape(0, 0)
    _escape.write(new_escape)

    # change signer
    assert_not_zero(new_signer)
    _signer.write(new_signer)

    return()
end

####################
# VIEW FUNCTIONS
####################

@view
func is_valid_signature{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        hash: felt,
        sig_len: felt,
        sig: felt*
    ) -> ():
    validate_signer_signature(hash, sig, sig_len)
    validate_guardian_signature(hash, sig + 2, sig_len - 2)
    return ()
end

@view
func get_nonce{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> (nonce: felt):
    let (res) = _current_nonce.read()
    return (nonce=res)
end

@view
func get_signer{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> (signer: felt):
    let (res) = _signer.read()
    return (signer=res)
end

@view
func get_guardian{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> (guardian: felt):
    let (res) = _guardian.read()
    return (guardian=res)
end

@view
func get_guardian_backup{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> (guardian_backup: felt):
    let (res) = _guardian_backup.read()
    return (guardian_backup=res)
end

@view
func get_escape{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> (active_at: felt, caller_is_signer: felt):
    let (res) = _escape.read()
    return (active_at=res.active_at, caller_is_signer=res.caller_is_signer)
end

@view
func get_version() -> (version: felt):
    return (version=VERSION)
end

####################
# INTERNAL FUNCTIONS
####################

func assert_only_self{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } () -> ():
    let (self) = get_contract_address()
    let (caller_address) = get_caller_address()
    assert self = caller_address
    return()
end

func assert_guardian_set{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } ():
    let (guardian) = _guardian.read()
    assert_not_zero(guardian)
    return()
end

func validate_and_bump_nonce{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        message_nonce: felt
    ) -> ():
    let (current_nonce) = _current_nonce.read()
    assert current_nonce = message_nonce
    _current_nonce.write(current_nonce + 1)
    return()
end

func validate_signer_signature{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        message: felt, 
        signatures: felt*,
        signatures_len: felt
    ) -> ():
    assert_nn(signatures_len - 2)
    let (signer) = _signer.read()
    verify_ecdsa_signature(
        message=message,
        public_key=signer,
        signature_r=signatures[0],
        signature_s=signatures[1])
    return()
end

func validate_guardian_signature{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    } (
        message: felt,
        signatures: felt*,
        signatures_len: felt
    ) -> ():
    alloc_locals
    let (guardian) = _guardian.read()
    if guardian == 0:
        return()
    else:
        if signatures_len == 2:
            # must be signed by guardian
            verify_ecdsa_signature(
                message=message,
                public_key=guardian,
                signature_r=signatures[0],
                signature_s=signatures[1])
            tempvar syscall_ptr: felt* = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
            tempvar pedersen_ptr: HashBuiltin* = pedersen_ptr
        else:
            # must be signed by guardian_backup
            assert signatures_len = 4
            assert (signatures[0] + signatures[1]) = 0
            let (guardian_backup) = _guardian_backup.read()
            verify_ecdsa_signature(
                message=message,
                public_key=guardian_backup,
                signature_r=signatures[2],
                signature_s=signatures[3])
            tempvar syscall_ptr: felt* = syscall_ptr
            tempvar range_check_ptr = range_check_ptr
            tempvar pedersen_ptr: HashBuiltin* = pedersen_ptr
        end
        return()
    end
end

func get_message_hash{
        syscall_ptr: felt*, 
        pedersen_ptr: HashBuiltin*,
        range_check_ptr
    } (
        to: felt,
        selector: felt,
        calldata_len: felt,
        calldata: felt*,
        nonce: felt
    ) -> (res: felt):
    alloc_locals
    let (account) = get_contract_address()
    let (calldata_hash) = hash_calldata(calldata, calldata_len)
    let hash_ptr = pedersen_ptr
    with hash_ptr:
        let (hash_state_ptr) = hash_init()
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, account)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, to)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, selector)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, calldata_hash)
        let (hash_state_ptr) = hash_update_single(hash_state_ptr, nonce)
        let (res) = hash_finalize(hash_state_ptr)
        let pedersen_ptr = hash_ptr
        return (res=res)
    end
    
end

func hash_calldata{
        pedersen_ptr: HashBuiltin*
    }(
        calldata: felt*,
        calldata_size: felt
    ) -> (res: felt):
    let hash_ptr = pedersen_ptr
    with hash_ptr:
        let (hash_state_ptr) = hash_init()
        let (hash_state_ptr) = hash_update(
            hash_state_ptr,
            calldata,
            calldata_size
        )
        let (res) = hash_finalize(hash_state_ptr)
        let pedersen_ptr = hash_ptr
        return (res=res)
    end
end

####################
# TMP HACK
####################

@storage_var
func _block_timestamp() -> (res: felt):
end

@view
func get_block_timestamp{
    syscall_ptr: felt*, 
    pedersen_ptr: HashBuiltin*,
    range_check_ptr}() -> (block_timestamp: felt):
    let (res) = _block_timestamp.read()
    return (block_timestamp=res)
end

@external
func set_block_timestamp{
    syscall_ptr: felt*, 
    pedersen_ptr: HashBuiltin*,
    range_check_ptr}(new_block_timestamp: felt):
    _block_timestamp.write(new_block_timestamp)
    return ()
end