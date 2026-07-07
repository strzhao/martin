import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://www.xn--wcv59z.com';

cli({
  site: 'jiaofu',
  name: 'list',
  description: '列出教父站影片卡片（含豆瓣分/评分人数/状态/年份/地区/类型），支持排序与状态筛选',
  access: 'read',
  example: 'opencli jiaofu list --kind tv --sort date --status 完结 -f json',
  domain: 'www.xn--wcv59z.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'kind', default: 'tv', choices: ['mv', 'tv', 'ac'], help: '类型：mv=电影 tv=剧集 ac=动漫' },
    { name: 'sort', default: 'date', choices: ['date', 'uptime', 'uptime', 'score', 'number', 'numbers', 'cscore'],
      help: '排序：date=首播时间 uptime=更新时间 score=评分最高 number=评分人数 cscore=综合' },
    { name: 'status', default: '', help: '状态过滤：预告 / 连载 / 完结，留空=不限' },
    { name: 'page', type: 'int', default: 1, help: '页码（每页约 48 条）' },
    { name: 'limit', type: 'int', default: 48, help: '返回条数上限' },
  ],
  columns: ['title', 'href', 'douban', 'rating_count', 'status', 'year', 'region', 'genre'],
  func: async (page, args) => {
    const params = new URLSearchParams();
    params.set('sort', args.sort);
    if (args.status) params.set('status', args.status);
    if (Number(args.page) > 1) params.set('page', String(args.page));
    const listUrl = `${HOST}/${args.kind}?${params.toString()}`;

    // 列表页主体公开，但复用登录态 cookie 可避开部分频控
    await page.goto(listUrl, { waitUntil: 'load', settleMs: 1200 });
    await page.wait({ selector: 'main li', timeout: 8 }).catch(() => {});

    const limit = Number(args.limit) || 48;
    const rows = await page.evaluate(`
      (() => {
        // 取 use[href="#icon-douban"] / ["#icon-fire"] 各自所在 svg 之后的 <i> 文本
        const iAfter = (use) => {
          if (!use) return '';
          const svg = use.closest('svg');
          const n = svg ? svg.nextElementSibling : null;
          return (n && n.tagName === 'I') ? n.textContent.trim() : '';
        };
        const out = [];
        document.querySelectorAll('main li').forEach(li => {
          const a = li.querySelector('a[href][title]');
          if (!a) return;
          const useDb = li.querySelector('use[href="#icon-douban"]');
          const useFire = li.querySelector('use[href="#icon-fire"]');
          const bottom = li.querySelector('[class*=bottom]');
          const tag = (li.querySelector('.tag')?.innerText || '').replace(/\\s+/g, ' ').trim();
          const tagParts = tag.split('/').map(s => s.trim()).filter(Boolean);
          out.push({
            title: a.getAttribute('title') || a.innerText.trim(),
            href: a.getAttribute('href'),
            douban: iAfter(useDb),          // 豆瓣分（无分时为 "--"）
            rating_count: iAfter(useFire),  // 评分人数（无人评时为 "--"）
            status: bottom ? (bottom.querySelector('span:last-child')?.innerText || '').replace(/\\s+/g, ' ').trim() : '',
            year: tagParts[0] || '',
            region: tagParts[1] || '',
            genre: tagParts.slice(2).join(' / '),
          });
        });
        return out;
      })()
    `);
    return rows.slice(0, limit);
  },
});
