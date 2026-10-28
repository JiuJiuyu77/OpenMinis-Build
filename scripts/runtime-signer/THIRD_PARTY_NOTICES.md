# Runtime signer notices

`codex-sign` is built from source. The output is not copied from an attachment
and no prebuilt helper is an input to the build.

## Fixed sources

- TrollStore `opa334/TrollStore` commit `88424f683b2a08f34a3f88985f790f97d84ce1df`, including `Exploits/fastPathSign/src`.
- ChOma `opa334/ChOma` commit `964023ddac2286ef8e843f90df64d44ac6a673df` (the pinned TrollStore submodule).
- OpenSSL release `openssl-3.5.9`, archive SHA-256 `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a`.

## Licenses

TrollStore and ChOma are MIT for the files used here. OpenSSL 3.5.9 is
Apache-2.0. The TrollStore repository also records a BSD-4-Clause exception
for `RootHelper/uicache.m`; that file is not compiled by this signer. GPL-3.0
and MPL-2.0 code is not a dependency of this implementation. They are listed
explicitly so a future source change cannot silently add a component without
re-checking its notice and source obligations.

The complete, unmodified fixed source trees, the OpenSSL source archive, this
adapter, build script, build parameters and generated provenance must be
published together with any redistributed signer binary. A URL-only notice or
a copied license file is not a substitute for the corresponding source asset.
The repository's `LICENSE` files remain the authoritative full license text;
the build script packages them in its source-assets archive.
