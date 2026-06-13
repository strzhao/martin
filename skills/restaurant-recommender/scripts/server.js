/**
 * Restaurant Recommender HTTP 服务器
 * 零外部依赖 — 仅使用 Node.js 内置 http/fs/path 模块
 *
 * 用法: node scripts/server.js [port]
 * 默认端口: 3457
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3457;
const SKILL_ROOT = path.join(__dirname, '..');
const RESTAURANT_HTML = path.join(SKILL_ROOT, 'output', 'restaurant.html');

// 检查 HTML 文件是否存在
if (!fs.existsSync(RESTAURANT_HTML)) {
  console.error(`❌ 推荐页面不存在: ${RESTAURANT_HTML}`);
  console.error('   请先运行: python3 scripts/inject.py output/restaurant_data.json');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // 路由: / → restaurant.html (餐厅排名推荐)
  if (url.pathname === '/' || url.pathname === '/index.html') {
    const stream = fs.createReadStream(RESTAURANT_HTML);
    stream.on('error', () => {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Internal Server Error');
    });
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    stream.pipe(res);
    return;
  }

  // 路由: /health → 健康检查
  if (url.pathname === '/health') {
    try {
      const stat = fs.statSync(RESTAURANT_HTML);
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(
        JSON.stringify({
          status: 'ok',
          file: RESTAURANT_HTML,
          size: stat.size,
          updated: stat.mtime.toISOString(),
        })
      );
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ status: 'error', message: e.message }));
    }
    return;
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

server.listen(PORT, () => {
  const htmlSize = (fs.statSync(RESTAURANT_HTML).size / 1024).toFixed(1);
  console.log('');
  console.log(`🌐 餐厅排名推荐页面已上线:`);
  console.log(`   餐厅排名: http://localhost:${PORT}/`);
  console.log(`   健康检查: http://localhost:${PORT}/health`);
  console.log(`   文件: ${RESTAURANT_HTML} (${htmlSize} KB)`);
  console.log('');
  console.log('   按 Ctrl+C 停止服务');
});

// 优雅退出
process.on('SIGINT', () => {
  console.log('\n👋 服务已停止');
  process.exit(0);
});

process.on('SIGTERM', () => {
  process.exit(0);
});
