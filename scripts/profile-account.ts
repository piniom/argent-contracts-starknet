import {
  deployAccount,
  deployAccountWithoutGuardian,
  deployOldAccount,
  deployContract,
} from "../tests-integration/lib";
import { makeProfiler } from "../tests-integration/lib/gas";

const testDappContract = await deployContract("TestDapp");

const profiler = makeProfiler();

{
  const name = "Old Account";
  console.log(name);
  const { account } = await deployOldAccount();
  testDappContract.connect(account);
  await profiler.profile(name, await testDappContract.set_number(42));
}

{
  const name = "New Account";
  console.log(name);
  const { account } = await deployAccount();
  testDappContract.connect(account);
  await profiler.profile(name, await testDappContract.set_number(42));
}

{
  const name = "New Account without guardian";
  console.log(name);
  const { account } = await deployAccountWithoutGuardian();
  testDappContract.connect(account);
  await profiler.profile(name, await testDappContract.set_number(42));
}

profiler.printReport();
