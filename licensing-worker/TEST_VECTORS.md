# License string test vectors

Regenerate with `npm run vectors`. Used to cross-check this worker's
signing against the Swift verifier -- both must produce byte-identical
strings for the same inputs and the same test keypair.

## Test keypair (NOT secret, deterministic, for cross-checking only)

Derived as `SHA-256("PeekLicenseKit-TEST-KEY-DO-NOT-USE-IN-PRODUCTION")`.

- Private key (hex, 32 bytes): `63f2716f729f77386f71aa3388ae4a2784badf3a65f4088189fddb5b9f894acf`
- Public key (hex, 32 bytes): `e60868d30765ae875f1fa9317197f3328cff10935386011dfb42470d05a6e741`

## Vectors

### Vector 1 -- ASCII email

Input:

```json
{
  "schemaVersion": 1,
  "productId": 1,
  "issuedAt": 1732000000,
  "polarKey": "POLAR-AB12-CD34-EF56-7890",
  "email": "mario.rossi@example.com"
}
```

Output license string:

```
PK3D-040PE-F1S00-CN0KT-C8592-TGA26-4S2TG-T46CT-2THA6-6MV2T-DSR74-R1EVB-1E9MP-YBKJD-XSQ6T-A0CNW-62VBG-DHJJW-RVFDM-YM364-33MH9-0JFXZ-8X667-9FDN4-6MX64-15EH3-2HXWF-8F2CE-K15PG-1H28N-X13N1-HE97R-H344N-J9XTC-6TW5B-MEH2N-4SHZ5-0KQ0R-W3T7S-05
```

### Vector 2 -- non-ASCII UTF-8 email

Input:

```json
{
  "schemaVersion": 1,
  "productId": 1,
  "issuedAt": 1690000000,
  "polarKey": "POLAR-0000-1111-2222-3333",
  "email": "società@ésempio.it"
}
```

Output license string:

```
PK3D-040P9-ETTG0-CN0KT-C8592-TC1G6-0R2TC-9H64R-JTCHJ-68S2T-CSK6C-SH8WV-FCDMP-AX63M-10C7A-BKCNP-Q0TBF-5SMQ8-VN6TX-ENZQB-QZ1YZ-MS5GG-EMYNB-EZJGF-3B0ED-BBGT4-2V0P2-61DAB-ARMJ7-M72E8-BKZMT-N4AYJ-Y3KCN-CM1PS-P1SZ7-6G3S3-396BG-CA5XB-830
```

### Vector 3 -- another ASCII case

Input:

```json
{
  "schemaVersion": 1,
  "productId": 1,
  "issuedAt": 1800000000,
  "polarKey": "POLAR-ZZZZ-9999-AAAA-BBBB",
  "email": "qa+peek3d@anthropic.test"
}
```

Output license string:

```
PK3D-040PP-JEJ00-CN0KT-C8592-TPJTB-9D2TE-9S74W-JTGA1-850JT-GJ289-11GWB-15DR6-ASBB6-DJ40R-BEEHM-74VVG-D5HJW-X35ED-T0NSE-3BYYR-D26WN-7PWB3-2STPE-ATN2K-5PAVJ-6H24B-J2RY2-446FE-Q5Z9D-9P0G3-PRVZR-1FHM7-KCCV9-YFKWJ-JET8R-DKACH-YGGZX-DNFCP-M514
```

