// https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/Intel_TDX_DCAP_Quoting_Library_API.pdf

import { fromBER } from "asn1js";
import { CertificateRevocationList, Certificate } from "pkijs";
import {
  importPublicECDSAKey,
  verifySignature,
  validateCertificateChain,
  fromBase64,
  toBase64,
  sha256,
  joinByteArrays,
  eqByteArr,
  toText
} from "./utils.js";

const INTEL_ROOT_CA = `-----BEGIN CERTIFICATE-----
MIICjzCCAjSgAwIBAgIUImUM1lqdNInzg7SVUr9QGzknBqwwCgYIKoZIzj0EAwIw
aDEaMBgGA1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENv
cnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJ
BgNVBAYTAlVTMB4XDTE4MDUyMTEwNDExMVoXDTMzMDUyMTEwNDExMFowaDEaMBgG
A1UEAwwRSW50ZWwgU0dYIFJvb3QgQ0ExGjAYBgNVBAoMEUludGVsIENvcnBvcmF0
aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0ExCzAJBgNVBAYT
AlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEC6nEwMDIYZOj/iPWsCzaEKi7
1OiOSLRFhWGjbnBVJfVnkY4u3IjkDYYL0MxO4mqsyYjlBalTVYxFP2sJBK5zlKOB
uzCBuDAfBgNVHSMEGDAWgBQiZQzWWp00ifODtJVSv1AbOScGrDBSBgNVHR8ESzBJ
MEegRaBDhkFodHRwczovL2NlcnRpZmljYXRlcy50cnVzdGVkc2VydmljZXMuaW50
ZWwuY29tL0ludGVsU0dYUm9vdENBLmNybDAdBgNVHQ4EFgQUImUM1lqdNInzg7SV
Ur9QGzknBqwwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYBAf8CAQAwCgYI
KoZIzj0EAwIDSQAwRgIhAIpQ/KlO1XE4hH8cw5Ol/E0yzs8PToJe9Pclt+bhfLUg
AiEAss0qf7FlMmAMet+gbpLD97ldYy/wqjjmwN7yHRVr2AM=
-----END CERTIFICATE-----`;

// Intel Root CA CRL (DER, base64-encoded). Updated yearly by Intel;
// refresh from https://certificates.trustedservices.intel.com/IntelSGXRootCA.crl
// Current: lastUpdate=Feb 26 2026, nextUpdate=Feb 26 2027
const INTEL_ROOT_CA_CRL_B64 = "MIIBIjCByAIBATAKBggqhkjOPQQDAjBoMRowGAYDVQQDDBFJbnRlbCBTR1ggUm9vdCBDQTEaMBgGA1UECgwRSW50ZWwgQ29ycG9yYXRpb24xFDASBgNVBAcMC1NhbnRhIENsYXJhMQswCQYDVQQIDAJDQTELMAkGA1UEBhMCVVMXDTI2MDIyNjEzMDQwMFoXDTI3MDIyNjEzMDQwMFqgLzAtMAoGA1UdFAQDAgEBMB8GA1UdIwQYMBaAFCJlDNZanTSJ84O0lVK/UBs5JwasMAoGCCqGSM49BAMCA0kAMEYCIQDCUu1Zx5W6KxFJakqZdYu4y8OAoeu7CGW+afLEs4u2QAIhAJp9iwNgKp7i1iMi11kWbWkz0k2d+gGrP95FIGkdcVvX";

const INTEL_SGX_PCK_CERTIFICATE = `-----BEGIN CERTIFICATE-----
MIICljCCAj2gAwIBAgIVAJVvXc29G+HpQEnJ1PQzzgFXC95UMAoGCCqGSM49BAMC
MGgxGjAYBgNVBAMMEUludGVsIFNHWCBSb290IENBMRowGAYDVQQKDBFJbnRlbCBD
b3Jwb3JhdGlvbjEUMBIGA1UEBwwLU2FudGEgQ2xhcmExCzAJBgNVBAgMAkNBMQsw
CQYDVQQGEwJVUzAeFw0xODA1MjExMDUwMTBaFw0zMzA1MjExMDUwMTBaMHAxIjAg
BgNVBAMMGUludGVsIFNHWCBQQ0sgUGxhdGZvcm0gQ0ExGjAYBgNVBAoMEUludGVs
IENvcnBvcmF0aW9uMRQwEgYDVQQHDAtTYW50YSBDbGFyYTELMAkGA1UECAwCQ0Ex
CzAJBgNVBAYTAlVTMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAENSB/7t21lXSO
2Cuzpxw74eJB72EyDGgW5rXCtx2tVTLq6hKk6z+UiRZCnqR7psOvgqFeSxlmTlJl
eTmi2WYz3qOBuzCBuDAfBgNVHSMEGDAWgBQiZQzWWp00ifODtJVSv1AbOScGrDBS
BgNVHR8ESzBJMEegRaBDhkFodHRwczovL2NlcnRpZmljYXRlcy50cnVzdGVkc2Vy
dmljZXMuaW50ZWwuY29tL0ludGVsU0dYUm9vdENBLmRlcjAdBgNVHQ4EFgQUlW9d
zb0b4elAScnU9DPOAVcL3lQwDgYDVR0PAQH/BAQDAgEGMBIGA1UdEwEB/wQIMAYB
Af8CAQAwCgYIKoZIzj0EAwIDRwAwRAIgXsVki0w+i6VYGW3UF/22uaXe0YJDj1Ue
nA+TjD1ai5cCICYb1SAmD5xkfTVpvo4UoyiSYxrDWLmUR4CI9NKyfPN+
-----END CERTIFICATE-----`;

const INTEL_QUOTE_VERSION = 4;
const ECDSA_256_SIGNATURE_TYPE= 2;
const OE_SGX_PCK_ID_PCK_CERT_CHAIN = 5;
const CERT_DATA_TYPE_QE_REPORT_CERTIFICATION_DATA = 6;
const ENCLAVE_TYPE_TDX = 0x81;

const crls = {};

const checkCRLValidity = (name) => {
  const crl = crls[name];
  if (!crl) {
    return false;
  }
  const nextUpdateValue = crl.nextUpdate?.value;
  if (!nextUpdateValue || new Date(nextUpdateValue).getTime() < new Date().getTime()) {
    return false;
  }
  return true;
};

const checkCRL = async (name, pem, url, preloadedCRLData) => {
  if (!checkCRLValidity(name)) {
    let crlData;
    if (preloadedCRLData) {
      crlData = preloadedCRLData;
    } else {
      crlData = new Uint8Array(await (await fetch(url)).arrayBuffer());
    }
    crls[name] = new CertificateRevocationList({
      schema: fromBER(crlData).result,
    });
  }

  const certificate = importPEM(pem);
  if (certificate instanceof Error) {
    return certificate;
  }

  const crl = crls[name];
  if (!crl) {
    return new Error("CRL is not available");
  }

  const verified = await crl.verify({ issuerCertificate: certificate });
  if (!verified) {
    return new Error("Could not verify CRL signature");
  }

  return certificate;
};

const importPEM = (pem) => {
  if (typeof pem !== "string") {
    return new Error(`Certificate.importPEM expects a string. (got ${pem})`);
  }

  const berString = pem.match(
    /(?:-+BEGIN CERTIFICATE-+)([\s\S]+?)(?:-+END CERTIFICATE-+)/i
  );
  if (!berString) {
    return new Error("Bad PEM.");
  }

  const berData = fromBase64(berString[1].replace(/\s/g, ""));

  return new Certificate({
    schema: fromBER(berData).result,
  });
};

async function parseSignature(seeker) {
  // u8[32] r
  // u8[32] s

  // See https://tools.ietf.org/html/rfc3278#section-8.2 for more information.

  const r = seeker.extract(32);
  if (r instanceof Error) {
    return r;
  }
  const s = seeker.extract(32);
  if (s instanceof Error) {
    return s;
  }

  return joinByteArrays([r, s]);
}

async function parsePublicECDSAKey(seeker) {
  // u8[32] x
  // u8[32] y

  const x = seeker.extract(32);
  if (x instanceof Error) {
    return x;
  }
  const y = seeker.extract(32);
  if (y instanceof Error) {
    return y;
  }

  const key = await importPublicECDSAKey(
    joinByteArrays([new Uint8Array([0x04]), x, y]),
    "raw"
  );
  if (key instanceof Error) {
    return key;
  }
  return {
    key,
    raw: joinByteArrays([x, y]),
  };
}

function parseQuoteHeader(data) {
  // https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/Intel_TDX_DCAP_Quoting_Library_API.pdf
  // A.3.1. TD Quote Header
  const seeker = new Seeker(data);
  const version = seeker.extractLEU16();
  if (version instanceof Error) { return version; }
  const attestationType = seeker.extractLEU16();
  if (attestationType instanceof Error) { return attestationType; }
  const teeType = seeker.extractLEU32();
  if (teeType instanceof Error) { return teeType; }
  /* reserved */ seeker.skip(4);
  const qeVendorID = seeker.extract(16);
  if (qeVendorID instanceof Error) { return qeVendorID; }
  const userData = seeker.extract(20);
  if (userData instanceof Error) { return userData; }
  return {
      version,
      attestationType,
      teeType,
      qeVendorID,
      userData,
  };
}

function parseQuoteBody(data) {
  // https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/Intel_TDX_DCAP_Quoting_Library_API.pdf
  // A.3.2. TD Quote Body Descriptor
  const seeker = new Seeker(data);
  const teeTcbSvn = seeker.extract(16);
  if (teeTcbSvn instanceof Error) { return teeTcbSvn; }
  const mrSEAM = seeker.extract(48);
  if (mrSEAM instanceof Error) { return mrSEAM; }
  const mrSignerSEAM = seeker.extract(48);
  if (mrSignerSEAM instanceof Error) { return mrSignerSEAM; }
  const seamAttributes = seeker.extractLEU64();            
  if ( seamAttributes instanceof Error) { return seamAttributes; } 
  const tdAttributes = seeker.extractLEU64(); 
  if (  tdAttributes instanceof Error) { return tdAttributes; }   
  const xfam = seeker.extractLEU64(); 
  if (  xfam instanceof Error) { return xfam; }   
  const mrTd = seeker.extract(48); 
  if (  mrTd instanceof Error) { return mrTd; }   
  const mrConfigId= seeker.extract(48); 
  if (  mrConfigId instanceof Error) { return mrConfigId; }   
  const mrOwner= seeker.extract(48); 
  if (  mrOwner instanceof Error) { return mrOwner; }   
  const mrOwnerConfig= seeker.extract(48); 
  if (  mrOwnerConfig instanceof Error) { return mrOwnerConfig; }   
  const RTMR0 = seeker.extract(48); 
  if (  RTMR0 instanceof Error) { return RTMR0; }   
  const RTMR1 = seeker.extract(48); 
  if (  RTMR1 instanceof Error) { return RTMR1; }   
  const RTMR2 = seeker.extract(48); 
  if (  RTMR2 instanceof Error) { return RTMR2; }   
  const RTMR3 = seeker.extract(48); 
  if (  RTMR3 instanceof Error) { return RTMR3; }   
  const reportData = seeker.extract(64); 
  if (  reportData instanceof Error) { return reportData; }   

  return {
    teeTcbSvn,
    mrSEAM,
    mrSignerSEAM,
    seamAttributes,
    tdAttributes: {
      debug: tdAttributes & 0x1,
      reservedTUD: (tdAttributes >> 1) & 0x7F,
      reservedSEC: (tdAttributes >> 8) & 0xFFFFF,
      septVeDisable: (tdAttributes >> 28) & 0x1,
      reservedSEC2: (tdAttributes >> 29) & 0x1,
      PKS: (tdAttributes >> 30) & 0x1,
      KL: (tdAttributes >> 31) & 0x1,
      otherReserved: Number((BigInt(tdAttributes)>> 32n) & 0x7FFFFFFFn),
      otherPerfMon: Number((BigInt(tdAttributes)>> 63n) & 0x1n),
    },
    xfam,
    mrTd,
    mrConfigId,
    mrOwner,
    mrOwnerConfig,
    RTMR0,
    RTMR1,
    RTMR2,
    RTMR3,
    reportData,
  };
}

function parseEnclaveReportBody(data) { //A.3.10
  const seeker = new Seeker(data);
  const cpuSvn = seeker.extract(16);
  if (cpuSvn instanceof Error) { return cpuSvn; }
  const miscSelect = seeker.extractLEU32();
  if (miscSelect instanceof Error) { return miscSelect; }
  /* reserved */ seeker.skip(28);
  const attributes = seeker.extract(16);
  if (attributes instanceof Error) { return attributes; }
  const mrEnclave = seeker.extract(32);
  if (mrEnclave instanceof Error) { return mrEnclave; }
  /* reserved */ seeker.skip(32);
  const mrSigner = seeker.extract(32);
  if (mrSigner instanceof Error) { return mrSigner; }
  /* reserved */ seeker.skip(96);
  const isvProdId = seeker.extractLEU16();
  if (isvProdId instanceof Error) { return isvProdId; }
  const isvSvn = seeker.extractLEU16();
  if (isvSvn instanceof Error) { return isvSvn; }
  /* reserved */ seeker.skip(60);
  const reportData = seeker.extract(64);
  if (reportData instanceof Error) { return reportData; }

  return {
    cpuSvn,
    miscSelect,
    attributes,
    mrEnclave,
    mrSigner,
    isvProdId,
    isvSvn,
    reportData,
  };
}

function parseQEReportCertificationDataStructure(data) { //A.3.11
  const seeker = new Seeker(data);
  const qeReportDataRaw = seeker.extract(384)
  if (qeReportDataRaw instanceof Error) { return qeReportDataRaw; }
  const qeReportData = parseEnclaveReportBody(qeReportDataRaw) //A.3.10
  const qeReportSignature = seeker.extract(64) //A.3.5
  if (qeReportSignature instanceof Error) { return qeReportSignature; }
  const qeAuthDataSize = seeker.extractLEU16() //A.3.7 (inlined in parsing A.3.11 since the size fiels is part of the A.3.7 struct itself)
  if (qeAuthDataSize instanceof Error) { return qeAuthDataSize; }
  const qeAuthData = seeker.extract(qeAuthDataSize)
  if (qeAuthData instanceof Error) { return qeAuthData; }
  const innerQeCertDataBlock = seeker.extract(seeker.remaining) // TODO safety check remaining size
  if (innerQeCertDataBlock instanceof Error) { return innerQeCertDataBlock; }
  const innerQeCertData = parseQECertificationDataStructure(innerQeCertDataBlock, 5)
  return {
    qeReportData,
    qeReportDataRaw,
    qeReportSignature,
    qeAuthData,
    innerQeCertData
  }
}

function parsePCKCertChain(chain) {
  const certificateStringChain = toText(chain).match(/(-+BEGIN CERTIFICATE-+[\s\S]+?-+END CERTIFICATE-+)/g);
  if (!certificateStringChain) {
    return Error(`Bad certificate chain.`);
  }
  const certificateChain = [];
  for (const certificateString of certificateStringChain) {
    const certificate = importPEM(certificateString);
    if (certificate instanceof Error) {
      return certificate;
    }
    certificateChain.push(certificate);
  }
  return certificateChain;
}

function parseQECertificationDataStructure(data, expectedType) { // A.3.9
  const seeker = new Seeker(data);
  const certDataType = seeker.extractLEU16()
  if (certDataType instanceof Error) {
    return certDataType;
  }
  const certDataLength = seeker.extractLEU32()
  if (certDataLength instanceof Error) {
    return certDataLength;
  }
  if (seeker.remaining != certDataLength) { 
    return new Error(`Error, bad cert data length.${seeker.remaining} ${certDataLength}`);
  }
  if (certDataType != expectedType) { 
    return new Error("certification data type not supported");
  }
  const qeReportCertDataBlock = seeker.extract(certDataLength) 
  if (qeReportCertDataBlock instanceof Error) {
    return qeReportCertDataBlock;
  } else if (certDataType == 6) {
    return {
      certDataType,
      certData: parseQEReportCertificationDataStructure(qeReportCertDataBlock),
    };
  } else if (certDataType == 5) {
    return {
      certDataType,
      certData: parsePCKCertChain(qeReportCertDataBlock),
    };
  } else {
    return new Error("Cert Data Type not expected");
  }
}

function parseQuoteSignature(data) {
  // https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/Intel_TDX_DCAP_Quoting_Library_API.pdf
  // A.3.8 ECDSA 256-bit Quote Signature Data Structure – Version 4
  const seeker = new Seeker(data);
  const quoteSignature = seeker.extract(64)
  if (quoteSignature instanceof Error) { return quoteSignature; }
  const pubAttestKeyQE = seeker.extract(64)
  if (pubAttestKeyQE instanceof Error) { return pubAttestKeyQE; }
  const qeCertDataBlock = seeker.extract(seeker.remaining);
  if (qeCertDataBlock instanceof Error) { return qeCertDataBlock; }
  const qeCertificationData = parseQECertificationDataStructure(qeCertDataBlock, 6) //6 for outer struct
  return {
      quoteSignature,
      pubAttestKeyQE,
      qeCertificationData,
  };
}

async function parseQuote(data) {
  // https://download.01.org/intel-sgx/latest/dcap-latest/linux/docs/Intel_TDX_DCAP_Quoting_Library_API.pdf
  // A.3. Version 4 Quote Format
  const seeker = new Seeker(data);

  const headerRaw = seeker.extract(48);
  if (headerRaw instanceof Error) { return headerRaw; }
  const header = parseQuoteHeader(headerRaw);

  if (header.version !== 4) {
    return Error("Only version 4 is supported.");
  }

  const bodyRaw = seeker.extract(584);
  if (bodyRaw instanceof Error) { return bodyRaw; }
  const body = parseQuoteBody(bodyRaw);

  const signatureLength = seeker.extractLEU32();
  if (signatureLength instanceof Error) { return signatureLength; }
  const signatureRaw = seeker.extract(signatureLength)
  if (signatureRaw instanceof Error) { return signatureRaw; }
  const signature = parseQuoteSignature(signatureRaw);

  return {
    header,
    body,
    signature,
  }
}

async function checkHeader(header) {
  if (header.version != INTEL_QUOTE_VERSION) {
    return Error(
      `Unexpected quote version ${header.version}. Expected ${INTEL_QUOTE_VERSION}.`
    );
  }
  if (header.attestationType != ECDSA_256_SIGNATURE_TYPE) {
    return Error(
      `Unexpected signature type ${header.attestationType}. Expected ${ECDSA_256_SIGNATURE_TYPE}.`
    );
  }
  if (header.teeType != ENCLAVE_TYPE_TDX) {
    return Error(
      `Unexpected enclave type ${header.teeType}. Expected ${ENCLAVE_TYPE_TDX}.`
    );
  }

  // TODO check user data also?
}


async function checkBody(body, expectedRTMR2) {
  if (!expectedRTMR2) {
    return new Error('Expected RTMR2 not set — build pipeline must record RTMR2 before building the client');
  }
  const rtmr2Hex = Array.from(body.RTMR2)
    .map(b => b.toString(16).padStart(2, '0'))
    .join('');
  if (rtmr2Hex !== expectedRTMR2.toLowerCase()) {
    return new Error(`RTMR2 mismatch: expected ${expectedRTMR2}, got ${rtmr2Hex}`);
  }
}

async function checkSignature(signature) {
  // Extract the PCK certificate chain from the signature data structure
  const certChain = signature.qeCertificationData?.certData?.innerQeCertData?.certData;
  if (!certChain) {
    return new Error("PCK certificate chain not found in signature");
  }

  // Check the PCK Cert (signature chain).
  const intelSgxRootCA = importPEM(INTEL_ROOT_CA);
  const pckCAcert = importPEM(INTEL_SGX_PCK_CERTIFICATE);
  const pckCert =  certChain[0];

  const validPckCA = await pckCAcert.verify(intelSgxRootCA)
  const validPck = await pckCert.verify(pckCAcert)

  if (!validPckCA || !validPck) {
    return new Error(`Failed to verify cert chain`);
  }

  // Download and verify the CRL
  try {
    if (!checkCRLValidity("INTEL_SGX_PCK_CRL")) {
      if (!window.uploadedCRL) {
        return new Error("CRL not available. Please download and upload the CRL file first.");
      }
      crls["INTEL_SGX_PCK_CRL"] = new CertificateRevocationList({
        schema: fromBER(window.uploadedCRL).result,
      });
    }

    const crl = crls["INTEL_SGX_PCK_CRL"];
    if (!crl) {
      return new Error("PCK CRL is not available");
    }

    // Check if the PCK certificate is revoked
    const isRevoked = crl.revokedCertificates?.some(revokedCert => {
      const pckCertSerialNumber = pckCert.serialNumber.valueBlock.valueHexView;
      const revokedSerialNumber = revokedCert.userCertificate.valueBlock.valueHexView;
      return revokedSerialNumber === pckCertSerialNumber;
    });

    if (isRevoked) {
      return new Error("PCK certificate is revoked");
    }
  } catch (error) {
    return new Error(`PCK CRL check failed: ${error.message}`);
  }

  // Check the verification collaterals' cert signature chain, including PCK Cert Chain, TCB info chain and QE identity chain
  // Check if verification collaterals are on the CRL.
  // Check the TDQE Report signature and the contained AK hash using the PCK Cert.
  // Check the measurements of the TDQE contained in the TDQE Report.
  // Check the signature of the TD Quote using the public key–part of the AK. Implicitly, this validated the TD and TDX Module measurements.
  // Evaluate the TDX TCB information contained in the TD Quote

  return true;
}

export default async (
  report,
  {
    securityVersion = 0,
    uniqueID,
    signerID,
    productID,
    expectedRTMR2 = null
  }
) => {
  // Parse report
  const quote = await parseQuote(report);
  if (quote instanceof Error) { return quote; }

  //check report
  const headerResult = await checkHeader(quote.header);
  if (headerResult instanceof Error) { return headerResult; }
  const bodyResult = await checkBody(quote.body, expectedRTMR2);
  if (bodyResult instanceof Error) { return bodyResult; }
  const signatureResult = await checkSignature(quote.signature);
  if (signatureResult instanceof Error) { return signatureResult; }


  if (quote.signature.qeCertificationData.certDataType != CERT_DATA_TYPE_QE_REPORT_CERTIFICATION_DATA) {
    return Error(`Missing QE report certification data.`);
  }
  if (quote.signature.qeCertificationData.certData.innerQeCertData.certDataType != OE_SGX_PCK_ID_PCK_CERT_CHAIN) {
    return Error(`Missing QE report certification data certificate chain.`);
  }
  if (!quote.signature.qeCertificationData.certData.innerQeCertData.certData) {
    return Error(`Missing QE report certification data certificate chain.`);
  }

  // Verify CRL signatures against Intel certificates
  const intelRootCA = await checkCRL(
    "INTEL_ROOT_CA",
    INTEL_ROOT_CA,
    "https://certificates.trustedservices.intel.com/IntelSGXRootCA.crl",
    window.uploadedRootCRL || fromBase64(INTEL_ROOT_CA_CRL_B64),
  );
  if (intelRootCA instanceof Error) {
    return intelRootCA;
  }
  const intelSGXPCKCertificate = await checkCRL(
    "INTEL_SGX_PCK_CERTIFICATE",
    INTEL_SGX_PCK_CERTIFICATE,
    "https://api.trustedservices.intel.com/sgx/certification/v3/pckcrl?ca=platform&encoding=der",
    window.uploadedCRL,
  );
  if (intelSGXPCKCertificate instanceof Error) {
    return intelSGXPCKCertificate
  }

  // Verify certificate chain
  const validateCertResult = await validateCertificateChain(
    [intelRootCA],
    quote.signature.qeCertificationData.certData.innerQeCertData.certData.slice().reverse()
  );
  if (validateCertResult instanceof Error || validateCertResult.result !== true) {
    return Error(`Failed to verify certificate chain.`);
  }
  
  // Verify report body signature
  const publicKey = await quote.signature.qeCertificationData.certData.innerQeCertData.certData[0].getPublicKey();
  const verifiedReportBodySignature = await verifySignature(
    publicKey,
    quote.signature.qeCertificationData.certData.qeReportSignature,
    quote.signature.qeCertificationData.certData.qeReportDataRaw,
  );
  if (verifiedReportBodySignature instanceof Error) {
    return verifiedReportBodySignature;
  }
  return quote
  //
  // // Verify quote signature
  // const attestationKey = quote.quoteAuthData.attestationKey.key
  // if (attestationKey instanceof Error) {
  //   return attestationKey;
  // }
  // const verifiedQuoteSignature = await verifySignature(
  //   attestationKey,
  //   quote.quoteAuthData.signature,
  //   quote.signedData
  // );
  // if (verifiedQuoteSignature instanceof Error) {
  //   return verifiedQuoteSignature;
  // }
  //
  // // Verify hash
  // const authDataHash = await sha256(
  //   joinByteArrays([quote.quoteAuthData.attestationKey.raw, quote.qeAuthData])
  // );
  // if (!eqByteArr(authDataHash, quote.quoteAuthData.qeReportBody.reportData.slice(0, 32))) {
  //   return Error(`Hash mismatch.`);
  // }
  //
  // Verify unique ID
  // if (
  //   uniqueID &&
  //   !eqByteArr(fromBase64(uniqueID), quote.reportBody.mrenclave)
  // ) {
  //   return Error(`Unique ID mismatch. (expected: ${uniqueID}, got: ${toBase64(quote.reportBody.mrenclave)})`);
  // }
  //
  // // Verify signer ID
  // if (
  //   signerID &&
  //   !eqByteArr(fromBase64(signerID), quote.reportBody.mrsigner)
  // ) {
  //   return Error(`Signer ID mismatch. (expected: ${signerID}, got: ${toBase64(quote.reportBody.mrsigner)})`);
  // }
  //
  // // Verify product ID
  // if (
  //   productID &&
  //   !eqByteArr(fromBase64(productID), quote.reportBody.productID)
  // ) {
  //   return Error(`Product ID mismatch. (expected: ${productID}, got: ${toBase64(quote.reportBody.productID)})`);
  // }
  //
  // // Verify security version
  // if (quote.quoteAuthData.qeReportBody.securityVersion < securityVersion) {
  //   return Error(`Security version is out of date. (expected: ${securityVersion}, got: ${quote.quoteAuthData.qeReportBody.securityVersion})`);
  // }
  //
  // return quote.reportBody;
};

const unpackLENumber = (bytes) => {
  return bytes.reduceRight((acc, byte) => (acc << 8) + byte, 0);
};

class Seeker {
  pos;
  remaining;
  data;
  constructor(data) {
    this.pos = 0;
    this.remaining = data.length;
    this.data = data;
  }

  extract(length) {
    if (this.pos + length > this.data.length) {
      return new Error(
        `Can't extract: Out of bounds. (pos=${this.pos}, len=${length}, available=${this.remaining})`
      );
    }
    const data = this.data.slice(this.pos, this.pos + length);
    this.pos += length;
    this.remaining -= length;
    return data;
  }

  extractLEU16() {
    const data = this.extract(2);
    if (data instanceof Error) {
      return data;
    }
    return unpackLENumber(data);
  }

  extractLEU32() {
    const data = this.extract(4);
    if (data instanceof Error) {
      return data;
    }
    return unpackLENumber(data);
  }

  extractLEU64() {
    const data = this.extract(8);
    if (data instanceof Error) {
      return data;
    }
    return unpackLENumber(data);
  }

  skip(length) {
    this.pos += length;
    this.remaining -= length;
  }
}

