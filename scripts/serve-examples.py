#!/usr/bin/env python3
"""Serve Cove's fictional web examples; optionally share demo files over loopback SMB."""
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, urlencode
import argparse
import html
import mimetypes
import re
import threading

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'examples/local-demo/assets'
ITEMS = [
    ('valley', '山谷慢行', 'nature', '山间的一次短暂漫游'),
    ('night', '夜航手记', 'nature', '在夜色中寻找安静'),
    ('coast', '沿海来信', 'nature', '海风与灯塔之间'),
    ('city', '城市漫游', 'city', '收藏一座城市的细节'),
    ('forest', '森林回声', 'nature', '留给绿色的一段时间'),
    ('orbit', '星际日记', 'city', '想象另一种生活'),
    ('valley-2', '山谷慢行：清晨', 'nature', '第二页的内容'),
    ('coast-2', '沿海来信：日落', 'nature', '第二页的内容'),
]


def page(title, body):
    return ('<!doctype html><html lang="zh"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{html.escape(title)}</title><style>'
            'body{max-width:1000px;margin:40px auto;padding:0 24px;background:#f4f1eb;color:#17232a;'
            'font:17px/1.7 system-ui}a{color:#5b49a2}img{max-width:100%;border-radius:14px}'
            '.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:26px}'
            '.title{font-size:22px;font-weight:600}.duration,.tag,.author{font-size:14px;color:#687879}'
            '.resource{display:block;margin:20px 0}.resource img{width:160px;vertical-align:middle;margin-right:20px}'
            'article.body{max-width:760px}header{margin-bottom:30px}video{width:100%}'
            '</style></head><body><header><a href="/">Cove 本地演示</a>'
            '<p>固定的虚构内容 · 不包含真实站点或账户</p></header>' + body + '</body></html>').encode()


def picture(identifier):
    return '/assets/' + identifier.split('-')[0] + '.png'


def catalog(kind, query):
    selected = [x for x in ITEMS if query.get('q', [''])[0] in x[1]
                and (not query.get('tag') or x[2] == query['tag'][0])]
    number = max(1, int(query.get('page', ['1'])[0]))
    visible = selected[(number - 1) * 6:number * 6]
    cards = []
    for identifier, title, tag, description in visible:
        image = picture(identifier)
        if kind == 'videos':
            cards.append(f'<article class="media-card"><a href="/watch/{identifier}"><img src="{image}" alt="{title}">'
                         f'<span class="title">{title}</span></a><div><span class="duration">00:06</span>'
                         f' · <span class="tag">{"自然" if tag == "nature" else "城市"}</span></div></article>')
        elif kind == 'comics':
            cards.append(f'<article class="book-card"><a href="/book/{identifier}"><img src="{image}" alt="{title}">'
                         f'<span class="title">{title}</span></a><div class="author">Cove 演示绘本 · 2 章</div></article>')
        else:
            cards.append(f'<article class="story"><a href="/post/{identifier}"><img src="{image}" alt="{title}">'
                         f'<h2>{title}</h2></a><p class="author">沿途编辑部</p><p>{description}</p></article>')
    next_link = ''
    if kind == 'videos' and number * 6 < len(selected):
        parameters = {k: v[0] for k, v in query.items() if k in ['q', 'tag']}; parameters['page'] = number + 1
        next_link = f'<a rel="next" href="/videos/?{html.escape(urlencode(parameters), quote=True)}">下一页</a>'
    title = {'videos': '山海影库', 'comics': '漫游书架', 'journal': '沿途手记'}[kind]
    return page(title, f'<h1>{title}</h1><div class="grid">' + ''.join(cards) + '</div>' + next_link)


def document(path, query):
    if path == '/news':
        return (ROOT / 'examples/showcase/hacker-news.html').read_bytes()
    if path == '/':
        return page('Cove 本地演示', '<h1>把内容放进自己的阅读空间</h1>'
                    '<p><a href="/videos/">山海影库</a> · <a href="/comics/">漫游书架</a> · '
                    '<a href="/journal/">沿途手记</a> · <a href="/directory/">资源导航</a></p>'
                    '<p>导入 examples/sites/local-*.site，在 Cove 中打开同一内容。</p>')
    kind = path.strip('/').split('/')[0]
    if kind in ['videos', 'comics', 'journal']:
        return catalog(kind, query)
    if kind == 'directory':
        return page('资源导航', '<h1>资源导航</h1>' + ''.join(
            f'<a class="resource" href="/videos/?tag={tag}"><img src="/assets/{cover}.png"><span class="name">{name}</span></a>'
            for tag, cover, name in [('nature', 'valley', '自然影像'), ('city', 'city', '城市影像')]))
    identifier = path.strip('/').split('/')[-1]
    item = next((x for x in ITEMS if x[0] == identifier), ITEMS[0])
    title, image = item[1], picture(item[0])
    if kind == 'watch':
        return page(title, f'<h1>{title}</h1><video controls poster="{image}"><source src="/assets/demo.mp4" type="video/mp4"></video>')
    if kind == 'book':
        return page(title, f'<h1>{title}</h1><p class="author">Cove 演示绘本</p><img class="cover" src="{image}">'
                    '<p class="description">由原创矢量素材组成的两章演示绘本，用来验证列表、详情和章节阅读。</p>'
                    '<p><a class="chapter" href="/chapter/1">第一章 · 出发</a></p><p><a class="chapter" href="/chapter/2">第二章 · 归来</a></p>')
    if kind == 'chapter':
        covers = ['valley', 'coast', 'forest'] if identifier == '1' else ['city', 'orbit', 'night']
        navigation = '<a rel="next" href="/chapter/2">下一章</a>' if identifier == '1' else '<a rel="prev" href="/chapter/1">上一章</a>'
        return page('演示章节', '<main>' + ''.join(f'<img src="/assets/{x}.png" alt="原创演示页面">' for x in covers) + '</main>' + navigation)
    if kind == 'post':
        return page(title, f'<h1>{title}</h1><p class="author">沿途编辑部</p><article class="body">'
                    f'<p>{item[3]}。把路上遇到的影像和文字收进同一个地方，下次就能从这里继续。</p><img src="{image}" alt="{title}的原创演示插画">'
                    '<h2>沿途，慢一点</h2><p>看一段视频，读一页图文，也可以继续翻开书架里的故事。不同来源，共用熟悉的阅读方式。</p>'
                    '<blockquote>这里的标题、作者、插画和正文都是固定演示素材。</blockquote>'
                    '<p><a href="/journal/">回到手记列表</a></p></article>')
    return None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        request = urlsplit(self.path)
        if request.path.startswith('/assets/'):
            target = (ASSETS / request.path.removeprefix('/assets/')).resolve()
            if target.parent != ASSETS.resolve() or not target.is_file():
                self.send_error(404); return
            data = target.read_bytes(); media = mimetypes.guess_type(target.name)[0] or 'application/octet-stream'
        else:
            try: data = document(request.path, parse_qs(request.query))
            except ValueError: self.send_error(400); return
            if data is None: self.send_error(404); return
            media = 'text/html; charset=utf-8'
        total = len(data); start = 0; end = total - 1
        header = self.headers.get('Range') if request.path.startswith('/assets/') else None
        if header:
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', header)
            if not match: self.send_error(416); return
            start = int(match[1]); end = min(end, int(match[2])) if match[2] else end
            if start > end or start >= total: self.send_error(416); return
            data = data[start:end + 1]
        self.send_response(206 if header else 200); self.send_header('Content-Type', media)
        if header: self.send_header('Content-Range', f'bytes {start}-{end}/{total}')
        self.send_header('Accept-Ranges', 'bytes'); self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def log_message(self, *_): pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--smb', action='store_true', help='Also serve only the synthetic NAS files on loopback port 1445')
    args = parser.parse_args()
    if args.smb:
        try: from impacket.smbserver import SimpleSMBServer
        except ImportError: parser.error('Optional SMB demo needs impacket; see examples/nas/README.md')
        server = SimpleSMBServer(listenAddress='127.0.0.1', listenPort=1445)
        server.addShare('CoveDemo', str(ROOT / 'examples/nas/files'), shareComment='Cove synthetic demo', readOnly='yes')
        server.setSMB2Support(True)
        threading.Thread(target=server.start, daemon=True).start()
    print(f'Cove examples: http://{args.host}:{args.port}/', flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
