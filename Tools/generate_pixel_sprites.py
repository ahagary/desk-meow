#!/usr/bin/env python3
"""Draw a reproducible 64 px tabby sprite set with real pose changes.

Every exported PNG is a distinct drawing.  The character uses one palette,
one coordinate grid and a fixed ground line (y=59) across all clips.
"""
from __future__ import annotations

import json
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Assets" / "pixel"
OUT.mkdir(parents=True, exist_ok=True)
W = H = 64
GROUND = 59

PAL = {
    "ink": (46, 31, 27, 255),
    "stripe": (83, 50, 36, 255),
    "shade": (119, 73, 44, 255),
    "fur": (177, 113, 64, 255),
    "gold": (216, 153, 83, 255),
    "light": (238, 188, 112, 255),
    "cream": (247, 217, 160, 255),
    "ivory": (255, 241, 202, 255),
    "pink": (188, 113, 107, 255),
    "eye": (178, 190, 72, 255),
    "pupil": (32, 37, 27, 255),
    "white": (255, 250, 226, 255),
    "ball": (203, 86, 74, 255),
    "ballLight": (255, 177, 116, 255),
    "yarn": (149, 101, 149, 255),
    "yarnLight": (218, 164, 198, 255),
    "butterfly": (244, 193, 80, 255),
    "paper": (255, 242, 202, 255),
    "poop": (111, 68, 42, 255),
}


class Canvas:
    def __init__(self):
        self.p = bytearray(W * H * 4)

    def px(self, x, y, color):
        x, y = round(x), round(y)
        if 0 <= x < W and 0 <= y < H:
            self.p[(y * W + x) * 4:(y * W + x) * 4 + 4] = PAL[color]

    def rect(self, x, y, w, h, color):
        for yy in range(round(y), round(y + h)):
            for xx in range(round(x), round(x + w)):
                self.px(xx, yy, color)

    def ellipse(self, x, y, w, h, color, outline=None):
        if outline:
            self.ellipse(x - 1, y - 1, w + 2, h + 2, outline)
        cx, cy = x + w / 2, y + h / 2
        for yy in range(math.floor(y), math.ceil(y + h)):
            for xx in range(math.floor(x), math.ceil(x + w)):
                if ((xx + .5 - cx) / (w / 2)) ** 2 + ((yy + .5 - cy) / (h / 2)) ** 2 <= 1:
                    self.px(xx, yy, color)

    def poly(self, points, color):
        low = math.floor(min(y for _, y in points))
        high = math.ceil(max(y for _, y in points))
        for yy in range(low, high + 1):
            xs = []
            for i, (x1, y1) in enumerate(points):
                x2, y2 = points[(i + 1) % len(points)]
                if (y1 <= yy + .5 < y2) or (y2 <= yy + .5 < y1):
                    xs.append(x1 + (yy + .5 - y1) * (x2 - x1) / (y2 - y1))
            xs.sort()
            for a, b in zip(xs[::2], xs[1::2]):
                for xx in range(math.ceil(a), math.ceil(b)):
                    self.px(xx, yy, color)

    def line(self, x1, y1, x2, y2, color, width=1):
        steps = max(1, math.ceil(max(abs(x2 - x1), abs(y2 - y1)) * 2))
        for i in range(steps + 1):
            t = i / steps
            cx, cy = x1 + (x2 - x1) * t, y1 + (y2 - y1) * t
            for yy in range(math.floor(cy - width / 2), math.ceil(cy + width / 2) + 1):
                for xx in range(math.floor(cx - width / 2), math.ceil(cx + width / 2) + 1):
                    if (xx - cx) ** 2 + (yy - cy) ** 2 <= (width / 2 + .25) ** 2:
                        self.px(xx, yy, color)

    def path(self, points, color, width):
        for a, b in zip(points, points[1:]):
            self.line(*a, *b, color, width)

    def shift_up(self, amount):
        if amount <= 0:
            return
        row = W * 4
        self.p[:(H - amount) * row] = self.p[amount * row:]
        self.p[(H - amount) * row:] = bytes(amount * row)

    def png(self, target):
        raw = b"".join(b"\0" + self.p[y * W * 4:(y + 1) * W * 4] for y in range(H))

        def chunk(kind, payload):
            body = kind + payload
            return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

        target.write_bytes(b"\x89PNG\r\n\x1a\n" +
                           chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0)) +
                           chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def tail(c, bend=0, high=0, curled=False):
    if curled:
        pts = [(43, 51), (51, 51), (56, 48), (57 + bend, 43), (54 + bend, 39)]
    else:
        pts = [(44, 48), (50, 44), (54 + bend, 36), (55 + bend, 27 - high),
               (53 + bend, 20 - high), (48 + bend, 18 - high)]
    c.path(pts, "ink", 8)
    c.path(pts, "fur", 6)
    for i in (1, 2, 3):
        x, y = pts[i]
        c.line(x - 2, y - 2, x + 2, y + 2, "stripe", 2)
    c.rect(47 + bend, 16 - high if not curled else 38, 3, 2, "light")


def torso(c, sit=False, breath=0, lean=0, back=False):
    if sit:
        c.ellipse(23 + lean, 31 - breath, 27, 26 + breath, "fur", "ink")
        c.ellipse(38 + lean, 43, 13, 15, "shade", "ink")
        c.ellipse(24 + lean, 35, 16, 20 + breath, "cream")
        for x, y in ((37, 35), (41, 39), (43, 44), (43, 50)):
            c.line(x + lean, y, x + 4 + lean, y + 3, "stripe", 2)
    else:
        c.ellipse(18 + lean, 30 - breath, 33, 26 + breath, "fur", "ink")
        c.ellipse(38 + lean, 41, 13, 16, "shade", "ink")
        c.ellipse(18 + lean, 34, 17, 19 + breath, "cream")
        for x, y in ((36, 32), (40, 35), (43, 39), (44, 44)):
            c.line(x + lean, y, x + 5 + lean, y + 4, "stripe", 2)
    c.line(19 + lean, 47, 31 + lean, 54, "stripe", 2)
    c.line(20 + lean, 42, 29 + lean, 49, "stripe", 2)
    if back:
        c.ellipse(18 + lean, 30 - breath, 31, 24 + breath, "fur", "ink")
        for x in (23, 29, 35, 41):
            c.line(x + lean, 33, x + 4 + lean, 51, "stripe", 3)


def legs(c, sit=False, step=0, reach=0, jump=0, lean=0):
    if sit:
        c.ellipse(17 + lean, 54 - jump, 14, 5, "gold", "ink")
        c.ellipse(35 + lean, 54 - jump, 14, 5, "gold", "ink")
        c.line(26 + lean, 44 - jump, 25 + lean, 55 - jump, "fur", 8)
        c.line(37 + lean, 44 - jump, 40 + lean, 55 - jump, "fur", 8)
    else:
        c.line(46 + lean, 45 - jump, 46 + lean - step, 54 - jump, "shade", 8)
        c.ellipse(41 + lean - step, 53 - jump, 11, 6, "gold", "ink")
        c.line(36 + lean, 44 - jump, 38 + lean + step, 54 - jump, "fur", 8)
        c.ellipse(32 + lean + step, 53 - jump, 12, 6, "gold", "ink")
        c.line(24 + lean, 42 - jump, 23 + lean - step, 54 - jump, "fur", 9)
        c.ellipse(18 + lean - step, 53 - jump, 12, 6, "gold", "ink")
    if reach:
        x, y = 16 + lean - reach * 2, 51 - reach * 4 - jump
        c.line(23 + lean, 42 - jump, x + 4, y + 2, "ink", 9)
        c.line(23 + lean, 42 - jump, x + 4, y + 2, "fur", 7)
        c.ellipse(x, y, 9, 6, "gold", "ink")
        c.line(x + 2, y + 4, x + 2, y + 5, "stripe")
    elif sit:
        c.ellipse(19 + lean, 54 - jump, 11, 5, "gold", "ink")
    for x in (23 + lean - step, 37 + lean + step):
        c.line(x, 55 - jump, x, 57 - jump, "stripe")


def head(c, dx=0, dy=0, blink=False, look=0, mouth=0,
         back=False, profile=False, ears=0):
    x, y = dx, dy
    if back:
        c.poly([(12+x, 20+y), (15+x, 8+y+ears), (25+x, 17+y)], "ink")
        c.poly([(32+x, 17+y), (42+x, 8+y+ears), (44+x, 23+y)], "ink")
        c.ellipse(10+x, 16+y, 35, 29, "fur", "ink")
        for sx in (20, 27, 34):
            c.line(sx+x, 19+y, sx+x+1, 31+y, "stripe", 3)
        return
    if profile:
        c.poly([(16+x, 22+y), (17+x, 9+y+ears), (29+x, 19+y)], "ink")
        c.poly([(20+x, 18+y), (21+x, 13+y+ears), (27+x, 20+y)], "pink")
        c.poly([(33+x, 19+y), (39+x, 10+y+ears), (44+x, 25+y)], "ink")
        c.poly([(37+x, 20+y), (39+x, 14+y+ears), (41+x, 23+y)], "pink")
        c.ellipse(14+x, 18+y, 33, 26, "fur", "ink")
        c.ellipse(19+x, 21+y, 25, 18, "gold")
        for sx in (24, 31, 38):
            c.line(sx+x, 20+y, sx+2+x, 28+y, "stripe", 2)
        c.ellipse(34+x, 31+y, 15, 11, "cream")
        if blink:
            c.line(36+x, 29+y, 42+x, 30+y, "stripe", 2)
        else:
            c.ellipse(35+x, 26+y, 8, 9, "ink")
            c.ellipse(37+x, 27+y, 5, 6, "eye")
            c.rect(39+x, 28+y, 2, 5, "pupil")
            c.px(37+x, 28+y, "white")
        c.poly([(44+x, 34+y), (49+x, 35+y), (45+x, 38+y)], "pink")
        c.line(44+x, 39+y, 46+x, 40+y, "stripe")
        for wy in (35, 38, 41):
            c.line(44+x, wy+y, 55+x, wy-2+y, "ivory")
        return
    # Ears and large head are drawn as discrete shapes, never transformed as a bitmap.
    c.poly([(11+x, 23+y), (14+x, 7+y+ears), (25+x, 17+y)], "ink")
    c.poly([(14+x, 20+y), (16+x, 11+y+ears), (23+x, 18+y)], "pink")
    c.poly([(31+x, 18+y), (41+x, 8+y+ears), (44+x, 24+y)], "ink")
    c.poly([(35+x, 19+y), (40+x, 12+y+ears), (41+x, 22+y)], "pink")
    c.ellipse(10+x, 16+y, 35, 29, "fur", "ink")
    c.ellipse(13+x, 19+y, 27, 21, "gold")
    c.poly([(25+x, 18+y), (28+x, 18+y), (27+x, 27+y)], "stripe")
    c.poly([(19+x, 18+y), (22+x, 18+y), (24+x, 26+y)], "stripe")
    c.poly([(32+x, 18+y), (35+x, 19+y), (31+x, 26+y)], "stripe")
    for sy in (27, 31):
        c.line(11+x, sy+y, 16+x, sy+2+y, "stripe", 2)
        c.line(39+x, sy+2+y, 44+x, sy+y, "stripe", 2)
    c.ellipse(15+x, 31+y, 24, 12, "cream")
    c.ellipse(18+x, 34+y, 18, 7, "ivory")
    for ex in (20, 33):
        if blink:
            c.line(ex-2+x, 29+y, ex+3+x, 29+y, "stripe", 2)
            c.px(ex+4+x, 28+y, "ink")
        else:
            c.ellipse(ex-4+x, 25+y, 9, 10, "ink")
            c.ellipse(ex-2+x, 26+y, 6, 7, "eye")
            c.rect(ex+look+x, 27+y, 2, 6, "pupil")
            c.px(ex-1+x, 27+y, "white")
    c.poly([(26+x, 34+y), (32+x, 34+y), (29+x, 38+y)], "pink")
    if mouth:
        c.ellipse(27+x, 38+y, 5, 3 + mouth, "ink")
        c.rect(28+x, 40+y, 3, 1, "pink")
    else:
        c.line(29+x, 38+y, 29+x, 40+y, "stripe")
        c.line(25+x, 40+y, 29+x, 41+y, "stripe")
        c.line(29+x, 41+y, 33+x, 40+y, "stripe")
    for wy, end in ((34, 9), (37, 7), (40, 9)):
        c.line(18+x, wy+y, end+x, wy-2+y, "ivory")
        c.line(37+x, wy+y, 48+x, wy-2+y, "ivory")


def draw(spec):
    c = Canvas()
    mode = spec.get("mode", "stand")
    sit = mode in ("sit", "eat")
    back = mode in ("back", "poop")
    lean = spec.get("lean", 0)
    jump = spec.get("jump", 0)
    tail(c, spec.get("tail", 0), spec.get("tailHigh", 0),
         sit or back or mode == "profile")
    torso(c, sit=sit, breath=spec.get("breath", 0), lean=lean, back=back)
    legs(c, sit=sit, step=spec.get("step", 0), reach=spec.get("reach", 0),
         jump=min(jump, 2), lean=lean)
    head(c, dx=spec.get("headX", 0), dy=spec.get("headY", 0),
         blink=spec.get("blink", False), look=spec.get("look", 0),
         mouth=spec.get("mouth", 0), back=back, profile=mode == "profile",
         ears=spec.get("ears", 0))
    if not back:
        c.line(41 + lean, 45, 47 + lean, 49, "stripe", 2)
        c.line(34 + lean, 48, 41 + lean, 53, "stripe", 2)
    if jump:
        c.shift_up(jump)
    if mode == "play":
        bx = spec.get("ballX", 6)
        by = spec.get("ballY", 53)
        c.ellipse(bx, by, 8, 8, "ball", "ink")
        c.rect(bx + 2, by + 1, 3, 2, "ballLight")
    if mode == "yarn":
        bx = spec.get("ballX", 6)
        by = spec.get("ballY", 53)
        c.ellipse(bx, by, 9, 8, "yarn", "ink")
        c.line(bx + 2, by + 2, bx + 7, by + 5, "yarnLight")
        c.line(bx + 2, by + 5, bx + 6, by + 2, "yarnLight")
        c.path([(bx + 8, by + 4), (bx + 12, by + 2), (bx + 17, by + 3)], "yarn", 1)
    if mode == "butterfly":
        bx = spec.get("butterflyX", 7)
        by = spec.get("butterflyY", 20)
        wing = spec.get("wing", 0)
        c.ellipse(bx - 3 - wing, by - 2, 4 + wing, 4, "butterfly", "ink")
        c.ellipse(bx + 1, by - 2, 4 + wing, 4, "butterfly", "ink")
        c.rect(bx, by - 1, 1, 5, "stripe")
        c.line(bx, by - 2, bx - 2, by - 4, "stripe")
        c.line(bx + 1, by - 2, bx + 3, by - 4, "stripe")
    if mode == "eat":
        card = spec.get("card", 0)
        if card:
            c.rect(5 + card * 4, 42 - card * 2, 10, 7, "ink")
            c.rect(6 + card * 4, 43 - card * 2, 8, 5, "paper")
            c.line(8 + card * 4, 45 - card * 2, 13 + card * 4, 45 - card * 2, "shade")
    if mode == "poop":
        size = spec.get("poopSize", 0)
        if size:
            c.ellipse(46, 55 - size, 6 + size, 3 + size, "poop", "ink")
            c.rect(48, 56 - size, 3, 1, "gold")
    if spec.get("sparkle"):
        for sx, sy in ((7, 15), (50, 12)):
            c.line(sx-2, sy, sx+2, sy, "light")
            c.line(sx, sy-2, sx, sy+2, "light")
    return c


CLIPS = {
    "Idle": (True, [
        ({"tail": -1}, .35), ({"tail": 0, "breath": 1}, .35),
        ({"tail": 1, "breath": 1}, .35), ({"tail": 2}, .35),
        ({"tail": 1}, .35), ({"tail": 0, "blink": True}, .12),
        ({"tail": -1, "breath": 1}, .35), ({"tail": -2}, .35),
    ]),
    "IdleAccent": (False, [
        ({"headY": 0}, .10), ({"headY": -1, "ears": -1}, .12),
        ({"headY": -2, "look": -1}, .16), ({"headY": -1}, .12),
    ]),
    "Hover": (True, [
        ({"headX": 0, "tailHigh": 0}, .10),
        ({"headX": -1, "headY": -1, "tailHigh": 1}, .10),
        ({"headX": -2, "headY": -1, "reach": 1, "tailHigh": 2}, .10),
        ({"headX": -3, "headY": 0, "reach": 2, "tailHigh": 3, "tail": -1}, .12),
        ({"headX": -2, "headY": 0, "reach": 2, "tailHigh": 3, "tail": 1}, .12),
        ({"headX": -3, "headY": 0, "reach": 2, "tailHigh": 3, "tail": -1, "blink": True}, .10),
        ({"headX": -2, "headY": -1, "reach": 2, "tailHigh": 2}, .10),
        ({"headX": -1, "headY": -1, "reach": 1, "tailHigh": 1, "tail": -1}, .10),
        ({"headX": 0, "tail": 1}, .10),
    ]),
    "EnterAwait": (False, [
        ({}, .10), ({"breath": 1, "headY": 1}, .10),
        ({"mode": "sit", "headY": 2}, .12), ({"mode": "sit"}, .10),
    ]),
    "AwaitInput": (True, [
        ({"mode": "sit"}, .40), ({"mode": "sit", "breath": 1}, .40),
        ({"mode": "sit", "breath": 1, "tail": 1}, .40),
        ({"mode": "sit", "tail": 2}, .40),
        ({"mode": "sit", "blink": True, "tail": 1}, .12),
        ({"mode": "sit", "tail": -1}, .40),
    ]),
    "ExitAwait": (False, [
        ({"mode": "sit"}, .10), ({"mode": "sit", "headY": 2}, .10),
        ({"breath": 1, "headY": 1}, .12), ({}, .10),
    ]),
    "Play": (False, [
        ({"mode": "play", "ballX": 8, "look": -1}, .18),
        ({"mode": "play", "ballX": 10, "reach": 1, "headY": 1}, .12),
        ({"mode": "play", "ballX": 14, "reach": 2, "headY": 1}, .12),
        ({"mode": "play", "ballX": 20, "ballY": 50, "reach": 2}, .12),
        ({"mode": "play", "ballX": 27, "ballY": 48, "reach": 1, "headY": -1}, .12),
        ({"mode": "play", "ballX": 34, "ballY": 51, "look": 1}, .12),
        ({"mode": "play", "ballX": 42, "ballY": 53, "look": 1}, .16),
        ({"mode": "play", "ballX": 49, "ballY": 53}, .16),
    ]),
    "PlayYarn": (False, [
        ({"mode": "yarn", "ballX": 7, "look": -1}, .16),
        ({"mode": "yarn", "ballX": 9, "reach": 1, "headY": 1}, .12),
        ({"mode": "yarn", "ballX": 13, "reach": 2, "headY": 1}, .12),
        ({"mode": "yarn", "ballX": 19, "ballY": 51, "reach": 2}, .12),
        ({"mode": "yarn", "ballX": 24, "ballY": 49, "reach": 1}, .12),
        ({"mode": "yarn", "ballX": 31, "ballY": 50, "look": 1}, .12),
        ({"mode": "yarn", "ballX": 39, "ballY": 53, "headX": 1}, .14),
        ({"mode": "yarn", "ballX": 45, "ballY": 53, "blink": True}, .16),
    ]),
    "PlayButterfly": (False, [
        ({"mode": "butterfly", "butterflyX": 5, "butterflyY": 28,
          "headY": -1, "look": -1}, .12),
        ({"mode": "butterfly", "butterflyX": 7, "butterflyY": 24,
          "headY": -1, "wing": 1, "look": -1}, .10),
        ({"mode": "butterfly", "butterflyX": 4, "butterflyY": 20,
          "headY": -1, "reach": 1, "look": -1}, .10),
        ({"mode": "butterfly", "butterflyX": 8, "butterflyY": 16,
          "headY": -1, "reach": 2, "wing": 1, "look": -1}, .10),
        ({"mode": "butterfly", "butterflyX": 5, "butterflyY": 12,
          "headY": -1, "reach": 2, "look": -1}, .10),
        ({"mode": "butterfly", "butterflyX": 9, "butterflyY": 10,
          "headY": -1, "reach": 1, "wing": 1, "look": -1}, .10),
        ({"mode": "butterfly", "butterflyX": 6, "butterflyY": 7,
          "headY": -1, "look": -1}, .12),
        ({"mode": "butterfly", "butterflyX": 10, "butterflyY": 5,
          "headY": -1, "wing": 1, "look": -1}, .14),
    ]),
    "Roam": (False, [
        ({"step": -2, "headX": -1, "tail": -1}, .12),
        ({"step": -1, "headX": -1, "breath": 1}, .12),
        ({"step": 0, "headX": 0}, .12),
        ({"step": 1, "headX": 1, "breath": 1}, .12),
        ({"step": 2, "headX": 1, "tail": 1}, .12),
        ({"step": 1, "headX": 0}, .12),
    ]),
    "FeedStart": (False, [
        ({"mode": "sit", "look": -1}, .10),
        ({"mode": "sit", "headX": -1, "headY": 1, "look": -1}, .10),
        ({"mode": "eat", "headX": -2, "reach": 1, "card": 1}, .12),
    ]),
    "Eat": (False, [
        ({"mode": "eat", "headX": -2, "reach": 2, "card": 2, "mouth": 2}, .10),
        ({"mode": "eat", "headX": -1, "reach": 1, "card": 3, "mouth": 1}, .09),
        ({"mode": "eat", "headX": 0, "mouth": 2}, .09),
        ({"mode": "eat", "headY": 1, "mouth": 1}, .09),
        ({"mode": "eat", "headY": -1, "mouth": 2}, .09),
        ({"mode": "eat", "headY": 0, "mouth": 0}, .10),
    ]),
    "Celebrate": (False, [
        ({"mode": "sit", "headY": 2}, .09),
        ({"jump": 2, "headY": -1, "sparkle": True}, .10),
        ({"jump": 5, "headY": -2, "sparkle": True}, .11),
        ({"jump": 3, "headY": -1, "sparkle": True}, .10),
        ({"jump": 0, "headY": 1}, .10),
    ]),
    "TurnBack": (False, [
        ({"headX": 1, "look": 1}, .12),
        ({"mode": "profile", "headX": 1, "tail": 1}, .12),
        ({"mode": "profile", "headX": 2, "tail": 2, "blink": True}, .10),
        ({"mode": "back", "tail": 1}, .15),
    ]),
    "Poop": (False, [
        ({"mode": "poop", "headY": 1}, .13),
        ({"mode": "poop", "headY": 2, "poopSize": 1}, .13),
        ({"mode": "poop", "headY": 1, "poopSize": 2}, .13),
        ({"mode": "poop", "poopSize": 3}, .15),
    ]),
    "Proud": (False, [
        ({"mode": "back", "tail": -1}, .12),
        ({"mode": "back", "tail": 1}, .12),
        ({"mode": "profile", "headX": 1, "tail": 2}, .12),
        ({"headX": 1, "tail": 2, "sparkle": True}, .14),
        ({"tail": 0, "sparkle": True}, .18),
    ]),
}


def main():
    manifest = {"canvas": [W, H], "clips": {}}
    for name, (loop, frames) in CLIPS.items():
        entries = []
        for index, (spec, duration) in enumerate(frames):
            filename = f"pixel-{name.lower()}-{index:02}.png"
            draw(spec).png(OUT / filename)
            entries.append({"file": f"pixel/{filename}", "duration": duration,
                            "anchor": [32, GROUND]})
        manifest["clips"][name] = {"loop": loop, "provisional": False,
                                     "frames": entries}
    (ROOT / "Assets" / "pet-animations-pixel.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"wrote {sum(len(x[1]) for x in CLIPS.values())} distinct 64x64 frames")


if __name__ == "__main__":
    main()
