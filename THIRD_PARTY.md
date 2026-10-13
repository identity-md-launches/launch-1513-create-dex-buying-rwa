# Third-party code and offline fixtures

Application code is GPL-2.0-or-later unless a file states otherwise. The included OpenZeppelin and forge-std files retain their upstream licenses. No git submodules or package-manager installation are needed to compile or test.

| Component | Pinned source | Included files |
| --- | --- | --- |
| OpenZeppelin Contracts | [v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | The unmodified dependency closure used by the application and ERC20 test doubles, plus MIT license, under `lib/openzeppelin-contracts`. |
| forge-std | [v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7) | Unmodified `src/` and MIT/Apache licenses under `lib/forge-std`. |
| Uniswap v3-core | npm `@uniswap/v3-core@1.0.1`, git `ed88be38ab2032d82bf10ac6f8d03aa631889d48` | Factory creation bytecode (including pool creation code) as a Solidity hex fixture; original upstream licenses under `test/fixtures`. The original core license specifies GPL-2.0-or-later after its change date. |
| Uniswap v3-periphery | npm `@uniswap/v3-periphery@1.4.4`, git `697c2474757ea89fec12a4e6db16a574fe259610` | Original SwapRouter and QuoterV2 creation bytecode as Solidity hex fixtures, and upstream GPL license, under `test/fixtures`. |

Download URLs and archive SHA-256 values for source dependencies are in [lib/DEPENDENCIES.json](lib/DEPENDENCIES.json). Npm artifact paths, git revisions, archive hashes, and bytecode hashes are in [test/fixtures/PROVENANCE.json](test/fixtures/PROVENANCE.json).

The fixture hex constants are the published creation bytecode, with no bytecode modifications. Test constructors append only the local fixture's factory and wrapped-token addresses. The Solidity wrappers allow offline deployment in tests without filesystem permissions, environment variables, RPC endpoints, additional compiler versions, or runtime package downloads. They are not application contracts and must not be launched.

Corresponding upstream contract sources, licenses, dependency lockfiles, and build settings are also preserved in `test/fixtures/upstream/*-sources.tar.gz`, with hashes in the fixture provenance file. They are reference archives and are not extracted during the build. Original sources: [v3-core revision](https://github.com/Uniswap/v3-core/tree/ed88be38ab2032d82bf10ac6f8d03aa631889d48) and [v3-periphery revision](https://github.com/Uniswap/v3-periphery/tree/697c2474757ea89fec12a4e6db16a574fe259610). Their build settings used Solidity 0.7.6; this project consumes the existing artifacts only, and all Solidity compiled locally is pinned to 0.8.26.
