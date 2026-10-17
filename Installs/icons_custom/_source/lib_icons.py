import math

def circle(cx, cy, r, cw=True):
    s = 1 if cw else 0
    return (f"M{cx-r:.3f} {cy:.3f} A{r:.3f} {r:.3f} 0 1 {s} {cx+r:.3f} {cy:.3f} "
            f"A{r:.3f} {r:.3f} 0 1 {s} {cx-r:.3f} {cy:.3f} Z")

def capsule(x1, y1, x2, y2, w, cw=True):
    # Swapping the endpoints traverses the same shape the other way round, which
    # is what punches a hole under the non-zero fill rule.
    if not cw:
        x1, y1, x2, y2 = x2, y2, x1, y1
    r = w / 2.0
    dx, dy = x2 - x1, y2 - y1
    L = math.hypot(dx, dy) or 1e-6
    ux, uy = dx / L, dy / L
    px, py = -uy, ux
    a = (x1 + px*r, y1 + py*r); b = (x2 + px*r, y2 + py*r)
    c = (x2 - px*r, y2 - py*r); d = (x1 - px*r, y1 - py*r)
    return (f"M{a[0]:.3f} {a[1]:.3f} L{b[0]:.3f} {b[1]:.3f} "
            f"A{r:.3f} {r:.3f} 0 0 1 {c[0]:.3f} {c[1]:.3f} "
            f"L{d[0]:.3f} {d[1]:.3f} A{r:.3f} {r:.3f} 0 0 1 {a[0]:.3f} {a[1]:.3f} Z")

def ellipse(cx, cy, rx, ry, rot=0.0, cw=True):
    s = 1 if cw else 0
    a = math.radians(rot)
    def pt(t):
        x, y = rx*math.cos(t), ry*math.sin(t)
        return (cx + x*math.cos(a) - y*math.sin(a), cy + x*math.sin(a) + y*math.cos(a))
    p0, p1 = pt(math.pi), pt(0)
    return (f"M{p0[0]:.3f} {p0[1]:.3f} A{rx:.3f} {ry:.3f} {rot:.1f} 1 {s} {p1[0]:.3f} {p1[1]:.3f} "
            f"A{rx:.3f} {ry:.3f} {rot:.1f} 1 {s} {p0[0]:.3f} {p0[1]:.3f} Z")

def ering(cx, cy, rx, ry, w, rot=0.0):
    return ellipse(cx, cy, rx, ry, rot) + " " + ellipse(cx, cy, rx-w, ry-w, rot, cw=False)

def ring(cx, cy, r, w):
    return circle(cx, cy, r) + " " + circle(cx, cy, r-w, cw=False)

def poly(pts, cw=True):
    p = pts if cw else list(reversed(pts))
    return "M" + " L".join(f"{x:.3f} {y:.3f}" for x, y in p) + " Z"

def hexagon(cx, cy, r, rot=90, cw=True):
    return poly([(cx + r*math.cos(math.radians(rot + i*60)),
                  cy + r*math.sin(math.radians(rot + i*60))) for i in range(6)], cw)

def rrect(x, y, w, h, r, cw=True):
    """Rounded rectangle, as four lines and four arcs."""
    x2, y2 = x + w, y + h
    s = 1 if cw else 0
    pts = ([(x+r, y), (x2-r, y)], [(x2, y+r), (x2, y2-r)],
           [(x2-r, y2), (x+r, y2)], [(x, y2-r), (x, y+r)])
    if not cw:
        return rrect(x, y, w, h, r).replace('A', 'a#').replace('a#', 'A')  # unused
    d = f"M{x+r:.3f} {y:.3f} L{x2-r:.3f} {y:.3f} A{r} {r} 0 0 1 {x2:.3f} {y+r:.3f} "
    d += f"L{x2:.3f} {y2-r:.3f} A{r} {r} 0 0 1 {x2-r:.3f} {y2:.3f} "
    d += f"L{x+r:.3f} {y2:.3f} A{r} {r} 0 0 1 {x:.3f} {y2-r:.3f} "
    d += f"L{x:.3f} {y+r:.3f} A{r} {r} 0 0 1 {x+r:.3f} {y:.3f} Z"
    return d

def rrect_hole(x, y, w, h, r):
    """Same rectangle traversed the other way, to punch it out."""
    x2, y2 = x + w, y + h
    d = f"M{x+r:.3f} {y:.3f} A{r} {r} 0 0 0 {x:.3f} {y+r:.3f} "
    d += f"L{x:.3f} {y2-r:.3f} A{r} {r} 0 0 0 {x+r:.3f} {y2:.3f} "
    d += f"L{x2-r:.3f} {y2:.3f} A{r} {r} 0 0 0 {x2:.3f} {y2-r:.3f} "
    d += f"L{x2:.3f} {y+r:.3f} A{r} {r} 0 0 0 {x2-r:.3f} {y:.3f} Z"
    return d

def rframe(x, y, w, h, r, t):
    return rrect(x, y, w, h, r) + " " + rrect_hole(x+t, y+t, w-2*t, h-2*t, max(r-t, 0.3))

def chevron(x, y, s, w=1.3):
    return capsule(x, y-s, x+s*0.8, y, w) + " " + capsule(x+s*0.8, y, x, y+s, w)

def arcband(cx, cy, r, w, a0, a1, cw=True):
    """A slice of a ring, between two angles (degrees)."""
    a0r, a1r = math.radians(a0), math.radians(a1)
    ro, ri = r, r - w
    large = 1 if abs(a1-a0) > 180 else 0
    p1 = (cx+ro*math.cos(a0r), cy+ro*math.sin(a0r))
    p2 = (cx+ro*math.cos(a1r), cy+ro*math.sin(a1r))
    p3 = (cx+ri*math.cos(a1r), cy+ri*math.sin(a1r))
    p4 = (cx+ri*math.cos(a0r), cy+ri*math.sin(a0r))
    return (f"M{p1[0]:.3f} {p1[1]:.3f} A{ro:.3f} {ro:.3f} 0 {large} 1 {p2[0]:.3f} {p2[1]:.3f} "
            f"L{p3[0]:.3f} {p3[1]:.3f} A{ri:.3f} {ri:.3f} 0 {large} 0 {p4[0]:.3f} {p4[1]:.3f} Z")

def rot_rect(cx, cy, w, h, ang, cw=True):
    """A rectangle rotated about its centre."""
    a = math.radians(ang)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for dx, dy in ((-w/2,-h/2),(w/2,-h/2),(w/2,h/2),(-w/2,h/2)):
        pts.append((cx + dx*ca - dy*sa, cy + dx*sa + dy*ca))
    return poly(pts, cw)

def rot_frame(cx, cy, w, h, ang, t):
    return rot_rect(cx, cy, w, h, ang) + " " + rot_rect(cx, cy, w-2*t, h-2*t, ang, cw=False)

def rot_capsule(cx, cy, length, w, ang):
    a = math.radians(ang)
    dx, dy = math.cos(a)*length/2, math.sin(a)*length/2
    return capsule(cx-dx, cy-dy, cx+dx, cy+dy, w)
