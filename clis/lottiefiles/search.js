import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://lottiefiles.com';

cli({
  site: 'lottiefiles',
  name: 'search',
  description: '在 LottieFiles 免费区搜索 Lottie 动画（lottiefiles.com/free-animations）',
  access: 'read',
  example: 'opencli lottiefiles search "tiger" --limit 20',
  domain: 'lottiefiles.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词（英文）' },
    { name: 'limit', type: 'int', default: 30, help: '返回数量上限' },
  ],
  columns: ['slug', 'name', 'author', 'downloads', 'url'],
  func: async (page, args) => {
    const keyword = String(args.keyword || '').trim();
    if (!keyword) return [];
    const limit = Number(args.limit) || 30;

    const url = `${HOST}/free-animations/${encodeURIComponent(keyword.toLowerCase().replace(/\s+/g, '-'))}`;
    await page.goto(url, { waitUntil: 'load', settleMs: 1500 });
    await page.wait({ selector: 'a[href*="/free-animation/"], a[href*="/animation/"]', timeout: 8 }).catch(() => {});

    const rows = await page.evaluate(`
      (() => {
        const anchors = Array.from(document.querySelectorAll('a[href*="/free-animation/"], a[href*="/animation/"]'));
        const seen = new Set();
        const out = [];
        for (const a of anchors) {
          const href = a.getAttribute('href') || '';
          if (seen.has(href)) continue;
          seen.add(href);
          const block = a.closest('div.w-full.flex.flex-col') || a.parentElement;
          const avatar = block && block.querySelector('img[alt]');
          const author = avatar ? avatar.getAttribute('alt') : '';
          // download count line: usually "<author>\\n\\n<count>"
          let downloads = '';
          const textNodes = block ? Array.from(block.querySelectorAll('span, p, div')) : [];
          for (const el of textNodes) {
            const t = (el.innerText || '').trim();
            const m = t.match(/(?:^|\\n)([\\d.]+[KMB]?)\\s*$/i);
            if (m) { downloads = m[1]; break; }
          }
          const m = href.match(/\\/(free-animation|animation)\\/(.+?)(_(\\d+))?$/);
          const slug = m ? m[2] : href.replace(/^.*\\//, '');
          const nameGuess = slug.replace(/-[A-Za-z0-9]{10}$/, '').replace(/-/g, ' ');
          out.push({
            slug,
            name: nameGuess.replace(/\\b\\w/g, c => c.toUpperCase()),
            author,
            downloads,
            url: href.startsWith('http') ? href : 'https://lottiefiles.com' + href,
          });
        }
        return out;
      })()
    `);

    return rows.slice(0, limit);
  },
});
