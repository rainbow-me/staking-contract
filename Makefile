.PHONY: build test coverage clean deploy-staging deploy-production verify-staging verify-production

build:
	forge build

test:
	forge test

test-fast:
	forge test --fuzz-runs 100 --no-match-contract Invariants

coverage:
	forge coverage

clean:
	forge clean

deploy-staging:
	@test -f .env.staging || (echo "Error: .env.staging not found. Copy .env.staging.example to .env.staging and fill in values." && exit 1)
	@bash -c 'set -a && source .env.staging && set +a && forge script script/Deploy.s.sol:DeployScript \
		--rpc-url $$RPC_URL \
		--private-key $$PRIVATE_KEY \
		--broadcast \
		--verify \
		--etherscan-api-key $$ETHERSCAN_API_KEY \
		--verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
		-vvvv'

deploy-production:
	@test -f .env.production || (echo "Error: .env.production not found. Copy .env.production.example to .env.production and fill in values." && exit 1)
	@echo "WARNING: You are about to deploy to PRODUCTION (Base mainnet)."
	@read -p "Are you sure? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@bash -c 'set -a && source .env.production && set +a && forge script script/Deploy.s.sol:DeployScript \
		--rpc-url $$RPC_URL \
		--private-key $$PRIVATE_KEY \
		--broadcast \
		--verify \
		--etherscan-api-key $$ETHERSCAN_API_KEY \
		--verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
		-vvvv'

verify-staging:
	@test -n "$(ADDRESS)" || (echo "Usage: make verify-staging ADDRESS=0x..." && exit 1)
	@bash -c 'set -a && source .env.staging && set +a && forge verify-contract $(ADDRESS) src/RNBWStaking.sol:RNBWStaking \
		--etherscan-api-key $$ETHERSCAN_API_KEY \
		--verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
		--chain-id 8453 \
		--constructor-args $$(cast abi-encode "constructor(address,address,address)" $$RNBW_TOKEN $$SAFE_ADDRESS $$SIGNER)'

verify-production:
	@test -n "$(ADDRESS)" || (echo "Usage: make verify-production ADDRESS=0x..." && exit 1)
	@bash -c 'set -a && source .env.production && set +a && forge verify-contract $(ADDRESS) src/RNBWStaking.sol:RNBWStaking \
		--etherscan-api-key $$ETHERSCAN_API_KEY \
		--verifier-url https://api.etherscan.io/v2/api?chainid=8453 \
		--chain-id 8453 \
		--constructor-args $$(cast abi-encode "constructor(address,address,address)" $$RNBW_TOKEN $$SAFE_ADDRESS $$SIGNER)'
