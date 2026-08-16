#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模拟 VidAll_TV 的刮削 + SubHub 字幕搜索，评估结果准确度。"""
import json, os, re, sys, urllib.parse, urllib.request, time

TMDB_KEY = os.environ.get("TMDB_API_KEY", "")
SUBHUB_KEY = os.environ.get("SUBHUB_API_KEY", "")
SUBHUB_BASE = "https://subhub.softeehub.com"

FILES = os.environ.get("FILES", "")

VIDEO_EXT = {'.mkv', '.mp4', '.m4v', '.avi', '.ts', '.mov', '.wmv', '.flv', '.webm', '.m2ts', '.mpg', '.mpeg', '.rmvb', '.rm'}
# 排除的干扰项（隐藏临时文件 / 下载临时 / 字幕 / 元数据）
BAD_SUFFIX = ('.fg', '.fg.ed', '.fg.op', '.nfo', '.torrent', '.js', '.srt', '.ass', '.ssa', '.smi', '.sub', '.jpg', '.png', '.json', '.xml', '.txt', '.ini')


def parse_file_name(fn: str):
    without_ext = re.sub(r'\.[^.]+$', '', fn)
    year = None
    m = re.search(r'[.\[(]((?:19|20)\d{2})[.)\]]', without_ext)
    if m:
        year = int(m.group(1))
    season = episode = None
    m = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', without_ext)
    if not m:
        m = re.search(r'[Ss](\d{1,2})\b.*?\b[Ee][Pp]?\s*(\d{1,3})\b', without_ext)
    if m:
        season = int(m.group(1))
        episode = int(m.group(2))
    media_type = 'tv' if m else 'movie'
    work = without_ext
    work = re.sub(r'[.\[(]((?:19|20)\d{2})[.)\]]', ' ', work)
    work = re.sub(r'[Ss]\d{1,2}[Ee]\d{1,3}.*', '', work, flags=re.I)
    q = re.search(r'\b(1080p|720p|4k|2160p|480p|uhd|hdr|hdr10|hdr10plus|bluray|blu-ray|web-?dl|webrip|hdtv|dvdrip|bdrip|x264|x265|hevc|h\.?264|h\.?265|aac|aac\d\.\d|dts|dts-?x|ddp?\d\.\d|dd5\.?1|ac3|atmos|truehd|remux|proper|repack|imax|dv|\d{1,2}bit|\d\.\d)\b', work, flags=re.I)
    if q:
        work = work[:q.start()]
    work = re.sub(r'[\[\]()]', ' ', work)
    work = re.sub(r'[._-]', ' ', work)
    title = re.sub(r'\s{2,}', ' ', work).strip()
    return {'title': title, 'year': year, 'media_type': media_type, 'season': season, 'episode': episode}


def has_english(s):
    return bool(re.search(r'[A-Za-z]{2,}', s))


def build_search_title(parsed_title: str) -> str:
    # 模拟 buildSearchTitles 的首候选
    m = re.search(r"[A-Za-z][A-Za-z0-9\s''\-:,!?&.]+", parsed_title)
    english = m.group(0).strip() if m else ''
    if has_english(parsed_title) and english:
        return english
    return parsed_title.strip()


def http_json(url: str):
    req = urllib.request.Request(url, headers={'User-Agent': 'VidAll-Eval/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def tmdb_search_movie(title, year):
    q = urllib.parse.quote(title)
    u = f"https://api.themoviedb.org/3/search/movie?api_key={TMDB_KEY}&query={q}&language=zh-CN"
    if year:
        u += f"&year={year}"
    d = http_json(u)
    return d.get('results', [])


def tmdb_search_tv(title):
    q = urllib.parse.quote(title)
    u = f"https://api.themoviedb.org/3/search/tv?api_key={TMDB_KEY}&query={q}&language=zh-CN"
    d = http_json(u)
    return d.get('results', [])


def tmdb_movie_detail(tid):
    u = f"https://api.themoviedb.org/3/movie/{tid}?api_key={TMDB_KEY}&language=zh-CN"
    return http_json(u)


def tmdb_tv_detail(tid):
    u = f"https://api.themoviedb.org/3/tv/{tid}?api_key={TMDB_KEY}&language=zh-CN&append_to_response=external_ids"
    return http_json(u)


def subhub_search(params):
    qs = urllib.parse.urlencode(params)
    u = f"{SUBHUB_BASE}/api/subtitles/search?{qs}"
    req = urllib.request.Request(u, headers={'Authorization': f'Bearer {SUBHUB_KEY}', 'User-Agent': 'VidAll-Eval/1.0'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode('utf-8'))


def episode_key(rel):
    m = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', rel)
    if m:
        return (int(m.group(1)), int(m.group(2)))
    return None


def main():
    if not FILES.strip():
        print("请通过 FILES 环境变量提供评估媒体路径。", file=sys.stderr)
        sys.exit(2)
    lines = [l.strip() for l in FILES.strip().splitlines() if l.strip()]
    videos = []
    for p in lines:
        base = p.rsplit('/', 1)[-1]
        if base.startswith('.'):
            continue
        low = base.lower()
        if not any(low.endswith(e) for e in VIDEO_EXT):
            continue
        if any(low.endswith(b) for b in BAD_SUFFIX):
            continue
        videos.append(p)

    print(f"提取视频文件 {len(videos)} 个\n")
    ok = 0
    bad = 0
    skip = 0
    results = []
    for p in videos:
        time.sleep(0.25)
        base = p.rsplit('/', 1)[-1]
        parsed = parse_file_name(base)
        title = parsed['title']
        mt = parsed['media_type']
        season = parsed['season']
        episode = parsed['episode']
        folder = p.rsplit('/', 2)[-2] if '/' in p else ''

        # 1) 模拟刮削：用文件名标题去 TMDB 拿英文原名 + imdb_id
        search_title = build_search_title(title)
        zh_title = ''
        original_title = ''
        imdb_id = ''
        tmdb_id = ''
        if not search_title or re.fullmatch(r'[\d\s._-]+', search_title):
            # 纯数字/无意义标题，尝试用父目录中文名
            search_title = folder.strip()

        try:
            if mt == 'movie':
                res = tmdb_search_movie(search_title, parsed['year'])
                if res:
                    d = tmdb_movie_detail(res[0]['id'])
                    original_title = d.get('original_title') or ''
                    imdb_id = d.get('imdb_id') or ''
                    zh_title = d.get('title') or ''
                    tmdb_id = str(d.get('id', ''))
            else:
                res = tmdb_search_tv(search_title)
                if res:
                    d = tmdb_tv_detail(res[0]['id'])
                    original_title = d.get('original_name') or ''
                    imdb_id = (d.get('external_ids') or {}).get('imdb_id') or ''
                    zh_title = d.get('name') or ''
                    tmdb_id = str(d.get('id', ''))
        except Exception as e:
            results.append((p, parsed, 'SCRAPE_ERR', str(e)[:80]))
            skip += 1
            continue

        # 2) 模拟 App 的 SubHub 搜索
        q = original_title or search_title
        params = {'title': q, 'query': q, 'language': 'zh-CN'}
        if parsed['year']:
            params['year'] = parsed['year']
        if mt == 'tv':
            if season is not None and episode is not None:
                params['season'] = season
                params['episode'] = episode
                params['type'] = 'episode'
            else:
                params['type'] = 'episode'
        if imdb_id:
            params['imdb_id'] = imdb_id

        try:
            resp = subhub_search(params)
        except Exception as e:
            results.append((p, parsed, 'SUBHUB_ERR', str(e)[:80]))
            skip += 1
            continue

        data = resp.get('data') or {}
        rels = [r.get('releaseName') or '' for r in data.get('results', [])]
        failures = data.get('provider_failures') or []

        # 3) 判定准确度
        correct = False
        if mt == 'tv' and season is not None and episode is not None:
            for r in rels:
                k = episode_key(r)
                if k and k == (season, episode):
                    correct = True
                    break
        elif mt == 'movie':
            norm = re.sub(r'[^a-z0-9]+', '', (original_title or q).lower())
            for r in rels:
                if norm and norm in re.sub(r'[^a-z0-9]+', '', r.lower()):
                    correct = True
                    break
        if correct:
            ok += 1
        else:
            bad += 1

        results.append((p, parsed, zh_title, original_title, imdb_id, tmdb_id, rels, failures, correct))

    # 输出
    for r in results:
        if len(r) == 4:  # error tuple
            p, parsed, tag, msg = r
            print(f"[{tag}] {p}\n  解析: {parsed}\n  {msg}\n")
            continue
        p, parsed, zh, en, imdb, tmdb, rels, failures, correct = r
        mark = '✓' if correct else '✗'
        se = f"S{parsed['season']}E{parsed['episode']}" if parsed['season'] is not None else '-'
        print(f"{mark} [{parsed['media_type']}{' '+se if se!='-' else ''}] {p}")
        print(f"    解析标题={parsed['title']!r} → 刮削中文={zh!r} 英文={en!r} imdb={imdb} tmdb={tmdb}")
        if rels:
            print(f"    结果({len(rels)}): " + ' | '.join(x[:60] for x in rels[:3]))
        elif failures:
            print(f"    无结果，provider: {json.dumps(failures, ensure_ascii=False)}")
        else:
            print(f"    无结果")
        print()

    total = ok + bad
    print("=" * 60)
    print(f"准确 {ok}/{total}  不准确 {bad}/{total}  跳过(错误) {skip}")


if __name__ == '__main__':
    main()
