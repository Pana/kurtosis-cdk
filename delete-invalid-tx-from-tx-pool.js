const { Client } = require('pg');

// 数据库连接配置
const client = new Client({
  host: '172.23.41.26',      // 数据库地址
  port: 5432,             // 数据库端口
  user: 'pool_manager_user',  // 用户名
  password: 'redacted', // 密码
  database: 'pool_manager_db'  // 数据库名
});

async function deleteTransactions() {
  try {
    await client.connect();
    do {
        let sql = `DELETE FROM pool.transaction
            WHERE id IN (
                SELECT id
                FROM pool.transaction
                WHERE status = 'invalid' and error = 'INTERNAL_ERROR: queued sub-pool is full'
                ORDER BY id
                LIMIT 10000
            );`;
        let res = await client.query(sql);
        console.log(`Deleted full-error ${res.rowCount} rows from pool.transaction`);
        sql = `DELETE FROM pool.transaction
            WHERE id IN (
                SELECT id
                FROM pool.transaction
                WHERE status = 'invalid' and error = 'ALREADY_EXISTS: already known'
                ORDER BY id
                LIMIT 10000
            );`;
        res = await client.query(sql);
        console.log(`Deleted known-error ${res.rowCount} rows from pool.transaction`);
        sql = `DELETE FROM pool.transaction
            WHERE id IN (
                SELECT id
                FROM pool.transaction
                WHERE status = 'expired'
                ORDER BY id
                LIMIT 10000
            );`;
        res = await client.query(sql);
        console.log(`Deleted expired ${res.rowCount} rows from pool.transaction`);
        await sleep(3000);
    } while (true);
  } catch (err) {
    console.error('Error deleting transactions:', err);
  } finally {
    await client.end();
  }
}

deleteTransactions();

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}