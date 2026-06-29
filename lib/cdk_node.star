constants = import_module("../src/package_io/constants.star")
data_availability_package = import_module("./data_availability.star")
ports_package = import_module("../src/package_io/ports.star")

AGGKIT_BINARY_NAME = "aggkit"


def create_cdk_node_service_config(
    args,
    config_artifact,
    genesis_artifact,
    keystore_artifact,
):
    cdk_node_name = "cdk-node" + args["deployment_suffix"]
    (ports, public_ports) = get_cdk_node_ports(args)
    service_command = get_cdk_node_cmd(args)
    cdk_node_service_config = ServiceConfig(
        image=args["cdk_node_image"],
        ports=ports,
        public_ports=public_ports,
        files={
            "/etc/cdk": Directory(
                artifact_names=[
                    config_artifact,
                    genesis_artifact,
                    keystore_artifact.aggregator,
                    keystore_artifact.sequencer,
                    keystore_artifact.claim_sponsor,
                    keystore_artifact.agglayer,
                ],
            ),
            "/data": Directory(
                artifact_names=[],
            ),
        },
        entrypoint=["sh", "-c"],
        cmd=service_command,
    )

    return {cdk_node_name: cdk_node_service_config}


def get_cdk_node_ports(args):
    # We won't have an aggregator if we're in PP mode
    if args["consensus_contract_type"] == constants.CONSENSUS_TYPE.pessimistic:
        ports = {
            "rpc": PortSpec(
                args.get("cdk_node_rpc_port"),
                application_protocol="http",
                wait=None,
            ),
            "rest": PortSpec(
                args.get("aggkit_node_rest_api_port"),
                application_protocol="http",
                wait=None,
            ),
        }
        public_ports = ports_package.get_public_ports(
            ports, "cdk_node_start_port", args
        )
        return (ports, public_ports)

    # In the case where we have pre deployed contract, the cdk node
    # can go through a syncing process that takes a long time and
    # might exceed the start up time
    aggregator_wait = "2m"
    if (
        "use_previously_deployed_contracts" in args
        and args["use_previously_deployed_contracts"]
    ):
        aggregator_wait = None

    # FEP requires the aggregator
    ports = {
        "rpc": PortSpec(
            args.get("cdk_node_rpc_port"),
            application_protocol="http",
            wait=None,
        ),
        "rest": PortSpec(
            args.get("aggkit_node_rest_api_port"),
            application_protocol="http",
            wait=None,
        ),
    }

    # Non-pessimistic rollups require an aggregator.
    if args.get("consensus_contract_type") != constants.CONSENSUS_TYPE.pessimistic:
        # Determine the wait time for the aggregator.
        # If using pre-deployed contracts, the cdk node can go through a syncing process
        # that takes a long time and might exceed the start up time.
        aggregator_wait = "2m"
        if args.get("use_previously_deployed_contracts"):
            aggregator_wait = None

        ports["aggregator"] = PortSpec(
            args.get("zkevm_aggregator_port"),
            application_protocol="grpc",
            wait=aggregator_wait,
        )

    public_ports = ports_package.get_public_ports(ports, "cdk_node_start_port", args)
    return (ports, public_ports)


def get_cdk_node_cmd(args):
    binary_name = args.get("binary_name")

    # Workaround: pre-seed the synchronizer fork_id table so that
    # SequenceBatches events are not dropped with forkid=0.
    # The L1 CreateNewRollup event carries forkID=0 in its data,
    # and the RollupTypeMap ABI call returns a wrong value,
    # leaving the fork_id table empty.  Inject the configured
    # fork_id after cdk-node has finished its 0001.sql migration
    # (which creates the fork_id table) but before it starts the
    # synchronizer event loop.  We use a background launcher that
    # polls for the fork_id table and then INSERTs the row.
    fork_id = args.get("zkevm_rollup_fork_id", "12")
    dq = chr(34)  # double quote
    sq = chr(39)  # single quote
    # shell command run by the side-car to inject the fork_id row
    inject_cmd = (
        "i=0; while [ $i -lt 30 ]; do "
        + "if sqlite3 /tmp/aggregator_sync_db.sqlite "
        + dq + "SELECT name FROM sqlite_master WHERE type='table' AND name='fork_id';" + dq
        + " 2>/dev/null | grep -q fork_id; then "
        + "sqlite3 /tmp/aggregator_sync_db.sqlite "
        + dq + "INSERT OR IGNORE INTO fork_id (fork_id, from_batch_num, to_batch_num, version, block_num) "
        + "VALUES (" + str(fork_id) + ", 1, 9223372036854775807, " + sq + "banana" + sq + ", 0);" + dq
        + " && echo injected-forkid-" + str(fork_id) + " && break; fi; "
        + "i=$((i+1)); sleep 1; done; "
    )

    # Workaround: fix cdk-node-config.toml genesisBlockNumber to match
    # the createRollupBlockNumber from genesis.json.  The default value
    # comes from zkevm_rollup_manager_block_number (the block where
    # RollupManager contract itself was deployed, which is several
    # blocks AFTER our rollup was actually created).  This causes the
    # synchronizer to miss the InitialSequenceBatches event that emits
    # batch 1, leaving the sequenced_batches table without batch 1
    # forever, which blocks the aggregator from ever dispatching
    # proof tasks.  Read the correct value from genesis.json and
    # rewrite cdk-node-config.toml to use it.
    patch_config_cmd = (
        "GBN=$(awk -F: '/\"genesisBlockNumber\"/ {gsub(/[^0-9]/, \"\", $2); print $2; exit}' /etc/cdk/genesis.json); "
        + "if [ -n \"$GBN\" ] && [ \"$GBN\" != \"0\" ]; then "
        + "sed -i -E 's|^genesisBlockNumber[[:space:]]*=.*|genesisBlockNumber = \"'\"$GBN\"'\"|' "
        + "/etc/cdk/cdk-node-config.toml; "
        + "sed -i -E 's|^rollupCreationBlockNumber[[:space:]]*=.*|rollupCreationBlockNumber = \"'\"$GBN\"'\"|' "
        + "/etc/cdk/cdk-node-config.toml; "
        + "sed -i -E 's|^rollupManagerCreationBlockNumber[[:space:]]*=.*|rollupManagerCreationBlockNumber = \"'\"$GBN\"'\"|' "
        + "/etc/cdk/cdk-node-config.toml; "
        + "echo patched-genesis-block-number-to-$GBN; "
        + "else echo 'failed to determine genesisBlockNumber from /etc/cdk/genesis.json' >&2; exit 1; fi; "
    )

    service_command = [
        "sleep 20 && ("
        + inject_cmd
        + ") & "
        + patch_config_cmd
        + "cdk-node run "
        + "--cfg=/etc/cdk/cdk-node-config.toml "
        + "--custom-network-file=/etc/cdk/genesis.json "
        + "--components=sequence-sender,aggregator; "
        + "wait"
    ]

    if args["consensus_contract_type"] == constants.CONSENSUS_TYPE.pessimistic:
        service_command = [
            "sleep 20 && cdk-node run "
            + "--cfg=/etc/cdk/cdk-node-config.toml "
            + "--custom-network-file=/etc/cdk/genesis.json "
            + "--save-config-path=/tmp "
            + "--components=aggsender"
        ]

    if binary_name == AGGKIT_BINARY_NAME:
        service_command = [
            "sleep 20 && aggkit run "
            + "--cfg=/etc/cdk/cdk-node-config.toml "
            + "--save-config-path=/tmp "
            + "--components=aggsender,bridge"
        ]

    return service_command
