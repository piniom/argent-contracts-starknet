import pytest
import asyncio
from starkware.starknet.testing.starknet import Starknet
from starkware.starknet.definitions.error_codes import StarknetErrorCode
from utils.Signer import Signer
from utils.utilities import cached_contract, compile, assert_revert, str_to_felt, assert_event_emmited, update_starknet_block, reset_starknet_block, DEFAULT_TIMESTAMP
from utils.TransactionSender import TransactionSender

signer = Signer(1)
guardian = Signer(2)
guardian_backup = Signer(3)

new_signer = Signer(4)
new_guardian = Signer(5)
new_guardian_backup = Signer(6)

wrong_signer = Signer(7)
wrong_guardian = Signer(8)

ESCAPE_SECURITY_PERIOD = 24*7*60*60

VERSION = str_to_felt('0.2.3')
NAME = str_to_felt('ArgentAccount')

IACCOUNT_ID = 0xf10dbd44

ESCAPE_TYPE_GUARDIAN = 1
ESCAPE_TYPE_SIGNER = 2

@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
def contract_classes():
    account_cls = compile('contracts/account/ArgentAccount.cairo')
    dapp_cls = compile("contracts/test/TestDapp.cairo")
    
    return account_cls, dapp_cls

@pytest.fixture(scope='module')
async def contract_init(contract_classes):
    account_cls, dapp_cls = contract_classes
    starknet = await Starknet.empty()

    account = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )
    await account.initialize(signer.public_key, guardian.public_key).execute()

    account_no_guardian = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )
    await account_no_guardian.initialize(signer.public_key, 0).execute()

    dapp = await starknet.deploy(
        contract_class=dapp_cls,
        constructor_calldata=[],
    )

    return starknet.state, account, account_no_guardian, dapp

@pytest.fixture
async def contract_factory(contract_classes, contract_init):
    account_cls, dapp_cls = contract_classes
    state, account, account_no_guardian, dapp = contract_init
    _state = state.copy()

    account = cached_contract(_state, account_cls, account)
    account_no_guardian = cached_contract(_state, account_cls, account_no_guardian)
    dapp = cached_contract(_state, dapp_cls, dapp)

    return account, account_no_guardian, dapp

@pytest.mark.asyncio
async def test_initializer(contract_factory):
    account, _, _ = contract_factory
    # should be configured correctly
    assert (await account.get_signer().call()).result.signer == (signer.public_key)
    assert (await account.get_guardian().call()).result.guardian == (guardian.public_key)
    assert (await account.get_version().call()).result.version == VERSION
    assert (await account.get_name().call()).result.name == NAME
    assert (await account.supportsInterface(IACCOUNT_ID).call()).result.success == 1
    # should throw when calling initialize twice
    await assert_revert(
         account.initialize(signer.public_key, guardian.public_key).execute(),
         "already initialized"
     )

@pytest.mark.asyncio
async def test_call_dapp_with_guardian(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    calls = [(dapp.contract_address, 'set_number', [47])]

    # should revert with the wrong nonce
    await assert_revert(
        sender.send_transaction(calls, [signer, guardian], nonce=3),
        expected_code=StarknetErrorCode.INVALID_TRANSACTION_NONCE
    )

    # should revert with the wrong signer
    await assert_revert(
        sender.send_transaction(calls, [wrong_signer, guardian]),
        "signer signature invalid"
    )

    # should revert with the wrong guardian
    await assert_revert(
        sender.send_transaction(calls, [signer, wrong_guardian]),
        "guardian signature invalid"
    )

    # should fail with only 1 signer
    await assert_revert(
        sender.send_transaction(calls, [signer]),
        "guardian signature invalid"
    )

    # should call the dapp
    assert (await dapp.get_number(account.contract_address).call()).result.number == 0
    
    tx_exec_info = await sender.send_transaction(calls, [signer, guardian])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='transaction_executed'
    )

    assert (await dapp.get_number(account.contract_address).call()).result.number == 47

@pytest.mark.asyncio
async def test_call_dapp_no_guardian(contract_factory):
    _, account_no_guardian, dapp = contract_factory
    sender = TransactionSender(account_no_guardian)

    # should call the dapp
    assert (await dapp.get_number(account_no_guardian.contract_address).call()).result.number == 0
    await sender.send_transaction([(dapp.contract_address, 'set_number', [47])], [signer])
    assert (await dapp.get_number(account_no_guardian.contract_address).call()).result.number == 47

    # should change the signer
    assert (await account_no_guardian.get_signer().call()).result.signer == (signer.public_key)
    await sender.send_transaction([(account_no_guardian.contract_address, 'change_signer', [new_signer.public_key])], [signer])
    assert (await account_no_guardian.get_signer().call()).result.signer == (new_signer.public_key)

    # should reverts calls that require the guardian to be set
    await assert_revert(
        sender.send_transaction([(account_no_guardian.contract_address, 'trigger_escape_guardian', [])], [new_signer]),
        "guardian must be set"
    )

    # should add a guardian
    assert (await account_no_guardian.get_guardian().call()).result.guardian == (0)
    await sender.send_transaction([(account_no_guardian.contract_address, 'change_guardian', [new_guardian.public_key])], [new_signer])
    assert (await account_no_guardian.get_guardian().call()).result.guardian == (new_guardian.public_key)

@pytest.mark.asyncio
async def test_multicall(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    # should reverts when one of the call is to the account
    await assert_revert(
        sender.send_transaction([(dapp.contract_address, 'set_number', [47]), (account.contract_address, 'trigger_escape_guardian', [])], [signer, guardian])
    )
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'trigger_escape_guardian', []), (dapp.contract_address, 'set_number', [47])], [signer, guardian])
    )

    # should call the dapp
    assert (await dapp.get_number(account.contract_address).call()).result.number == 0
    await sender.send_transaction([(dapp.contract_address, 'set_number', [47]), (dapp.contract_address, 'increase_number', [10])], [signer, guardian])
    assert (await dapp.get_number(account.contract_address).call()).result.number == 57

@pytest.mark.asyncio
async def test_change_signer(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    assert (await account.get_signer().call()).result.signer == (signer.public_key)

    # should revert with the wrong signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_signer', [new_signer.public_key])], [wrong_signer, guardian]),
        "signer signature invalid"
    )

    # should revert with the wrong guardian signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_signer', [new_signer.public_key])], [signer, wrong_guardian]),
        "guardian signature invalid"
    )

    # should work with the correct signers
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'change_signer', [new_signer.public_key])], [signer, guardian])
    
    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='signer_changed',
        data=[new_signer.public_key]
    )

    assert (await account.get_signer().call()).result.signer == (new_signer.public_key)

@pytest.mark.asyncio
async def test_change_guardian(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    assert (await account.get_guardian().call()).result.guardian == (guardian.public_key)

    # should revert with the wrong signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_guardian', [new_guardian.public_key])], [wrong_signer, guardian]),
        "signer signature invalid"
    )

    # should revert with the wrong guardian signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_guardian', [new_guardian.public_key])], [signer, wrong_guardian]),
        "guardian signature invalid"
    )

    # should work with the correct signers
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'change_guardian', [new_guardian.public_key])], [signer, guardian])
    
    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='guardian_changed',
        data=[new_guardian.public_key]
    )

    assert (await account.get_guardian().call()).result.guardian == (new_guardian.public_key)

@pytest.mark.asyncio
async def test_change_guardian_backup(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    # should revert with the wrong signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_guardian_backup', [new_guardian_backup.public_key])], [wrong_signer, guardian]),
        "signer signature invalid"
    )

    # should revert with the wrong guardian signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'change_guardian_backup', [new_guardian_backup.public_key])], [signer, wrong_guardian]),
        "guardian signature invalid"
    )

    # should work with the correct signers
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'change_guardian_backup', [new_guardian_backup.public_key])], [signer, guardian])
    
    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='guardian_backup_changed',
        data=[new_guardian_backup.public_key]
    )

    assert (await account.get_guardian_backup().call()).result.guardian_backup == (new_guardian_backup.public_key)

@pytest.mark.asyncio
async def test_change_guardian_backup_when_no_guardian(contract_factory):
    _, account_no_guardian, dapp = contract_factory
    sender = TransactionSender(account_no_guardian)

    await assert_revert(
        sender.send_transaction([(account_no_guardian.contract_address, 'change_guardian_backup', [new_guardian_backup.public_key])], [signer])
    )

@pytest.mark.asyncio
async def test_trigger_escape_guardian_by_signer(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0)

    tx_exec_info = await sender.send_transaction([(account.contract_address, 'trigger_escape_guardian', [])], [signer])
    
    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='escape_guardian_triggered',
        data=[DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD]
    )

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_GUARDIAN)

@pytest.mark.asyncio
async def test_trigger_escape_signer_by_guardian(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0)

    tx_exec_info = await sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [guardian])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='escape_signer_triggered',
        data=[DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD]
    )

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_SIGNER)

@pytest.mark.asyncio
async def test_trigger_escape_signer_by_guardian_backup(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    # set guardian backup
    await sender.send_transaction([(account.contract_address, 'change_guardian_backup', [guardian_backup.public_key])], [signer, guardian])
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0)

    tx_exec_info = await sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [0, guardian_backup])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='escape_signer_triggered',
        data=[DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD]
    )

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_SIGNER)

@pytest.mark.asyncio
async def test_escape_guardian(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)

    # reset block_timestamp
    reset_starknet_block(state=account.state)

    # trigger escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_guardian', [])], [signer])

    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_GUARDIAN)

    # should fail to escape before the end of the period
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'escape_guardian', [new_guardian.public_key])], [signer]),
        "escape is not valid"
    )

    # wait security period
    update_starknet_block(state=account.state, block_timestamp=(DEFAULT_TIMESTAMP+ESCAPE_SECURITY_PERIOD))

    # should escape after the security period
    assert (await account.get_guardian().call()).result.guardian == (guardian.public_key)
    
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'escape_guardian', [new_guardian.public_key])], [signer])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='guardian_escaped',
        data=[new_guardian.public_key]
    )

    assert (await account.get_guardian().call()).result.guardian == (new_guardian.public_key)

    # escape should be cleared
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0 and escape.type == 0)

@pytest.mark.asyncio
async def test_escape_signer(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    # trigger escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [guardian])
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_SIGNER)

    # should fail to escape before the end of the period
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'escape_signer', [new_signer.public_key])], [guardian]),
        "escape is not valid"
    )

    # wait security period
    update_starknet_block(state=account.state, block_timestamp=(DEFAULT_TIMESTAMP+ESCAPE_SECURITY_PERIOD))

    # should escape after the security period
    assert (await account.get_signer().call()).result.signer == (signer.public_key)
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'escape_signer', [new_signer.public_key])], [guardian])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='signer_escaped',
        data=[new_signer.public_key]
    )

    assert (await account.get_signer().call()).result.signer == (new_signer.public_key)

    # escape should be cleared
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0 and escape.type == 0)

@pytest.mark.asyncio
async def test_signer_overrides_trigger_escape_signer(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    # trigger escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [guardian])
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_SIGNER)

    # wait few seconds
    update_starknet_block(state=account.state, block_timestamp=(DEFAULT_TIMESTAMP+100))

    # signer overrides escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_guardian', [])], [signer])
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + 100 + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_GUARDIAN)

@pytest.mark.asyncio
async def test_guardian_overrides_trigger_escape_guardian(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    # trigger escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_guardian', [])], [signer])
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_GUARDIAN)

    # wait few seconds
    update_starknet_block(state=account.state, block_timestamp=(DEFAULT_TIMESTAMP+100))

    # guradian tries to override escape => should fail
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [guardian]),
        "cannot overrride signer escape"
    )


@pytest.mark.asyncio
async def test_cancel_escape(contract_factory):
    account, _, dapp = contract_factory
    sender = TransactionSender(account)
    
    # reset block_timestamp
    reset_starknet_block(state=account.state)

    # trigger escape
    await sender.send_transaction([(account.contract_address, 'trigger_escape_signer', [])], [guardian])
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == (DEFAULT_TIMESTAMP + ESCAPE_SECURITY_PERIOD) and escape.type == ESCAPE_TYPE_SIGNER)

    # should fail to cancel with only the signer
    await assert_revert(
        sender.send_transaction([(account.contract_address, 'cancel_escape', [])], [signer]),
        "guardian signature invalid"
    )

    # cancel escape
    tx_exec_info = await sender.send_transaction([(account.contract_address, 'cancel_escape', [])], [signer, guardian])

    assert_event_emmited(
        tx_exec_info,
        from_address=account.contract_address,
        name='escape_canceled',
        data=[]
    )

    # escape should be cleared
    escape = (await account.get_escape().call()).result
    assert (escape.active_at == 0 and escape.type == 0)

@pytest.mark.asyncio
async def test_is_valid_signature(contract_factory):
    account, _, dapp = contract_factory
    hash = 1283225199545181604979924458180358646374088657288769423115053097913173815464

    signatures = []
    for sig in [signer, guardian]:
        signatures += list(sig.sign(hash))
    
    res = (await account.is_valid_signature(hash, signatures).call()).result
    assert (res.is_valid == 1)