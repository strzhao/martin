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
const TRIP2_HTML = path.join(SKILL_ROOT, 'output', 'trip2.html');
const TRIP3_HTML = path.join(SKILL_ROOT, 'output', 'trip3.html');

// 检查 HTML 文件是否存在
if (!fs.existsSync(TRIP_HTML)) {
  console.error(`❌ 攻略文件不存在: ${TRIP_HTML}`);
  console.error('   请先运行: python3 scripts/inject.py output/trip_data.json');
  process.exit(1);
}

// 缓存文件存在状态（仅在启动时检查）
const routeExists = {
  '': true,  // trip.html always exists (checked above)
  '2': fs.existsSync(TRIP2_HTML),
  '3': fs.existsSync(TRIP3_HTML),
};

function serveTripHtml(res, htmlPath, label) {
  if (fs.existsSync(htmlPath)) {
    res.writeHead(200, {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    fs.createReadStream(htmlPath).pipe(res);
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end(label + ' not found');
  }
}

const ROUTE_MAP = {
  '/': TRIP_HTML,
  '/index.html': TRIP_HTML,
  '/route2': TRIP2_HTML,
  '/route3': TRIP3_HTML,
};
const ROUTE_LABELS = {
  '/': 'Route 1',
  '/index.html': 'Route 1',
  '/route2': 'Route 2',
  '/route3': 'Route 3',
};

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  // 路线路由
  const htmlPath = ROUTE_MAP[url.pathname];
  if (htmlPath) {
    serveTripHtml(res, htmlPath, ROUTE_LABELS[url.pathname]);
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
        route2: routeExists['2'] ? 'available' : 'missing',
        route3: routeExists['3'] ? 'available' : 'missing',
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
  const r2 = routeExists['2'] ? '✅ 可用' : '❌ 未生成';
  const r3 = routeExists['3'] ? '✅ 可用' : '❌ 未生成';
  console.log('');
  console.log(`🌐 攻略页面已上线:`);
  console.log(`   路线1: http://localhost:${PORT}/      (运河 City Walk)`);
  console.log(`   路线2: http://localhost:${PORT}/route2 (萧山 City Walk) ${r2}`);
  console.log(`   路线3: http://localhost:${PORT}/route3 (滨江 City Walk) ${r3}`);
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
