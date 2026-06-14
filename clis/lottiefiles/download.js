import { cli, Strategy } from '@jackwener/opencli/registry';
import { writeFile, mkdir } from 'node:fs/promises';
import { resolve, join } from 'node:path';

const HOST = 'https://lottiefiles.com';
const CDN = 'https://assets-v2.lottiefiles.com/';

function parseSlug(input) {
  if (!input) return '';
  let s = String(input).trim();
  const urlMatch = s.match(/\/free-animation\/([^/?#]+)/);
  if (urlMatch) return urlMatch[1];
  return s.replace(/^\/+|\/+$/g, '');
}

cli({
  site: 'lottiefiles',
  name: 'download',
  description: '下载 LottieFiles 免费动画（.lottie 或 .json）到本地',
  access: 'read',
  example: 'opencli lottiefiles download cute-tiger-mQRL44hfYB --out ./anims --fmt lottie',
  domain: 'lottiefiles.com',
  strategy: Strategy.COOKIE,
  browser: true,
  args: [
    { name: 'slug', required: true, positional: true, help: '动画 slug（如 cute-tiger-mQRL44hfYB）或完整 URL' },
    { name: 'out', default: '.', help: '输出目录（默认当前目录）' },
    { name: 'fmt', default: 'lottie', choices: ['lottie', 'json'], help: '文件格式：lottie=dotLottie ZIP（小，默认），json=原始 Lottie JSON' },
    { name: 'name', help: '自定义输出文件名（不含扩展名，默认用 slug 的可读形式）' },
  ],
  func: async (page, args) => {
    const slug = parseSlug(args.slug);
    if (!slug) throw new Error('Missing slug');
    const format = args.fmt === 'json' ? 'json' : 'lottie';
    const outDir = resolve(String(args.out || '.'));

    // 1) 用浏览器会话调 API（同源，带 cookies，绕过 Cloudflare）
    await page.goto(`${HOST}/free-animation/${slug}`, { waitUntil: 'load', settleMs: 800 });
    const meta = await page.evaluate(`
      fetch('/api/v1/animation/${slug.replace(/'/g, '')}', { credentials: 'include' })
        .then(r => r.ok ? r.json() : Promise.reject(new Error('http_' + r.status)))
        .then(j => ({
          id: j.data && j.data.id,
          name: j.data && j.data.name,
          slug: j.data && j.data.slug,
          hash: j.data && j.data.hash,
          lottiePath: j.data && j.data.lottiePath,
          downloadCount: j.data && j.data.downloadCount,
          variants: j.data && j.data.variants,
          fileSize: j.data && j.data.meta && j.data.meta.fileSize,
        }))
    `);

    if (!meta || !meta.lottiePath) {
      throw new Error('Could not resolve lottie URL for slug: ' + slug);
    }

    // 2) 决定下载 URL
    let downloadUrl = meta.lottiePath;
    let ext = 'lottie';
    if (format === 'json') {
      const jsonVariant = (meta.variants || []).find(v => v.type === 'json' && !v.isOptimized) ||
                          (meta.variants || []).find(v => v.type === 'json');
      if (!jsonVariant) throw new Error('No JSON variant available for ' + slug);
      downloadUrl = CDN + jsonVariant.path.replace(/^\/+/, '');
      ext = 'json';
    }

    // 3) 直接拉 CDN（公开 URL，无需 cookies）
    const res = await fetch(downloadUrl);
    if (!res.ok) throw new Error('CDN fetch failed: ' + res.status + ' ' + downloadUrl);
    const buf = Buffer.from(await res.arrayBuffer());

    // 4) 写盘
    await mkdir(outDir, { recursive: true });
    const baseName = String(args.name || meta.slug || slug).replace(/[/\\?%*:|"<>]/g, '-');
    const filePath = join(outDir, `${baseName}.${ext}`);
    await writeFile(filePath, buf);

    return {
      slug,
      name: meta.name,
      path: filePath,
      size: buf.length,
      source: downloadUrl,
    };
  },
});
