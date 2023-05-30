import { expect } from "chai";
import { CallData, Contract } from "starknet";
import {
  MultisigSigner,
  declareContract,
  deployer,
  expectEvent,
  expectRevertWithErrorMessage,
  loadContract,
} from "./lib";
import { deployMultisig } from "./lib/multisig";

describe("ArgentMultisig: Execute", function () {
  let multisigAccountClassHash: string;
  let testDappContract: Contract;

  before(async () => {
    multisigAccountClassHash = await declareContract("ArgentMultisig");
    const testDappClassHash = await declareContract("TestDapp");
    const { contract_address } = await deployer.deployContract({
      classHash: testDappClassHash,
    });
    testDappContract = await loadContract(contract_address);
  });

  it("Should be able to execute a transaction using one owner when (signer_list = 1, threshold = 1)", async function () {
    const threshold = 1;
    const signersLength = 1;

    const { account } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

    const initalNumber = await testDappContract.get_number(account.address);
    expect(initalNumber).to.equal(0n);

    testDappContract.connect(account);
    const { transaction_hash } = await testDappContract.set_number(42);
    const response = await account.waitForTransaction(transaction_hash);

    const finalNumber = await testDappContract.get_number(account.address);
    expect(finalNumber).to.equal(42n);

    await expectEvent(response, {
      from_address: account.address,
      keys: ["TransactionExecuted"],
      data: CallData.compile([response.transaction_hash, [[finalNumber]]]),
    });
  });

  it("Should be able to execute a transaction using one owner when (signer_list > 1, threshold = 1) ", async function () {
    const threshold = 1;
    const signersLength = 3;

    const { account, keys } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

    account.signer = new MultisigSigner(keys.slice(0, 1));

    testDappContract.connect(account);
    const { transaction_hash } = await testDappContract.set_number(42);
    await account.waitForTransaction(transaction_hash);

    const finalNumber = await testDappContract.get_number(account.address);
    expect(finalNumber).to.equal(42n);
  });

  it("Should be able to execute a transaction using multiple owners when (signer_list > 1, threshold > 1)", async function () {
    const threshold = 3;
    const signersLength = 5;

    const { account, keys } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

    account.signer = new MultisigSigner(keys.slice(0, 3));

    testDappContract.connect(account);
    const { transaction_hash } = await testDappContract.set_number(42);
    await account.waitForTransaction(transaction_hash);

    const finalNumber = await testDappContract.get_number(account.address);
    expect(finalNumber).to.equal(42n);
  });

  it("Should be able to execute multiple transactions using multiple owners when (signer_list > 1, threshold > 1)", async function () {
    const threshold = 3;
    const signersLength = 5;

    const { account, keys } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

    account.signer = new MultisigSigner(keys.slice(0, 3));
    const calls = await account.execute([
      testDappContract.populateTransaction.increase_number(2),
      testDappContract.populateTransaction.increase_number(40),
    ]);

    await account.waitForTransaction(calls.transaction_hash);

    const finalNumber = await testDappContract.get_number(account.address);
    expect(finalNumber).to.equal(42n);
  });

  it("Expect 'argent/signatures-not-sorted' when tx signed in incorrect/repeated order (signer_list > 1, threshold > 1)", async function () {
    const threshold = 3;
    const signersLength = 5;

    const { account, keys } = await deployMultisig(multisigAccountClassHash, threshold, signersLength);

    testDappContract.connect(account);

    // change order of signers
    const wrongSignerOrder = [keys[1], keys[3], keys[0]];
    account.signer = new MultisigSigner(wrongSignerOrder);

    await expectRevertWithErrorMessage(
      "argent/signatures-not-sorted",
      async () => await testDappContract.set_number(42),
    );

    // repeated signers
    const repeatedSigners = [keys[0], keys[0], keys[1]];
    account.signer = new MultisigSigner(repeatedSigners);

    await expectRevertWithErrorMessage(
      "argent/signatures-not-sorted",
      async () => await testDappContract.set_number(42),
    );
  });
});
