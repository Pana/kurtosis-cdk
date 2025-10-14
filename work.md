# Conflux L2

## TODOs

- [X] Set up bridge UI
- [X] Disable agglayer: 关闭此模块, 会导致 Last Verified Batch Number 不更新, 需要修改 cdk-node 配置(SettlementBackend 从 agglayer 改为 l1)
- [X] Test on L1(then Conflux eSpace Testnet)
  1. 需要修改合约部署的脚本 ✅
  2. 启动 zkevm-bridge-proxy-001 服务
- [X] 弄清楚整个 kurtosis-cdk 的部署流程: 大致搞明白了 zkEVM rollup 的部署流程, 具体细节可以查看部署脚本实现(可借助 AI 读代码)
- [ ] 熟悉 Polygon zkEVM 的工作原理和架构, 整体包含哪些组件, 各个组件的作用

## zkEVM 架构分析

1. [zkEVM系列第一篇：Polygon zkEVM的整体架构和交易执行流程](https://www.panewslab.com/zh/articles/i71orlsq)
2. [zkEVM系列（2）｜Polygon zkEVM关于Sequencer和Bridge更多的技术细节](https://www.panewslab.com/zh/articles/z67h14694f14)
3. [官方 zkevm 架构图](https://docs.agglayer.dev/cdk/cdk-erigon/architecture/#cdk-erigon-zkrollup)

### Polygon zkEVM 组件

1. Agglayer stack (contracts, agglayer service and mock prover).
2. L2 CDK-Erigon blockchain (cdk-erigon(rpc, sequencer), zkevm-pool-manager, zkevm-prover and executor, cdk-node).

zkevm 核心组件:

1. cdk-erigon-rpc-001: hermeznetwork/cdk-erigon:v2.61.24
2. cdk-erigon-sequencer-001: hermeznetwork/cdk-erigon:v2.61.24
3. cdk-node-001: ghcr.io/0xpolygon/cdk:0.5.4
4. zkevm-pool-manager-001: hermeznetwork/zkevm-pool-manager:v0.1.2
5. zkevm-prover-001: hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12
6. zkevm-stateless-executor-001: hermeznetwork/zkevm-prover:v8.0.0-RC16-fork.12

#### 组件作用简介

1. cdk-erigon: 负责作为 RPC 节点和 Sequencer 节点(负责排序和生成 batch), 处理 L2 交易
2. cdk-node: 核心组件为 sequence-sender, aggregator; 前者负责将 batch 发送到 L1 合约, 后者负责从 L1 合约获取 batch, 并发给 prover 生成证明, 最后把证明聚合后提交到 L1 合约验证, 并最终 finalize 状态变化.
3. zkevm-pool-manager: 负责管理交易池
4. zkevm-prover: 负责生成 zk proof
5. zkevm-stateless-executor: 负责快速验证 zk proof

问题: prover 和 executor 使用同一个镜像, 各自的作用是什么?
在 arg 中有一个参数 `erigon_strict_mode` 他的注释简单说明了 stateless executor 的作用: `This flag will enable a stateless executor to verify the execution of the batches. Set to true to run erigon as the sequencer.`

### [agglayer-contracts](https://github.com/agglayer/agglayer-contracts)

该项目原来叫做 zkevm-contracts, 现在改名为 agglayer-contracts. 该项目包含了 zkEVM L2 的智能合约, 包括:

1. zkEVM Rollup 合约: RollupManager, verifier
2. Bridge 合约
3. Util 合约: TimeLock, Depolyer

该项目主要使用 hardhat 进行开发, 也配置了 foundry.

项目目录介绍: 

1. contracts: 智能合约代码
2. compiled-contracts: 编译后的 json 文件
3. docs: 合约文档, 主要是合约接口
4. src & tools: 一些脚本工具
5. test: 测试代码
6. deployments 部署脚本, 主要是 v2 目录

### [lxly-bridge-and-call](https://github.com/AggLayer/lxly-bridge-and-call)

## 概念

1. FEP: Full Execution Proofs
2. Pesimistic Proof: 悲观证明

## 参考

1. [Sunsetting Polygon zkEVM Mainnet Beta in 2026](https://forum.polygon.technology/t/sunsetting-polygon-zkevm-mainnet-beta-in-2026/21020)
2. [Polygon联创Baylina携zkEVM核心团队成立新项目Zisk](https://www.theblockbeats.info/flash/299005)

## common scripts

```sh
# 设置 cast 环境变量, 方便后续使用
export ETH_RPC_URL="$(kurtosis port print cdk cdk-erigon-rpc-001 rpc)"
export PK="0x12d7de8621a77640c9241b2595ba78ce443d05e94090365ab3bb5e19df82c625"
export PK="0x2a22f4a6dfc0ed2182e839409cd2e743ddbf63f131def86ef8b50e47f0f3b55f"

# 压测
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 50000 --rate-limit 50 --concurrency 5 --mode t
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 10 --mode 2
polycli loadtest --rpc-url "$ETH_RPC_URL" --legacy --private-key "$PK" --verbosity 700 --requests 500 --rate-limit 3  --mode uniswapv3

cast rpc zkevm_batchNumber          # Latest batch number on the L2
cast rpc zkevm_virtualBatchNumber   # Latest batch received on the L1
cast rpc zkevm_verifiedBatchNumber  # Latest batch verified or "proven" on the L1

# kurtosis 常用命令
kurtosis run --enclave cdk --args-file external-l1.yml .
kurtosis run --enclave cdk --args-file params.yml .
kurtosis service shell cdk contracts-001
kurtosis service logs cdk cdk-node-001 --follow
kurtosis service logs cdk cdk-node-001 --follow --match error

# 通过转账测试 RPC 是否可用
cast send --rpc-url "https://evmtestnet.confluxrpc.com/7mCztCVfajeGYYkWSea3Fk6ojynwUmBZ6L1ue2YTkudVfus7XkqbKnoMcYVYZYYVJSjDw73u45Nr4zHmyRLaG5x2w" --mnemonic "slice avocado mutual shield affair puppy gap seed afford hip alley slab" --value 0 "0x6Dd5d190a06612A1cEb90575e6295a9C5B1BAe00"
```

## 需要注意的地方

1. 部署到已有 L1 时需要注意的几点:
  a. zkevm_l2_admin_address 账户要有超过 1000 ETH, 部署过程它会给bridge_spammer 组件的某个账户打钱
  b. 第二次部署, 需要更新 deploy_parameters.json 中的 salt 值
  c. 需要修改 cdk-node 的一行代码(适配 block hash), 修改之前需要切换到某个 release 版本的 tag, 否则会编译失败. 修改完之后需要本地 build, 然后使用自己 build 的镜像.
2. 迁移到 conflux 测试网遇到的问题
  1. l1 need fund address: 0x8943545177806ED17B9F23F0a21ee5948eCaa776(panoptichain) 和 0x8Ff13e6e26206e8DeB61A7ab634b3CF9e1605FB8(bridge spammer 随机生成)
  2. Confura 有两个不兼容的 rpc: eth_getLogs(fromBlock=earliest) 和 eth_getTransactionByBlockHashAndIndex ✅
  3. cast send 有的操作会返回失败: server returned a null response when a non-null response was expected; 可能是因为 eth_feeHistory 失败概率比较高导致
  4. 另外两个错误:
    ```shell
    [2025-09-17 06:44:33] Setting the data availability committee
    error: invalid value 'null' for '[TO]': invalid string length

    For more information, try '--help'.
    [2025-09-17 06:44:33] Setting the data availability protocol
    Error: parser error:
    null
    ^
    expected hex digits or the `0x` prefix for an empty hex string
    ```
    此两个操作执行时, 会从 combined.json 中读取地址 `polygonDataCommitteeAddress`, 但是该地址为 null, 导致报错.
    因为只有 validium  模式, 才会在部署合约 PolygonDataCommittee.
    所以此错误可以忽略

3. 随着服务的运行, sequenced batch 和 verified batch 的上链时间间隔会扩大, 服务刚启动为 5 分钟, 运行三四天后为经常会 10 分钟, 观察到 postgres 的数据和 cpu 负载很高, 
    怀疑是数据库压力过大导致, 因此可考虑将数据库服务拆分到单独的服务器上.

### 需要额外配置的账户

1. panoptichain 组件的 0x8943545177806ED17B9F23F0a21ee5948eCaa776
2. 如果启动 bridge spammer 组件, 则会随机生成一个新的账户, 并在 l1 和 l2 上给该账户打钱


kurtosis 中生成新账户的方式:

1. cast wallet new
2. cast wallet private-key
3. polycli wallet inspect --mnemonic
  

### 关于 db

cdk 的多个组件会用到 postgres 数据库. 该数据库的大小会随着时间快速增长, 经过查看主要是 pool-manager 的数据库增长较快.

其中 transaction.status = 'invalid' 目前发现有两种:

1. INTERNAL_ERROR: queued sub-pool is full: 并且此种交易还在不断增加, 应该是某个组件做某些工作的结果
2. INTERNAL_ERROR: insufficient funds
3. ALREADY_EXISTS: already known
4. method handler crashed

cdk 也可配置使用外部的数据库, 而不是自行部署一个 postgres 容器, 具体参看 database.star

```sh
psql -h 127.0.0.1 -p 51300 -U pool_manager_user -d pool_manager_db
psql -h 127.0.0.1 -p 51300 -U bridge_user -d bridge_db
redacted


select count(*) from pool.transaction where status = 'invalid' and error = 'INTERNAL_ERROR: queued sub-pool is full';

DELETE FROM pool.transaction
WHERE id IN (
    SELECT id
    FROM pool.transaction
    WHERE status = 'invalid' and error = 'INTERNAL_ERROR: queued sub-pool is full'
    ORDER BY id
    LIMIT 500000
);

SELECT DISTINCT error FROM pool.transaction WHERE status = 'invalid';

SELECT DISTINCT from_address FROM pool.transaction WHERE status = 'invalid' and error = 'INTERNAL_ERROR: insufficient funds';
SELECT
```

#### 配置使用外部数据库

1. deploy_databases: false
2. 修改 databases.star
  a. USE_REMOTE_POSTGRES = True
  b. POSTGRES_HOSTNAME = "your_postgres_host"
  c. 根据需要创建 用户, db, 初始化操作

aggregator_db
aggregator_syncer_db
bridge_db
dac_db
op_succinct_db
pool_manager_db
prover_db

```sql
CREATE USER master_user WITH PASSWORD 'master_password';
CREATE DATABASE master OWNER master_user;
GRANT ALL PRIVILEGES ON DATABASE master TO master_user;

ALTER ROLE master_user CREATEDB;
ALTER ROLE master_user CREATEROLE;
ALTER ROLE master_user LOGIN;
ALTER ROLE master_user SUPERUSER;
ALTER ROLE master_user NOSUPERUSER;

# 查看某用户权限
\du master_user
```

```sql
-- init sql
    \connect master master_user;
    CREATE USER aggregator_user with password 'redacted';
    CREATE DATABASE aggregator_db OWNER aggregator_user;

    grant all privileges on database aggregator_db to aggregator_user;

    \connect master master_user;
    CREATE USER aggregator_syncer_db_user with password 'redacted';
    CREATE DATABASE aggregator_syncer_db OWNER aggregator_syncer_db_user;

    grant all privileges on database aggregator_syncer_db to aggregator_syncer_db_user;

    \connect master master_user;
    CREATE USER bridge_user with password 'redacted';
    CREATE DATABASE bridge_db OWNER bridge_user;

    grant all privileges on database bridge_db to bridge_user;

    \connect master master_user;
    CREATE USER dac_user with password 'redacted';
    CREATE DATABASE dac_db OWNER dac_user;

    grant all privileges on database dac_db to dac_user;

    \connect master master_user;
    CREATE USER op_succinct_user with password 'op_succinct_password';
    CREATE DATABASE op_succinct_db OWNER op_succinct_user;

    grant all privileges on database op_succinct_db to op_succinct_user;

    \connect master master_user;
    CREATE USER pool_manager_user with password 'redacted';
    CREATE DATABASE pool_manager_db OWNER pool_manager_user;

    grant all privileges on database pool_manager_db to pool_manager_user;

    \connect master master_user;
    CREATE USER prover_user with password 'redacted';
    CREATE DATABASE prover_db OWNER prover_user;

        \connect prover_db prover_user;
        CREATE SCHEMA state;

CREATE TABLE state.nodes (hash BYTEA PRIMARY KEY, data BYTEA NOT NULL);
CREATE TABLE state.program (hash BYTEA PRIMARY KEY, data BYTEA NOT NULL);



    grant all privileges on database prover_db to prover_user;
    ```

### 如何保证 l2 的持续运行

1. 机器资源足够: 主要是硬盘
2. sequence sender 和 aggregator 在 L1 上有足够的 eth 用于支付 gas 费用
3. 确保 panoptichain 的 l1_sender_address (0x8943545177806ED17B9F23F0a21ee5948eCaa776) 有足够的 eth 用于支付手续费, 该组件应该主要是用来测试 L1 和 l2 的可用性
4. 如果启用了 bridge_spammer, tx_spammer, test_runner 等组件, 需要确保他们发交易的账户有足够的 eth

## 信息总结

### cdk 0.4.8 相比之前版本差异

1. zkevm-contracts 被重命名为 agglayer-contracts

### docker 访问宿主机

docker 内服务访问宿主机服务, 可使用 ip http://172.17.0.1:8545

### 如何复用 L1 之前部署的合约

```yml
use_previously_deployed_contracts: true
```

还需要准备一些配置文件, docs/_legacy_docs 中可能有相关文档

### 组件差异

CDK deploy to exist l1, 相比部署整套的 L1 + CDK 缺少的组件, 前四个应该为 L1 组件:

```sh
068a127c9bfe   cl-1-lighthouse-geth                             http: 4000/tcp -> http://127.0.0.1:50011                  RUNNING
                                                                metrics: 5054/tcp -> http://127.0.0.1:50012
                                                                quic-discovery: 50013/udp -> 127.0.0.1:50013
                                                                tcp-discovery: 50010/tcp -> 127.0.0.1:50010
                                                                udp-discovery: 50010/udp -> 127.0.0.1:50010
07eb65ad4e6c   el-1-geth-lighthouse                             engine-rpc: 8551/tcp -> 127.0.0.1:50001                   RUNNING
                                                                metrics: 9001/tcp -> http://127.0.0.1:50002
                                                                rpc: 8545/tcp -> 127.0.0.1:50003
                                                                tcp-discovery: 50000/tcp -> 127.0.0.1:50000
                                                                udp-discovery: 50000/udp -> 127.0.0.1:50000
                                                                ws: 8546/tcp -> 127.0.0.1:50004
a33abe54eb2f   validator-key-generation-cl-validator-keystore   <none>                                                    RUNNING
5e10fef92c23   vc-1-geth-lighthouse                             metrics: 8080/tcp -> http://127.0.0.1:50020               RUNNING
54e89dd5c999   zkevm-bridge-proxy-001                           web-ui: 80/tcp -> http://127.0.0.1:51220                  RUNNING
```

zkevm-bridge-proxy-001 服务因为脚本逻辑和配置未启动, 需要修改 kurtosis-cdk 的脚本逻辑

### 测试账户
Phrase:
slice avocado mutual shield affair puppy gap seed afford hip alley slab

export PK="0x2a22f4a6dfc0ed2182e839409cd2e743ddbf63f131def86ef8b50e47f0f3b55f"
Accounts:
- Account 0:
Address:     0x939EFDb3a33f09415d60060b9cdf879671385740
Private key: 0x2a22f4a6dfc0ed2182e839409cd2e743ddbf63f131def86ef8b50e47f0f3b55f

```json
{
  "RootKey": "xprv9s21ZrQH143K2HzCpWNK8yZDbqJh8on7xth2oV7D35yQWq158oWRCfvtn1h1kSFAZAGdbachUMnPfd7RgTZHHFXXKAabf5Wqjexmv2UL28Q",
  "Seed": "91ab935d5ffbe25361f5dc3733a3b4eba473b2575237eefe66a8195ffca4c23b605a7b329fe501203466edbb51f7401bf07b3d33394bef7288d107c37fcc8ab3",
  "Mnemonic": "slice avocado mutual shield affair puppy gap seed afford hip alley slab",
  "DerivationPath": "m/44'/60'/0'",
  "AccountPublicKey": "xpub6D95mVrG8PsBgE7n7KCrP4Z1arvPLngjfK9W2VsLByfYbhQRXWn8KmYfLUyevzpSzcS9cA9V5H9bo9nja42LFu1yaw1RkdspyUsRQpqfZbC",
  "AccountPrivateKey": "xprv9z9jMzKNJ2JtTk3K1Hfr1vcH2q5twKxtJ6DuE7Tide8Ziu5GyyTsmyEBVCyBcPbCUV9z8WTcc6okBoMDNaAPCRQRGTZ5kFJAyhmbNuAsztt",
  "BIP32PublicKey": "xpub6FGDsnoTpDGHSSjiwQe2DZgF55aPAYwSkJGcnN1TJg5bQbtrdMGQTwhxUHWRDaoejNZY43XBCyExXpcCbkq34aHBKEDzW4h1JGE6qHciL2M",
  "BIP32PrivateKey": "xprvA2GsUHGZyqhzDxfFqP71rRjWX3jtm6DbP5M1yybqkLYcXoZi5ox9v9PUczp6vTrQHUMD6K1PnPsVqbH3SA6kv6LHwhe5GVJgkqw932BXrkM",
  "Addresses": [
   {
    "Path": "m/44'/60'/0'/0/0",
    "HexPublicKey": "0228c8031bda1aae688f602c5f335fc7d48723387ca04b9120f55b00238e251877",
    "HexFullPublicKey": "28c8031bda1aae688f602c5f335fc7d48723387ca04b9120f55b00238e251877475418803fff1b3df8f20b33518e172cb44aa0a5650ef6ab4a2b65c604521c26",
    "HexPrivateKey": "2a22f4a6dfc0ed2182e839409cd2e743ddbf63f131def86ef8b50e47f0f3b55f",
    "ETHAddress": "0x939EFDb3a33f09415d60060b9cdf879671385740",
    "BTCAddress": "1JpL1BsbBxUxeuEqpb1v15iG93TDkfdYbz",
    "WIF": "KxdcqxpA5wbT2NdzA5dy7uWMnPnkqu8pKPZeUMqdV9CsCPpCZiDH"
   },
   {
    "Path": "m/44'/60'/0'/0/1",
    "HexPublicKey": "0219697f4e157709a494ef27be7c4862a3d8a512cc9a0ff9bd26143574a5f21831",
    "HexFullPublicKey": "19697f4e157709a494ef27be7c4862a3d8a512cc9a0ff9bd26143574a5f21831c30a95d06759662e008a9a88cc589d7015dc10eec39b499918688c1540ce9404",
    "HexPrivateKey": "c3510e3b3ab6516cd0ce1ab6c325009c8c30d2d70d2501d173cc87c5b015d415",
    "ETHAddress": "0x6Dd5d190a06612A1cEb90575e6295a9C5B1BAe00",
    "BTCAddress": "1NY6ncZBwKnXGi8JVcGNdPUh4fqGq9jfS5",
    "WIF": "L3mP3WodTF25rgQZ32tVqPVo1Tu1rdoqoDfUwgYJd1JH2i2nmfM2"
   },
   {
    "Path": "m/44'/60'/0'/0/2",
    "HexPublicKey": "03ed8b6902450e358a47e6c77872fde9307613b4aa7cd184776997a30f792fc71f",
    "HexFullPublicKey": "ed8b6902450e358a47e6c77872fde9307613b4aa7cd184776997a30f792fc71f8ed03d1d2c719fadd607ea8f60c9adc3d08d4134abc3c2ce7fb0b79427389617",
    "HexPrivateKey": "de293a47671753c18d6bd1a4c93215cb5a3fcbad0b4750523b68d57482dd6b9a",
    "ETHAddress": "0x7Fe2c67EdAc4C4d1432beE614f79BC7325725405",
    "BTCAddress": "1LM5pTtMx4Dagj4FDDKnhcDmdktHV4yDRu",
    "WIF": "L4fZbvh8Zpg2JxCduavcmKxuvS48x6AqxdRrhHfqQBkkzQturSpU"
   },
   {
    "Path": "m/44'/60'/0'/0/3",
    "HexPublicKey": "036364f014555124d6b2ef25339a4d09f1bf5d5fbacfd20045a3326a254befddf6",
    "HexFullPublicKey": "6364f014555124d6b2ef25339a4d09f1bf5d5fbacfd20045a3326a254befddf6eabd6d5c6c0547e934f47ddbbe651cbf521b25dd600fad5daa425c0453ec2677",
    "HexPrivateKey": "82296f7cebe1e9771fa27481cdc0789788db2ba2a28d98c9422dcb7ad165e0a2",
    "ETHAddress": "0x73D0DC20aBF79ED272346440eDcd0df21EB091De",
    "BTCAddress": "183nVPMG25nNwHqPfbuB8D2KvoEaYzJrXA",
    "WIF": "L1ajD1HyK9JWxhQGPJhzLqzDPrSTJ6tcB5LWP5otQU9CPu9rkbLB"
   },
   {
    "Path": "m/44'/60'/0'/0/4",
    "HexPublicKey": "03c2458c050075b79e8f0864e865706bd3f18561418687c912184797344f05bea6",
    "HexFullPublicKey": "c2458c050075b79e8f0864e865706bd3f18561418687c912184797344f05bea63be67ef2f4ec082387b0118744dbd2d155e6cd1d5c2f02dea2de23ed5b9f90bf",
    "HexPrivateKey": "4bb363e92e9d53bc38e9ec28dbfb84785a38c6ad184090c49118d50cbe511502",
    "ETHAddress": "0x8956d13525Fa141c45569745b71E60Fd332136f1",
    "BTCAddress": "1LVHjcBRsDe5hKT6zpGcpsHUFNHine5zGh",
    "WIF": "Kyks2AyhBmmjXxNx2PiivDXtFzV72fgfN7MaDYEhoZrMkxRfQzgM"
   },
   {
    "Path": "m/44'/60'/0'/0/5",
    "HexPublicKey": "02666e4daa963cdf25dd33143539c6d43c5abbf013bf44b38094771e577220908b",
    "HexFullPublicKey": "666e4daa963cdf25dd33143539c6d43c5abbf013bf44b38094771e577220908b4b7cf7c5178ab1828ea6632846cfbc5613de449b4c41028cd66a7fe7784978d2",
    "HexPrivateKey": "db16beb632d0ec1d775a4d90d9f4c3c16955123cbcc9a31398d3a736c3a9fccc",
    "ETHAddress": "0x44dE328DFADee5eAbFF836Aa6946f1AF0688Cb9a",
    "BTCAddress": "1JY9ZzHBbVLZ1ZuYyeDtKqbvBpG4kpha8t",
    "WIF": "L4ZbEHJh7HNRA5mpf1mWNZWfzCTygwQc9yHV65DRDqxwqu7jNfGV"
   },
   {
    "Path": "m/44'/60'/0'/0/6",
    "HexPublicKey": "02c57a506c933875f535923c8ff2c6d31e08f2116e7931c98adb616ecffa0c4f7a",
    "HexFullPublicKey": "c57a506c933875f535923c8ff2c6d31e08f2116e7931c98adb616ecffa0c4f7aea6b7352c1246e8d42f426e61f4fd68df04f75c7c42383c0587159be42c1e4dc",
    "HexPrivateKey": "96c7c3c3006bd4d1accb13293c6a0cf82f1f8549d8ac2c712a00db60346a3b8a",
    "ETHAddress": "0x06B507b692895705CADC1F41d9EB584AcB5eFe87",
    "BTCAddress": "1AHqtRZ5qhvmhjEV8gnvFFnfZsCGZ3CePk",
    "WIF": "L2GopqivJ1phr6syMj6Q4sJHvnpoLXs1vgV9CMCVwGcSkQCXz7YW"
   },
   {
    "Path": "m/44'/60'/0'/0/7",
    "HexPublicKey": "0246380c9a0cb05e7f4ec96ba1a407a02335733fcff696fbe3a8732859dcb93a85",
    "HexFullPublicKey": "46380c9a0cb05e7f4ec96ba1a407a02335733fcff696fbe3a8732859dcb93a8560de0972484e6936373dfeb9964f1cafb17443e299eb86070ecaf27e1c749990",
    "HexPrivateKey": "36d34100ae1aae996176fa3e61a5e125441f61a05c0f0c4dd98cd9e11398a7d0",
    "ETHAddress": "0x5aeA3b604d409e91a7e3c3f40aAB1C3306300E37",
    "BTCAddress": "1FFQQLxzfJhoAKsn13BR2XJLT4NdNzQPtb",
    "WIF": "Ky4HRP7fwrou3iEyKiXaCHhp8aiifLAYp35pbzvLTs1DedGfdv1v"
   },
   {
    "Path": "m/44'/60'/0'/0/8",
    "HexPublicKey": "03c248e5740a4ab5893e72a636423127071d5aa072b2b3b4a0e84c2080e084127e",
    "HexFullPublicKey": "c248e5740a4ab5893e72a636423127071d5aa072b2b3b4a0e84c2080e084127e3ba011604bead688efc8a2330607f73a7e639c5d3cfa7aa3cb0a48e53878d959",
    "HexPrivateKey": "efa32ac9745248cb8b63b063e9a0c97b91faef5a555b0be42e96700709653c58",
    "ETHAddress": "0xba8A619760d51664fa3C1f2b0d2E8a7c85d95402",
    "BTCAddress": "1GKKexuRVGy1FWr8o3vVgZHRyZ93hjHJRZ",
    "WIF": "L5FXxhuG7WWmUNKMWhXPyiwYSddGfv4kPSre8xurRUaSWToZegJo"
   },
   {
    "Path": "m/44'/60'/0'/0/9",
    "HexPublicKey": "03490a2e9ce4dae07268342488ececdb74114c07942c80b2800e787f3d8ade04a6",
    "HexFullPublicKey": "490a2e9ce4dae07268342488ececdb74114c07942c80b2800e787f3d8ade04a6a995a3a29b2e077a9c488c9601f2669cf6b8d4d112645733cacd4d13296d7f35",
    "HexPrivateKey": "ceb8e59c475a7563fb36d58d55cd22eac66bd3be1a380acad6e57d9415dc892c",
    "ETHAddress": "0x33000A529557D23D8a785A8dde0F900F31e97d67",
    "BTCAddress": "13LgkEBtdZwWUDVmWjQpYC8oMArsVAMJLy",
    "WIF": "L49YxwcjVeLjLKQJCExjavVYDwf3w23ZsF8g2wG1ZAbmPheEdk7N"
   }
  ]
 }
```


### cdk error

应该是因为区块回滚导致的错误, 正常现象, 不影响系统正常运行

```shell
[cdk-node-001] 2025-09-19T02:49:27.645Z	ERROR	txbuilder/banana_base.go:152	error getting CounterL1InfoRoot: error calling GetLatestInfoUntilBlock with block num 232702740: given block(s) have not been processed yet%!(EXTRA string=
[cdk-node-001] /go/src/github.com/0xPolygon/cdk/log/log.go:257 github.com/0xPolygon/cdk/log.Errorf()
[cdk-node-001] 2025-09-19T02:49:27.646Z	ERROR	sequencesender/sequencesender.go:318	error getting sequences: error calling GetLatestInfoUntilBlock with block num 232702740: given block(s) have not been processed yet	{"pid": 9, "version": "v0.5.4", "module": "sequence-sender"}
```

因为最新区块发生了 reorg, 导致 evmdownloader.Download 方法的 ctx 被 cancel 了, 所以触发了此错误
```shell
[cdk-node-001] 2025-09-19T03:19:22.052Z	ERROR	sync/evmdownloader.go:140	error getting last finalized block: Post "http://172.17.0.1:3030": context canceled	{"pid": 9, "version": "v0.5.4", "syncer": "l1infotreesync"}
```

### l1 error rpc log

应该是因为区块回滚导致的错误, 正常现象, 不影响系统正常运行

```sh
2025-09-21T01:57:32.493Z error: Req-18992 Error: {"method":"eth_getLogs","params":[{"address":["0xf64d95c79d8000daea79bb5c10a04ad911fa7ad5","0x14411d03e4833089ed5327dd52d6cf60e8563541"],"fromBlock":"0xde15ae9","toBlock":"0xde15ae9","topics":null}],"error":{"code":-32016,"message":"Error processing request: Filter error: Filter has wrong epoch numbers set (from: 232872681, to: 232872680)"}}
```

### l2 rpc error log

```sh
# RPC 请求问题: 不应该同时指定 gasPrice 和 (maxFeePerGas or maxPriorityFeePerGas)
[cdk-erigon-rpc-001] [WARN] [09-21|02:13:29.554] [rpc] served                             conn=172.16.0.30:47784 method=eth_call reqid=6 t=135.681µs err="both gasPrice and (maxFeePerGas or maxPriorityFeePerGas) specified"
# 某个账户的余额不足
[cdk-erigon-rpc-001] [WARN] [09-21|02:13:30.016] [rpc] served                             conn=172.16.0.21:35318 method=eth_sendRawTransaction reqid=17 t=2.721452ms err="RPC error response: INTERNAL_ERROR: insufficient funds"
```