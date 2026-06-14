import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://www.xn--wcv59z.com';

cli({
  site: 'jiaofu',
  name: 'search',
  description: '在教父 BT 站搜索电影/剧集并返回所有磁力资源',
  access: 'read',
  example: 'opencli jiaofu search "暴裂无声" -f json',
  domain: 'www.xn--wcv59z.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词（中文/英文片名）' },
    { name: 'kind', default: 'mv', choices: ['mv', 'tv', 'ac', 'any'], help: '类型：mv=电影 tv=剧集 ac=动漫 any=不限' },
    { name: 'limit', type: 'int', default: 50, help: '返回磁力数量上限' },
  ],
  columns: ['title', 'size', 'seeds', 'date', 'magnet'],
  func: async (page, args) => {
    const keyword = args.keyword;
    const limit = Number(args.limit) || 50;
    const kindPrefix = args.kind === 'any' ? null : `/${args.kind}/`;

    // 1) 搜索页拿候选影片
    const searchUrl = `${HOST}/search?q=${encodeURIComponent(keyword)}`;
    await page.goto(searchUrl, { waitUntil: 'load', settleMs: 1000 });
    await page.wait({ selector: 'main', timeout: 8 }).catch(() => {});

    const candidates = await page.evaluate(`
      (() => {
        const out = [];
        const seen = new Set();
        document.querySelectorAll('main a[href^="/mv/"], main a[href^="/tv/"], main a[href^="/ac/"]').forEach(a => {
          const href = a.getAttribute('href');
          if (seen.has(href)) return;
          seen.add(href);
          out.push(href);
        });
        return out;
      })()
    `);

    if (!candidates.length) return [];

    // 2) 按 kind 过滤；取第一个匹配的候选
    let target = candidates[0];
    if (kindPrefix) {
      const matched = candidates.find(h => h.startsWith(kindPrefix));
      if (matched) target = matched;
    }

    // 3) 详情页提取磁力
    const detailUrl = `${HOST}${target}`;
    await page.goto(detailUrl, { waitUntil: 'load', settleMs: 1000 });
    await page.wait({ selector: 'a[href^="magnet:"]', timeout: 10 }).catch(() => {});

    const rows = await page.evaluate(`
      (() => {
        const rowMap = new Map();
        document.querySelectorAll('a[href^="magnet:"]').forEach(a => {
          const tr = a.closest('tr');
          if (!tr) return;
          if (!rowMap.has(tr)) rowMap.set(tr, []);
          rowMap.get(tr).push(a.href);
        });
        const out = [];
        for (const [tr, magnets] of rowMap) {
          const cells = tr.querySelectorAll('td');
          const titleCell = cells[0];
          const title = (titleCell?.innerText || '').replace(/详情[\\s\\S]*$/, '').replace(/\\s+/g, ' ').trim();
          const size = (cells[2]?.innerText || '').trim();
          const seedsTxt = (cells[3]?.innerText || '0').trim();
          const seeds = parseInt(seedsTxt, 10) || 0;
          const date = (cells[4]?.innerText || '').trim();
          out.push({ title, size, seeds, date, magnet: magnets[0] });
        }
        return out;
      })()
    `);

    return rows.slice(0, limit);
  },
});
