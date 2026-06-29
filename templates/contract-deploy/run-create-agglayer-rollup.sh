#!/bin/bash
# This script is responsible for deploying the contracts for zkEVM/CDK.
global_log_level="{{.global_log_level}}"
if [[ $global_log_level == "debug" ]]; then
    set -x
fi
set -euo pipefail

echo_ts() {
    green="\e[32m"
    end_color="\e[0m"

    timestamp=$(date +"[%Y-%m-%d %H:%M:%S]")
    echo -e "$green$timestamp$end_color $1" >&2
}

wait_for_rpc_to_be_available() {
    counter=0
    max_retries=20
    until cast send --rpc-url "{{.l1_rpc_url}}" --mnemonic "{{.l1_preallocated_mnemonic}}" --value 0 "{{.zkevm_l2_sequencer_address}}" &> /dev/null; do
        ((counter++))
        echo_ts "Can't send L1 transfers yet... Retrying ($counter)..."
        if [[ $counter -ge $max_retries ]]; then
            echo_ts "Exceeded maximum retry attempts. Exiting."
            exit 1
        fi
        sleep 5
    done
}

create_genesis() {
    echo_ts "Step 4: Creating genesis"
    pushd /opt/zkevm-contracts || exit 1
    MNEMONIC="{{.l1_preallocated_mnemonic}}" npx ts-node deployment/v2/1_createGenesis.ts 2>&1 | tee 02_create_genesis.out
    if [[ ! -e deployment/v2/genesis.json ]]; then
        echo_ts "The genesis file was not created after running createGenesis"
        exit 1
    fi
    popd || exit 1
}

# Transform CDK-style genesis.json into the erigon dynamic-*-allocs.json format.
# Hoisted from its original location (after rollup creation) to here, so we
# can pre-compute the SMT genesis root BEFORE the L1 rollup is created. The
# SMT root must match what cdk-erigon computes at startup, otherwise
# L1 batchNumToStateRoot[0] won't equal the prover's oldStateRoot for
# batch 1 and verifyBatches reverts with InvalidProof. See
# doc-report/fix-plan-invalidProof.md.
transform_genesis_to_allocs() {
    local jq_script='
.genesis | map({
  (.address): {
    contractName: (if .contractName == "" then null else .contractName end),
    balance: (if .balance == "" then null else .balance end),
    nonce: (if .nonce == "" then null else .nonce end),
    code: (if .bytecode == "" then null else .bytecode end),
    storage: (if .storage == null or .storage == {} then null else (.storage | to_entries | sort_by(.key) | from_entries) end)
  }
}) | add'

    # Read from the contracts dir (where create_genesis wrote it) and write
    # to /opt/zkevm/ where cdk-erigon (ZKDynamicConfigPath) will read it.
    if ! output_json=$(jq "$jq_script" /opt/zkevm-contracts/deployment/v2/genesis.json); then
        echo_ts "Error processing JSON with jq"
        exit 1
    fi

    if ! echo "$output_json" | jq . > /opt/zkevm/dynamic-{{.chain_name}}-allocs.json; then
        echo_ts "Error writing to file /opt/zkevm/dynamic-{{.chain_name}}-allocs.json"
        exit 1
    fi
    echo_ts "Transformation complete. Output written to /opt/zkevm/dynamic-{{.chain_name}}-allocs.json"
}

# Pre-compute the SMT genesis root using the cdk-erigon/smt-genesis binary
# (mounted at /opt/cdk-erigon/smt-genesis). The result is exported as
# SMT_GENESIS_ROOT and written into create_rollup_parameters.json as
# smtGenesisRoot, so that 4_createRollup.ts can pass it as genesisFinal
# when calling addNewRollupType(...).
compute_smt_genesis_root() {
    local smt_bin="/opt/cdk-erigon/smt-genesis"
    local alloc_file="/opt/zkevm/dynamic-{{.chain_name}}-allocs.json"

    if [[ ! -x "$smt_bin" ]]; then
        echo_ts "FATAL: $smt_bin is not present or not executable"
        exit 1
    fi
    if [[ ! -s "$alloc_file" ]]; then
        echo_ts "FATAL: $alloc_file is missing or empty"
        exit 1
    fi

    local smt_root
    if ! smt_root=$("$smt_bin" --alloc "$alloc_file" 2>/tmp/smt-genesis.err); then
        echo_ts "FATAL: smt-genesis binary failed:"
        cat /tmp/smt-genesis.err >&2
        exit 1
    fi
    if [[ ! "$smt_root" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
        echo_ts "FATAL: smt-genesis output is not a valid bytes32: $smt_root"
        exit 1
    fi
    echo_ts "SMT genesis root = $smt_root"
    export SMT_GENESIS_ROOT="$smt_root"

    # Inject the SMT root into the create_rollup_parameters.json file that
    # 4_createRollup.ts will load. We write the file in-place under
    # /opt/zkevm-contracts/deployment/v2 so the script picks it up.
    if ! jq --arg sgr "$smt_root" '.smtGenesisRoot = $sgr' \
            /opt/contract-deploy/create_rollup_parameters.json \
            > /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json; then
        echo_ts "FATAL: failed to inject smtGenesisRoot into create_rollup_parameters.json"
        exit 1
    fi

    # Patch 4_createRollup.ts to use smtGenesisRoot as genesisFinal when
    # available, falling back to genesis.root (MPT) when not.
    local ts_file="/opt/zkevm-contracts/deployment/v2/4_createRollup.ts"
    if [[ ! -f "$ts_file" ]]; then
        echo_ts "FATAL: $ts_file not found"
        exit 1
    fi
    sed -i 's|genesisFinal = genesis\.root;|genesisFinal = (createRollupParameters.smtGenesisRoot \&\& createRollupParameters.smtGenesisRoot !== "" \&\& createRollupParameters.smtGenesisRoot !== ethers.ZeroHash) ? createRollupParameters.smtGenesisRoot : genesis.root;|' \
        "$ts_file" || { echo_ts "FATAL: failed to patch 4_createRollup.ts"; exit 1; }
    echo_ts "Patched 4_createRollup.ts to honor smtGenesisRoot"
}

echo_ts "Waiting for the L1 RPC to be available"
wait_for_rpc_to_be_available "{{.l1_rpc_url}}"
echo_ts "L1 RPC is now available"

cp /opt/contract-deploy/deploy_parameters.json /opt/zkevm-contracts/deployment/v2/deploy_parameters.json
cp /opt/contract-deploy/create_rollup_parameters.json /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json

create_genesis

# Build the dynamic-*-allocs.json that cdk-erigon consumes at startup, then
# pre-compute the SMT genesis root from it. The SMT root is what cdk-erigon
# will use as oldStateRoot for batch 1, so we must write it into
# create_rollup_parameters.json and into L1 (via 4_createRollup.ts) before
# the L1 rollup is created. See doc-report/fix-plan-invalidProof.md.
transform_genesis_to_allocs
compute_smt_genesis_root

echo_ts "Setting up local zkevm-contracts repo for deployment"
pushd /opt/zkevm-contracts || exit 1
# Set up the hardhat environment. It needs to be executed even in custom genesis mode
sed -i 's#http://127.0.0.1:8545#{{.l1_rpc_url}}#' hardhat.config.ts

# Deploy gas token
# shellcheck disable=SC1054,SC1072,SC1083
{{ if .gas_token_enabled }}
# shellcheck disable=SC1009,SC1073,SC1065,SC1050
{{ if or (eq .gas_token_address "0x0000000000000000000000000000000000000000") (eq .gas_token_address "") }}
echo_ts "Deploying gas token to L1"
forge create \
    --broadcast \
    --json \
    --rpc-url "{{.l1_rpc_url}}" \
    --mnemonic "{{.l1_preallocated_mnemonic}}" \
    contracts/mocks/ERC20PermitMock.sol:ERC20PermitMock \
    --constructor-args "CDK Gas Token" "CDK" "{{.zkevm_l2_admin_address}}" "1000000000000000000000000" \
    > gasToken-erc20.json
jq \
    --slurpfile c gasToken-erc20.json \
    '.gasTokenAddress = $c[0].deployedTo' \
    /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json \
    > /tmp/crp_with_gas.json && mv /tmp/crp_with_gas.json /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json

# shellcheck disable=SC1073,SC1009
{{ else }}
echo_ts "Using L1 pre-deployed gas token: {{ .gas_token_address }}"
jq \
    --arg c "{{ .gas_token_address }}" \
    '.gasTokenAddress = $c' \
    /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json \
    > /tmp/crp_with_gas.json && mv /tmp/crp_with_gas.json /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json
{{ end }}
{{ end }}

cp /opt/zkevm-contracts/deployment/v2/genesis.json /opt/zkevm/

# Do not create another rollup in the case of an optimism rollup. This will be done in run-sovereign-setup.sh
deploy_optimism_rollup="{{.deploy_optimism_rollup}}"
rollup_created=0
if [[ "$deploy_optimism_rollup" != "true" ]]; then
    echo_ts "Step 5: Creating Rollup/Validium"
    npx hardhat run deployment/v2/4_createRollup.ts --network localhost 2>&1 | tee 05_create_rollup.out
    # Support for new output file format
    if [[ $(echo deployment/v2/create_rollup_output_* | wc -w) -gt 1 ]]; then
        echo_ts "There are multiple create rollup output files. We don't know how to handle this situation"
        exit 1
    fi
    if [[ $(echo deployment/v2/create_rollup_output_* | wc -w) -eq 1 ]]; then
        mv deployment/v2/create_rollup_output_* deployment/v2/create_rollup_output.json
    fi
    if [[ -e deployment/v2/create_rollup_output.json ]]; then
        rollup_created=1
        echo_ts "Successfully created rollup"
    else
        echo_ts "WARNING: The create_rollup_output.json file was not created after running createRollup"
        echo_ts "This may be due to missing PolygonRollupManager address. Continuing with minimal configuration..."
    fi
fi

# Combine contract deploy files.
# At this point, all of the contracts /should/ have been deployed.
# Now we can combine all of the files and put them into the general zkevm folder.

# Check create_rollup_output.json exists before copying it.
# For the case of deploy_optimism_rollup, create_rollup_output.json will not be created.
if [[ -e /opt/zkevm-contracts/deployment/v2/create_rollup_output.json ]]; then
    cp /opt/zkevm-contracts/deployment/v2/create_rollup_output.json /opt/zkevm/
else
    echo "File /opt/zkevm-contracts/deployment/v2/create_rollup_output.json does not exist."
fi
cp /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json /opt/zkevm/
popd || exit 1

echo_ts "Modifying combined.json"
pushd /opt/zkevm/ || exit 1

cp genesis.json genesis.original.json
# Check create_rollup_output.json exists before copying it.
# For the case of deploy_optimism_rollup, create_rollup_output.json will not be created.
if [[ -e create_rollup_output.json ]]; then
    echo "File create_rollup_output.json exists. Combining files..."
    jq --slurpfile rollup create_rollup_output.json '. + $rollup[0]' deploy_output.json > combined.json
else
    echo "File create_rollup_output.json does not exist. Trying to copy deploy_output.json to combined.json."
    cp deploy_output.json combined.json
fi
jq '.polygonZkEVML2BridgeAddress = .polygonZkEVMBridgeAddress' combined.json > c.json; mv c.json combined.json

# Always create these fields regardless of fork_id, as they are required by downstream processes
# Handle both polygonRollupManager and polygonRollupManagerContract field names
jq 'if .polygonRollupManager then .polygonRollupManagerAddress = .polygonRollupManager elif .polygonRollupManagerContract then .polygonRollupManager = .polygonRollupManagerContract | .polygonRollupManagerAddress = .polygonRollupManagerContract else . end' combined.json > c.json; mv c.json combined.json

# deploymentBlockNumber may not exist in deploy_output.json from zkevm-contracts
# Fall back to current block number if it doesn't exist
current_block=$(cast block-number --rpc-url "{{.l1_rpc_url}}")
jq --arg cb "$current_block" '.deploymentRollupManagerBlockNumber = (if .deploymentBlockNumber then .deploymentBlockNumber else ($cb | tonumber) end)' combined.json > c.json; mv c.json combined.json
jq '.admin = "{{.zkevm_l2_admin_address}}"' combined.json > c.json; mv c.json combined.json

# Add the L2 GER Proxy address in combined.json (for panoptichain).
zkevm_global_exit_root_l2_address=$(jq -r '.genesis[] | select(.contractName == "PolygonZkEVMGlobalExitRootL2 proxy") | .address' /opt/zkevm/genesis.json)
jq --arg a "$zkevm_global_exit_root_l2_address" '.polygonZkEVMGlobalExitRootL2Address = $a' combined.json > c.json; mv c.json combined.json

{{ if .gas_token_enabled }}
jq --slurpfile cru /opt/zkevm-contracts/deployment/v2/create_rollup_parameters.json '.gasTokenAddress = $cru[0].gasTokenAddress' combined.json > c.json; mv c.json combined.json
{{ end }}


# There are a bunch of fields that need to be renamed in order for the
# older fork7 code to be compatible with some of the fork8
# automations. This schema matching can be dropped once this is
# versioned up to 8
# DEPRECATED we will likely remove support for anything before fork 9 soon
fork_id="{{.zkevm_rollup_fork_id}}"
if [[ $fork_id -lt 8 ]]; then
    jq '.createRollupBlockNumber = .createRollupBlock' combined.json > c.json; mv c.json combined.json
fi

# NOTE there is a disconnect in the necessary configurations here between the validium node and the zkevm node
jq --slurpfile c combined.json '.rollupCreationBlockNumber = $c[0].createRollupBlockNumber' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.rollupManagerCreationBlockNumber = $c[0].upgradeToULxLyBlockNumber' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.genesisBlockNumber = $c[0].createRollupBlockNumber' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.L1Config = {chainId:{{.l1_chain_id}}}' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.L1Config.polygonZkEVMGlobalExitRootAddress = $c[0].polygonZkEVMGlobalExitRootAddress' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.L1Config.polygonRollupManagerAddress = $c[0].polygonRollupManagerAddress' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.L1Config.polTokenAddress = $c[0].polTokenAddress' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.L1Config.polygonZkEVMAddress = $c[0].rollupAddress' genesis.json > g.json; mv g.json genesis.json
jq --slurpfile c combined.json '.bridgeGenBlockNumber = $c[0].createRollupBlockNumber' combined.json > c.json; mv c.json combined.json

echo_ts "Final combined.json is ready:"
cp combined.json "combined{{.deployment_suffix}}.json"
cat combined.json

echo_ts "Approving the rollup address to transfer POL tokens on behalf of the sequencer"
cast send \
    --private-key "{{.zkevm_l2_sequencer_private_key}}" \
    --legacy \
    --rpc-url "{{.l1_rpc_url}}" \
    "$(jq -r '.polTokenAddress' combined.json)" \
    'approve(address,uint256)(bool)' \
    "$(jq -r '.rollupAddress' combined.json)" 1000000000000000000000000000

polygon_data_committee_address="$(jq -r '.polygonDataCommitteeAddress // empty' combined.json)"
if [[ -n "$polygon_data_committee_address" && "$polygon_data_committee_address" != "null" && "$polygon_data_committee_address" != "0x0000000000000000000000000000000000000000" ]]; then
    # The DAC needs to be configured with a required number of signatures.
    # Right now the number of DAC nodes is not configurable.
    # If we add more nodes, we'll need to make sure the urls and keys are sorted.
    echo_ts "Setting the data availability committee"
    cast send \
        --private-key "{{.zkevm_l2_admin_private_key}}" \
        --rpc-url "{{.l1_rpc_url}}" \
        "$polygon_data_committee_address" \
        'function setupCommittee(uint256 _requiredAmountOfSignatures, string[] urls, bytes addrsBytes) returns()' \
        1 ["http://zkevm-dac{{.deployment_suffix}}:{{.zkevm_dac_port}}"] "{{.zkevm_l2_dac_address}}"

    # The DAC needs to be enabled with a call to set the DA protocol.
    echo_ts "Setting the data availability protocol"
    cast send \
        --private-key "{{.zkevm_l2_admin_private_key}}" \
        --rpc-url "{{.l1_rpc_url}}" \
        "$(jq -r '.rollupAddress' combined.json)" \
        'setDataAvailabilityProtocol(address)' \
        "$polygon_data_committee_address"
else
    echo_ts "Skipping DAC setup because polygonDataCommitteeAddress is empty"
fi

if [[ -e create_rollup_output.json ]]; then
    jq '{"root": .root, "timestamp": 0, "gasLimit": 0, "difficulty": 0}' /opt/zkevm/genesis.json > "dynamic-{{.chain_name}}-conf.json"
    batch_timestamp=$(jq '.firstBatchData.timestamp' combined.json)
    jq --arg bt "$batch_timestamp" '.timestamp |= ($bt | tonumber)' "dynamic-{{.chain_name}}-conf.json" > tmp_output.json
    mv tmp_output.json "dynamic-{{.chain_name}}-conf.json"
else
    echo_ts "WARNING: Without create_rollup_output.json, using default timestamp"
    jq '{"root": .root, "timestamp": 0, "gasLimit": 0, "difficulty": 0}' /opt/zkevm/genesis.json > "dynamic-{{.chain_name}}-conf.json"
fi

# zkevm.initial-batch.config
# Only create if firstBatchData exists in combined.json
if jq '.firstBatchData' combined.json 2>/dev/null | grep -q -v "null"; then
    jq '.firstBatchData' combined.json > first-batch-config.json
    echo_ts "Created first-batch-config.json"
else
    echo_ts "WARNING: firstBatchData not found in combined.json, creating empty first-batch-config.json"
    echo '{}' > first-batch-config.json
fi

if [[ ! -s "dynamic-{{.chain_name}}-conf.json" ]]; then
    echo_ts "Error creating the dynamic kurtosis config"
    exit 1
fi

# If we've configured the l1 network with the minimal preset, we
# should probably wait for the first finalized block. This isn't
# strictly specific to minimal preset, but if we don't have "minimal"
# configured, it's going to take like 25 minutes for the first
# finalized block
# NOTE: For external L1 networks (like Conflux eSpace), we skip this wait
# because block finalization is handled by the external network
l1_preset="{{.l1_preset}}"
deploy_l1="{{.deploy_l1}}"

# Only wait for finalized block if we're using a local L1 with minimal preset
if [[ $deploy_l1 == "true" && $l1_preset == "minimal" ]]; then
    echo_ts "Waiting for the first finalized block"
    # This might not be required, but it seems like the downstream
    # processes are more reliable if we wait for all of the deployments to
    # finalize before moving on
    current_block_number="$(cast block-number --rpc-url '{{.l1_rpc_url}}')"
    finalized_block_number=0
    until [[ $finalized_block_number -gt $current_block_number ]]; do
        sleep 5
        finalized_block_number="$(cast block-number --rpc-url '{{.l1_rpc_url}}' finalized)"
    done
else
    echo_ts "Skipping finalized block wait for external L1 network"
fi

# The contract setup is done!
touch "/opt/zkevm/.init-complete{{.deployment_suffix}}.lock"
