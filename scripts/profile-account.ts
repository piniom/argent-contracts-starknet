import { CallData, uint256 } from "starknet";
import {
  Eip191KeyPair,
  EthKeyPair,
  LegacyStarknetKeyPair,
  Secp256r1KeyPair,
  StarknetKeyPair,
  WebauthnOwner,
  clearCache,
  deployAccount,
  deployAccountWithoutGuardian,
  deployOldAccount,
  deployOpenZeppelinAccount,
  getEthContract,
  provider,
  restart,
  setupSession,
} from "../tests-integration/lib";
import { newProfiler } from "../tests-integration/lib/gas";

const profiler = newProfiler(provider);
const fundingAmount = 2e16;
const maxFee = 1e16;

let privateKey: string;
if (provider.isDevnet) {
  // With the KeyPairs hardcoded, we gotta reset to avoid some issues
  await restart();
  privateKey = "0x1";
  clearCache();
} else {
  privateKey = new StarknetKeyPair().privateKey;
}

const ethContract = await getEthContract();
const recipient = "0xadbe1";
const amount = uint256.bnToUint256(1);
const starknetOwner = new StarknetKeyPair(privateKey);
const guardian = new StarknetKeyPair(42n);

{
  const { account } = await deployOldAccount();
  ethContract.connect(account);
  await profiler.profile("Old account", await ethContract.transfer(recipient, amount));
}

{
  const { account } = await deployAccount({
    owner: starknetOwner,
    guardian,
    salt: "0x2",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Account",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

{
  const { account } = await deployAccount({
    owner: starknetOwner,
    guardian,
    salt: "0x2",
    fundingAmount,
  });
  const allowedMethod = [{ "Contract Address": ethContract.address, selector: "transfer" }];
  const call = [ethContract.populateTransaction.transfer(recipient, amount)];
  console.log(Date.now());
  const sessionAccount = await setupSession(guardian, account, allowedMethod, BigInt(Date.now() + 10000));
  // await profiler.profile("Account with Session", await sessionAccount.execute(call));
}

{
  const { account } = await deployAccountWithoutGuardian({
    owner: starknetOwner,
    salt: "0x3",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Account w/o guardian",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

{
  const { account } = await deployOpenZeppelinAccount({ owner: new LegacyStarknetKeyPair(42n), salt: "0x1" });
  ethContract.connect(account);
  await profiler.profile("OZ account", await ethContract.transfer(recipient, amount));
}

{
  const { account } = await deployAccount({
    owner: new EthKeyPair(privateKey),
    guardian,
    salt: "0x4",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Eth sig w guardian",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

{
  const { account } = await deployAccount({
    owner: new Secp256r1KeyPair(privateKey),
    guardian,
    salt: "0x5",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Secp256r1 w guardian",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

{
  const { account } = await deployAccount({
    owner: new Eip191KeyPair(privateKey),
    guardian,
    salt: "0x6",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Eip161 with guardian",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

{
  const { account } = await deployAccount({
    owner: new WebauthnOwner(privateKey),
    guardian,
    salt: "0x7",
    fundingAmount,
  });
  ethContract.connect(account);
  await profiler.profile(
    "Webauthn w/o guardian",
    await ethContract.invoke("transfer", CallData.compile([recipient, amount]), { maxFee }),
  );
}

profiler.printSummary();
profiler.updateOrCheckReport();
