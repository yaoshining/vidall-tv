#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模拟 VidAll_TV 的刮削 + SubHub 字幕搜索，评估结果准确度。"""
import json, os, re, sys, urllib.parse, urllib.request, time

TMDB_KEY = os.environ.get("TMDB_API_KEY", "")
SUBHUB_KEY = os.environ.get("SUBHUB_API_KEY", "")
SUBHUB_BASE = "https://subhub.softeehub.com"

FILES = os.environ.get("FILES", r'''
/volume1/Videos/测试视频/571aca35-18c7a955216.mp4
/volume1/Videos/Samples/MediaStorm/十小时助眠样片_杜比音效.mp4
/volume1/Videos/TV Series/御赐小仵作第二季/04.mp4
/volume1/Videos/TV Series/御赐小仵作第二季/.04.mp4.fg.ed
/volume1/Videos/TV Series/御赐小仵作第二季/03.mp4
/volume1/Videos/TV Series/御赐小仵作第二季/.04.mp4.fg.op
/volume1/Videos/TV Series/御赐小仵作第二季/02.mp4
/volume1/Videos/TV Series/御赐小仵作第二季/.02.mp4.fg.op
/volume1/Videos/TV Series/御赐小仵作第二季/.02.mp4.fg.ed
/volume1/Videos/TV Series/御赐小仵作第二季/01.mp4
/volume1/Videos/TV Series/御赐小仵作第二季/.01.mp4.fg.op
/volume1/Videos/TV Series/御赐小仵作第二季/.03.mp4.fg.ed
/volume1/Videos/TV Series/御赐小仵作第二季/.03.mp4.fg.op
/volume1/Videos/TV Series/御赐小仵作第二季/.01.mp4.fg.ed
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E03.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E05.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E05.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi(1).mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E02.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E07.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E06.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E08.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/怪奇物语 第一季[全8集][简繁英字幕].Stranger.Things.S01.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi/Stranger.Things.S01E04.2016.NF.WEB-DL.2160p.HEVC.HDR.DDP-Xiaomi.mkv
/volume1/Videos/TV Series/Outlander Blood of My Blood/Season1/Outlander Blood Of My Blood S01E01 1080p 10bit WEBRip 6CH X265 HEVC-PSA[EZTVx.to].mkv
/volume1/Videos/TV Series/Outlander Blood of My Blood/Season1/Outlander Blood Of My Blood S01E02 1080p 10bit WEBRip 6CH X265 HEVC-PSA[EZTVx.to].mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E02 - 第 2 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E07 - 第 7 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E04 - 第 4 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E08 - 第 8 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E06 - 第 6 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E01 - 第 1 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E05 - 第 5 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/亢奋/第一季/Euphoria S01E03 - 第 3 集 - 2160p WEB-DL HDR H265 DDP 5.1.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E04.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E09.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E07.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E11.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E03.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E16.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E02.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E10.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E12.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E06.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E15.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E13.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E14.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E08.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E01.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/黑暗荣耀/黑暗荣耀S01E05.2160p.NF.WEB-DL.DDP5.1.Atmos.DV.HDR.HEVC-CEBEX.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E10 - 第 10 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E02 - 第 2 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E03 - 第 3 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E08 - 第 8 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E06 - 第 6 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E09 - 第 9 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E07 - 第 7 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E05 - 第 5 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E01 - 第 1 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/台风商社/第 1 季 - 1080p WEB-DL x264 AAC/Typhoon Family S01E04 - 第 4 集 - 1080p WEB-DL x264 AAC.mkv
/volume1/Videos/TV Series/月鳞绮纪/S01E05 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E11 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E03 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E07 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E12 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E14 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E04 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E13 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E02 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E06 4KHQ60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E08 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E01 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E10 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E15 4K60FPS.mp4
/volume1/Videos/TV Series/月鳞绮纪/S01E09 4KHQHDR60FPS.mp4
/volume1/Videos/TV Series/山河枕/36.mp4
/volume1/Videos/TV Series/山河枕/04.mp4
/volume1/Videos/TV Series/山河枕/21.mp4
/volume1/Videos/TV Series/山河枕/11.mp4
/volume1/Videos/TV Series/山河枕/14.mp4
/volume1/Videos/TV Series/山河枕/03.mp4
/volume1/Videos/TV Series/山河枕/13.mp4
/volume1/Videos/TV Series/山河枕/38.mp4
/volume1/Videos/TV Series/山河枕/20.mp4
/volume1/Videos/TV Series/山河枕/02.mp4
/volume1/Videos/TV Series/山河枕/05.mp4
/volume1/Videos/TV Series/山河枕/27.mp4
/volume1/Videos/TV Series/山河枕/17.mp4
/volume1/Videos/TV Series/山河枕/10.mp4
/volume1/Videos/TV Series/山河枕/24.mp4
/volume1/Videos/TV Series/山河枕/08.mp4
/volume1/Videos/TV Series/山河枕/16.mp4
/volume1/Videos/TV Series/山河枕/33.mp4
/volume1/Videos/TV Series/山河枕/25.mp4
/volume1/Videos/TV Series/山河枕/19.mp4
/volume1/Videos/TV Series/山河枕/15.mp4
/volume1/Videos/TV Series/山河枕/12.mp4
/volume1/Videos/TV Series/山河枕/40.mp4
/volume1/Videos/TV Series/山河枕/32.mp4
/volume1/Videos/TV Series/山河枕/18.mp4
/volume1/Videos/TV Series/山河枕/35.mp4
/volume1/Videos/TV Series/山河枕/06.mp4
/volume1/Videos/TV Series/山河枕/29.mp4
/volume1/Videos/TV Series/山河枕/22.mp4
/volume1/Videos/TV Series/山河枕/09.mp4
/volume1/Videos/TV Series/山河枕/01.mkv
/volume1/Videos/TV Series/山河枕/31.mp4
/volume1/Videos/TV Series/山河枕/30.mp4
/volume1/Videos/TV Series/山河枕/39.mp4
/volume1/Videos/TV Series/山河枕/26.mp4
/volume1/Videos/TV Series/山河枕/34.mp4
/volume1/Videos/TV Series/山河枕/23.mp4
/volume1/Videos/TV Series/山河枕/37.mp4
/volume1/Videos/TV Series/山河枕/07.mp4
/volume1/Videos/TV Series/山河枕/28.mp4
/volume1/Videos/TV Series/于氏王后/04.mp4
/volume1/Videos/TV Series/于氏王后/03.mp4
/volume1/Videos/TV Series/于氏王后/02.mp4
/volume1/Videos/TV Series/于氏王后/05.mp4
/volume1/Videos/TV Series/于氏王后/08.mp4
/volume1/Videos/TV Series/于氏王后/01.mp4
/volume1/Videos/TV Series/于氏王后/06.mp4
/volume1/Videos/TV Series/于氏王后/07.mp4
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 32.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 13.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 29.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 35.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 27.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 09.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 22.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 36.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 23.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 12.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 04.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 17.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 26.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 34.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 16.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 05.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 02.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 08.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 15.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 18.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 24.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 10.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 28.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 07.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 19.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 11.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 25.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 20.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 31.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 06.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 30.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 03.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 33.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 14.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 21.mkv
/volume1/Videos/TV Series/御赐小仵作/S01 4K EP 01.mkv
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E05.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E09.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E07.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E02.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E10.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E03.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E08.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E04.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E06.mp4
/volume1/Videos/TV Series/艾米丽在巴黎(第五季)/S05E01.mp4
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E03.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E09.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E02.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E10.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E08.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E05.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E07.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E04.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E06.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/我的王室死对头/S01/My.Royal.Nemesis.S01E01.2026.1080p.NF.WEB-DL.x264.AAC.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E11.Vengeance.Is.Mine.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E06.Best.Laid.Schemes.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E08.The.Foxs.Lair.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E07.Faith.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E04.La.Dame.Blanche.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E02.Not.In.Scotland.Anymore.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E01.Through.A.Glass.Darkly.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E09.Je.Suis.Prest.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E05.Untimely.Resurrection.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E03.Useful.Occupations.and.Deceptions.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E10.Prestonpans.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E13.Dragonfly.In.Amber.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season2/S02E12.The.Hail.Mary.1080p.WEB-DL.DD.5.1.H.265.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E04.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E03.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E10.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E13.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E06.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E01.BRAZiLiAN.1080p.WEB.H264-BRASTEMP.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E05.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E09.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E15.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E11.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E16.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E08.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E12.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E07.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E14.1080p.WEBRip.x265-KONTRAST.mkv
/volume1/Videos/TV Series/Outlander/Season1/Outlander.S01E02.BRAZiLiAN.1080p.WEB.H264-BRASTEMP.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E03.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E06.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E01.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E04.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E02.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第八季/权力的游戏.Game.of.Thrones.S08E05.2019.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E06.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E6.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E04.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E4.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E05.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E5.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E02.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E2.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E03.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E3.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E01.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E1.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E08.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E8.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E09.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E9.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E10.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E10.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第六季/Game.of.Thrones.S06E07.noHDR.2160p.22CH.26Subs.WEB.权力的游戏S6E7.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E05.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E02.1080p.BluRay.x264.DTS-WiKi .mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E06.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E08.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E04.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E01.1080p.BluRay.x264.DTS-WiKi.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E07.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E10.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E09.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第四季/Game.of.Thrones.S04E03.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E08.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E07.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E01.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E03.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E06.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E02.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E09.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E10.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E04.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第五季/Game.of.Thrones.S05E05.noHDR.2160p.22CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E04.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E09.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E02.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E07.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E05.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E06.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E01.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E10.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E08.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第三季/Game.of.Thrones.S03E03.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E2.noHDR.2160p.20CH.26Subs.权力的游戏.第一季.中英26国字幕.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E9.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E6.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E3.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E4.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E7.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E10.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E8.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E5.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第一季/Game.of.Thrones.S1E1.noHDR.2160p.20CH.26Subs.WEB.权力的游戏.第一季.中英26国字幕.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E01.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E02.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E07.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E06.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E04.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E05.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E03.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E08.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E10.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第二季/Game.of.Thrones.S02E09.noHDR.2160p.14CH.26Subs.WEB.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E03.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E05.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E02.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E01.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E04.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E07.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/权力的游戏/第七季/权力的游戏.Game.of.Thrones.S07E06.2017.2160p.Max.WEB-DL.DDP5.1.Atmos.H265.HDR.DV.2Audio-ZeroTV.mkv
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E08.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E03.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E01.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E05.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E04.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E07.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E02.mp4
/volume1/Videos/TV Series/斯巴达克斯：亚述家族Spartacus House of Ashur(2025)/斯巴达克斯：亚述家族S01E06.mp4
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E08 - 第 8 集 - 1080p WEB-DL H264 AAC 2.0.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E09 - 第 9 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E02 - 第 2 集 - 1080p WEB-DL H264 AAC 2.0.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E05 - 第 5 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E01 - 第 1 集 - 1080p WEB-DL H264 AAC 2.0.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E03 - 第 3 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/S01E10.1080p.WEB-DL.AAC2.0.H.264-BlackTV.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E07 - 第 7 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E06 - 第 6 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/权欲之巅(2026)/第 1 季 - 1080p WEB-DL H264 AAC 2.0/Climax S01E04 - 第 4 集 - 1080p WEB-DL H264 AAC.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E06.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E10.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E02.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E04.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E01.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E08.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E09.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E07.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E05.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/TV Series/龙之家族/第一季/House.of.the.Dragon.S01E03.2022.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-HHWEB.mkv
/volume1/Videos/Movies/长安的荔枝/The.Lychee.Road.2025.2160p.HQ.60fps.WEB-DL.HEVC.10bit.DTS5.1&DDP5.1-GyWEB.mp4
/volume1/Videos/Movies/猫和老鼠：星盘奇缘/猫和老鼠：星盘奇缘.mp4
/volume1/Videos/Movies/看不见的爱/Your.Eyes.Tell.2020.1080p.BluRay.x264.AAC5.1-[YTS.MX].mp4
'''

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
    ok = 0; bad = 0; skip = 0
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
        if not search_title or (not has_english(search_title) and not search_title):
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
