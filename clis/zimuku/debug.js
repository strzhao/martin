import { cli, Strategy } from '@jackwener/opencli/registry';

const HOST = 'https://zimuku.org';

cli({
  site: 'zimuku',
  name: 'debug',
  description: '诊断：访问 zimuku 搜索页，看是否被 Yunsuo WAF 拦截',
  access: 'read',
  example: 'opencli zimuku debug "暴裂无声"',
  domain: 'zimuku.org',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'keyword', required: true, positional: true, help: '搜索关键词' },
  ],
  columns: ['stage', 'len', 'has_yunsuo', 'has_captcha', 'has_login', 'has_results', 'title', 'preview'],
  func: async (page, args) => {
    const out = [];

    // 1) 直接访问首页（确认登录态）
    await page.goto(HOST + '/', { waitUntil: 'load', settleMs: 1500 });
    const homeInfo = await page.evaluate(`
      (() => {
        const html = document.documentElement.outerHTML;
        return {
          len: html.length,
          has_yunsuo: /yunsuo|yundun|防火墙|cloudflare/i.test(html),
          has_captcha: /captcha|验证码|geetest|滑块/i.test(html),
          has_login: /退出|登出|个人中心|我的|logout|sign\\s*out/i.test(html),
          has_results: false,
          title: document.title,
          preview: html.slice(0, 800),
        };
      })()
    `);
    out.push({ stage: 'home', ...homeInfo });

    // 2) 走标准搜索 URL（GET /search.php?q=xxx 是 zimuku 的老接口）
    const searchUrl1 = HOST + '/search?q=' + encodeURIComponent(args.keyword);
    await page.goto(searchUrl1, { waitUntil: 'load', settleMs: 2000 });
    const s1 = await page.evaluate(`
      (() => {
        const html = document.documentElement.outerHTML;
        return {
          len: html.length,
          has_yunsuo: /yunsuo|yundun|防火墙|访问已被拦截|忙碌中|安全验证/i.test(html),
          has_captcha: /captcha|验证码|geetest|滑块|请输入验证码/i.test(html),
          has_login: /退出|登出|个人中心|我的|logout/i.test(html),
          has_results: !!document.querySelector('a[href*="/detail/"], a[href*="/subs/"], .item, .clearfix .title, table tbody tr'),
          title: document.title,
          preview: html.slice(0, 1500),
        };
      })()
    `);
    out.push({ stage: 'search-page', ...s1 });

    // 3) 用 fetch（XHR）从已有页面发出，绕一些 navigation-level 检查
    const fetchInfo = await page.evaluate(`
      (async () => {
        try {
          const r = await fetch('${HOST}/search?q=' + encodeURIComponent(${JSON.stringify(args.keyword)}), {credentials:'include'});
          const html = await r.text();
          return {
            len: html.length,
            has_yunsuo: /yunsuo|yundun|防火墙|访问已被拦截|忙碌中|安全验证/i.test(html),
            has_captcha: /captcha|验证码|geetest|滑块/i.test(html),
            has_login: /退出|登出|个人中心|我的|logout/i.test(html),
            has_results: /\\/(detail|subs)\\//.test(html),
            title: (html.match(/<title>([\\s\\S]*?)<\\/title>/)?.[1] || '').trim(),
            preview: html.slice(0, 1500),
          };
        } catch (e) {
          return { len: 0, has_yunsuo: false, has_captcha: false, has_login: false, has_results: false, title: 'fetch error: ' + e.message, preview: '' };
        }
      })()
    `);
    out.push({ stage: 'search-fetch', ...fetchInfo });

    return out;
  },
});
