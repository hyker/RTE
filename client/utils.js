import { CertificateChainValidationEngine } from "pkijs";

// Use globalThis.crypto which works in both modern Node.js (v15+) and browsers
const crypto = globalThis.crypto;

export const toText = (uint8Array) => {
  return new TextDecoder().decode(uint8Array);
};

export const toBase64 = (uint8Array) => {
  // Browser-compatible base64 encoding
  if (typeof Buffer === 'undefined') {
    // Browser environment
    let binary = '';
    const len = uint8Array.byteLength;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(uint8Array[i]);
    }
    return btoa(binary);
  }
  // Node.js
  return Buffer.from(uint8Array).toString("base64");
}

// Returns zero bytes on bad base64.
export const fromBase64 = (base64Text) => {
  base64Text += "=".repeat(3 - (base64Text.length + 3) % 4);
  if (!/^([0-9a-zA-Z+/]{4})*(([0-9a-zA-Z+/]{2}==)|([0-9a-zA-Z+/]{3}=))?$/.test(base64Text)) {
    return new Uint8Array(0);
  }

  // Browser environment
  if (typeof Buffer === 'undefined') {
    const binary = atob(base64Text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  // Node.js
  const buf = Buffer.from(base64Text, "base64");
  const length = buf.length / Uint8Array.BYTES_PER_ELEMENT;
  return new Uint8Array(buf.buffer, buf.byteOffset, length);
}

export const eqByteArr = (a, b) => {
  if (a === b) {
    return true;
  }
  if (a.byteLength !== b.byteLength) {
    return false;
  }
  if (a.byteLength === 0) {
    return true;
  }
  // if few elements, then just checking each byte is faster
  if (a.byteLength < 1000) {
    let i = a.byteLength;
    while (i--) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }
  // check the remining bytes
  for (let i = 1; i <= a.byteLength % 4; i++) {
    if (a[a.length - i] !== b[b.length - i]) {
      return false;
    }
  }
  if (a.byteLength < 4) {
    return true;
  }
  // then check the rest four bytes at a time
  let a32 = new Uint32Array(
    a.buffer,
    a.byteOffset,
    Math.floor(a.byteLength / 4),
  );
  let b32 = new Uint32Array(
    b.buffer,
    b.byteOffset,
    Math.floor(b.byteLength / 4),
  );
  let i = a32.length;
  while (i--) {
    if (a32[i] !== b32[i]) {
      return false;
    }
  }
  return true;
};

export const joinByteArrays = (arrays) => {
  let length = 0;
  let offset = 0;
  for (const array of arrays) {
    length += array.length;
  }
  const joined = new Uint8Array(length);
  for (const array of arrays) {
    joined.set(array, offset);
    offset += array.length;
  }
  return joined;
};

export const sha256 = async (bytes) => {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}


export const importPublicECDSAKey = async (
  keyData, //: Uint8Array | JsonWebKey,
  format //: "raw" | "jwk" | "spki",
) => {
  const keyUsages = ["verify"];
  const extractable = true;
  const algorithm = {
    name: "ECDSA",
    namedCurve: "P-256",
  };
  return await importPublicKey(
    keyData,
    format,
    extractable,
    algorithm,
    keyUsages,
  );
};

export const importPublicKey = async (
  keyData, //: Uint8Array | JsonWebKey,
  format, //: "raw" | "jwk" | "spki",
  extractable, //: boolean,
  algorithm, //: EcKeyImportParams,
  keyUsages, //: KeyUsages,
) => {
  try {
    if (format === "jwk") {
      if (keyData instanceof Uint8Array) {
        return new Error("Format is jwk but KeyData is not JsonWebKey.");
      }
      return await crypto.subtle.importKey(
        "jwk",
        keyData,
        algorithm,
        extractable,
        keyUsages,
      );
    } else {
      if (!(keyData instanceof Uint8Array)) {
        return new Error("Format is not jwk but KeyData is not Uint8Array.");
      }
      if (format === "raw" && (keyData.length !== 65 || keyData[0] !== 0x04)) {
        return new Error("Compressed public keys are not supported.");
      }
      return await crypto.subtle.importKey(
        format,
        keyData,
        algorithm,
        extractable,
        keyUsages,
      );
    }
  } catch (e) {
    if (e instanceof Error) {
      return e;
    } else if (e instanceof DOMException) {
      return new Error(e.message);
    } else {
      return new Error(String(e));
    }
  }
};

export const verifySignature = async (
  publicKey, //: CryptoKey,
  signature, //: Uint8Array,
  data, //: Uint8Array,
) => {
  try {
    const result = await crypto.subtle.verify(
      {
        name: "ECDSA",
        hash: { name: "SHA-256" },
      },
      publicKey,
      signature,
      data,
    );
    if (result !== true) {
      return new Error("Could not verify signature.");
    }
    return true;
  } catch (e) {
    if (e instanceof Error) {
      return e;
    } else if (e instanceof DOMException) {
      return new Error(e.message);
    } else {
      return new Error(String(e));
    }
  }
};


export const validateCertificateChain = async (
  trustedCerts, //: Certificate[],
  certificateChain, //: Certificate[],
) => {
  const res = await new CertificateChainValidationEngine({ trustedCerts, certs: [...certificateChain] }).verify();
  if (res?.result !== true) {
    return new Error("Could not validate certificate chain.");
  }
  return res;
}
