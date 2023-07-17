import { CallData, hash, num, uint256 } from "starknet";
import {
  ArgentSigner,
  ESCAPE_SECURITY_PERIOD,
  declareContract,
  deployAccount,
  deployer,
  expectEvent,
  getEthContract,
  increaseTime,
  provider,
  randomKeyPair,
  setTime,
  declareContractFixtures,
} from "./lib";

describe("ArgentAccount: events", function () {
  let argentAccountClassHash: string;

  before(async () => {
    argentAccountClassHash = await declareContract("ArgentAccount");
  });

  it("Expect 'AccountCreated(owner, guardian)' when deploying an account", async function () {
    const owner = "21";
    const guardian = "42";
    const constructorCalldata = CallData.compile({ owner, guardian });
    const { transaction_hash, contract_address } = await deployer.deployContract({
      classHash: argentAccountClassHash,
      constructorCalldata,
    });
    await expectEvent(transaction_hash, {
      from_address: contract_address,
      keys: ["AccountCreated", owner],
      data: [guardian],
    });
  });

  it("Expect 'EscapeOwnerTriggered(ready_at, new_owner)' on trigger_escape_owner", async function () {
    const { account, accountContract, guardian } = await deployAccount(argentAccountClassHash);
    account.signer = guardian;

    const newOwner = "42";
    const activeAt = num.toHex(42n + ESCAPE_SECURITY_PERIOD);
    await setTime(42);

    await expectEvent(() => accountContract.trigger_escape_owner(newOwner), {
      from_address: account.address,
      keys: ["EscapeOwnerTriggered"],
      data: [activeAt, newOwner],
    });
  });

  it("Expect 'OwnerEscaped(new_signer)' on escape_owner", async function () {
    const { account, accountContract, guardian } = await deployAccount(argentAccountClassHash);
    account.signer = guardian;

    const newOwner = "42";
    await setTime(42);

    await accountContract.trigger_escape_owner(newOwner);
    await increaseTime(ESCAPE_SECURITY_PERIOD);

    await expectEvent(() => accountContract.escape_owner(), {
      from_address: account.address,
      keys: ["OwnerEscaped"],
      data: [newOwner],
    });
  });

  it("Expect 'EscapeGuardianTriggered(ready_at, new_owner)' on trigger_escape_guardian", async function () {
    const { account, accountContract, owner } = await deployAccount(argentAccountClassHash);
    account.signer = owner;

    const newGuardian = "42";
    const activeAt = num.toHex(42n + ESCAPE_SECURITY_PERIOD);
    await setTime(42);

    await expectEvent(() => accountContract.trigger_escape_guardian(newGuardian), {
      from_address: account.address,
      keys: ["EscapeGuardianTriggered"],
      data: [activeAt, newGuardian],
    });
  });

  it("Expect 'GuardianEscaped(new_signer)' on escape_guardian", async function () {
    const { account, accountContract, owner } = await deployAccount(argentAccountClassHash);
    account.signer = owner;
    const newGuardian = "42";
    await setTime(42);

    await accountContract.trigger_escape_guardian(newGuardian);
    await increaseTime(ESCAPE_SECURITY_PERIOD);

    await expectEvent(() => accountContract.escape_guardian(), {
      from_address: account.address,
      keys: ["GuardianEscaped"],
      data: [newGuardian],
    });
  });

  it("Expect 'OwnerChanged(new_signer)' on change_owner", async function () {
    const { accountContract, owner } = await deployAccount(argentAccountClassHash);

    const newOwner = randomKeyPair();
    const changeOwnerSelector = hash.getSelectorFromName("change_owner");
    const chainId = await provider.getChainId();
    const contractAddress = accountContract.address;

    const msgHash = hash.computeHashOnElements([changeOwnerSelector, chainId, contractAddress, owner.publicKey]);
    const [r, s] = newOwner.signHash(msgHash);

    await expectEvent(() => accountContract.change_owner(newOwner.publicKey, r, s), {
      from_address: accountContract.address,
      keys: ["OwnerChanged"],
      data: [newOwner.publicKey.toString()],
    });
  });

  it("Expect 'GuardianChanged(new_guardian)' on change_guardian", async function () {
    const { accountContract } = await deployAccount(argentAccountClassHash);

    const newGuardian = "42";

    await expectEvent(() => accountContract.change_guardian(newGuardian), {
      from_address: accountContract.address,
      keys: ["GuardianChanged"],
      data: [newGuardian],
    });
  });

  it("Expect 'GuardianBackupChanged(new_guardian_backup)' on change_guardian_backup", async function () {
    const { accountContract } = await deployAccount(argentAccountClassHash);

    const newGuardianBackup = "42";

    await expectEvent(() => accountContract.change_guardian_backup(newGuardianBackup), {
      from_address: accountContract.address,
      keys: ["GuardianBackupChanged"],
      data: [newGuardianBackup],
    });
  });

  it("Expect 'AccountUpgraded(new_implementation)' on upgrade", async function () {
    const { account, accountContract } = await deployAccount(argentAccountClassHash);
    const argentAccountFutureClassHash = await declareContractFixtures("ArgentAccountFutureVersion");

    await expectEvent(
      () => account.execute(accountContract.populateTransaction.upgrade(argentAccountFutureClassHash, ["0"])),
      {
        from_address: account.address,
        keys: ["AccountUpgraded"],
        data: [argentAccountFutureClassHash],
      },
    );
  });

  describe("Expect 'EscapeCanceled()'", function () {
    it("Expected on cancel_escape", async function () {
      const { account, accountContract, owner, guardian } = await deployAccount(argentAccountClassHash);
      account.signer = owner;

      await accountContract.trigger_escape_guardian(42);

      account.signer = new ArgentSigner(owner, guardian);
      await expectEvent(() => accountContract.cancel_escape(), {
        from_address: account.address,
        keys: ["EscapeCanceled"],
        data: [],
      });
    });

    it("Expected on trigger_escape_owner", async function () {
      const { account, accountContract, guardian } = await deployAccount(argentAccountClassHash);
      account.signer = guardian;

      await accountContract.trigger_escape_owner(42);

      await expectEvent(() => accountContract.trigger_escape_owner(42), {
        from_address: account.address,
        keys: ["EscapeCanceled"],
        data: [],
      });
    });

    it("Expected on trigger_escape_guardian", async function () {
      const { account, accountContract, owner } = await deployAccount(argentAccountClassHash);
      account.signer = owner;

      await accountContract.trigger_escape_guardian(42);

      await expectEvent(() => accountContract.trigger_escape_guardian(42), {
        from_address: account.address,
        keys: ["EscapeCanceled"],
        data: [],
      });
    });
  });

  describe("Expect 'TransactionExecuted(transaction_hash, retdata)' on multicall", function () {
    it("Expect ret data to contain one array with one element when making a simple transaction", async function () {
      const { account } = await deployAccount(argentAccountClassHash);
      const ethContract = await getEthContract();
      ethContract.connect(account);

      const recipient = "42";
      const amount = uint256.bnToUint256(1000);
      const first_retdata = [1];
      const { transaction_hash } = await ethContract.transfer(recipient, amount);
      await expectEvent(transaction_hash, {
        from_address: account.address,
        keys: ["TransactionExecuted", transaction_hash],
        data: CallData.compile([[first_retdata]]),
      });
    });

    it("Expect retdata to contain multiple data when making a multicall transaction", async function () {
      const { account } = await deployAccount(argentAccountClassHash);
      const ethContract = await getEthContract();
      ethContract.connect(account);

      const recipient = "0x33";
      const amount = 10n;

      const { balance: balanceUint256 } = await ethContract.balanceOf(recipient);
      const balance = uint256.uint256ToBN(balanceUint256);

      const finalBalance = uint256.bnToUint256(balance + amount);
      const firstReturn = [1];
      const secondReturn = [finalBalance.low, finalBalance.high];

      const { transaction_hash } = await account.execute([
        ethContract.populateTransaction.transfer(recipient, uint256.bnToUint256(amount)),
        ethContract.populateTransaction.balanceOf(recipient),
      ]);
      await expectEvent(transaction_hash, {
        from_address: account.address,
        keys: ["TransactionExecuted", transaction_hash],
        data: CallData.compile([[firstReturn, secondReturn]]),
      });
    });
    // TODO Could add some more tests regarding multicall later
  });
});
