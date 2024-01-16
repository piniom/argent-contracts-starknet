import {
  Account,
  ArraySignatureType,
  Call,
  InvocationsSignerDetails,
  RPC,
  V2InvocationsSignerDetails,
  ec,
  hash,
  selector,
  transaction,
  typedData,
} from "starknet";
import {
  KeyPair,
  OffChainSession,
  OutsideExecution,
  StarknetSig,
  getSessionTypedData,
  getTypedData,
  provider,
} from "./";

export class ArgentX {
  constructor(
    public account: Account,
    public backendService: BackendService,
  ) {}

  public async getOffchainSignature(sessionRequest: OffChainSession): Promise<ArraySignatureType> {
    const sessionTypedData = await getSessionTypedData(sessionRequest);
    return (await this.account.signMessage(sessionTypedData)) as ArraySignatureType;
  }
}

export class BackendService {
  constructor(private guardian: KeyPair) {}

  public async signTxAndSession(
    calls: Call[],
    transactionsDetail: InvocationsSignerDetails,
    sessionTokenToSign: OffChainSession,
  ): Promise<StarknetSig> {
    // verify session param correct

    // extremely simplified version of the backend verification
    const allowed_methods = sessionTokenToSign.allowed_methods;
    if (
      !calls.every((call) => {
        return allowed_methods.some(
          (method) =>
            method["Contract Address"] === call.contractAddress &&
            method.selector === selector.getSelectorFromName(call.entrypoint),
        );
      })
    ) {
      throw new Error("Call not allowed");
    }

    const compiledCalldata = transaction.getExecuteCalldata(calls, transactionsDetail.cairoVersion);
    let msgHash;
    if (Object.values(RPC.ETransactionVersion2).includes(transactionsDetail.version as any)) {
      const det = transactionsDetail as V2InvocationsSignerDetails;
      msgHash = hash.calculateInvokeTransactionHash({
        ...det,
        senderAddress: det.walletAddress,
        compiledCalldata,
        version: det.version,
      });
    } else if (Object.values(RPC.ETransactionVersion3).includes(transactionsDetail.version as any)) {
      throw Error("not implemented");
    } else {
      throw Error("unsupported signTransaction version");
    }

    const sessionMessageHash = typedData.getMessageHash(
      await getSessionTypedData(sessionTokenToSign),
      transactionsDetail.walletAddress,
    );
    const sessionWithTxHash = ec.starkCurve.pedersen(msgHash, sessionMessageHash);
    const [r, s] = this.guardian.signHash(sessionWithTxHash);
    return { r: BigInt(r), s: BigInt(s) };
  }

  public async signOutsideTxAndSession(
    calls: Call[],
    sessionTokenToSign: OffChainSession,
    accountAddress: string,
    outsideExecution: OutsideExecution,
  ): Promise<StarknetSig> {
    const currentTypedData = getTypedData(outsideExecution, await provider.getChainId());
    const messageHash = typedData.getMessageHash(currentTypedData, accountAddress);

    const sessionMessageHash = typedData.getMessageHash(await getSessionTypedData(sessionTokenToSign), accountAddress);
    const sessionWithTxHash = ec.starkCurve.pedersen(messageHash, sessionMessageHash);
    const [r, s] = this.guardian.signHash(sessionWithTxHash);
    return { r: BigInt(r), s: BigInt(s) };
  }

  public getGuardianKey(): bigint {
    return this.guardian.publicKey;
  }
}
