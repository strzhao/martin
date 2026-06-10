/**
 * Travel Planner HTTP 服务器
 * 零外部依赖 — 仅使用 Node.js 内置 http/fs/path 模块
 *
 * 用法: node scripts/server.js [port]
 * 默认端口: 3456
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3456;
const SKILL_ROOT = path.join(__dirname, '..');
const TRIP_HTML = path.join(SKILL_ROOT, 'output', 'trip.html');

// 检查 HTML 文件是否存在
if (!fs.existsSync(TRIP_HTML)) {
  console.error(`❌ 攻略文件不存在: ${TRIP_HTML}`);
  console.error('   请先运行: python3 scripts/inject.py output/trip_data.json');
  process.exit(1);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // 路由: / → trip.html
  if (url.pathname === '/' || url.pathname === '/index.html') {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    fs.createReadStream(TRIP_HTML).pipe(res);
    return;
  }

  // 路由: /health → 健康检查
  if (url.pathname === '/health') {
    const stat = fs.statSync(TRIP_HTML);
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(
      JSON.stringify({
        status: 'ok',
        file: TRIP_HTML,
        size: stat.size,
        updated: stat.mtime.toISOString(),
      })
    );
    return;
  }

  // 404
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not found');
});

server.listen(PORT, () => {
  const htmlSize = (fs.statSync(TRIP_HTML).size / 1024).toFixed(1);
  console.log('');
  console.log(`🌐 攻略页面已上线:`);
  console.log(`   本地: http://localhost:${PORT}/`);
  console.log(`   健康: http://localhost:${PORT}/health`);
  console.log(`   文件: ${TRIP_HTML} (${htmlSize} KB)`);
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
