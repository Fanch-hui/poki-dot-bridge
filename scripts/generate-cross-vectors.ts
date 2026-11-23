import {
  canonicalDeviceMessage,
  canonicalPairMessage,
  ed25519KeyPairFromSeed,
  sha256Hex,
  signEd25519,
  verifyEd25519,
} from "../src/server/crypto.ts";

async function main() {
  const seed = Uint8Array.from({ length: 32 }, (_, i) => i);
  const kp = await ed25519KeyPairFromSeed(seed);
  const body = JSON.stringify({ wait_ms: 10000 });
  const bodySha256 = await sha256Hex(body);
  const deviceMsg = canonicalDeviceMessage({
    method: "POST",
    path: "/api/device/poll",
    timestamp: 1795334400,
    nonce: "vector-nonce-0001",
    bodySha256,
  });
  const deviceSig = await signEd25519(kp.privateKey, deviceMsg);
  const deviceOk = await verifyEd25519({
    publicKeyB64: kp.publicKeyB64,
    signatureB64: deviceSig,
    message: deviceMsg,
  });

  const codeHash = await sha256Hex("ABCD-EFGH-2345");
  const pairMsg = canonicalPairMessage({
    codeHash,
    label: kp.label,
    timestamp: 1795334400,
    nonce: "vector-pair-nonce-0001",
  });
  const pairSig = await signEd25519(kp.privateKey, pairMsg);
  const pairOk = await verifyEd25519({
    publicKeyB64: kp.publicKeyB64,
    signatureB64: pairSig,
    message: pairMsg,
  });

  console.log(
    JSON.stringify(
      {
        seedHex: Buffer.from(seed).toString("hex"),
        publicKeyB64: kp.publicKeyB64,
        label: kp.label,
        bodySha256,
        deviceSigB64: deviceSig,
        deviceVerified: deviceOk,
        codeHash,
        pairSigB64: pairSig,
        pairVerified: pairOk,
      },
      null,
      2,
    ),
  );
}

void main();
